import AppKit
import SwiftUI
import CabrioDomain
import CabrioApplication
import CabrioAdapters

/// Estado de la pestaña Reglas: lista de reglas, actividad reciente y deshacer.
@MainActor
final class RulesModel: ObservableObject {
    static let shared = RulesModel()

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var activity: [HistoryEntry] = []
    @Published var message: String?
    @Published var masterEnabled = Prefs.rulesEnabled

    private let services = Services.shared
    private var listener: Task<Void, Never>?

    private init() {
        rules = (try? services.ruleStore.load()) ?? []
        listener = Task { [weak self] in
            guard let events = self?.services.ruleRunner.events else { return }
            for await event in events {
                switch event {
                case .applied: await self?.refreshActivity()
                case .failed(let m): self?.message = m
                }
            }
        }
        Task { await refreshActivity() }
    }

    /// Arranque de la app: enciende la vigilancia según el interruptor general.
    func start() { Task { await services.ruleRunner.setEnabled(masterEnabled) } }

    func setMaster(_ on: Bool) {
        masterEnabled = on
        Prefs.rulesEnabled = on
        Task { await services.ruleRunner.setEnabled(on) }
    }

    func save(_ rule: Rule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        persist()
    }

    func delete(_ rule: Rule) { rules.removeAll { $0.id == rule.id }; persist() }

    func setEnabled(_ rule: Rule, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].isEnabled = on
        persist()
    }

    private func persist() {
        do { try services.ruleStore.save(rules) } catch { message = L("No se pudieron guardar las reglas.") }
        Task { await services.ruleRunner.reload() }
    }

    func preview(_ rule: Rule) async -> [URL] { await services.ruleRunner.matches(for: rule) }

    func runNow(_ rule: Rule) async -> Int {
        let done = await services.ruleRunner.runNow(rule)
        await refreshActivity()
        return done.count
    }

    func refreshActivity() async {
        activity = await services.history.recent(limit: 80).filter { if case .folderRule = $0.operation { return true } else { return false } }
            .prefix(10).map { $0 }
    }

    func undo(_ entry: HistoryEntry) {
        Task {
            do { try await services.operations.undo(entry.id); message = nil }
            catch { message = error.localizedDescription }
            await refreshActivity()
        }
    }

    // MARK: Plantillas

    private static func folder(_ dir: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: dir, in: .userDomainMask)[0]
    }

    static func presets() -> [(title: String, rule: Rule)] {
        let downloads = folder(.downloadsDirectory), desktop = folder(.desktopDirectory)
        let pictures = folder(.picturesDirectory), documents = folder(.documentDirectory)
        return [
            (L("Capturas de pantalla a Imágenes"), Rule(name: L("Capturas de pantalla"), folder: desktop,
                condition: RuleCondition(kinds: [.image], nameContains: ["Captura de pantalla", "Screenshot"]),
                actions: [.moveTo(folder: pictures.appendingPathComponent("Capturas"), subfolder: .byMonth)])),
            (L("PDF de Descargas a Documentos"), Rule(name: L("PDF de Descargas"), folder: downloads,
                condition: RuleCondition(kinds: [.pdf]),
                actions: [.moveTo(folder: documents.appendingPathComponent("PDF"), subfolder: .byYear)])),
            (L("Instaladores viejos a la Papelera"), Rule(name: L("Instaladores viejos"), folder: downloads,
                condition: RuleCondition(extensions: ["dmg", "pkg"], olderThanDays: 14), actions: [.moveToTrash])),
            (L("HEIC a JPG"), Rule(name: L("HEIC a JPG"), folder: downloads,
                condition: RuleCondition(extensions: ["heic"]), actions: [.convertImage(.jpg)])),
        ]
    }

    static func summary(_ rule: Rule) -> String {
        var parts: [String] = []
        let names: [FileKind: String] = [.image: L("Imágenes"), .pdf: "PDF", .video: L("Video"), .audio: "Audio",
                                         .archive: L("Comprimidos"), .officeDocument: L("Documentos"), .other: L("Otros")]
        if !rule.condition.kinds.isEmpty { parts.append(rule.condition.kinds.compactMap { names[$0] }.sorted().joined(separator: ", ")) }
        if !rule.condition.extensions.isEmpty { parts.append("." + rule.condition.extensions.joined(separator: " .")) }
        if !rule.condition.nameContains.isEmpty { parts.append("«" + rule.condition.nameContains.joined(separator: "», «") + "»") }
        if let d = rule.condition.olderThanDays { parts.append(L("más de %d días", d)) }
        if let b = rule.condition.largerThanBytes { parts.append(L("más de %@", formatBytes(b))) }
        let actions = rule.actions.map { a -> String in
            switch a {
            case .moveTo(let f, _): return L("mover a %@", f.lastPathComponent)
            case .moveToTrash: return L("a la Papelera")
            case .convertImage(let fmt): return L("convertir a %@", fmt.fileExtension.uppercased())
            }
        }
        return "\(rule.folder.lastPathComponent): " + parts.joined(separator: " · ") + " → " + actions.joined(separator: ", ")
    }

    static func pickFolder(start: URL?, prompt: String) -> (URL, Data?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}
