import Foundation
import CryptoKit

/// Constantes del periodo de prueba y la licencia (ver SPEC de ChocolitosLicense). Un solo lugar para cambiarlas.
public enum LicenseConfig {
    public static let appID = "cabrio"
    /// Último día de la prueba: 9 de febrero de 2027 (hora local, hasta las 23:59:59).
    public static let trialEndYear = 2027, trialEndMonth = 2, trialEndDay = 9
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
public enum TrialPolicy {
    /// - Parameters:
    ///   - lastSeen: la fecha más alta que la app ha visto; retrasar el reloj no revive la prueba.
    public static func state(now: Date, lastSeen: Date?, licensed: Bool, calendar: Calendar = .current) -> TrialState {
        if licensed { return .licensed }
        let effective = max(now, lastSeen ?? now)
        let today = calendar.startOfDay(for: effective)
        guard let endDay = calendar.date(from: DateComponents(year: LicenseConfig.trialEndYear,
                                                              month: LicenseConfig.trialEndMonth,
                                                              day: LicenseConfig.trialEndDay)),
              let days = calendar.dateComponents([.day], from: today, to: endDay).day else { return .expired }
        let daysLeft = days + 1   // el último día cuenta como «queda 1 día»
        if daysLeft <= 0 { return .expired }
        return daysLeft <= LicenseConfig.lastDaysThreshold ? .lastDays(daysLeft: daysLeft) : .trial(daysLeft: daysLeft)
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
