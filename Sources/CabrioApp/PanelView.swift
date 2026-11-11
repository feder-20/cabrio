import SwiftUI
import CabrioDomain
import CabrioApplication

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var rules = RulesModel.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            HStack {
                Label(L("Todo se procesa en tu Mac"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(L("Reglas"), isOn: Binding(get: { rules.masterEnabled }, set: { rules.setMaster($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .help(L("Reglas de carpetas: ordenan tus carpetas solas"))
            }
        }
        .padding(20)
        .frame(width: 340)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
    }

    private var header: some View {
        HStack {
            Text("cabrio").font(.system(size: 17, weight: .bold))
            Spacer()
            if !model.items.isEmpty, !model.isRunning {
                Button(L("Quitar")) { model.clear() }.buttonStyle(.link).font(.caption)
            }
            Button { model.onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Ajustes"))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .running(let title, let fraction):
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.medium))
                if let fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                else { ProgressView().progressViewStyle(.linear) }
                Button(L("Cancelar")) { model.cancel() }
            }
        case .done(let urls, _, let reports):
            VStack(alignment: .leading, spacing: 10) {
                Label(urls.count == 1 ? urls[0].lastPathComponent : L("%d archivos listos", urls.count),
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                if reports.isEmpty {
                    Text(model.lastWasRename ? L("Renombrados en su misma carpeta.") : L("Guardado junto al original."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ReportView(reports: reports)
                }
                HStack {
                    Button(L("Mostrar en Finder")) { model.reveal(urls) }.buttonStyle(.cabrioPrimary)
                    Button(L("Deshacer")) { model.undo() }
                }
                if reports.contains(where: { !$0.reachedTarget && !$0.nothingToGain }) {
                    Button(L("Cambiar la meta")) { model.changeTarget() }.buttonStyle(.link).font(.caption)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.red)
                if !model.items.isEmpty { actionsView }
            }
        case .idle:
            if model.items.isEmpty { dropZone }
            else if let pending = model.pending { OptionsView(model: model, action: pending) }
            else { filesView }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light))
            Text(L("Suelta archivos aquí")).font(.subheadline.weight(.medium))
            Text(L("PDF, imágenes o carpetas")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(targeted ? Color.primary : Color.secondary.opacity(0.4))
        )
    }

    private var filesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.items.count == 1 ? model.items[0].url.lastPathComponent : L("%d archivos", model.items.count))
                    .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(formatBytes(model.items.reduce(0) { $0 + $1.byteSize }))
                    .font(.caption).foregroundStyle(.secondary)
            }
            actionsView
        }
    }

    @ViewBuilder private var actionsView: some View {
        let list = model.actions
        if !list.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(list) { a in
                    Button { model.choose(a) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: a.symbol).font(.system(size: 18))
                            Text(L(a.title)).font(.caption).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add([url]) }
            }
        }
    }
}

/// Opciones de las acciones que las necesitan: dividir y hacer buscable (OCR).
struct OptionsView: View {
    @ObservedObject var model: AppModel
    let action: ActionDef

    @State private var splitByRanges = false
    @State private var rangesText = ""
    @AppStorage("ocrSpanish") private var spanish = true
    @AppStorage("ocrEnglish") private var english = true
    @AppStorage("ocrPortuguese") private var portuguese = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.pending = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text(L(action.title)).font(.subheadline.weight(.semibold))
            }
            switch action.kind {
            case .needsSplitOptions: splitOptions
            case .needsOCROptions: ocrOptions
            case .needsCompressOptions: compressOptions
            case .needsProtectOptions: protectOptions
            case .needsUnlockOptions: unlockOptions
            case .needsImageFormatOptions: imageFormatOptions
            case .needsVideoOptions: videoOptions
            case .needsRenameOptions: RenameOptionsView(model: model)
            case .immediate: EmptyView()
            }
        }
    }

    private var splitOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $splitByRanges) {
                Text(L("Cada página")).tag(false)
                Text(L("Por rangos")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if splitByRanges {
                TextField("1-3, 5, 8-", text: $rangesText).textFieldStyle(.roundedBorder)
                Text(L("Cada rango será un PDF. «8-» llega hasta la última página."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Se crea una carpeta con un PDF por página."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Dividir")) {
                model.run(.splitPDF(splitByRanges ? .ranges(rangesText) : .everyPage), title: L("Dividir"))
            }
            .buttonStyle(.cabrioPrimary)
            .disabled(splitByRanges && rangesText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @State private var password = ""
    @State private var confirmation = ""
    @AppStorage("compressByTarget") private var byTarget = false
    @AppStorage("compressLevel") private var levelRaw = CompressionLevel.medium.rawValue
    @AppStorage("compressTargetMB") private var targetMB = 2.0

    private var compressOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $byTarget) {
                Text(L("Por nivel")).tag(false)
                Text(L("Meta de tamaño")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if byTarget {
                HStack {
                    Text(L("Menos de"))
                    TextField("2", value: $targetMB, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("MB")
                }
                Text(L("Cabrio busca la mejor calidad que cumpla la meta."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $levelRaw) {
                    Text(L("Baja")).tag(CompressionLevel.low.rawValue)
                    Text(L("Media")).tag(CompressionLevel.medium.rawValue)
                    Text(L("Alta")).tag(CompressionLevel.high.rawValue)
                }.pickerStyle(.segmented).labelsHidden()
                Text(L("Solo se reducen las imágenes; el texto sigue siendo texto."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Comprimir")) {
                let target: CompressionTarget = byTarget
                    ? .maxBytes(Int64(max(targetMB, 0.1) * 1_000_000))
                    : .level(CompressionLevel(rawValue: levelRaw) ?? .medium)
                model.run(.compressPDF(target), title: L("Comprimir"))
            }
            .buttonStyle(.cabrioPrimary)
        }
    }

    @State private var imageFormat = ImageFormat.jpg
    @AppStorage("videoByTarget") private var videoByTarget = false
    @AppStorage("videoLevel") private var videoLevelRaw = CompressionLevel.medium.rawValue
    @AppStorage("videoTargetMB") private var videoTargetMB = 25.0
    @AppStorage("videoHEVC") private var videoHEVC = false

    private var imageFormatOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $imageFormat) {
                Text("JPG").tag(ImageFormat.jpg)
                Text("PNG").tag(ImageFormat.png)
                Text("HEIC").tag(ImageFormat.heic)
            }.pickerStyle(.segmented).labelsHidden()
            Text(L("Se guarda una copia junto al original; el original no cambia."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Convertir")) {
                model.run(.convertImage(to: imageFormat, quality: imageFormat == .png ? 1 : Prefs.imageQuality),
                          title: L("Convertir formato"))
            }
            .buttonStyle(.cabrioPrimary)
        }
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $videoByTarget) {
                Text(L("Por nivel")).tag(false)
                Text(L("Meta de tamaño")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if videoByTarget {
                HStack {
                    Text(L("Menos de"))
                    TextField("25", value: $videoTargetMB, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("MB")
                }
            } else {
                Picker("", selection: $videoLevelRaw) {
                    Text(L("Suave")).tag(CompressionLevel.low.rawValue)
                    Text(L("Media")).tag(CompressionLevel.medium.rawValue)
                    Text(L("Fuerte")).tag(CompressionLevel.high.rawValue)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Toggle(L("HEVC (más pequeño, menos compatible)"), isOn: $videoHEVC).font(.caption)
            Button(L("Comprimir")) {
                let target: VideoTarget = videoByTarget
                    ? .maxBytes(Int64(max(videoTargetMB, 0.2) * 1_000_000))
                    : .level(CompressionLevel(rawValue: videoLevelRaw) ?? .medium)
                model.run(.compressVideo(target, hevc: videoHEVC), title: L("Comprimir"))
            }
            .buttonStyle(.cabrioPrimary)
        }
    }

    private var protectOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(L("Contraseña"), text: $password).textFieldStyle(.roundedBorder)
            SecureField(L("Repite la contraseña"), text: $confirmation).textFieldStyle(.roundedBorder)
            if !confirmation.isEmpty && password != confirmation {
                Text(L("Las contraseñas no coinciden.")).font(.caption).foregroundStyle(.red)
            }
            if !password.allSatisfy(\.isASCII) {
                Text(L("Las contraseñas con tildes o ñ pueden no abrirse en Vista Previa. Para máxima compatibilidad, usa letras sin tilde, números y símbolos."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(L("Cabrio no guarda la contraseña y no puede recuperarla. Guárdala en un lugar seguro."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Proteger")) {
                let secret = SecretRef(password)
                password = ""; confirmation = ""
                model.run(.protectPDF(password: secret), title: L("Proteger"))
            }
            .buttonStyle(.cabrioPrimary)
            .disabled(password.isEmpty || password != confirmation)
        }
    }

    private var unlockOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(L("Contraseña actual"), text: $password).textFieldStyle(.roundedBorder)
            Text(L("Déjala vacía si el PDF solo tiene restricciones de edición."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Quitar contraseña")) {
                let secret = SecretRef(password)
                password = ""
                model.run(.unlockPDF(password: secret), title: L("Quitar contraseña"))
            }
            .buttonStyle(.cabrioPrimary)
        }
    }

    private var languages: [String] {
        (spanish ? ["es"] : []) + (english ? ["en"] : []) + (portuguese ? ["pt"] : [])
    }

    private var ocrOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Idioma del texto")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Español"), isOn: $spanish)
            Toggle(L("Inglés"), isOn: $english)
            Toggle(L("Portugués"), isOn: $portuguese)
            Text(L("La imagen no cambia: se añade texto invisible para poder buscar y copiar."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Hacer buscable")) { model.run(.ocr(languages: languages), title: L("Hacer buscable")) }
                .buttonStyle(.cabrioPrimary)
                .disabled(languages.isEmpty)
        }
    }
}

/// Antes y después de una compresión, con el aviso de meta imposible.
struct ReportView: View {
    let reports: [CompressionReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if reports.count == 1, let r = reports.first {
                if r.nothingToGain {
                    Text(L("Este archivo ya estaba optimizado.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(formatBytes(r.originalBytes)) → \(formatBytes(r.resultBytes))  (−\(saved(r)) %)")
                        .font(.caption.weight(.medium))
                }
                if !r.reachedTarget, let t = r.targetBytes {
                    Text(L("No se pudo bajar de %@. El mínimo posible fue %@.", formatBytes(t), formatBytes(r.resultBytes)))
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                let before = reports.reduce(Int64(0)) { $0 + $1.originalBytes }
                let after = reports.reduce(Int64(0)) { $0 + $1.resultBytes }
                Text("\(formatBytes(before)) → \(formatBytes(after))").font(.caption.weight(.medium))
                let missed = reports.filter { !$0.reachedTarget }.count
                if missed > 0 {
                    Text(L("%d archivos no alcanzaron la meta.", missed)).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func saved(_ r: CompressionReport) -> Int {
        guard r.originalBytes > 0 else { return 0 }
        return Int((1 - Double(r.resultBytes) / Double(r.originalBytes)) * 100)
    }
}

/// Renombrar por lotes con plantilla y vista previa antes de tocar nada.
struct RenameOptionsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("renameTemplate") private var template = "{name}-{n:3}"
    @State private var start = 1
    @State private var find = ""
    @State private var replacement = ""
    @State private var caseStyle = CaseStyle.keep
    @State private var sortByDate = false

    private var spec: RenameSpec {
        RenameSpec(template: template, start: start, find: find, replaceWith: replacement,
                   caseStyle: caseStyle, sortByDate: sortByDate)
    }

    private static let presets: [(String, String)] = [
        ("Nombre + número", "{name}-{n:3}"), ("Fecha + número", "{date}-{n:2}"),
        ("Carpeta + número", "{parent}-{n:3}"), ("Solo número", "{n:3}"),
    ]

    var body: some View {
        let preview = model.renamePreview(spec)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.pending = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text(L("Renombrar")).font(.subheadline.weight(.semibold))
                Spacer()
                Menu(L("Plantillas")) {
                    ForEach(Self.presets, id: \.1) { p in Button(L(p.0)) { template = p.1 } }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            TextField("{name}-{n:3}", text: $template).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            Text(L("{name} nombre · {n} número · {date} fecha · {parent} carpeta"))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField(L("Buscar"), text: $find).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").font(.caption)
                TextField(L("Reemplazar por"), text: $replacement).textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("", selection: $caseStyle) {
                    Text(L("Igual")).tag(CaseStyle.keep)
                    Text(L("minúsculas")).tag(CaseStyle.lower)
                    Text(L("MAYÚSCULAS")).tag(CaseStyle.upper)
                    Text(L("Título")).tag(CaseStyle.title)
                }.labelsHidden().fixedSize()
                Stepper(L("Empieza en %d", start), value: $start, in: 0...99999).font(.caption)
            }
            Toggle(L("Ordenar por fecha en vez de por nombre"), isOn: $sortByDate).font(.caption)

            switch preview {
            case .failure(let e):
                Text(e.localizedDescription).font(.caption).foregroundStyle(.red)
            case .success(let moves):
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(moves.prefix(4)), id: \.self) { m in
                        HStack(spacing: 4) {
                            Text(m.from.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").font(.caption2)
                            Text(m.to.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }.font(.caption)
                    }
                    if moves.count > 4 { Text(L("… y %d más", moves.count - 4)).font(.caption).foregroundStyle(.secondary) }
                    if moves.isEmpty { Text(L("Los nombres ya son los que pediste.")).font(.caption).foregroundStyle(.secondary) }
                }
                Button(L("Renombrar %d archivos", moves.count)) {
                    model.run(.batchRename(spec), title: L("Renombrar"))
                }
                .buttonStyle(.cabrioPrimary)
                .disabled(moves.isEmpty)
            }
        }
    }
}
