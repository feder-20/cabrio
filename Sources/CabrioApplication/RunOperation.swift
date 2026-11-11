import Foundation
import CabrioDomain
import CabrioPorts

/// Caso de uso: ejecuta una operación, guarda el resultado junto al original y lo anota en el historial.
public final class RunOperation: Sendable {
    private let pdf: PDFEngine
    private let image: ImageEngine
    private let archive: ArchiveEngine
    private let media: MediaEngine
    private let ocr: OCREngine
    private let fs: FileSystem
    private let history: HistoryStore
    private let suffixProvider: @Sendable () -> String

    public init(pdf: PDFEngine, image: ImageEngine, archive: ArchiveEngine,
                media: MediaEngine, ocr: OCREngine, fileSystem: FileSystem, history: HistoryStore, suffix: @escaping @Sendable () -> String = { "_cabrio" }) {
        self.pdf = pdf
        self.image = image
        self.archive = archive
        self.media = media
        self.ocr = ocr
        self.fs = fileSystem
        self.history = history
        self.suffixProvider = suffix
    }

    @discardableResult
    public func callAsFunction(_ op: CabrioOperation, inputs: [URL],
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> [URL] {
        guard let first = inputs.first else { throw CabrioError.notEnoughFiles }
        let dir = first.deletingLastPathComponent()
        let suffix = suffixProvider()   // se lee una vez por operación: un cambio en Ajustes no parte un lote
        var outputs: [URL] = []
        var reports: [CompressionReport] = []
        var renames: [FileMove] = []
        var rollback: [() -> Void] = []

        func freeURL(base: String, suffix: String, ext: String) -> URL {
            let name = OutputNaming.firstFree(base: base, suffix: suffix, ext: ext) { candidate in
                let url = dir.appendingPathComponent(candidate)
                return fs.exists(url) || outputs.contains(url)
            }
            return dir.appendingPathComponent(name)
        }

        do {
            switch op {
            case .folderRule:
                throw CabrioError.unsupported(tr("Las reglas de carpeta se ejecutan solas, no desde aquí."))

            case .batchRename(let spec):
                let moves = try RenamePlanner(fileSystem: fs).plan(inputs, spec: spec)
                guard !moves.isEmpty else {
                    throw CabrioError.unsupported(tr("Los nombres ya son los que pediste: no hay nada que cambiar."))
                }
                try applyMoves(moves, rollback: &rollback)
                renames = moves
                outputs = moves.map(\.to)
                progress?(1)

            case .compressImage(let level):
                let (quality, side): (Double, Int) = switch level {
                case .low: (0.85, 3000)
                case .medium: (0.7, 2000)
                case .high: (0.55, 1200)
                }
                for input in inputs {
                    try Task.checkCancellation()
                    let format = ImageFormat(fileExtension: input.pathExtension)
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: format.fileExtension)
                    outputs.append(out)
                    try await image.convert(input, to: format, quality: quality, maxSide: side, output: out)
                    progress?(Double(outputs.count) / Double(inputs.count))
                }

            case .removeBackground:
                for input in inputs {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "png")
                    outputs.append(out)
                    try await image.removeBackground(input, output: out)
                    progress?(Double(outputs.count) / Double(inputs.count))
                }

            case .compressVideo(let target, let hevc):
                let count = Double(inputs.count)
                for (i, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "mp4")
                    outputs.append(out)
                    let done = Double(i)
                    reports.append(try await media.compressVideo(input, target: target, hevc: hevc, output: out) { f in
                        progress?((done + f) / count)
                    })
                }

            case .audioToM4A:
                let count = Double(inputs.count)
                for (i, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "m4a")
                    outputs.append(out)
                    let done = Double(i)
                    try await media.audioToM4A(input, output: out) { f in progress?((done + f) / count) }
                }

            case .compressPDF(let target):
                let count = Double(inputs.count)
                for (i, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "pdf")
                    outputs.append(out)
                    let done = Double(i)
                    reports.append(try await pdf.compress(input, target: target, output: out) { f in
                        progress?((done + f) / count)
                    })
                }

            case .protectPDF(let password), .unlockPDF(let password):
                var isProtect = false
                if case .protectPDF = op { isProtect = true }
                let count = Double(inputs.count)
                for (i, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "pdf")
                    outputs.append(out)
                    if isProtect { try await pdf.protect(input, password: password.value, output: out) }
                    else { try await pdf.unlock(input, password: password.value, output: out) }
                    progress?(Double(i + 1) / count)
                }

            case .splitPDF(let mode):
                guard inputs.count == 1 else { throw CabrioError.unsupported(tr("Divide un PDF a la vez.")) }
                let total = try await pdf.pageCount(of: first)
                guard total > 0 else { throw CabrioError.unreadableFile(first.lastPathComponent) }
                let ranges: [ClosedRange<Int>]
                switch mode {
                case .everyPage: ranges = (1...total).map { $0...$0 }
                case .ranges(let text): ranges = try PageRanges.parse(text, pageCount: total)
                }
                let base = first.deletingPathExtension().lastPathComponent
                let folder = freeURL(base: base, suffix: suffix, ext: "")
                outputs.append(folder)
                try fs.createDirectory(folder)
                let width = String(total).count
                func pad(_ n: Int) -> String { String(format: "%0\(width)d", n) }
                let files = ranges.map { r -> URL in
                    let label = r.lowerBound == r.upperBound ? pad(r.lowerBound) : "\(pad(r.lowerBound))-\(pad(r.upperBound))"
                    return folder.appendingPathComponent("\(base)_p\(label).pdf")
                }
                try await pdf.split(first, ranges: ranges, outputs: files)
                progress?(1)

            case .ocr(let languages):
                let count = Double(inputs.count)
                for (i, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "pdf")
                    outputs.append(out)
                    let done = Double(i)
                    try await ocr.makeSearchable(input, languages: languages, output: out) { f in
                        progress?((done + f) / count)
                    }
                }

            case .mergePDFs:
                guard inputs.count >= 2 else { throw CabrioError.notEnoughFiles }
                let out = freeURL(base: first.deletingPathExtension().lastPathComponent, suffix: suffix, ext: "pdf")
                outputs.append(out)
                try await pdf.merge(inputs, into: out)

            case .imagesToPDF:
                let base = first.deletingPathExtension().lastPathComponent
                let out = freeURL(base: base, suffix: suffix, ext: "pdf")
                outputs.append(out)
                try await pdf.makePDF(fromImages: inputs, output: out)

            case .convertImage(let format, let quality):
                for input in inputs {
                    try Task.checkCancellation()
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent,
                                      suffix: suffix, ext: format.fileExtension)
                    outputs.append(out)
                    try await image.convert(input, to: format, quality: quality, maxSide: nil, output: out)
                }

            case .resizeImage(let maxSide):
                for input in inputs {
                    try Task.checkCancellation()
                    let format = ImageFormat(fileExtension: input.pathExtension)
                    let out = freeURL(base: input.deletingPathExtension().lastPathComponent,
                                      suffix: suffix, ext: format.fileExtension)
                    outputs.append(out)
                    try await image.convert(input, to: format, quality: 0.8, maxSide: maxSide, output: out)
                }

            case .cleanZip(let name):
                let out = freeURL(base: name, suffix: "", ext: "zip")
                outputs.append(out)
                try await archive.cleanZip(inputs, output: out)
            }
        } catch {
            // Renombrados a medias: se devuelven a su nombre. Nunca se manda a la Papelera un archivo renombrado.
            for undo in rollback.reversed() { undo() }
            // Solo se retira lo que Cabrio creó a medias, y a la Papelera; los originales no se tocan.
            if renames.isEmpty { for out in outputs where fs.exists(out) { try? fs.moveToTrash(out) } }
            if error is CancellationError { throw CabrioError.cancelled }
            if let e = error as? CabrioError { throw e }
            throw CabrioError.writeFailed(error.localizedDescription)
        }

        // La contraseña nunca llega al historial: ni en memoria ni persistida.
        var recorded = op
        switch op {
        case .protectPDF: recorded = .protectPDF(password: SecretRef(""))
        case .unlockPDF: recorded = .unlockPDF(password: SecretRef(""))
        default: break
        }
        await history.record(HistoryEntry(operation: recorded, inputs: inputs, outputs: outputs, reports: reports, moves: renames))
        return outputs
    }

    /// Deshace una operación: los resultados van a la Papelera. Los originales nunca se modificaron.
    public func undo(_ id: UUID) async throws {
        guard let entry = await history.entry(id: id) else { return }
        if !entry.moves.isEmpty {
            let back = entry.moves.map { FileMove(from: $0.to, to: $0.from) }
            if let missing = back.first(where: { !fs.exists($0.from) }) {
                throw CabrioError.writeFailed(tr("«%@» ya no está donde Cabrio lo dejó.", missing.from.lastPathComponent))
            }
            var rollback: [() -> Void] = []
            do { try applyMoves(back, rollback: &rollback) }
            catch { for undo in rollback.reversed() { undo() }; throw error }
            // Resultados que una regla creó además de mover (p. ej. una conversión): a la Papelera.
            let moved = Set(entry.moves.map(\.to))
            for out in entry.outputs where !moved.contains(out) && fs.exists(out) { _ = try? fs.moveToTrash(out) }
            await history.remove(id: id)
            return
        }
        for out in entry.outputs where fs.exists(out) { try fs.moveToTrash(out) }
        await history.remove(id: id)
    }

    /// Mueve archivos sin pisar nunca otro. Si un destino es el nombre actual de otro archivo del lote
    /// (por ejemplo, intercambiar a↔b), pasa primero por nombres temporales.
    private func applyMoves(_ moves: [FileMove], rollback: inout [() -> Void]) throws {
        let sources = Set(moves.map { $0.from.path.lowercased() })
        for m in moves where fs.exists(m.to) && !sources.contains(m.to.path.lowercased()) {
            throw CabrioError.writeFailed(tr("Ya existe «%@».", m.to.lastPathComponent))
        }
        let chained = moves.contains { m in
            let key = m.to.path.lowercased()
            return sources.contains(key) && key != m.from.path.lowercased()
        }
        let caseOnly = moves.contains { $0.to.path.lowercased() == $0.from.path.lowercased() }
        if !chained && !caseOnly {
            for m in moves {
                try fs.moveItem(from: m.from, to: m.to)
                rollback.append { [fs] in try? fs.moveItem(from: m.to, to: m.from) }
            }
            return
        }
        var temps: [(FileMove, URL)] = []
        for m in moves {
            let tmp = m.from.deletingLastPathComponent().appendingPathComponent(".cabrio-\(UUID().uuidString)")
            try fs.moveItem(from: m.from, to: tmp)
            rollback.append { [fs] in try? fs.moveItem(from: tmp, to: m.from) }
            temps.append((m, tmp))
        }
        for (m, tmp) in temps {
            try fs.moveItem(from: tmp, to: m.to)
            rollback.append { [fs] in try? fs.moveItem(from: m.to, to: tmp) }
        }
    }
}
