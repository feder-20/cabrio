import AppKit
import SwiftUI
import CabrioDomain
import CabrioApplication

/// Preferencias en UserDefaults (el estado de la prueba no usa red ni Keychain).
struct UserDefaultsPreferenceStore: PreferenceStore, @unchecked Sendable {
    var defaults: UserDefaults = .standard
    var prefix = "cabrio."
    func string(forKey key: String) -> String? { defaults.string(forKey: prefix + key) }
    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}

/// Textos del estado de la prueba (puros, para probarlos sin ventanas).
enum TrialText {
    static func footer(_ state: TrialState) -> String? {
        switch state {
        case .licensed: return nil
        case .trial(let d): return L("Versión de prueba · quedan %d días · Premium: %@", d, LicenseConfig.priceText)
        case .lastDays(let d):
            return d == 1 ? L("Versión de prueba · último día · Premium: %@", LicenseConfig.priceText)
                          : L("Quedan %d días de prueba · Premium: %@", d, LicenseConfig.priceText)
        case .expired: return L("El periodo de prueba terminó")
        }
    }

    static func notice(_ state: TrialState) -> String? {
        switch state {
        case .licensed: return nil
        case .trial(let d), .lastDays(let d): return d == 1 ? L("Hoy es el último día de la prueba.") : L("Quedan %d días de prueba.", d)
        case .expired: return L("El periodo de prueba terminó")
        }
    }
}

/// Puente observable entre el gestor de licencia y la interfaz. Reloj, almacén y abridor de URL son inyectables.
@MainActor
final class LicenseController: ObservableObject {
    static let shared = LicenseController(manager: Services.shared.license)

    @Published private(set) var state: TrialState
    @Published private(set) var holder: String?
    let manager: LicenseManager
    private let openURL: (URL) -> Void
    var onStateChange: (TrialState) -> Void = { _ in }
    private var timer: Timer?

    init(manager: LicenseManager, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.manager = manager
        self.openURL = openURL
        self.state = manager.state()
        self.holder = manager.license?.name
    }

    var isExpired: Bool { state == .expired }

    /// Reevalúa el estado (cambio de día, reloj, licencia) y avisa si cambió.
    func refresh() {
        let new = manager.state()
        holder = manager.license?.name
        guard new != state else { return }
        state = new
        onStateChange(new)
    }

    func startRefreshing() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openPurchase() { openURL(LicenseConfig.purchaseURL) }

    /// Devuelve nil si se activó, o el mensaje de error.
    func activate(_ key: String) -> String? {
        do { try manager.activate(key) } catch { refresh(); return error.localizedDescription }
        refresh()
        return nil
    }

    func removeLicense() {
        manager.removeLicense()
        refresh()
    }
}
