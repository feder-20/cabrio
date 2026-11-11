import AppKit
import SwiftUI
import CabrioDomain

/// Línea discreta del pie del panel: estado de la prueba + «Obtener premium».
struct TrialFooter: View {
    @ObservedObject var license: LicenseController

    var body: some View {
        if let text = TrialText.footer(license.state) {
            HStack(spacing: 6) {
                Text(text).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(isLast ? Color.orange : Color.secondary)
                Spacer(minLength: 4)
                Button(L("Obtener premium")) { license.openPurchase() }.buttonStyle(.link).font(.caption2)
            }
        }
    }

    private var isLast: Bool { if case .lastDays = license.state { return true } else { return false } }
}

/// Aviso de primer arranque y recordatorio diario de los últimos días.
struct TrialNoticeView: View {
    let state: TrialState
    var onOK: () -> Void
    var onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Estás usando una versión de prueba (tester)")).font(.title3.weight(.semibold))
            if case .lastDays = state, let n = TrialText.notice(state) {
                Label(n, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange).font(.subheadline.weight(.medium))
            }
            Text(L("Cabrio está en periodo de prueba hasta el 9 de febrero de 2027. Es gratis durante este periodo y nos ayudas a mejorarla. Después, cada app costará %@ (pago único). Tus archivos nunca se tocan ni se pierden.", LicenseConfig.priceText))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Más información / Obtener premium")) { onMore() }
                Spacer()
                Button(L("Entendido"), action: onOK).buttonStyle(.cabrioPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
    }
}

/// Campo «Tengo una clave». En la ventana de periodo terminado no se cierra y ofrece «Salir».
struct ActivationView: View {
    @ObservedObject var license: LicenseController
    let expired: Bool
    var onActivated: () -> Void
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(expired ? L("El periodo de prueba terminó") : L("Introducir clave de licencia")).font(.title3.weight(.semibold))
            if expired {
                Text(L("Gracias por probar Cabrio. Para seguir usándola, obtén la versión premium (%@, pago único).", LicenseConfig.priceText))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Tus archivos y tus reglas se conservan intactos."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Obtener premium")) { license.openPurchase() }.buttonStyle(.cabrioPrimary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Tengo una clave")).font(.subheadline.weight(.medium))
                HStack {
                    TextField(L("Pega aquí tu clave"), text: $key).textFieldStyle(.roundedBorder)
                        .onSubmit(activate)
                    Button(L("Activar"), action: activate).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if expired {
                HStack { Spacer(); Button(L("Salir")) { NSApp.terminate(nil) } }
            }
        }
        .padding(24).frame(width: 460)
    }

    private func activate() {
        error = license.activate(key)
        if error == nil { onActivated() }
    }
}

/// Pestaña «Licencia» de Ajustes.
struct LicenseSettings: View {
    @ObservedObject var license: LicenseController
    var onEnterKey: () -> Void = { WindowPresenter.shared.showActivation() }

    var body: some View {
        Form {
            Section(L("Estado")) {
                switch license.state {
                case .licensed:
                    Label(L("Premium activado · %@", license.holder ?? ""), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button(L("Quitar licencia")) { license.removeLicense() }
                case .expired:
                    Label(L("El periodo de prueba terminó"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default:
                    Text(TrialText.footer(license.state) ?? "")
                }
                if license.state != .licensed {
                    Text(L("La prueba termina el 9 de febrero de 2027. Cabrio es gratis durante el periodo de prueba; después, cada app costará %@ (pago único).", LicenseConfig.priceText))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Obtener premium")) { license.openPurchase() }.buttonStyle(.cabrioPrimary)
                        Button(L("Introducir clave…"), action: onEnterKey)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Ventana que no se cierra con Esc ni con el botón de cierre (periodo terminado).
final class UncloseableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {}
    override func performClose(_ sender: Any?) {}
}
