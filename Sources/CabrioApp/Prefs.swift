import AppKit
import Carbon.HIToolbox
import CabrioDomain

/// Preferencias de Cabrio (UserDefaults). Las pantallas usan las mismas claves con @AppStorage.
enum Prefs {
    static let suffixKey = "outputSuffix"
    static let imageQualityKey = "imageQuality"
    static let hotKeyCodeKey = "hotKeyCode"
    static let hotKeyModsKey = "hotKeyMods"
    static let onboardingKey = "onboardingDone"
    static let rulesEnabledKey = "rulesEnabled"
    static let changed = Notification.Name("CabrioPrefsChanged")

    static let defaultSuffix = "_cabrio"
    static let defaultHotKey: (code: UInt32, mods: UInt32) = (UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey | cmdKey))

    static var suffix: String {
        get {
            guard let s = UserDefaults.standard.string(forKey: suffixKey) else { return defaultSuffix }
            return OutputNaming.sanitizeSuffix(s)
        }
        set { UserDefaults.standard.set(OutputNaming.sanitizeSuffix(newValue), forKey: suffixKey) }
    }

    static var imageQuality: Double {
        let v = UserDefaults.standard.object(forKey: imageQualityKey) as? Double ?? 0.9
        return min(max(v, 0.5), 1)
    }

    static var hotKey: (code: UInt32, mods: UInt32)? {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: hotKeyCodeKey) == nil { return defaultHotKey }
            let code = d.integer(forKey: hotKeyCodeKey)
            return code < 0 ? nil : (UInt32(code), UInt32(d.integer(forKey: hotKeyModsKey)))   // -1 = sin atajo
        }
        set {
            let d = UserDefaults.standard
            if let n = newValue { d.set(Int(n.code), forKey: hotKeyCodeKey); d.set(Int(n.mods), forKey: hotKeyModsKey) }
            else { d.set(-1, forKey: hotKeyCodeKey) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Interruptor general de las reglas de carpetas (encendido por defecto; no hay reglas hasta que se crean).
    static var rulesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: rulesEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rulesEnabledKey) }
    }

    static var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    // MARK: Atajos

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Espacio", kVK_Return: "↩", kVK_Tab: "⇥", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func label(code: UInt32, mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (keyNames[Int(code)] ?? "Tecla \(code)")
    }

    static var hotKeyLabel: String {
        guard let h = hotKey else { return "—" }
        return label(code: h.code, mods: h.mods)
    }
}
