import Foundation
import UniformTypeIdentifiers
import CabrioDomain
import CabrioPorts

public struct LocalFileSystem: FileSystem {
    public init() {}
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func attributes(of url: URL) -> FileAttributes {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey])
        return FileAttributes(isDirectory: v?.isDirectory ?? false, created: v?.creationDate,
                              modified: v?.contentModificationDate, size: Int64(v?.fileSize ?? 0))
    }
    public func moveItem(from: URL, to: URL) throws {
        // Sin sobrescribir nunca: si el destino existe (salvo cambio de mayúsculas del mismo archivo), falla.
        if FileManager.default.fileExists(atPath: to.path),
           from.path.lowercased() != to.path.lowercased() {
            throw CabrioError.writeFailed(tr("Ya existe «%@».", to.lastPathComponent))
        }
        try FileManager.default.moveItem(at: from, to: to)
    }
    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

/// Historial en memoria; se reemplaza por SwiftData (cabrio.md §6.1).
public actor InMemoryHistoryStore: HistoryStore {
    private var entries: [HistoryEntry] = []
    public init() {}
    public func record(_ entry: HistoryEntry) { entries.insert(entry, at: 0) }
    public func entry(id: UUID) -> HistoryEntry? { entries.first { $0.id == id } }
    public func remove(id: UUID) { entries.removeAll { $0.id == id } }
    public func recent(limit: Int) -> [HistoryEntry] { Array(entries.prefix(limit)) }
}

/// Detecta el tipo de archivo con `UTType`.
public struct FileKindDetector: FileKindDetecting {
    public init() {}

    private static let officeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key"]

    public func item(for url: URL) -> FileItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentTypeKey, .fileSizeKey]
        let rv = try? url.resourceValues(forKeys: keys)
        var size = Int64(rv?.fileSize ?? 0)
        let kind: FileKind
        if rv?.isDirectory == true {
            kind = .folder
            size = 0
        } else if Self.officeExtensions.contains(url.pathExtension.lowercased()) {
            kind = .officeDocument
        } else if let t = rv?.contentType {
            if t.conforms(to: .pdf) { kind = .pdf }
            else if t.conforms(to: .image) { kind = .image }
            else if t.conforms(to: .movie) || t.conforms(to: .video) { kind = .video }
            else if t.conforms(to: .audio) { kind = .audio }
            else if t.conforms(to: .archive) { kind = .archive }
            else { kind = .other }
        } else {
            kind = .other
        }
        return FileItem(url: url, kind: kind, byteSize: size)
    }
}
