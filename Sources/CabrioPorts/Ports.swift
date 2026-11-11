import Foundation
import CabrioDomain

public protocol PDFEngine: Sendable {
    func merge(_ inputs: [URL], into output: URL) async throws
    func makePDF(fromImages images: [URL], output: URL) async throws
    /// Reduce el peso sin rasterizar el texto: solo se recomprimen las imágenes.
    func compress(_ input: URL, target: CompressionTarget, output: URL,
                  progress: @Sendable (Double) -> Void) async throws -> CompressionReport
    /// Cifra con contraseña (AES de 128 bits) sin tocar el contenido de las páginas.
    func protect(_ input: URL, password: String, output: URL) async throws
    /// Quita la contraseña conocida (también sirve la vacía, para PDF con solo restricciones).
    func unlock(_ input: URL, password: String, output: URL) async throws
    func pageCount(of input: URL) async throws -> Int
    /// `ranges` son de páginas (desde 1); `outputs[i]` recibe `ranges[i]`.
    func split(_ input: URL, ranges: [ClosedRange<Int>], outputs: [URL]) async throws
}

public protocol OCREngine: Sendable {
    /// Deja el PDF buscable: la imagen original queda intacta y se añade una capa de texto invisible.
    func makeSearchable(_ input: URL, languages: [String], output: URL,
                        progress: @Sendable (Double) -> Void) async throws
}

public protocol ImageEngine: Sendable {
    /// PNG con el fondo transparente (Vision, máscara de primer plano).
    func removeBackground(_ input: URL, output: URL) async throws
    /// Convierte `input` a `format`; si `maxSide` no es nil, reduce el lado mayor a ese valor.
    func convert(_ input: URL, to format: ImageFormat, quality: Double, maxSide: Int?, output: URL) async throws
}

public protocol MediaEngine: Sendable {
    /// MP4 con H.264 o HEVC. Con meta de tamaño se calcula el bitrate; el informe dice si se alcanzó.
    func compressVideo(_ input: URL, target: VideoTarget, hevc: Bool, output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionReport
    /// Audio AAC en M4A, a partir de un video o de otro audio.
    func audioToM4A(_ input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public protocol ArchiveEngine: Sendable {
    /// ZIP compatible con Windows: sin metadatos de macOS, nombres NFC, marca UTF-8.
    func cleanZip(_ inputs: [URL], output: URL) async throws
}

public struct FileAttributes: Sendable {
    public let isDirectory: Bool
    public let created: Date?
    public let modified: Date?
    public let size: Int64
    public init(isDirectory: Bool, created: Date?, modified: Date?, size: Int64 = 0) {
        self.size = size
        self.isDirectory = isDirectory
        self.created = created
        self.modified = modified
    }
}

public protocol FileSystem: Sendable {
    func attributes(of url: URL) -> FileAttributes
    func moveItem(from: URL, to: URL) throws
    func exists(_ url: URL) -> Bool
    /// Nunca se borra de forma permanente: solo a la Papelera.
    /// Crea la carpeta y las que falten; no falla si ya existe.
    func createDirectory(_ url: URL) throws
    /// Archivos y carpetas directos (sin entrar en subcarpetas).
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    /// Devuelve dónde quedó en la Papelera, para poder restaurarlo.
    @discardableResult func moveToTrash(_ url: URL) throws -> URL?
}

public protocol HistoryStore: Sendable {
    func record(_ entry: HistoryEntry) async
    func entry(id: UUID) async -> HistoryEntry?
    func remove(id: UUID) async
    func recent(limit: Int) async -> [HistoryEntry]
}

public protocol FileKindDetecting: Sendable {
    func item(for url: URL) -> FileItem
}

public protocol RuleStore: Sendable {
    func load() throws -> [Rule]
    func save(_ rules: [Rule]) throws
}

/// Avisa de archivos nuevos o modificados que están directamente en `folder`.
public protocol FolderWatcher: Sendable {
    func events(for folder: URL) -> AsyncStream<URL>
}
