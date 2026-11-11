import Foundation

/// Subcarpeta dentro del destino de una regla.
public enum Subfolder: String, Sendable, Codable, Hashable, CaseIterable {
    case none, byYear, byMonth, byKind

    public func name(for kind: FileKind, date: Date?) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch self {
        case .none: return nil
        case .byYear: f.dateFormat = "yyyy"; return f.string(from: date ?? Date())
        case .byMonth: f.dateFormat = "yyyy-MM"; return f.string(from: date ?? Date())
        case .byKind:
            switch kind {
            case .image: return tr("Imágenes")
            case .pdf: return tr("PDF")
            case .video: return tr("Video")
            case .audio: return tr("Audio")
            case .officeDocument: return tr("Documentos")
            case .archive: return tr("Comprimidos")
            case .folder: return tr("Carpetas")
            case .other: return tr("Otros")
            }
        }
    }
}

public enum RuleAction: Sendable, Codable, Hashable {
    case moveTo(folder: URL, subfolder: Subfolder)
    /// Nunca borra de forma permanente: va a la Papelera y se puede deshacer.
    case moveToTrash
    /// Crea la copia convertida junto al original; el original se conserva.
    case convertImage(ImageFormat)
}

public struct RuleCondition: Sendable, Codable, Hashable {
    public var kinds: Set<FileKind>
    /// Sin punto, en minúsculas.
    public var extensions: [String]
    /// Coincide si el nombre contiene cualquiera (sin distinguir mayúsculas ni tildes).
    public var nameContains: [String]
    public var olderThanDays: Int?
    public var largerThanBytes: Int64?

    public init(kinds: Set<FileKind> = [], extensions: [String] = [], nameContains: [String] = [],
                olderThanDays: Int? = nil, largerThanBytes: Int64? = nil) {
        self.kinds = kinds
        self.extensions = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
        self.nameContains = nameContains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.olderThanDays = olderThanDays
        self.largerThanBytes = largerThanBytes
    }

    /// Una condición vacía no coincide con nada: una regla sin criterios movería todos los archivos.
    public var isEmpty: Bool {
        kinds.isEmpty && extensions.isEmpty && nameContains.isEmpty && olderThanDays == nil && largerThanBytes == nil
    }

    public func matches(name: String, kind: FileKind, size: Int64, created: Date?, modified: Date?, now: Date) -> Bool {
        guard !isEmpty else { return false }
        if !kinds.isEmpty, !kinds.contains(kind) { return false }
        if !extensions.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            if !extensions.contains(ext) { return false }
        }
        if !nameContains.isEmpty,
           !nameContains.contains(where: { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) { return false }
        if let days = olderThanDays {
            guard let date = created ?? modified, now.timeIntervalSince(date) >= Double(days) * 86_400 else { return false }
        }
        if let limit = largerThanBytes, size <= limit { return false }
        return true
    }
}

public struct Rule: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var folder: URL
    /// Marcador de seguridad de la carpeta (necesario cuando la app corra con sandbox).
    public var bookmark: Data?
    public var condition: RuleCondition
    public var actions: [RuleAction]
    public var isEnabled: Bool
    /// El usuario confirmó, viendo cuántos archivos afectaría, que la regla actúe sola. Solo importa en las reglas
    /// que lo exigen (`requiresApproval`). Las reglas guardadas antes de existir este campo quedan sin aprobar.
    public var isApproved: Bool

    public init(id: UUID = UUID(), name: String, folder: URL, bookmark: Data? = nil, condition: RuleCondition,
                actions: [RuleAction], isEnabled: Bool = true, isApproved: Bool = false) {
        self.id = id
        self.name = name
        self.folder = folder
        self.bookmark = bookmark
        self.condition = condition
        self.actions = actions
        self.isEnabled = isEnabled
        self.isApproved = isApproved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decode(URL.self, forKey: .folder)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        condition = try c.decode(RuleCondition.self, forKey: .condition)
        actions = try c.decode([RuleAction].self, forKey: .actions)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        isApproved = try c.decodeIfPresent(Bool.self, forKey: .isApproved) ?? false
    }

    /// Reglas que dependen solo del tiempo: los eventos de archivos nuevos no las activan, se revisan cada tanto.
    public var isAgeBased: Bool { condition.olderThanDays != nil }

    /// Las que pueden hacer daño sin que el usuario mire (antigüedad o Papelera) piden confirmación explícita antes
    /// de su primera ejecución automática.
    public var requiresApproval: Bool {
        isAgeBased || actions.contains { if case .moveToTrash = $0 { return true } else { return false } }
    }

    /// Puede actuar sin intervención (eventos y barridos programados).
    public var mayRunUnattended: Bool { !requiresApproval || isApproved }

    /// La aprobación vale para lo que se confirmó: si cambia lo que la regla afecta, hay que volver a confirmar.
    public func sameScope(as other: Rule) -> Bool {
        folder.standardizedFileURL == other.folder.standardizedFileURL && condition == other.condition && actions == other.actions
    }
}

/// Carpetas que no se pueden vigilar: demasiado amplias o del sistema.
public enum RuleFolderPolicy {
    public static func isForbidden(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func norm(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        let path = norm(url)
        let homePath = norm(home)
        if path == "/" || path == homePath || path == "/Users" { return true }
        let exact: Set<String> = ["/Applications"]
        if exact.contains(path) { return true }
        let trees = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Applications/Utilities",
                     homePath + "/Library"]
        return trees.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// Archivos que Cabrio no debe tocar: ocultos, descargas a medias y temporales de Office.
public enum RuleFileFilter {
    private static let temporaryExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
    public static func isIgnorable(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$") || temporaryExtensions.contains((name as NSString).pathExtension.lowercased())
            || name.hasSuffix("~") || name.hasPrefix("Unconfirmed ")
    }
}
