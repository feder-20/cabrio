import XCTest
import Carbon.HIToolbox
import CryptoKit
import CabrioDomain
import CabrioApplication
@testable import CabrioApp

final class PrefsTests: XCTestCase {
    func testHotKeyLabels() {
        XCTAssertEqual(Prefs.label(code: UInt32(kVK_ANSI_C), mods: UInt32(controlKey | optionKey | cmdKey)), "⌃⌥⌘C")
        XCTAssertEqual(Prefs.label(code: UInt32(kVK_ANSI_1), mods: UInt32(cmdKey | shiftKey)), "⇧⌘1")
        XCTAssertEqual(Prefs.label(code: UInt32(kVK_Space), mods: UInt32(optionKey)), "⌥Espacio")
        XCTAssertEqual(Prefs.label(code: 200, mods: UInt32(cmdKey)), "⌘Tecla 200")
    }

    func testHotKeyDefaultsAndClearing() {
        let d = UserDefaults.standard
        let savedCode = d.object(forKey: Prefs.hotKeyCodeKey), savedMods = d.object(forKey: Prefs.hotKeyModsKey)
        defer { d.set(savedCode, forKey: Prefs.hotKeyCodeKey); d.set(savedMods, forKey: Prefs.hotKeyModsKey) }
        d.removeObject(forKey: Prefs.hotKeyCodeKey)
        XCTAssertEqual(Prefs.hotKey?.code, Prefs.defaultHotKey.code)
        Prefs.hotKey = (UInt32(kVK_ANSI_K), UInt32(cmdKey))
        XCTAssertEqual(Prefs.hotKeyLabel, "⌘K")
        Prefs.hotKey = nil
        XCTAssertNil(Prefs.hotKey)
        XCTAssertEqual(Prefs.hotKeyLabel, "—")
    }

    func testSuffixIsSanitizedAndImageQualityClamped() {
        let d = UserDefaults.standard
        let savedS = d.object(forKey: Prefs.suffixKey), savedQ = d.object(forKey: Prefs.imageQualityKey)
        defer { d.set(savedS, forKey: Prefs.suffixKey); d.set(savedQ, forKey: Prefs.imageQualityKey) }
        Prefs.suffix = "_mío/2"
        XCTAssertEqual(Prefs.suffix, "_mío2")
        d.removeObject(forKey: Prefs.suffixKey)
        XCTAssertEqual(Prefs.suffix, "_cabrio")
        d.set(0.1, forKey: Prefs.imageQualityKey); XCTAssertEqual(Prefs.imageQuality, 0.5)
        d.set(7.0, forKey: Prefs.imageQualityKey); XCTAssertEqual(Prefs.imageQuality, 1)
    }
}

@MainActor
final class LicenseControllerTests: XCTestCase {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }   // enero de 2027

    func make(_ clock: Clock, opened: @escaping (URL) -> Void = { _ in }) -> (LicenseController, P256.Signing.PrivateKey) {
        let priv = P256.Signing.PrivateKey()
        let m = LicenseManager(publicKey: priv.publicKey, store: InMemoryPreferenceStore(), now: { clock.now })
        return (LicenseController(manager: m, openURL: opened), priv)
    }

    func testPurchaseOpensConfiguredURLWithoutNetwork() {
        var opened: [URL] = []
        let (c, _) = make(Clock()) { opened.append($0) }
        c.openPurchase()
        XCTAssertEqual(opened, [LicenseConfig.purchaseURL])
    }

    func testStateChangesAndNotifiesWhenTrialExpires() {
        let clock = Clock()
        let (c, _) = make(clock)
        var seen: [TrialState] = []
        c.onStateChange = { seen.append($0) }
        XCTAssertFalse(c.isExpired)
        clock.now = clock.now.addingTimeInterval(120 * 86_400)
        c.refresh()
        XCTAssertTrue(c.isExpired)
        XCTAssertEqual(seen, [.expired])
        XCTAssertEqual(c.activate("basura"), LicenseError.invalid.errorDescription)
    }

    func testFooterTexts() {
        XCTAssertEqual(TrialText.footer(.trial(daysLeft: 30)), "Versión de prueba · quedan 30 días · Premium: 10 USD")
        XCTAssertEqual(TrialText.footer(.lastDays(daysLeft: 1)), "Versión de prueba · último día · Premium: 10 USD")
        XCTAssertNil(TrialText.footer(.licensed))
    }

    func testEnglishForNewStringsAndUserDefaultsStoreRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Localization.bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources/en.lproj").path))
        defer { Localization.bundle = .main }
        XCTAssertEqual(TrialText.footer(.trial(daysLeft: 30)), "Trial version · 30 days left · Premium: 10 USD")
        XCTAssertEqual(LicenseError.wrongApp.localizedDescription, "That key is for a different app. You need a Cabrio key.")
        XCTAssertTrue(CabrioError.trialExpired.localizedDescription.hasPrefix("The trial period has ended."))
        let suite = UserDefaults(suiteName: "cabrio.tests.\(UUID().uuidString)")!
        let store = UserDefaultsPreferenceStore(defaults: suite)
        store.set("x", forKey: "k"); XCTAssertEqual(store.string(forKey: "k"), "x")
        store.set(nil, forKey: "k"); XCTAssertNil(store.string(forKey: "k"))
    }
}
