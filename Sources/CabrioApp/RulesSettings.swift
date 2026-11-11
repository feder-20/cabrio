import SwiftUI
import CabrioDomain

struct RulesSettings: View {
    @ObservedObject var model: RulesModel
    @State private var editing: Rule?
    @State private var confirmRun: (Rule, [URL])?
    @State private var confirmApprove: (Rule, [URL])?

    var body: some View {
        Form {
            Section {
                Toggle(L("Aplicar reglas de carpetas"), isOn: Binding(get: { model.masterEnabled }, set: { model.setMaster($0) }))
                Text(L("Cabrio vigila las carpetas de tus reglas y actúa solo. Nada se borra de forma permanente: lo máximo es la Papelera, y todo se puede deshacer."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Reglas")) {
                if model.rules.isEmpty {
                    Text(L("Todavía no hay reglas. Crea una a partir de una plantilla.")).foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.setEnabled(rule, $0) })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).fontWeight(.medium)
                            Text(RulesModel.summary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if rule.requiresApproval && !rule.isApproved {
                                Text(L("Pendiente de confirmar: no actuará sola hasta que la apruebes."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if rule.requiresApproval && !rule.isApproved {
                            Button(L("Aprobar…")) { Task { confirmApprove = (rule, await model.preview(rule)) } }.font(.caption)
                        }
                        Button(L("Ejecutar ahora")) { Task { confirmRun = (rule, await model.preview(rule)) } }.font(.caption)
                        Button { editing = rule } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                        Button { model.delete(rule) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
                Menu(L("Nueva regla")) {
                    ForEach(Array(RulesModel.presets().enumerated()), id: \.offset) { _, p in
                        Button(p.title) { editing = Rule(name: p.rule.name, folder: p.rule.folder, condition: p.rule.condition, actions: p.rule.actions) }
                    }
                    Divider()
                    Button(L("En blanco")) {
                        editing = Rule(name: L("Mi regla"), folder: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                                       condition: RuleCondition(), actions: [])
                    }
                }.fixedSize()
            }
            Section(L("Actividad reciente")) {
                if model.activity.isEmpty { Text(L("Aún no han actuado reglas.")).foregroundStyle(.secondary) }
                ForEach(model.activity) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if case .folderRule(let name) = entry.operation { Text(name).font(.caption.weight(.medium)) }
                            Text(entry.inputs.first?.lastPathComponent ?? "").font(.caption).lineLimit(1).truncationMode(.middle)
                            Text(entry.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Deshacer")) { model.undo(entry) }.font(.caption)
                    }
                }
            }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in RuleEditor(model: model, rule: rule) { editing = nil } }
        .alert(L("¿Ejecutar la regla ahora?"), isPresented: Binding(get: { confirmRun != nil }, set: { if !$0 { confirmRun = nil } })) {
            Button(L("Ejecutar")) {
                if let (r, _) = confirmRun {
                    // Ya vio cuántos archivos afecta: esta confirmación también aprueba la regla.
                    if r.requiresApproval { model.approve(r) }
                    Task { _ = await model.runNow(r) }
                }
            }
            Button(L("Cancelar"), role: .cancel) {}
        } message: {
            let files = confirmRun?.1 ?? []
            Text(files.isEmpty ? L("Ahora mismo no hay archivos que coincidan.")
                 : L("Afectará a %d archivos, por ejemplo: %@. Podrás deshacerlo.", files.count, files.prefix(3).map(\.lastPathComponent).joined(separator: ", ")))
        }
        .alert(L("¿Aprobar que la regla actúe sola?"), isPresented: Binding(get: { confirmApprove != nil }, set: { if !$0 { confirmApprove = nil } })) {
            Button(L("Aprobar")) { if let (r, _) = confirmApprove { model.approve(r) } }
            Button(L("Cancelar"), role: .cancel) {}
        } message: {
            let files = confirmApprove?.1 ?? []
            Text(files.isEmpty ? L("Ahora mismo no hay archivos que coincidan. Cuando lleguen, la regla actuará sola y podrás deshacerlo.")
                 : L("Ahora mismo afectaría a %d archivos, por ejemplo: %@. A partir de aquí actuará sola; podrás deshacerlo.", files.count, files.prefix(3).map(\.lastPathComponent).joined(separator: ", ")))
        }
        .onAppear { Task { await model.refreshActivity() } }
    }
}

struct RuleEditor: View {
    @ObservedObject var model: RulesModel
    @State var rule: Rule
    var close: () -> Void

    @State private var extensions = ""
    @State private var names = ""
    @State private var useAge = false
    @State private var days = 30
    @State private var useSize = false
    @State private var megabytes = 50.0
    @State private var actionKind = 0          // 0 mover, 1 papelera, 2 convertir
    @State private var destination: URL?
    @State private var subfolder = Subfolder.none
    @State private var convertFormat = ImageFormat.jpg
    @State private var testResult: String?

    private static let kinds: [(FileKind, String)] = [
        (.image, "Imágenes"), (.pdf, "PDF"), (.video, "Video"), (.audio, "Audio"), (.archive, "Comprimidos"),
        (.officeDocument, "Documentos"), (.other, "Otros"),
    ]

    var body: some View {
        let built = build()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Regla de carpeta")).font(.headline)
                TextField(L("Nombre"), text: $rule.name).textFieldStyle(.roundedBorder)
                HStack {
                    Text(L("Carpeta vigilada")); Spacer()
                    Text(rule.folder.lastPathComponent).foregroundStyle(.secondary)
                    Button(L("Elegir…")) {
                        if let (u, b) = RulesModel.pickFolder(start: rule.folder, prompt: L("Vigilar")) {
                            if let error = RulesModel.folderError(u) { testResult = error } else { rule.folder = u; rule.bookmark = b; testResult = nil }
                        }
                    }
                }
                GroupBox(L("Cuando llegue un archivo que…")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Sea de tipo")).font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)) {
                            ForEach(Self.kinds, id: \.0) { kind, title in
                                Toggle(L(title), isOn: Binding(get: { rule.condition.kinds.contains(kind) },
                                                               set: { if $0 { rule.condition.kinds.insert(kind) } else { rule.condition.kinds.remove(kind) } }))
                                    .font(.caption)
                            }
                        }
                        TextField(L("Extensiones: dmg, pkg"), text: $extensions).textFieldStyle(.roundedBorder)
                        TextField(L("El nombre contiene: factura, recibo"), text: $names).textFieldStyle(.roundedBorder)
                        HStack { Toggle(L("Tenga más de"), isOn: $useAge); Stepper("\(days) " + L("días"), value: $days, in: 1...3650).disabled(!useAge) }
                        HStack { Toggle(L("Pese más de"), isOn: $useSize); TextField("", value: $megabytes, format: .number).labelsHidden().frame(width: 60).disabled(!useSize); Text("MB") }
                    }.padding(6)
                }
                GroupBox(L("Hacer esto")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $actionKind) {
                            Text(L("Mover a una carpeta")).tag(0)
                            Text(L("Enviar a la Papelera")).tag(1)
                            Text(L("Convertir imagen")).tag(2)
                        }.labelsHidden().pickerStyle(.segmented)
                        switch actionKind {
                        case 0:
                            HStack {
                                Text(destination?.path ?? L("Sin destino")).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("Elegir…")) { if let (u, _) = RulesModel.pickFolder(start: destination, prompt: L("Mover aquí")) { destination = u } }
                            }
                            Picker(L("Subcarpeta"), selection: $subfolder) {
                                Text(L("Ninguna")).tag(Subfolder.none)
                                Text(L("Por año")).tag(Subfolder.byYear)
                                Text(L("Por mes")).tag(Subfolder.byMonth)
                                Text(L("Por tipo")).tag(Subfolder.byKind)
                            }
                        case 1:
                            Text(L("Los archivos irán a la Papelera, de donde puedes recuperarlos, o con «Deshacer». Nunca se borran de forma permanente."))
                                .font(.caption).foregroundStyle(.orange)
                        default:
                            Picker(L("Formato"), selection: $convertFormat) { ForEach(ImageFormat.allCases, id: \.self) { Text($0.fileExtension.uppercased()).tag($0) } }
                                .pickerStyle(.segmented)
                            Text(L("Se crea una copia convertida; el original se conserva.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(L("Probar")) { Task { testResult = await test(built) } }.disabled(built == nil)
                    Spacer()
                    Button(L("Cancelar")) { close() }
                    Button(L("Guardar")) { if let r = built { if model.save(r) { close() } else { testResult = model.message } } }
                        .buttonStyle(.cabrioPrimary).disabled(built == nil)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        extensions = rule.condition.extensions.joined(separator: ", ")
        names = rule.condition.nameContains.joined(separator: ", ")
        if let d = rule.condition.olderThanDays { useAge = true; days = d }
        if let b = rule.condition.largerThanBytes { useSize = true; megabytes = Double(b) / 1_000_000 }
        switch rule.actions.first {
        case .moveTo(let f, let s)?: actionKind = 0; destination = f; subfolder = s
        case .moveToTrash?: actionKind = 1
        case .convertImage(let fmt)?: actionKind = 2; convertFormat = fmt
        case nil: actionKind = 0
        }
    }

    /// La regla tal como quedaría; nil si le falta algo (nombre, criterios o destino).
    private func build() -> Rule? {
        var r = rule
        r.condition = RuleCondition(kinds: rule.condition.kinds,
                                    extensions: extensions.split(separator: ",").map(String.init),
                                    nameContains: names.split(separator: ",").map(String.init),
                                    olderThanDays: useAge ? days : nil,
                                    largerThanBytes: useSize ? Int64(megabytes * 1_000_000) : nil)
        switch actionKind {
        case 0: guard let destination else { return nil }; r.actions = [.moveTo(folder: destination, subfolder: subfolder)]
        case 1: r.actions = [.moveToTrash]
        default: r.actions = [.convertImage(convertFormat)]
        }
        guard !r.name.trimmingCharacters(in: .whitespaces).isEmpty, !r.condition.isEmpty else { return nil }
        return r
    }

    private func test(_ r: Rule?) async -> String {
        guard let r else { return "" }
        let files = await model.preview(r)
        if files.isEmpty { return L("Ahora mismo ningún archivo de la carpeta coincide.") }
        return L("Coinciden %d archivos ahora mismo: %@", files.count, files.prefix(4).map(\.lastPathComponent).joined(separator: ", "))
    }
}
