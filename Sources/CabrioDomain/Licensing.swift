import Foundation
import CryptoKit

/// Constantes del periodo de prueba y la licencia (ver SPEC de ChocolitosLicense). Un solo lugar para cambiarlas.
public enum LicenseConfig {
    public static let appID = "cabrio"
    /// Duración de la prueba por persona, contada desde la primera vez que abre la app (`firstLaunch`).
    public static let trialDays = 90
    public static let priceText = "10 USD"
    public static let purchaseURL = URL(string: "https://chocolitossoft.com/premium")!
    public static let publicKeySPKIBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAErtZHvwOjaMNN6Wv5ts90ulpylP9W1Y9Q7ChUIEvUlSZs7Tjvf+ZvGKoVDkE6Xl/LRx5k67YzxqilIIAE/c2GXQ=="
    /// Desde cuántos días restantes se considera «últimos días».
    public static let lastDaysThreshold = 14

    public static func publicKey() -> P256.Signing.PublicKey? {
        guard let der = Data(base64Encoded: publicKeySPKIBase64) else { return nil }
        return try? P256.Signing.PublicKey(derRepresentation: der)
    }
}

public enum TrialState: Equatable, Sendable {
    case licensed
    case trial(daysLeft: Int)
    case lastDays(daysLeft: Int)
    case expired
}

/// Único punto de verdad del estado de la prueba. Sin UI ni reloj propio: todo entra por parámetro.
/// D0 = día local de `firstLaunch`; la prueba cubre D0…D0+89 y D0+90 (00:00) ya está vencida.
public enum TrialPolicy {
    /// - Parameters:
    ///   - firstLaunch: primera vez que la persona abrió la app (si está en el futuro respecto al reloj efectivo, se usa este).
    ///   - lastSeen: la fecha más alta que la app ha visto; retrasar el reloj no revive la prueba.
    public static func state(now: Date, firstLaunch: Date, lastSeen: Date?, licensed: Bool, calendar: Calendar = .current) -> TrialState {
        if licensed { return .licensed }
        let effective = max(now, lastSeen ?? now)
        let first = min(firstLaunch, effective)
        guard let end = trialEndDay(firstLaunch: first, calendar: calendar),
              let daysLeft = calendar.dateComponents([.day], from: calendar.startOfDay(for: effective), to: end).day,
              daysLeft > 0 else { return .expired }
        return daysLeft <= LicenseConfig.lastDaysThreshold ? .lastDays(daysLeft: daysLeft) : .trial(daysLeft: daysLeft)
    }

    /// Primer día ya vencido (D0+90, 00:00 locales).
    public static func trialEndDay(firstLaunch: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: LicenseConfig.trialDays, to: calendar.startOfDay(for: firstLaunch))
    }

    /// Último día de uso de la prueba (D0+89, inicio del día) para mostrar «hasta el <fecha>».
    public static func endDate(firstLaunch: Date, calendar: Calendar = .current) -> Date? {
        trialEndDay(firstLaunch: firstLaunch, calendar: calendar).flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
    }
}

public enum LicenseError: Error, LocalizedError, Equatable, Sendable {
    case invalid
    case wrongApp
    case alreadyActivated

    public var errorDescription: String? {
        switch self {
        case .invalid: return tr("La clave no es válida. Revisa que la hayas copiado completa.")
        case .wrongApp: return tr("Esa clave es de otra app. Necesitas una clave de Cabrio.")
        case .alreadyActivated: return tr("Esta clave ya está activada.")
        }
    }
}

public struct LicensePayload: Equatable, Sendable {
    public let app: String
    public let name: String
    public let issued: String
}

/// Verifica claves `APP.<payload>.<firma>` (base64url sin relleno; ECDSA P-256/SHA-256, firma r‖s). Sin red.
public enum LicenseVerifier {
    private struct Raw: Decodable { let app: String; let name: String?; let issued: String? }

    public static func verify(_ key: String, forApp app: String, publicKey: P256.Signing.PublicKey) -> Result<LicensePayload, LicenseError> {
        let cleaned = key.filter { !$0.isWhitespace }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty,
              let payloadData = decodeBase64URL(parts[1]), let sigData = decodeBase64URL(parts[2]),
              sigData.count == 64, let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
              publicKey.isValidSignature(sig, for: payloadData),
              let raw = try? JSONDecoder().decode(Raw.self, from: payloadData),
              parts[0].lowercased() == raw.app.lowercased()
        else { return .failure(.invalid) }
        let payloadApp = raw.app.lowercased()
        guard payloadApp == "all" || payloadApp == app.lowercased() else { return .failure(.wrongApp) }
        return .success(LicensePayload(app: payloadApp, name: raw.name ?? "", issued: raw.issued ?? ""))
    }

    static func decodeBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "=", with: "")
        guard !b.isEmpty, b.count % 4 != 1 else { return nil }
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

/// Almacén de preferencias abstracto (UserDefaults en la app, memoria en las pruebas).
public protocol PreferenceStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

public final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    public func set(_ value: String?, forKey key: String) { lock.withLock { values[key] = value } }
}
