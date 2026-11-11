import SwiftUI

/// Botón principal de Cabrio: fondo del color del texto y texto del color del fondo, así se lee en claro y en oscuro.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3)))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var cabrioPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
