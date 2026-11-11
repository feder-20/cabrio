import AppKit
import CabrioDomain

/// «Cabrio» en el menú de Acciones rápidas del Finder (clic derecho → Acciones rápidas → Cabrio).
/// Es un flujo de Automator que abre la selección en Cabrio; se instala en ~/Library/Services.
enum QuickAction {
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/Cabrio.workflow", isDirectory: true)
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }
    static var bundledURL: URL? { Bundle.main.url(forResource: "Cabrio", withExtension: "workflow") }

    /// Devuelve un mensaje de error en español (clave de localización) o nil si todo salió bien.
    static func install() -> String? {
        guard let src = bundledURL else { return tr("Esta copia de Cabrio no incluye la Acción rápida.") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedURL.path) { try fm.removeItem(at: installedURL) }
            try fm.copyItem(at: src, to: installedURL)
            refreshServices()
            return nil
        } catch { return error.localizedDescription }
    }

    static func remove() -> String? {
        do { try FileManager.default.removeItem(at: installedURL); refreshServices(); return nil }
        catch { return error.localizedDescription }
    }

    /// Pide al sistema que relea los Servicios para que la acción aparezca sin cerrar sesión.
    private static func refreshServices() {
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-update"]
        try? pbs.run()
    }
}
