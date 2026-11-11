import Foundation

/// Idioma de los textos que genera el núcleo (errores, nombres de subcarpetas). Las pruebas pueden cambiarlo.
public enum Localization {
    public nonisolated(unsafe) static var bundle: Bundle = .main
}

/// Texto localizado: el español es la clave y el idioma base; `en.lproj` trae el inglés.
public func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: Localization.bundle, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

public enum FileKind: String, Sendable, Codable {
    case pdf, image, video, audio, officeDocument, archive, folder, other
}

public struct FileItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let kind: FileKind
    public let byteSize: Int64

    public init(id: UUID = UUID(), url: URL, kind: FileKind, byteSize: Int64) {
        self.id = id
        self.url = url
        self.kind = kind
        self.byteSize = byteSize
    }
}

public enum ImageFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case jpg, png, heic

    public var fileExtension: String { rawValue }

    /// Formato de salida que conserva el de origen (por extensión); JPG si no se reconoce.
    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "heic", "heif": self = .heic
        default: self = .jpg
        }
    }
}

/// Operaciones disponibles. Se amplía junto con el puerto, el adaptador y las pruebas (cabrio.md §15).
public enum SplitMode: Sendable, Codable, Hashable {
    case everyPage
    /// Texto del usuario, p. ej. «1-3, 5, 8-». Se interpreta con `PageRanges.parse`.
    case ranges(String)
}

public enum CompressionLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case low, medium, high
}

public enum CompressionTarget: Sendable, Codable, Hashable {
    case level(CompressionLevel)
    /// Meta de tamaño en bytes («menos de 2 MB»).
    case maxBytes(Int64)
}

public struct CompressionReport: Sendable, Codable, Hashable {
    public let originalBytes: Int64
    public let resultBytes: Int64
    public let targetBytes: Int64?
    /// Verdadero si no había meta o se cumplió.
    public let reachedTarget: Bool

    public init(originalBytes: Int64, resultBytes: Int64, targetBytes: Int64? = nil, reachedTarget: Bool = true) {
        self.originalBytes = originalBytes
        self.resultBytes = resultBytes
        self.targetBytes = targetBytes
        self.reachedTarget = reachedTarget
    }

    /// El PDF ya venía optimizado: no se pudo reducir de forma apreciable.
    public var nothingToGain: Bool { Double(resultBytes) >= Double(originalBytes) * 0.97 }
}

/// Contraseña en memoria. Nunca se persiste: al codificarse queda vacía y se muestra como «•••».
public struct SecretRef: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public init(from decoder: Decoder) throws { value = "" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("")
    }
    public var description: String { "•••" }
    public var debugDescription: String { "SecretRef(•••)" }
}

public enum VideoTarget: Sendable, Codable, Hashable {
    /// Convierte a MP4 manteniendo resolución y calidad (sin subir el bitrate del original).
    case keepQuality
    case level(CompressionLevel)
    case maxBytes(Int64)
}

public enum CaseStyle: String, Sendable, Codable, Hashable, CaseIterable {
    case keep, lower, upper, title
}

public struct RenameSpec: Sendable, Codable, Hashable {
    /// Marcadores: {name}, {n}, {n:3}, {date}, {date:yyyyMMdd}, {created}, {parent}.
    public var template: String
    public var start: Int
    public var find: String
    public var replaceWith: String
    public var caseStyle: CaseStyle
    public var sortByDate: Bool

    public init(template: String, start: Int = 1, find: String = "", replaceWith: String = "",
                caseStyle: CaseStyle = .keep, sortByDate: Bool = false) {
        self.template = template
        self.start = start
        self.find = find
        self.replaceWith = replaceWith
        self.caseStyle = caseStyle
        self.sortByDate = sortByDate
    }
}

public struct FileMove: Sendable, Codable, Hashable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public enum CabrioOperation: Sendable, Codable, Hashable {
    /// Acción automática de una regla de carpeta (la ejecuta `RuleRunner`, no `RunOperation`).
    case folderRule(name: String)
    case batchRename(RenameSpec)
    case compressImage(CompressionLevel)
    case removeBackground
    case compressVideo(VideoTarget, hevc: Bool)
    case audioToM4A
    case protectPDF(password: SecretRef)
    case unlockPDF(password: SecretRef)
    case compressPDF(CompressionTarget)
    case splitPDF(SplitMode)
    case ocr(languages: [String])
    case mergePDFs
    case imagesToPDF
    case convertImage(to: ImageFormat, quality: Double)
    case resizeImage(maxSide: Int)
    case cleanZip(name: String)
}

/// Errores con mensaje claro en español: causa y acción, nunca trazas técnicas.
public enum CabrioError: Error, LocalizedError, Sendable, Equatable {
    case notEnoughFiles
    case unreadableFile(String)
    case passwordRequired(String)
    case wrongPassword(String)
    case unsupported(String)
    case tooLarge(String)
    case writeFailed(String)
    case cancelled
    case trialExpired

    public var errorDescription: String? {
        switch self {
        case .notEnoughFiles: return tr("Faltan archivos para esta acción.")
        case .unreadableFile(let n): return tr("No se pudo leer «%@». Comprueba que no esté dañado.", n)
        case .passwordRequired(let n): return tr("«%@» tiene contraseña. Escríbela para continuar.", n)
        case .wrongPassword(let n): return tr("La contraseña de «%@» no es correcta.", n)
        case .unsupported(let m): return m
        case .tooLarge(let n): return tr("«%@» es demasiado grande para este formato (4 GB como máximo).", n)
        case .writeFailed(let m): return tr("No se pudo guardar el resultado. %@", m)
        case .cancelled: return tr("Operación cancelada.")
        case .trialExpired: return tr("El periodo de prueba terminó. Activa Cabrio Premium para seguir usándola; tus archivos no se han tocado.")
        }
    }
}

public enum JobState: Sendable, Equatable {
    case queued
    case running
    case progress(Double)
    case succeeded([URL])
    case failed(String)
    case cancelled
}

public struct Job: Identifiable, Sendable {
    public let id: UUID
    public let inputs: [FileItem]
    public let operation: CabrioOperation
    public var state: JobState

    public init(id: UUID = UUID(), inputs: [FileItem], operation: CabrioOperation, state: JobState = .queued) {
        self.id = id
        self.inputs = inputs
        self.operation = operation
        self.state = state
    }
}

public struct HistoryEntry: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let date: Date
    public let operation: CabrioOperation
    public let inputs: [URL]
    public let outputs: [URL]
    public let reports: [CompressionReport]
    /// Renombrados hechos: permiten deshacer devolviendo cada archivo a su nombre.
    public let moves: [FileMove]

    public init(id: UUID = UUID(), date: Date = Date(), operation: CabrioOperation, inputs: [URL], outputs: [URL],
                reports: [CompressionReport] = [], moves: [FileMove] = []) {
        self.reports = reports
        self.moves = moves
        self.id = id
        self.date = date
        self.operation = operation
        self.inputs = inputs
        self.outputs = outputs
    }
}

/// Nombre de salida: `<nombre>_cabrio.<ext>`; si existe, `-2`, `-3`… (cabrio.md §7.1).
public enum OutputNaming {
    /// Sufijo de los resultados: sin separadores de ruta ni caracteres de control, y de largo razonable.
    public static func sanitizeSuffix(_ s: String) -> String {
        let cleaned = String(s.filter { !"/:\\".contains($0) && $0.unicodeScalars.allSatisfy { $0.value >= 32 } })
        return String(cleaned.prefix(24))
    }

    public static func candidate(base: String, suffix: String, ext: String, index: Int) -> String {
        let n = index <= 1 ? "" : "-\(index)"
        return ext.isEmpty ? "\(base)\(suffix)\(n)" : "\(base)\(suffix)\(n).\(ext)"
    }

    public static func firstFree(base: String, suffix: String, ext: String, exists: (String) -> Bool) -> String {
        var i = 1
        while exists(candidate(base: base, suffix: suffix, ext: ext, index: i)) { i += 1 }
        return candidate(base: base, suffix: suffix, ext: ext, index: i)
    }
}

/// Interpreta rangos de páginas escritos por una persona: «1-3, 5, 8-» (8- = hasta el final).
public enum PageRanges {
    public static func parse(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let hint = tr("Usa por ejemplo: 1-3, 5, 8-")
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            throw CabrioError.unsupported(tr("Escribe las páginas que quieres separar. %@", hint))
        }
        var result: [ClosedRange<Int>] = []
        for t in tokens {
            let bad = CabrioError.unsupported(tr("No entiendo «%@». %@", t, hint))
            let parts = t.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let lo: Int, hi: Int
            switch parts.count {
            case 1:
                guard let n = Int(parts[0]) else { throw bad }
                lo = n; hi = n
            case 2:
                guard let a = Int(parts[0]) else { throw bad }
                if parts[1].isEmpty { hi = pageCount } else if let b = Int(parts[1]) { hi = b } else { throw bad }
                lo = a
            default: throw bad
            }
            guard lo >= 1, lo <= hi else { throw bad }
            guard hi <= pageCount else {
                throw CabrioError.unsupported(tr("El PDF tiene %d páginas y «%@» se pasa.", pageCount, t))
            }
            if !result.contains(lo...hi) { result.append(lo...hi) }
        }
        return result
    }
}

/// Plantillas de nombre: «{name}-{n:3}», «{date}_{parent}»…
public enum RenameTemplate {
    public static var help: String { tr("Usa {name}, {n}, {n:3}, {date}, {created} o {parent}.") }

    public static func render(_ template: String, name: String, parent: String, index: Int, start: Int,
                              created: Date?, modified: Date?) throws -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "{" else { out.append(c); i = template.index(after: i); continue }
            guard let close = template[i...].firstIndex(of: "}") else {
                throw CabrioError.unsupported(tr("Falta cerrar una llave «}». %@", help))
            }
            let body = String(template[template.index(after: i)..<close])
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = parts[0].lowercased()
            let arg = parts.count > 1 ? parts[1] : nil
            switch key {
            case "name": out += name
            case "parent": out += parent
            case "n":
                let width = arg.flatMap(Int.init) ?? 1
                guard (1...10).contains(width) else { throw CabrioError.unsupported(tr("{n:%@} no es válido: usa un ancho de 1 a 10.", arg ?? "")) }
                out += String(format: "%0\(width)d", start + index)
            case "date", "created":
                let date = key == "date" ? modified : created
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = (arg?.isEmpty == false) ? arg! : "yyyy-MM-dd"
                out += f.string(from: date ?? Date())
            default:
                throw CabrioError.unsupported(tr("No conozco el marcador {%@}. %@", parts[0], help))
            }
            i = template.index(after: close)
        }
        return out
    }

    /// Quita lo que los nombres de archivo no admiten y normaliza a NFC.
    public static func sanitize(_ s: String) throws -> String {
        var t = String(s.map { "/:\\".contains($0) ? "-" : $0 }.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } })
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        t = t.precomposedStringWithCanonicalMapping
        guard !t.isEmpty else { throw CabrioError.unsupported(tr("El nombre quedó vacío. Revisa la plantilla.")) }
        guard t.utf8.count <= 240 else { throw CabrioError.unsupported(tr("El nombre resultante es demasiado largo.")) }
        return t
    }
}
