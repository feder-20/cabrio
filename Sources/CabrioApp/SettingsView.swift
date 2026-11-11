import SwiftUI
import ServiceManagement
import CabrioDomain

/// Abrir al iniciar sesión (macOS 13+). Falla sin avisar si la app no está en una carpeta estable.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            RulesSettings(model: RulesModel.shared).tabItem { Label(L("Reglas"), systemImage: "folder.badge.gearshape") }
            QualitySettings().tabItem { Label(L("Formatos y calidad"), systemImage: "slider.horizontal.3") }
            ShortcutSettings().tabItem { Label(L("Atajos"), systemImage: "keyboard") }
            AboutSettings().tabItem { Label(L("Acerca de"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 540)
    }
}

struct GeneralSettings: View {
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(Prefs.suffixKey) private var suffix = Prefs.defaultSuffix
    var onShowWelcome: () -> Void = { WindowPresenter.shared.showWelcome() }

    var body: some View {
        Form {
            Section {
                Toggle(L("Abrir Cabrio al iniciar sesión"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section(L("Nombre de los resultados")) {
                TextField(L("Sufijo"), text: $suffix)
                    .onChange(of: suffix) { _, v in
                        let clean = OutputNaming.sanitizeSuffix(v)
                        if clean != v { suffix = clean }
                    }
                Text(L("Ejemplo: informe%@.pdf", OutputNaming.sanitizeSuffix(suffix)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Los originales nunca se reemplazan: el resultado se guarda al lado, con este sufijo."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Menú del Finder")) {
                FinderActionRow()
            }
            Section {
                Button(L("Ver la bienvenida")) { onShowWelcome() }
            }
        }
        .formStyle(.grouped)
    }
}

struct QualitySettings: View {
    @AppStorage(Prefs.imageQualityKey) private var imageQuality = 0.9
    @AppStorage("compressByTarget") private var pdfByTarget = false
    @AppStorage("compressLevel") private var pdfLevel = CompressionLevel.medium.rawValue
    @AppStorage("compressTargetMB") private var pdfTargetMB = 2.0
    @AppStorage("videoByTarget") private var videoByTarget = false
    @AppStorage("videoLevel") private var videoLevel = CompressionLevel.medium.rawValue
    @AppStorage("videoTargetMB") private var videoTargetMB = 25.0
    @AppStorage("videoHEVC") private var hevc = false
    @AppStorage("ocrSpanish") private var spanish = true
    @AppStorage("ocrEnglish") private var english = true
    @AppStorage("ocrPortuguese") private var portuguese = false

    var body: some View {
        Form {
            Section(L("Imágenes")) {
                LabeledContent(L("Calidad JPG y HEIC")) {
                    HStack {
                        Slider(value: $imageQuality, in: 0.5...1, step: 0.05).frame(width: 160)
                        Text("\(Int(imageQuality * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section(L("Comprimir PDF")) {
                Picker(L("Por defecto"), selection: $pdfByTarget) {
                    Text(L("Por nivel")).tag(false)
                    Text(L("Meta de tamaño")).tag(true)
                }.pickerStyle(.segmented)
                Picker(L("Nivel"), selection: $pdfLevel) {
                    Text(L("Baja")).tag(CompressionLevel.low.rawValue)
                    Text(L("Media")).tag(CompressionLevel.medium.rawValue)
                    Text(L("Alta")).tag(CompressionLevel.high.rawValue)
                }
                LabeledContent(L("Meta")) {
                    HStack {
                        TextField("", value: $pdfTargetMB, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden().frame(width: 60).multilineTextAlignment(.trailing)
                        Text("MB")
                    }
                }
            }
            Section(L("Comprimir video")) {
                Picker(L("Por defecto"), selection: $videoByTarget) {
                    Text(L("Por nivel")).tag(false)
                    Text(L("Meta de tamaño")).tag(true)
                }.pickerStyle(.segmented)
                Picker(L("Nivel"), selection: $videoLevel) {
                    Text(L("Suave")).tag(CompressionLevel.low.rawValue)
                    Text(L("Media")).tag(CompressionLevel.medium.rawValue)
                    Text(L("Fuerte")).tag(CompressionLevel.high.rawValue)
                }
                LabeledContent(L("Meta")) {
                    HStack {
                        TextField("", value: $videoTargetMB, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden().frame(width: 60).multilineTextAlignment(.trailing)
                        Text("MB")
                    }
                }
                Toggle(L("HEVC (más pequeño, menos compatible)"), isOn: $hevc)
            }
            Section(L("Hacer buscable (OCR)")) {
                Toggle(L("Español"), isOn: $spanish)
                Toggle(L("Inglés"), isOn: $english)
                Toggle(L("Portugués"), isOn: $portuguese)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @State private var label = Prefs.hotKeyLabel
    @State private var message: String?
    @State private var permission = FinderSelection.permission(ask: false)

    var body: some View {
        Form {
            Section(L("Abrir Cabrio con la selección del Finder")) {
                LabeledContent(L("Atajo")) {
                    HotKeyRecorder(label: $label) { code, mods in
                        Prefs.hotKey = (code, mods)
                        let ok = HotKeyCenter.shared.applyPreferences()
                        label = Prefs.hotKeyLabel
                        message = ok ? nil : L("Ese atajo ya lo usa otro programa. Prueba otro.")
                    }.frame(width: 150, height: 24)
                }
                HStack {
                    Button(L("Restablecer")) {
                        Prefs.hotKey = Prefs.defaultHotKey
                        HotKeyCenter.shared.applyPreferences()
                        label = Prefs.hotKeyLabel; message = nil
                    }
                    Button(L("Quitar atajo")) {
                        Prefs.hotKey = nil
                        HotKeyCenter.shared.applyPreferences()
                        label = Prefs.hotKeyLabel; message = nil
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                Text(L("Selecciona archivos en el Finder y pulsa el atajo: Cabrio los abre con sus acciones."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Permiso del Finder")) {
                switch permission {
                case .granted: Label(L("Cabrio puede leer la selección del Finder."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Label(L("Sin permiso. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización."), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .unknown:
                    Text(L("Todavía no se ha pedido el permiso.")).foregroundStyle(.secondary)
                }
                Button(L("Comprobar o pedir permiso")) { permission = FinderSelection.permission(ask: true) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            if let img = BrandImage.symbol { Image(nsImage: img).resizable().scaledToFit().frame(width: 64, height: 64) }
            Text("cabrio").font(.system(size: 22, weight: .bold))
            Text(L("Versión %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                .foregroundStyle(.secondary)
            Text(L("Todo se procesa en tu Mac. Nada se sube a internet."))
            Text(L("Versión de desarrollo, sin límites. La licencia llegará más adelante."))
                .font(.caption).foregroundStyle(.secondary)
            Text("© 2026 ChocolitosSoft").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

enum BrandImage {
    /// Símbolo de la marca como plantilla: se tiñe según el tema claro u oscuro.
    static var symbol: NSImage? {
        guard let url = Bundle.main.url(forResource: "Symbol", withExtension: "png"), let img = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "car.side", accessibilityDescription: nil)
        }
        img.isTemplate = true
        return img
    }
}

/// Instalar o quitar «Cabrio» del menú de clic derecho del Finder.
struct FinderActionRow: View {
    @State private var installed = QuickAction.isInstalled
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Acción rápida del Finder"))
                    Text(L("Clic derecho en archivos o carpetas → Acciones rápidas → Cabrio."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(installed ? L("Quitar acción") : L("Instalar")) {
                    message = installed ? QuickAction.remove() : QuickAction.install()
                    installed = QuickAction.isInstalled
                }
            }
            if installed {
                Text(L("Si no aparece, actívala en Ajustes del Sistema → Teclado → Atajos de teclado → Servicios → Archivos y carpetas."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
        }
    }
}
