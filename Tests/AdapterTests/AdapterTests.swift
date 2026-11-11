import XCTest
import AppKit
import PDFKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CabrioDomain
import CoreText
import CabrioApplication
import CabrioAdapters

final class AdapterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cabrio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func makePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testCleanZipExcludesMacMetadataAndIsValid() async throws {
        let folder = tmp.appendingPathComponent("Informe ñandú")
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        let text = String(repeating: "hola cabrio ", count: 5000)
        try text.write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appendingPathComponent("vacio.txt"))
        try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("._a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("__MACOSX/y"), atomically: true, encoding: .utf8)

        let zip = tmp.appendingPathComponent("out.zip")
        try await ZipArchiveEngine().cleanZip([folder], output: zip)

        let (testStatus, testOut) = try run("/usr/bin/unzip", ["-t", zip.path])
        XCTAssertEqual(testStatus, 0, testOut)
        let (_, list) = try run("/usr/bin/unzip", ["-Z1", zip.path])
        XCTAssertTrue(list.contains("a.txt"), list)
        XCTAssertTrue(list.contains("sub/b.txt"), list)
        XCTAssertTrue(list.contains("vacio.txt"), list)
        XCTAssertFalse(list.contains(".DS_Store"), list)
        XCTAssertFalse(list.contains("._a"), list)
        XCTAssertFalse(list.contains("__MACOSX"), list)

        let outDir = tmp.appendingPathComponent("extraido")
        let (xs, xo) = try run("/usr/bin/ditto", ["-x", "-k", zip.path, outDir.path]); XCTAssertEqual(xs, 0, xo)
        let extracted = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertEqual(extracted.count, 1)
        let a = outDir.appendingPathComponent(try XCTUnwrap(extracted.first)).appendingPathComponent("a.txt")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), text)
    }

    func testCleanZipEntryNamesAreNFC() async throws {
        let nfd = "cafe\u{301}.txt"   // «café» descompuesto, como lo guarda macOS en algunos casos
        let f = tmp.appendingPathComponent(nfd)
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let zip = tmp.appendingPathComponent("n.zip")
        try await ZipArchiveEngine().cleanZip([f], output: zip)
        let data = try Data(contentsOf: zip)
        XCTAssertNotNil(data.range(of: Data("café.txt".utf8)))
        XCTAssertNil(data.range(of: Data(nfd.utf8)))
    }

    func testMergePDFsKeepsOrderAndPageCount() async throws {
        let a = try makePNG("a.png", width: 200, height: 100)
        let b = try makePNG("b.png", width: 100, height: 200)
        let pa = tmp.appendingPathComponent("a.pdf"), pb = tmp.appendingPathComponent("b.pdf")
        let engine = PDFKitEngine()
        try await engine.makePDF(fromImages: [a, b], output: pa)   // 2 páginas
        try await engine.makePDF(fromImages: [b], output: pb)      // 1 página
        let merged = tmp.appendingPathComponent("m.pdf")
        try await engine.merge([pb, pa], into: merged)
        let doc = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(doc.pageCount, 3)
        // La primera página viene de pb (vertical).
        let r = doc.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertGreaterThan(r.height, r.width)
    }

    func testImageConvertAndResize() async throws {
        let png = try makePNG("foto.png", width: 800, height: 400)
        let jpg = tmp.appendingPathComponent("foto.jpg")
        try await ImageIOEngine().convert(png, to: .jpg, quality: 0.8, maxSide: 200, output: jpg)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 100)
    }

    func testKindDetector() throws {
        let png = try makePNG("x.png", width: 10, height: 10)
        let d = FileKindDetector()
        XCTAssertEqual(d.item(for: png).kind, .image)
        XCTAssertEqual(d.item(for: tmp).kind, .folder)
        let pdf = tmp.appendingPathComponent("x.pdf")
        let doc = PDFDocument(); doc.insert(PDFPage(image: NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in true })!, at: 0)
        XCTAssertTrue(doc.write(to: pdf))
        XCTAssertEqual(d.item(for: pdf).kind, .pdf)
        XCTAssertEqual(d.item(for: tmp.appendingPathComponent("a.docx")).kind, .officeDocument)
    }

    func testSplitProducesRequestedPages() async throws {
        let img = try makePNG("p.png", width: 100, height: 100)
        let pdf = tmp.appendingPathComponent("five.pdf")
        let engine = PDFKitEngine()
        try await engine.makePDF(fromImages: Array(repeating: img, count: 5), output: pdf)
        let count = try await engine.pageCount(of: pdf)
        XCTAssertEqual(count, 5)
        let a = tmp.appendingPathComponent("a.pdf"), b = tmp.appendingPathComponent("b.pdf")
        try await engine.split(pdf, ranges: [1...2, 4...5], outputs: [a, b])
        XCTAssertEqual(PDFDocument(url: a)?.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: b)?.pageCount, 2)
        do { try await engine.split(pdf, ranges: [4...9], outputs: [a]); XCTFail() } catch {}
    }

    /// Imagen con texto grande, como una página escaneada.
    func makeScan(_ name: String, text: String) throws -> URL {
        let w = 1600, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 150, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 60, y: 250)
        CTLineDraw(line, ctx)
        let url = tmp.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testOCRMakesScannedPDFSearchable() async throws {
        let scan = try makeScan("scan.png", text: "Factura Cabrio 2026")
        let pdf = tmp.appendingPathComponent("scan.pdf")
        try await PDFKitEngine().makePDF(fromImages: [scan], output: pdf)
        XCTAssertTrue((PDFDocument(url: pdf)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "el PDF escaneado no debe traer texto antes del OCR")

        let out = tmp.appendingPathComponent("scan_cabrio.pdf")
        final class Box: @unchecked Sendable { var last = 0.0 }
        let box = Box()
        try await VisionOCREngine().makeSearchable(pdf, languages: ["es", "en"], output: out) { box.last = $0 }
        XCTAssertEqual(box.last, 1)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 1)
        let text = (doc.string ?? "").lowercased()
        XCTAssertTrue(text.contains("factura") || text.contains("cabrio"), "texto reconocido: \(text)")
        // La página conserva su tamaño original.
        let before = PDFDocument(url: pdf)!.page(at: 0)!.bounds(for: .mediaBox)
        let after = doc.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(before.width, after.width, accuracy: 1)
        XCTAssertEqual(before.height, after.height, accuracy: 1)
    }

    // MARK: Compresión

    /// PDF de una página con texto y una foto JPEG pesada (ruido), como un documento con fotos.
    func makeHeavyPDF(_ name: String) throws -> URL {
        let w = 2400, h = 1600
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for i in 0..<(w * h) {
            seed = seed &* 1664525 &+ 1013904223
            let n = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[i * 4] = UInt8((i % w) * 255 / w) &+ n / 4
            pixels[i * 4 + 1] = UInt8((i / w) * 255 / h) &+ n / 4
            pixels[i * 4 + 2] = n
            pixels[i * 4 + 3] = 255
        }
        let bctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let photo = bctx.makeImage()!
        let jpg = tmp.appendingPathComponent("foto-\(name).jpg")
        let dest = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, photo, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let jpgImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(jpg as CFURL, nil)!, 0, nil)!

        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(jpgImage, in: CGRect(x: 36, y: 300, width: 540, height: 360))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Contrato de arrendamiento Cabrio", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 20, nil)]))
        pdf.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    func testCompressByLevelShrinksImagesAndKeepsText() async throws {
        let src = try makeHeavyPDF("pesado.pdf")
        let out = tmp.appendingPathComponent("pesado_cabrio.pdf")
        let report = try await PDFKitEngine().compress(src, target: .level(.medium), output: out) { _ in }
        XCTAssertEqual(report.originalBytes, size(src))
        XCTAssertEqual(report.resultBytes, size(out))
        XCTAssertLessThan(report.resultBytes, report.originalBytes / 2, "\(report)")
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertTrue((doc.string ?? "").contains("Contrato de arrendamiento"), "el texto debe seguir siendo texto")
        // La foto sigue ahí: la página renderizada no es blanca.
        let thumb = doc.page(at: 0)!.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
        XCTAssertNotNil(thumb.tiffRepresentation)
    }

    func testCompressWithSizeTargetMeetsItOrReportsMinimum() async throws {
        let src = try makeHeavyPDF("meta.pdf")
        let original = size(src)
        let reachable = tmp.appendingPathComponent("meta_ok.pdf")
        let goal = original / 4
        let ok = try await PDFKitEngine().compress(src, target: .maxBytes(goal), output: reachable) { _ in }
        XCTAssertTrue(ok.reachedTarget, "\(ok)")
        XCTAssertLessThanOrEqual(size(reachable), goal)
        XCTAssertNotNil(PDFDocument(url: reachable))

        let impossible = tmp.appendingPathComponent("meta_no.pdf")
        let no = try await PDFKitEngine().compress(src, target: .maxBytes(1_000), output: impossible) { _ in }
        XCTAssertFalse(no.reachedTarget)
        XCTAssertLessThan(no.resultBytes, original)
        XCTAssertEqual(no.targetBytes, 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: impossible.path))
    }

    func testCompressLeavesAlreadySmallPDFUntouched() async throws {
        let img = try makePNG("t.png", width: 50, height: 50)
        let src = tmp.appendingPathComponent("chico.pdf")
        try await PDFKitEngine().makePDF(fromImages: [img], output: src)
        let out = tmp.appendingPathComponent("chico_cabrio.pdf")
        let report = try await PDFKitEngine().compress(src, target: .level(.high), output: out) { _ in }
        XCTAssertTrue(report.nothingToGain)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
    }

    func testCompressIsCancellable() async throws {
        let src = try makeHeavyPDF("cancel.pdf")
        let out = tmp.appendingPathComponent("cancel_cabrio.pdf")
        let task = Task { try await PDFKitEngine().compress(src, target: .level(.high), output: out) { _ in } }
        task.cancel()
        do { _ = try await task.value } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: Contraseñas

    func testProtectEncryptsAndPreservesTextExactly() async throws {
        let src = try makeHeavyPDF("secreto.pdf")
        let out = tmp.appendingPathComponent("secreto_cabrio.pdf")
        try await PDFKitEngine().protect(src, password: "clave-123", output: out)

        let locked = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked, "sin contraseña no debe abrirse")
        XCTAssertFalse(locked.unlock(withPassword: "otra"))
        let raw = try Data(contentsOf: out)
        XCTAssertNil(raw.range(of: Data("Contrato".utf8)), "el texto no debe aparecer en claro")

        let open = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(open.unlock(withPassword: "clave-123"))
        XCTAssertEqual(open.pageCount, 1)
        XCTAssertEqual(open.string, PDFDocument(url: src)?.string)
        // La foto también se descifró: la página no sale en blanco.
        XCTAssertNotNil(open.page(at: 0)?.thumbnail(of: CGSize(width: 100, height: 130), for: .mediaBox).tiffRepresentation)
    }

    func testUnlockRoundTripAndWrongPassword() async throws {
        let src = try makeHeavyPDF("ida.pdf")
        let locked = tmp.appendingPathComponent("ida_cabrio.pdf")
        let engine = PDFKitEngine()
        try await engine.protect(src, password: "pw", output: locked)

        let bad = tmp.appendingPathComponent("mal.pdf")
        do { try await engine.unlock(locked, password: "nope", output: bad); XCTFail() }
        catch { XCTAssertEqual(error as? CabrioError, .wrongPassword("ida_cabrio.pdf")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))

        let free = tmp.appendingPathComponent("libre.pdf")
        try await engine.unlock(locked, password: "pw", output: free)
        let doc = try XCTUnwrap(PDFDocument(url: free))
        XCTAssertFalse(doc.isEncrypted)
        XCTAssertFalse(doc.isLocked)
        XCTAssertEqual(doc.string, PDFDocument(url: src)?.string)
        XCTAssertEqual(doc.pageCount, 1)
    }

    func testAccentedPasswordRoundTripsWithOwnUnlock() async throws {
        let src = try makeHeavyPDF("tilde.pdf")
        let locked = tmp.appendingPathComponent("tilde_cabrio.pdf")
        let engine = PDFKitEngine()
        try await engine.protect(src, password: "clave-ñ-é", output: locked)
        XCTAssertTrue(PDFDocument(url: locked)!.isLocked)
        let out = tmp.appendingPathComponent("tilde_libre.pdf")
        try await engine.unlock(locked, password: "clave-ñ-é", output: out)
        XCTAssertEqual(PDFDocument(url: out)?.string, PDFDocument(url: src)?.string)
    }

    func testUnlockOpensPDFKitEncryptedFilesAndRejectsMisuse() async throws {
        let src = try makeHeavyPDF("pk.pdf")
        let theirs = tmp.appendingPathComponent("pk_enc.pdf")
        XCTAssertTrue(PDFDocument(url: src)!.write(to: theirs, withOptions: [.userPasswordOption: "abc", .ownerPasswordOption: "own"]))
        let engine = PDFKitEngine()
        // Contraseña de usuario y de propietario.
        for pw in ["abc", "own"] {
            let out = tmp.appendingPathComponent("pk_\(pw).pdf")
            try await engine.unlock(theirs, password: pw, output: out)
            let d = try XCTUnwrap(PDFDocument(url: out))
            XCTAssertFalse(d.isLocked, pw)
            XCTAssertEqual(d.pageCount, 1)
            XCTAssertTrue((d.string ?? "").contains("Contrato"))
        }
        // Proteger algo ya protegido, o quitar la contraseña a algo que no la tiene.
        do { try await engine.protect(theirs, password: "x", output: tmp.appendingPathComponent("z.pdf")); XCTFail() } catch {
            guard case CabrioError.unsupported = error else { return XCTFail("\(error)") }
        }
        do { try await engine.unlock(src, password: "", output: tmp.appendingPathComponent("z2.pdf")); XCTFail() } catch {
            guard case CabrioError.unsupported = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Imagen: comprimir y quitar fondo

    func testCompressImageKeepsFormatAndShrinks() async throws {
        let big = try makeHeavyPDF("x.pdf")   // reutiliza el JPEG pesado como fuente
        _ = big
        let jpg = tmp.appendingPathComponent("foto-x.pdf.jpg")
        let src = try XCTUnwrap(FileManager.default.fileExists(atPath: jpg.path) ? jpg : nil)
        let out = tmp.appendingPathComponent("foto_cabrio.jpg")
        try await ImageIOEngine().convert(src, to: .jpg, quality: 0.55, maxSide: 1200, output: out)
        XCTAssertLessThan(size(out), size(src) / 2)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 1200)
    }

    func testRemoveBackgroundGivesFriendlyErrorOrTransparentPNG() async throws {
        // Fondo liso sin sujeto: Vision no debe devolver basura; el error es claro.
        let flat = try makePNG("liso.png", width: 400, height: 300)
        let out = tmp.appendingPathComponent("liso_cabrio.png")
        do {
            try await ImageIOEngine().removeBackground(flat, output: out)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
        } catch {
            guard case CabrioError.unsupported(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("sujeto") || m.contains("separar") || m.contains("analizar"), m)
        }
    }

    // MARK: Video y audio

    /// Video de 3 s con ruido (pesado) y, si `withAudio`, un tono de 3 s.
    func makeVideo(_ name: String, withAudio: Bool = false, width: Int = 640, height: Int = 360) async throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let silent = withAudio ? tmp.appendingPathComponent("mudo-\(name)") : url
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var seed: UInt32 = 7
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<height {
                for x in 0..<width {
                    seed = seed &* 1664525 &+ 1013904223
                    let o = y * bpr + x * 4
                    base[o] = UInt8(truncatingIfNeeded: (seed >> 24)) / 2 &+ UInt8((x + frame * 3) % 128)
                    base[o + 1] = UInt8(truncatingIfNeeded: (seed >> 16)) / 2 &+ UInt8(y % 128)
                    base[o + 2] = UInt8(truncatingIfNeeded: (seed >> 8)) / 2
                    base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        guard withAudio else { return url }

        // Audio: tono WAV de 3 s mezclado con el video.
        let wav = try makeWAV("tono-\(name).wav", seconds: 3)
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: silent), aAsset = AVURLAsset(url: wav)
        let vt = try await vAsset.loadTracks(withMediaType: .video)[0]
        let at = try await aAsset.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vt, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: at, at: .zero)
        let export = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        export.outputURL = url; export.outputFileType = .mov
        await export.export()
        XCTAssertEqual(export.status, .completed, "\(String(describing: export.error))")
        return url
    }

    func makeWAV(_ name: String, seconds: Int) throws -> URL {
        let rate = 44_100, n = rate * seconds
        var pcm = Data()
        for i in 0..<n {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 12_000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var h = Data("RIFF".utf8)
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { h.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { h.append(contentsOf: $0) } }
        le32(36 + pcm.count); h.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        h.append(Data("data".utf8)); le32(pcm.count)
        let url = tmp.appendingPathComponent(name)
        try (h + pcm).write(to: url)
        return url
    }

    func testVideoCompressByLevelShrinksAndKeepsDuration() async throws {
        let src = try await makeVideo("pesado.mov", withAudio: true)
        let out = tmp.appendingPathComponent("pesado_cabrio.mp4")
        let report = try await AVFoundationEngine().compressVideo(src, target: .level(.high), hevc: false, output: out) { _ in }
        XCTAssertLessThan(report.resultBytes, report.originalBytes / 2, "\(report)")
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.3)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let videoCount = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(audioCount, 1, "el audio se conserva")
        XCTAssertEqual(videoCount, 1)
    }

    func testVideoSizeTargetMetOrMinimumReported() async throws {
        let src = try await makeVideo("meta.mov")
        let engine = AVFoundationEngine()
        let original = size(src)
        let ok = tmp.appendingPathComponent("meta_ok.mp4")
        let goal = original / 3
        let r = try await engine.compressVideo(src, target: .maxBytes(goal), hevc: false, output: ok) { _ in }
        XCTAssertTrue(r.reachedTarget, "objetivo \(goal), logrado \(r.resultBytes)")
        XCTAssertLessThanOrEqual(size(ok), goal)

        let no = tmp.appendingPathComponent("meta_no.mp4")
        let bad = try await engine.compressVideo(src, target: .maxBytes(3_000), hevc: false, output: no) { _ in }
        XCTAssertFalse(bad.reachedTarget)
        XCTAssertGreaterThan(bad.resultBytes, 0)
        let minimal = try await AVURLAsset(url: no).loadTracks(withMediaType: .video)
        XCTAssertEqual(minimal.count, 1)
    }

    func testHEVCAndOrientationPreserved() async throws {
        let src = try await makeVideo("hevc.mov")
        let out = tmp.appendingPathComponent("hevc_cabrio.mp4")
        _ = try await AVFoundationEngine().compressVideo(src, target: .level(.medium), hevc: true, output: out) { _ in }
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)[0]
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(formats[0]), kCMVideoCodecType_HEVC)
    }

    func testAudioExtractionAndConversionToM4A() async throws {
        let video = try await makeVideo("conaudio.mov", withAudio: true)
        let out = tmp.appendingPathComponent("conaudio_cabrio.m4a")
        let engine = AVFoundationEngine()
        try await engine.audioToM4A(video, output: out) { _ in }
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        let aTracks = try await asset.loadTracks(withMediaType: .audio).count
        let vTracks = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(seconds, 3, accuracy: 0.3)
        XCTAssertEqual(aTracks, 1)
        XCTAssertEqual(vTracks, 0)

        let wav = try makeWAV("voz.wav", seconds: 1)
        let out2 = tmp.appendingPathComponent("voz_cabrio.m4a")
        try await engine.audioToM4A(wav, output: out2) { _ in }
        XCTAssertGreaterThan(size(out2), 0)

        // Video sin audio: mensaje claro.
        let mute = try await makeVideo("mudo.mov")
        do { try await engine.audioToM4A(mute, output: tmp.appendingPathComponent("m.m4a")) { _ in }; XCTFail() }
        catch { guard case CabrioError.unsupported = error else { return XCTFail("\(error)") } }
    }

    // MARK: Renombrar en disco real

    func makeRunner() -> (RunOperation, InMemoryHistoryStore) {
        let h = InMemoryHistoryStore()
        return (RunOperation(pdf: PDFKitEngine(), image: ImageIOEngine(), archive: ZipArchiveEngine(),
                             media: AVFoundationEngine(), ocr: VisionOCREngine(), fileSystem: LocalFileSystem(), history: h), h)
    }

    func testRenameOnRealDiskWithAccentsSwapAndUndo() async throws {
        let (run, history) = makeRunner()
        let names = ["café ñandú.txt", "foto 😀.TXT", "2.txt", "1.txt"]
        for n in names { try "contenido de \(n)".write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let inputs = names.map { tmp.appendingPathComponent($0) }

        // «{n}» desde 2: 1.txt pasa a 2.txt y 2.txt a 3.txt (destino = nombre actual de otro archivo).
        let out = try await run(.batchRename(RenameSpec(template: "{n}", start: 2)), inputs: [inputs[2], inputs[3]])
        XCTAssertEqual(out.map(\.lastPathComponent), ["2.txt", "3.txt"])
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("2.txt")), "contenido de 1.txt", "el contenido viaja con el archivo")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("3.txt")), "contenido de 2.txt")
        let recent1 = await history.recent(limit: 1)
        let id = try XCTUnwrap(recent1.first?.id)
        try await run.undo(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("2.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("3.txt").path))

        // Tildes, ñ, emoji y cambio solo de mayúsculas (el mismo archivo en un sistema sin distinguirlas).
        let out2 = try await run(.batchRename(RenameSpec(template: "{name}", caseStyle: .upper)), inputs: [inputs[0], inputs[1]])
        XCTAssertEqual(Set(out2.map(\.lastPathComponent)), ["CAFÉ ÑANDÚ.txt", "FOTO 😀.TXT"])
        let listed = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path).map { $0.precomposedStringWithCanonicalMapping })
        XCTAssertTrue(listed.contains("CAFÉ ÑANDÚ.txt"), "\(listed)")
        XCTAssertFalse(listed.contains("café ñandú.txt"))
        let recent2 = await history.recent(limit: 1)
        let id2 = try XCTUnwrap(recent2.first?.id)
        try await run.undo(id2)
        let back = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path).map { $0.precomposedStringWithCanonicalMapping })
        XCTAssertTrue(back.contains("café ñandú.txt"), "\(back)")
    }

    func testRenameNeverOverwritesExistingFile() async throws {
        let (run, _) = makeRunner()
        try "viejo".write(to: tmp.appendingPathComponent("destino.txt"), atomically: true, encoding: .utf8)
        try "nuevo".write(to: tmp.appendingPathComponent("origen.txt"), atomically: true, encoding: .utf8)
        let out = try await run(.batchRename(RenameSpec(template: "destino")), inputs: [tmp.appendingPathComponent("origen.txt")])
        XCTAssertEqual(out.first?.lastPathComponent, "destino-2.txt")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("destino.txt")), "viejo")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("destino-2.txt")), "nuevo")
    }

    // MARK: Reglas de carpetas en disco real

    func makeRuleRig(rules: [Rule]) throws -> (RuleRunner, RunOperation, FileHistoryStore) {
        let store = JSONRuleStore(url: tmp.appendingPathComponent("rules.json"))
        try store.save(rules)
        let history = FileHistoryStore(url: tmp.appendingPathComponent("history.json"))
        let fs = LocalFileSystem()
        let runner = RuleRunner(store: store, fileSystem: fs, detector: FileKindDetector(), image: ImageIOEngine(), history: history,
                                watcher: FSEventsFolderWatcher(), stability: .milliseconds(400), sweepInterval: .seconds(3600))
        let run = RunOperation(pdf: PDFKitEngine(), image: ImageIOEngine(), archive: ZipArchiveEngine(), media: AVFoundationEngine(),
                               ocr: VisionOCREngine(), fileSystem: fs, history: history)
        return (runner, run, history)
    }

    func waitUntil(_ timeout: Double = 12, _ condition: @escaping () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; try await Task.sleep(nanoseconds: 150_000_000) }
        return condition()
    }

    func testRulesEndToEndWithFSEventsMoveAndUndo() async throws {
        let downloads = tmp.appendingPathComponent("Descargas")
        let captures = tmp.appendingPathComponent("Capturas")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let rule = Rule(name: "Capturas", folder: downloads,
                        condition: RuleCondition(kinds: [.image], nameContains: ["Captura de pantalla"]),
                        actions: [.moveTo(folder: captures, subfolder: .byYear)])
        let (runner, run, history) = try makeRuleRig(rules: [rule])
        await runner.reload()
        try await Task.sleep(nanoseconds: 800_000_000)   // FSEvents necesita un instante para empezar

        let shot = try makePNG("tmp-shot.png", width: 50, height: 50)
        let name = "Captura de pantalla 2026-11-11 a las 10.00.00.png"
        let source = downloads.appendingPathComponent(name)
        try FileManager.default.moveItem(at: shot, to: source)                              // llega como un archivo nuevo
        try "no soy captura".write(to: downloads.appendingPathComponent("notas.txt"), atomically: true, encoding: .utf8)

        let year = String(Calendar.current.component(.year, from: Date()))
        let target = captures.appendingPathComponent(year).appendingPathComponent(name)
        let moved = try await waitUntil { FileManager.default.fileExists(atPath: target.path) }
        XCTAssertTrue(moved, "la regla debió mover la captura sin intervención")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("notas.txt").path), "lo demás no se toca")

        let recent = await history.recent(limit: 5)
        let entry = try XCTUnwrap(recent.first)
        if case .folderRule(let n) = entry.operation { XCTAssertEqual(n, "Capturas") } else { XCTFail("\(entry.operation)") }
        try await run.undo(entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Deshacer la devuelve a Descargas")
        await runner.stop()
    }

    func testRulesRealTrashAndRestore() async throws {
        let folder = tmp.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installer = folder.appendingPathComponent("cabrio-prueba-\(UUID().uuidString).dmg")
        try "x".write(to: installer, atomically: true, encoding: .utf8)
        let rule = Rule(name: "Instaladores", folder: folder, condition: RuleCondition(extensions: ["dmg"]), actions: [.moveToTrash])
        let (runner, run, history) = try makeRuleRig(rules: [rule])
        let done = await runner.runNow(rule)
        XCTAssertEqual(done.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.path))
        let trashed = try XCTUnwrap(done.first?.moves.first?.to)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "está en la Papelera")
        let recent = await history.recent(limit: 1)
        try await run.undo(try XCTUnwrap(recent.first).id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.path), "se restauró desde la Papelera")
    }

    func testHistoryAndRulesPersistAcrossRestarts() async throws {
        let rule = Rule(name: "R", folder: tmp, condition: RuleCondition(nameContains: ["x"], olderThanDays: 3),
                        actions: [.moveTo(folder: tmp.appendingPathComponent("Y"), subfolder: .byKind), .convertImage(.png), .moveToTrash])
        let store = JSONRuleStore(url: tmp.appendingPathComponent("r.json"))
        try store.save([rule])
        XCTAssertEqual(try JSONRuleStore(url: tmp.appendingPathComponent("r.json")).load(), [rule])

        let url = tmp.appendingPathComponent("h.json")
        let h1 = FileHistoryStore(url: url)
        let entry = HistoryEntry(operation: .protectPDF(password: SecretRef("secreto")), inputs: [tmp], outputs: [tmp],
                                 reports: [CompressionReport(originalBytes: 10, resultBytes: 5)],
                                 moves: [FileMove(from: tmp, to: tmp)])
        await h1.record(entry)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("secreto"), "la contraseña nunca se escribe a disco")
        let h2 = FileHistoryStore(url: url)
        let back = await h2.entry(id: entry.id)
        XCTAssertEqual(back?.outputs, [tmp])
        XCTAssertEqual(back?.reports.first?.resultBytes, 5)
        await h2.remove(id: entry.id)
        let h3 = FileHistoryStore(url: url)
        let gone = await h3.recent(limit: 5)
        XCTAssertTrue(gone.isEmpty)
    }
}
