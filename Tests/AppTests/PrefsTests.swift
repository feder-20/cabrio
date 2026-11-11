import XCTest
import Carbon.HIToolbox
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
