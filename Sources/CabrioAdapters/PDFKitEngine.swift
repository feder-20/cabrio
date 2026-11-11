import Foundation
import AppKit
import PDFKit
import ImageIO
import CabrioDomain
import CabrioPorts

public struct PDFKitEngine: PDFEngine {
    public init() {}

    public func merge(_ inputs: [URL], into output: URL) async throws {
        let result = PDFDocument()
        var sources: [PDFDocument] = []   // se conservan vivos hasta escribir
        var index = 0
        for url in inputs {
            try Task.checkCancellation()
            guard let doc = PDFDocument(url: url) else { throw CabrioError.unreadableFile(url.lastPathComponent) }
            if doc.isLocked { throw CabrioError.passwordRequired(url.lastPathComponent) }
            sources.append(doc)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                result.insert(page, at: index)
                index += 1
            }
        }
        guard index > 0 else { throw CabrioError.unreadableFile(inputs.first?.lastPathComponent ?? "") }
        guard result.write(to: output) else { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
        _ = sources
    }

    public func makePDF(fromImages images: [URL], output: URL) async throws {
        let result = PDFDocument()
        for (i, url) in images.enumerated() {
            try Task.checkCancellation()
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 8000,
                  ] as CFDictionary),
                  let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            else { throw CabrioError.unreadableFile(url.lastPathComponent) }
            result.insert(page, at: i)
        }
        guard result.pageCount > 0, result.write(to: output) else {
            throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir."))
        }
    }

    public func compress(_ input: URL, target: CompressionTarget, output: URL,
                         progress: @Sendable (Double) -> Void) async throws -> CompressionReport {
        try PDFCompressor.compress(input, target: target, output: output, progress: progress)
    }

    public func protect(_ input: URL, password: String, output: URL) async throws {
        try PDFPasswordTool.protect(input: input, password: password, output: output)
    }

    public func unlock(_ input: URL, password: String, output: URL) async throws {
        try PDFPasswordTool.unlock(input: input, password: password, output: output)
    }

    public func pageCount(of input: URL) async throws -> Int {
        guard let doc = PDFDocument(url: input) else { throw CabrioError.unreadableFile(input.lastPathComponent) }
        if doc.isLocked { throw CabrioError.passwordRequired(input.lastPathComponent) }
        return doc.pageCount
    }

    public func split(_ input: URL, ranges: [ClosedRange<Int>], outputs: [URL]) async throws {
        guard ranges.count == outputs.count else { throw CabrioError.unsupported(tr("Rangos y archivos no coinciden.")) }
        guard let doc = PDFDocument(url: input) else { throw CabrioError.unreadableFile(input.lastPathComponent) }
        if doc.isLocked { throw CabrioError.passwordRequired(input.lastPathComponent) }
        for (range, out) in zip(ranges, outputs) {
            try Task.checkCancellation()
            let part = PDFDocument()
            var index = 0
            for number in range {
                guard number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1)?.copy() as? PDFPage else {
                    throw CabrioError.unsupported(tr("El PDF tiene %d páginas.", doc.pageCount))
                }
                part.insert(page, at: index)
                index += 1
            }
            guard part.write(to: out) else { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
        }
    }
}
