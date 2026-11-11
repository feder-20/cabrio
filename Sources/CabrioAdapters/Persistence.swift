import Foundation
import CabrioDomain
import CabrioPorts

enum AppSupport {
    /// ~/Library/Application Support/Cabrio (o la carpeta del contenedor cuando haya sandbox).
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Cabrio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Reglas en un archivo JSON. (El `cabrio.md` prevé SwiftData; el puerto permite cambiarlo sin tocar nada más.)
public struct JSONRuleStore: RuleStore {
    private let url: URL
    public init(url: URL? = nil) { self.url = url ?? AppSupport.directory().appendingPathComponent("rules.json") }

    public func load() throws -> [Rule] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Rule].self, from: Data(contentsOf: url))
    }

    public func save(_ rules: [Rule]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rules).write(to: url, options: .atomic)
    }
}

/// Historial persistente: el «Deshacer» sobrevive a cerrar la app. Guarda las últimas 200 operaciones.
public actor FileHistoryStore: HistoryStore {
    private var entries: [HistoryEntry]
    private let url: URL

    public init(url: URL? = nil) {
        let file = url ?? AppSupport.directory().appendingPathComponent("history.json")
        self.url = file
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([HistoryEntry].self, from: Data(contentsOf: file))) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(entries).write(to: url, options: .atomic)
    }

    public func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        persist()
    }
    public func entry(id: UUID) -> HistoryEntry? { entries.first { $0.id == id } }
    public func remove(id: UUID) { entries.removeAll { $0.id == id }; persist() }
    public func recent(limit: Int) -> [HistoryEntry] { Array(entries.prefix(limit)) }
}
