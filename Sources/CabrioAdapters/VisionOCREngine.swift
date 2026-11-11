import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision
import CabrioDomain
import CabrioPorts

/// OCR con Vision. Redibuja cada página original (contenido intacto) y añade texto invisible encima.
public struct VisionOCREngine: OCREngine {
    public init() {}

    static let languageMap = ["es": "es-ES", "en": "en-US", "pt": "pt-BR", "fr": "fr-FR", "de": "de-DE", "it": "it-IT"]
    /// Páginas que ya traen texto propio no se vuelven a reconocer.
    static let existingTextThreshold = 20

    public func makeSearchable(_ input: URL, languages: [String], output: URL,
                               progress: @Sendable (Double) -> Void) async throws {
        guard let cgDoc = CGPDFDocument(input as CFURL) else { throw CabrioError.unreadableFile(input.lastPathComponent) }
        if cgDoc.isEncrypted && !cgDoc.isUnlocked { throw CabrioError.passwordRequired(input.lastPathComponent) }
        let pageTotal = cgDoc.numberOfPages
        guard pageTotal > 0 else { throw CabrioError.unreadableFile(input.lastPathComponent) }
        let textDoc = PDFDocument(url: input)
        let wanted = languages.compactMap { Self.languageMap[$0] ?? $0 }

        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir."))
        }

        for number in 1...pageTotal {
            try Task.checkCancellation()
            guard let page = cgDoc.page(at: number) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
            var rect = CGRect(origin: .zero, size: size)
            let transform = page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)

            pdf.beginPage(mediaBox: &rect)
            pdf.saveGState()
            pdf.concatenate(transform)
            pdf.drawPDFPage(page)
            pdf.restoreGState()

            let existing = textDoc?.page(at: number - 1)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            if existing < Self.existingTextThreshold,
               let image = Self.render(page, transform: transform, size: size) {
                try Self.drawRecognizedText(on: image, into: pdf, pageSize: size, languages: wanted)
            }
            pdf.endPage()
            progress(Double(number) / Double(pageTotal))
        }
        pdf.closePDF()
    }

    /// Página a ~300 DPI en gris (máximo 6000 px por lado, para no agotar memoria).
    private static func render(_ page: CGPDFPage, transform: CGAffineTransform, size: CGSize) -> CGImage? {
        let scale = min(300.0 / 72.0, 6000.0 / max(size.width, size.height))
        let w = max(Int(size.width * scale), 1), h = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(transform)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    private static func drawRecognizedText(on image: CGImage, into ctx: CGContext,
                                           pageSize: CGSize, languages: [String]) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = languages.filter { supported.contains($0) }
        if !usable.isEmpty { request.recognitionLanguages = usable }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let box = observation.boundingBox   // normalizado, origen abajo a la izquierda
            let r = CGRect(x: box.minX * pageSize.width, y: box.minY * pageSize.height,
                           width: box.width * pageSize.width, height: box.height * pageSize.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(r.height * 0.9, 1), nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: candidate.string, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = CGAffineTransform(a: r.width / width, b: 0, c: 0, d: 1, tx: r.minX, ty: r.minY + r.height * 0.2)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
