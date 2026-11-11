import Foundation
import CoreGraphics
import ImageIO
import Compression
import PDFKit
import UniformTypeIdentifiers
import CabrioDomain

/// Compresión de PDF sin rasterizar páginas: se reescribe el documento y solo se recomprimen
/// las imágenes (JPEG y Flate de 8 bits). Texto, vectores, enlaces y metadatos quedan intactos.
enum PDFCompressor {
    struct Setting { let dpi: Double; let quality: Double }

    /// Del más suave al más agresivo (cabrio.md §7.1: 300, 200, 150, 110, 96 y calidad 0,8 a 0,4).
    static let ladder: [Setting] = [
        Setting(dpi: 300, quality: 0.80), Setting(dpi: 200, quality: 0.75), Setting(dpi: 150, quality: 0.65),
        Setting(dpi: 110, quality: 0.55), Setting(dpi: 96, quality: 0.45), Setting(dpi: 72, quality: 0.40),
    ]

    static func setting(for level: CompressionLevel) -> Setting {
        switch level {
        case .low: return ladder[1]
        case .medium: return ladder[2]
        case .high: return ladder[4]
        }
    }

    // MARK: Punto de entrada

    static func compress(_ input: URL, target: CompressionTarget, output: URL,
                         progress: @Sendable (Double) -> Void) throws -> CompressionReport {
        let originalBytes = Int64((try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let doc = PDFDocument(url: input) else { throw CabrioError.unreadableFile(input.lastPathComponent) }
        if doc.isLocked { throw CabrioError.passwordRequired(input.lastPathComponent) }

        var maxLongInches = 8.5
        for i in 0..<doc.pageCount {
            if let b = doc.page(at: i)?.bounds(for: .mediaBox) {
                let long = Double(max(b.width, b.height)) / 72
                if long.isFinite { maxLongInches = max(maxLongInches, long) }
            }
        }
        // Un /MediaBox falso (hasta 14 400 pt por especificación) no debe anular la reducción de imágenes.
        maxLongInches = min(maxLongInches, PDFLimits.maxPageInches)
        // Se trabaja sobre los bytes originales: reescribir con PDFKit pierde parte del mapa de texto.
        guard let original = try? Data(contentsOf: input, options: .mappedIfSafe), let file = try? PDFRawFile(data: original), !file.isEncrypted else {
            return try copyOriginal(input, output, originalBytes, target)
        }
        let images = imageObjects(in: file)
        let iterations = Double(target.isMeta ? 4 : 1)
        var finished = 0.0

        func build(_ s: Setting) throws -> Data {
            let data = try rewrite(file, images: images, setting: s, maxLongInches: maxLongInches) { f in
                progress(min((finished + f) / iterations, 0.99))
            }
            finished += 1
            return data
        }

        var best: Data
        var reached = true
        var targetBytes: Int64?
        switch target {
        case .level(let level):
            best = try build(setting(for: level))
        case .maxBytes(let limit):
            targetBytes = limit
            // Búsqueda binaria sobre la escalera: el ajuste más suave que cumpla la meta.
            var lo = 0, hi = ladder.count - 1
            var candidate = try build(ladder[hi])          // lo más agresivo
            if Int64(candidate.count) > limit {
                reached = false
                best = candidate
            } else {
                best = candidate
                hi -= 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    candidate = try build(ladder[mid])
                    if Int64(candidate.count) <= limit { best = candidate; hi = mid - 1 } else { lo = mid + 1 }
                }
            }
        }

        if Int64(best.count) >= originalBytes {   // no se ganó nada: se entrega el original tal cual
            return try copyOriginal(input, output, originalBytes, target)
        }
        do { try best.write(to: output, options: .atomic) }
        catch { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
        progress(1)
        if let limit = targetBytes { reached = Int64(best.count) <= limit }
        return CompressionReport(originalBytes: originalBytes, resultBytes: Int64(best.count),
                                 targetBytes: targetBytes, reachedTarget: reached)
    }

    private static func copyOriginal(_ input: URL, _ output: URL, _ originalBytes: Int64,
                                     _ target: CompressionTarget) throws -> CompressionReport {
        do { try FileManager.default.copyItem(at: input, to: output) }
        catch { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
        var limit: Int64?
        if case .maxBytes(let l) = target { limit = l }
        return CompressionReport(originalBytes: originalBytes, resultBytes: originalBytes, targetBytes: limit,
                                 reachedTarget: limit.map { originalBytes <= $0 } ?? true)
    }

    // MARK: Imágenes

    struct PDFImage {
        let number: Int
        let gen: Int
        let dict: [String: PDFValue]
        let stream: Range<Int>
    }

    /// Claves que sabemos reproducir; si hay otras (máscaras de color, Decode…) la imagen no se toca.
    private static let allowedKeys: Set<String> = [
        "Type", "Subtype", "Width", "Height", "ColorSpace", "BitsPerComponent", "Filter", "DecodeParms",
        "Length", "SMask", "Interpolate", "Name", "Intent", "Matte",
    ]

    static func imageObjects(in file: PDFRawFile) -> [PDFImage] {
        var result: [PDFImage] = []
        for e in file.extents {
            // Descarte rápido: solo se analizan los objetos cuya cabecera menciona /Image.
            let headEnd = min(e.offset + 400, e.end)
            let head = String(decoding: file.bytes[e.offset..<max(headEnd, e.offset)], as: UTF8.self)
            guard head.contains("/Image"), let parsed = file.parse(e.number),
                  case .dict(let d) = parsed.value, d["Subtype"]?.name == "Image",
                  let stream = parsed.stream, Set(d.keys).isSubset(of: allowedKeys),
                  d["ImageMask"] == nil else { continue }
            result.append(PDFImage(number: e.number, gen: e.gen, dict: d, stream: stream))
        }
        return result
    }

    static func components(_ cs: PDFValue?, in file: PDFRawFile, depth: Int = 0) -> Int? {
        guard depth < 8 else { return nil }   // «6 0 obj 6 0 R»: una cadena de referencias no puede ser infinita
        switch cs {
        case .raw(let r)? where r.hasSuffix(" R"):
            guard let ref = PDFValue.raw(r).refNumber, let inner = file.parse(ref)?.value else { return nil }
            return components(inner, in: file, depth: depth + 1)
        case .raw("/DeviceRGB")?: return 3
        case .raw("/DeviceGray")?: return 1
        case .array(let a)?:
            if a.count == 2, a[0].name == "ICCBased", let ref = a[1].refNumber,
               let n = file.parse(ref)?.value.dict?["N"]?.int, n == 1 || n == 3 { return n }
            return nil
        default: return nil
        }
    }

    static func decode(_ img: PDFImage, in file: PDFRawFile) -> (cg: CGImage, gray: Bool)? {
        let f = PDFCodec.filterNames(img.dict)
        guard f.count == 1 else { return nil }
        let slice = file.bytes[img.stream]
        if f[0] == "DCTDecode" {
            guard let src = CGImageSourceCreateWithData(Data(slice) as CFData, nil),
                  dimensionsAreSafe(src),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let model = cg.colorSpace?.model else { return nil }
            if model == .rgb { return (cg, false) }
            if model == .monochrome { return (cg, true) }
            return nil   // CMYK y otros: se dejan como están
        }
        guard f[0] == "FlateDecode",
              let w = file.intValue(of: img.dict["Width"]), let h = file.intValue(of: img.dict["Height"]),
              file.intValue(of: img.dict["BitsPerComponent"]) == 8,
              let comps = components(img.dict["ColorSpace"], in: file),
              (1...PDFLimits.maxSide).contains(w), (1...PDFLimits.maxSide).contains(h),
              w * h >= 100_000, w * h <= PDFLimits.maxPixels else { return nil }
        let parms = PDFCodec.decodeParms(img.dict)
        let predictor = parms["Predictor"]?.int ?? 1
        let colors = parms["Colors"]?.int ?? comps
        let columns = parms["Columns"]?.int ?? w
        guard colors == comps, columns == w, predictor == 1 || predictor >= 10 else { return nil }
        let rowBytes = w * comps
        let expected = h * (rowBytes + (predictor >= 10 ? 1 : 0))
        // Con lados ≤ 20 000, w·h ≤ 100 Mpx y ≤ 3 componentes no hay desbordes; el tope de salida es el tamaño
        // esperado, así un /Width y /Height falsos o una bomba Flate se descartan sin reservar memoria.
        guard expected <= PDFLimits.maxInflatedBytes,
              var raw = PDFCodec.inflate(slice, hint: expected, limit: expected), raw.count == expected else { return nil }
        if predictor >= 10 {
            guard let un = PDFCodec.unfilterPNG(raw, rowBytes: rowBytes, bpp: comps, rows: h) else { return nil }
            raw = un
        }
        let space = comps == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * comps, bytesPerRow: rowBytes,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (cg, comps == 1)
    }

    /// Comprueba las dimensiones de un JPEG con los metadatos, antes de decodificarlo (bomba de píxeles).
    private static func dimensionsAreSafe(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...PDFLimits.maxSide).contains(w), (1...PDFLimits.maxSide).contains(h) else { return false }
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        return !overflow && pixels <= PDFLimits.maxPixels
    }

    static func recompress(_ cg: CGImage, gray: Bool, _ s: Setting, maxLongInches: Double) -> (data: Data, w: Int, h: Int)? {
        let allowed = max(Int((s.dpi * maxLongInches).rounded()), 1)
        let scale = min(1.0, Double(allowed) / Double(max(cg.width, cg.height)))
        let w = max(Int(Double(cg.width) * scale), 1), h = max(Int(Double(cg.height) * scale), 1)
        let ctx: CGContext?
        if gray {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: s.quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, w, h)
    }

    // MARK: Reescritura del archivo

    private static func rewrite(_ file: PDFRawFile, images: [PDFImage], setting s: Setting, maxLongInches: Double,
                                progress: (Double) -> Void) throws -> Data {
        var replacements: [Int: [UInt8]] = [:]
        for (i, img) in images.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(max(images.count, 1)))
            guard let (cg, gray) = decode(img, in: file),
                  let result = recompress(cg, gray: gray, s, maxLongInches: maxLongInches),
                  Double(result.data.count) < Double(img.stream.count) * 0.9 else { continue }
            var parts = "/Type /XObject /Subtype /Image /Width \(result.w) /Height \(result.h) "
            parts += "/ColorSpace /\(gray ? "DeviceGray" : "DeviceRGB") /BitsPerComponent 8 /Filter /DCTDecode "
            if let v = img.dict["Interpolate"] { parts += "/Interpolate \(v.serialized) " }
            if let v = img.dict["Matte"] { parts += "/Matte \(v.serialized) " }
            if let v = img.dict["SMask"] { parts += "/SMask \(v.serialized) " }
            var bytes = Array("\(img.number) \(img.gen) obj\n<< \(parts)/Length \(result.data.count) >>\nstream\n".utf8)
            bytes += result.data
            bytes += Array("\nendstream\nendobj\n".utf8)
            replacements[img.number] = bytes
        }

        return file.serialized(replacing: replacements)
    }
}

extension CompressionTarget {
    var isMeta: Bool { if case .maxBytes = self { return true } else { return false } }
}
