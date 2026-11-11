import AppKit
import CabrioDomain

/// Lee la selección actual del Finder con AppleScript. Pide el permiso de Automatización la primera vez.
@MainActor
enum FinderSelection {
    enum Permission { case granted, denied, unknown }

    static func permission(ask: Bool) -> Permission {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first != nil else { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    /// URLs seleccionadas en el Finder; lanza un `CabrioError` con instrucciones si no hay permiso.
    static func current() throws -> [URL] {
        let source = """
        tell application "Finder"
            set picked to selection as alias list
            set out to {}
            repeat with a in picked
                set end of out to POSIX path of a
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw CabrioError.unsupported(tr("Cabrio necesita permiso para leer la selección del Finder. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización."))
            }
            return []   // sin selección u otro error del Finder
        }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }.map { URL(fileURLWithPath: $0) }
    }
}
