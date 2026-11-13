import Foundation
import CryptoKit
import CabrioDomain

/// Puerta de ejecución: si lanza, la función principal no se ejecuta (y no se toca el disco).
public protocol ExecutionGate: Sendable {
    func check() throws
}

public struct OpenGate: ExecutionGate {
    public init() {}
    public func check() throws {}
}

/// Estado de licencia y prueba: combina reloj, almacén de preferencias y clave pública (todo inyectable).
public final class LicenseManager: ExecutionGate, @unchecked Sendable {
    enum Key {
        static let license = "license.key"
        static let firstLaunch = "trial.firstLaunch"
        static let lastSeen = "trial.lastSeen"
        static let noticeSeen = "trial.noticeSeen"
        static let lastReminder = "trial.lastReminderDay"
    }

    private let appID: String
    private let publicKey: P256.Signing.PublicKey?
    private let store: PreferenceStore
    /// Segundo lugar, independiente, donde se guarda `firstLaunch` (archivo en Application Support en la app).
    private let backup: PreferenceStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var cache: (key: String, payload: LicensePayload?)?

    public init(appID: String = LicenseConfig.appID, publicKey: P256.Signing.PublicKey?, store: PreferenceStore,
                backup: PreferenceStore = InMemoryPreferenceStore(),
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.appID = appID
        self.publicKey = publicKey
        self.store = store
        self.backup = backup
        self.now = now
        self.calendar = calendar
    }

    /// Licencia guardada y verificada de nuevo (una clave alterada en las preferencias no cuenta).
    public var license: LicensePayload? {
        lock.withLock { storedLicense() }
    }

    private func storedLicense() -> LicensePayload? {
        guard let key = store.string(forKey: Key.license) else { return nil }
        if let c = cache, c.key == key { return c.payload }
        let payload = publicKey.flatMap { try? LicenseVerifier.verify(key, forApp: appID, publicKey: $0).get() }
        cache = (key, payload)
        return payload
    }

    public func state() -> TrialState {
        lock.withLock {
            let current = now()
            let seen = store.string(forKey: Key.lastSeen).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            if let seen, seen > current {} else { store.set(String(current.timeIntervalSince1970), forKey: Key.lastSeen) }
            let first = resolveFirstLaunch(effectiveNow: max(current, seen ?? current))
            return TrialPolicy.state(now: current, firstLaunch: first, lastSeen: seen, licensed: storedLicense() != nil, calendar: calendar)
        }
    }

    /// Último día de la prueba de esta persona (para «hasta el <fecha>»).
    public func trialEndDate() -> Date? {
        lock.withLock {
            let current = now()
            let seen = store.string(forKey: Key.lastSeen).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            return TrialPolicy.endDate(firstLaunch: resolveFirstLaunch(effectiveNow: max(current, seen ?? current)), calendar: calendar)
        }
    }

    /// `firstLaunch` redundante: se usa el más antiguo de los dos registros y se recrea el que falte.
    /// Sin ninguno (primer arranque o migración desde la prueba de fecha fija) empieza ahora. Un valor futuro se corrige.
    private func resolveFirstLaunch(effectiveNow: Date) -> Date {
        func read(_ s: PreferenceStore) -> Date? {
            guard let v = s.string(forKey: Key.firstLaunch).flatMap(Double.init), v.isFinite else { return nil }
            return Date(timeIntervalSince1970: v)
        }
        let found = [read(store), read(backup)].compactMap { $0 }
        var first = found.min() ?? effectiveNow
        if first > effectiveNow { first = effectiveNow }
        let text = String(first.timeIntervalSince1970)
        if store.string(forKey: Key.firstLaunch) != text { store.set(text, forKey: Key.firstLaunch) }
        if backup.string(forKey: Key.firstLaunch) != text { backup.set(text, forKey: Key.firstLaunch) }
        return first
    }

    public func check() throws {
        if state() == .expired { throw CabrioError.trialExpired }
    }

    /// Verifica y guarda la clave. Devuelve el nombre del comprador.
    @discardableResult
    public func activate(_ key: String) throws -> String {
        try lock.withLock {
            let cleaned = key.filter { !$0.isWhitespace }
            guard let publicKey else { throw LicenseError.invalid }
            let payload = try LicenseVerifier.verify(cleaned, forApp: appID, publicKey: publicKey).get()
            if storedLicense() == payload { throw LicenseError.alreadyActivated }
            store.set(cleaned, forKey: Key.license)
            cache = nil
            return payload.name
        }
    }

    public func removeLicense() {
        lock.withLock { store.set(nil, forKey: Key.license); cache = nil }
    }

    // MARK: Avisos

    public var noticeSeen: Bool { store.string(forKey: Key.noticeSeen) == "1" }
    public func markNoticeSeen() { store.set("1", forKey: Key.noticeSeen) }

    /// true si en «últimos días» aún no se mostró el aviso de hoy; lo anota (no más de uno al día).
    public func takeDailyReminder() -> Bool {
        guard case .lastDays = state() else { return false }
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        let today = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        if store.string(forKey: Key.lastReminder) == today { return false }
        store.set(today, forKey: Key.lastReminder)
        return true
    }
}
