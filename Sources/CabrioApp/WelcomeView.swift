import SwiftUI

struct WelcomeView: View {
    var onStart: () -> Void
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var permission = FinderSelection.permission(ask: false)
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                if let img = BrandImage.symbol { Image(nsImage: img).resizable().scaledToFit().frame(width: 44, height: 44) }
                Text("cabrio").font(.system(size: 28, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Tus archivos no salen de tu Mac")).font(.title2.weight(.semibold))
                Text(L("Cabrio hace en tu equipo lo que otros servicios hacen subiendo tus documentos a internet."))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                benefit("lock.shield", L("Privado"), L("Cédulas, contratos y extractos se procesan aquí. Nada se sube."))
                benefit("bolt", L("Rápido y sin límites"), L("Resultados en segundos, sin tope de tamaño ni anuncios, y sin conexión."))
                benefit("square.grid.2x2", L("Todo en un lugar"), L("PDF, imágenes, video y carpetas: arrastra al ícono de la barra de menú."))
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Para empezar")).font(.headline)
                Toggle(L("Abrir Cabrio al iniciar sesión"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                FinderActionRow()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Leer la selección del Finder"))
                        Text(L("Con el atajo %@ abres Cabrio con lo que tengas seleccionado.", Prefs.hotKeyLabel))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch permission {
                    case .granted: Label(L("Permitido"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Text(L("Sin permiso: actívalo en Ajustes del Sistema → Automatización")).font(.caption).foregroundStyle(.orange).frame(maxWidth: 170)
                    case .unknown: Button(L("Permitir")) { permission = FinderSelection.permission(ask: true) }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Empezar"), action: onStart).buttonStyle(.cabrioPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    private func benefit(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
