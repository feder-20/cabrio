import Foundation
import CabrioDomain

/// Qué ocurre al elegir una acción: se ejecuta de inmediato o primero pide opciones.
public enum ActionKind: Sendable, Hashable {
    case immediate(CabrioOperation)
    case needsSplitOptions
    case needsOCROptions
    case needsCompressOptions
    case needsProtectOptions
    case needsUnlockOptions
    case needsImageFormatOptions
    case needsVideoOptions
    case needsRenameOptions
}

public struct ActionDef: Identifiable, Sendable, Hashable {
    public let id: String
    /// Texto en español; también es la clave de localización.
    public let title: String
    public let symbol: String
    public let kind: ActionKind

    public init(id: String, title: String, symbol: String, kind: ActionKind) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
    }

    public init(id: String, title: String, symbol: String, operation: CabrioOperation) {
        self.init(id: id, title: title, symbol: symbol, kind: .immediate(operation))
    }
}

/// Acciones que se ofrecen según el tipo de lo que se suelta (cabrio.md §4.3).
public enum ActionCatalog {
    public static let reducedSide = 1600

    public static func actions(for items: [FileItem]) -> [ActionDef] {
        let base = typeActions(for: items)
        guard !items.isEmpty else { return base }
        return base + [ActionDef(id: "rename", title: "Renombrar", symbol: "textformat.123", kind: .needsRenameOptions)]
    }

    private static func typeActions(for items: [FileItem]) -> [ActionDef] {
        guard !items.isEmpty else { return [] }
        let kinds = Set(items.map(\.kind))

        if kinds == [.pdf] {
            let many = items.count >= 2
            var list: [ActionDef] = [
                ActionDef(id: "compress", title: many ? "Comprimir todos" : "Comprimir",
                          symbol: "arrow.down.right.and.arrow.up.left", kind: .needsCompressOptions),
            ]
            if many {
                list.append(ActionDef(id: "merge", title: "Unir PDF", symbol: "doc.on.doc", operation: .mergePDFs))
            } else {
                list.append(ActionDef(id: "split", title: "Dividir", symbol: "scissors", kind: .needsSplitOptions))
            }
            list.append(ActionDef(id: "ocr", title: "Hacer buscable", symbol: "text.viewfinder", kind: .needsOCROptions))
            list.append(ActionDef(id: "protect", title: many ? "Proteger todos" : "Proteger", symbol: "lock", kind: .needsProtectOptions))
            list.append(ActionDef(id: "unlock", title: "Quitar contraseña", symbol: "lock.open", kind: .needsUnlockOptions))
            return list
        }
        if kinds == [.image] {
            return [
                ActionDef(id: "convert", title: "Convertir formato", symbol: "photo", kind: .needsImageFormatOptions),
                ActionDef(id: "icompress", title: "Comprimir", symbol: "arrow.down.right.and.arrow.up.left", operation: .compressImage(.medium)),
                ActionDef(id: "resize", title: "Reducir a 1600 px", symbol: "arrow.down.forward.and.arrow.up.backward", operation: .resizeImage(maxSide: reducedSide)),
                ActionDef(id: "bg", title: "Quitar fondo", symbol: "person.crop.circle.badge.minus", operation: .removeBackground),
                items.count == 1
                    ? ActionDef(id: "topdf", title: "Convertir a PDF", symbol: "doc.richtext", operation: .imagesToPDF)
                    : ActionDef(id: "topdf", title: "Unir en un PDF", symbol: "doc.richtext", operation: .imagesToPDF),
            ]
        }
        if kinds == [.video] {
            return [
                ActionDef(id: "vcompress", title: "Comprimir", symbol: "arrow.down.right.and.arrow.up.left", kind: .needsVideoOptions),
                ActionDef(id: "tomp4", title: "Convertir a MP4", symbol: "film", operation: .compressVideo(.keepQuality, hevc: false)),
                ActionDef(id: "extract", title: "Extraer audio", symbol: "waveform", operation: .audioToM4A),
            ]
        }
        if kinds == [.audio] {
            return [ActionDef(id: "tom4a", title: "Convertir a M4A", symbol: "waveform", operation: .audioToM4A)]
        }
        // Carpeta, mezcla u otros tipos.
        return [ActionDef(id: "zip", title: "ZIP para Windows", symbol: "archivebox", operation: .cleanZip(name: zipName(items)))]
    }

    static func zipName(_ items: [FileItem]) -> String {
        if items.count == 1 { return items[0].url.deletingPathExtension().lastPathComponent }
        return "Archivos"
    }
}
