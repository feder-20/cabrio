import XCTest
import AppKit
import PDFKit
import Compression
import ImageIO
import UniformTypeIdentifiers
import CabrioDomain
@testable import CabrioAdapters

/// PDFs hostiles o malformados construidos a mano: el lector/escritor propio debe lanzar un error controlado
/// (o ignorar el objeto roto), nunca un trap, un bucle infinito ni un consumo desmedido de memoria.
final class HostilePDFTests: XCTestCase {

    // MARK: Utilidades

    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    enum Outcome: Sendable, Equatable { case opened(Int), rejected(String), timeout }

    /// Ejecuta `work` en un hilo aparte con pila acotada y devuelve nil si no termina a tiempo.
    func timed<T: Sendable>(_ seconds: Double = 20, _ work: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread { box.value = work(); sem.signal() }
        thread.stackSize = 1 << 20
        thread.start()
        guard sem.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }

    func s(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Abre `bytes` con PDFRawFile y ejercita todo lo que usan el compresor y la herramienta de contraseña.
    func probe(_ bytes: [UInt8], seconds: Double = 20) -> Outcome {
        timed(seconds) { () -> Outcome in
            do {
                let f = try PDFRawFile(data: Data(bytes))
                for n in f.slots.keys.sorted() { _ = f.parse(n) }
                _ = PDFCompressor.imageObjects(in: f)
                _ = f.serialized(replacing: [:])
                return .opened(f.extents.count)
            } catch let e as CabrioError {
                return .rejected(e.errorDescription ?? "")
            } catch { return .rejected("\(error)") }
        } ?? .timeout
    }

    func assertRejected(_ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let t0 = Date()
        let r = probe(bytes)
        guard case .rejected(let msg) = r else { return XCTFail("\(what): se esperaba un error controlado y fue \(r)", file: file, line: line) }
        XCTAssertFalse(msg.isEmpty, what, file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10, "\(what): tardó demasiado", file: file, line: line)
    }

    func assertTerminates(_ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = probe(bytes)
        XCTAssertNotEqual(r, .timeout, "\(what): no terminó", file: file, line: line)
    }

    /// PDF clásico válido: objetos 1 (catálogo), 2 (páginas) y 3 (página) más `extra`.
    func classicPDF(extra: [(Int, [UInt8])] = [], trailer: String = "", startxref: String? = nil) -> [UInt8] {
        var objs: [(Int, [UInt8])] = [
            (1, s("<< /Type /Catalog /Pages 2 0 R >>")),
            (2, s("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")),
            (3, s("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")),
        ]
        objs += extra
        var out = s("%PDF-1.4\n")
        var offsets: [Int: Int] = [:]
        for (n, body) in objs {
            offsets[n] = out.count
            out += s("\(n) 0 obj\n") + body + s("\nendobj\n")
        }
        let size = (objs.map(\.0).max() ?? 0) + 1
        let xrefAt = out.count
        var x = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size {
            if let o = offsets[n] { x += String(format: "%010d 00000 n \n", o) } else { x += "0000000000 65535 f \n" }
        }
        x += "trailer\n<< /Size \(size) /Root 1 0 R \(trailer) >>\nstartxref\n\(startxref ?? String(xrefAt))\n%%EOF\n"
        return out + s(x)
    }

    /// Archivo con una sección xref escrita a mano justo tras la cabecera (y un catálogo mínimo antes).
    func handXref(_ section: String, startxref: ((Int) -> String)? = nil) -> [UInt8] {
        var out = s("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n")
        let at = out.count
        out += s(section + "\nstartxref\n\(startxref?(at) ?? String(at))\n%%EOF\n")
        return out
    }

    /// Archivo con xref de tipo stream: catálogo (1), `extra` y el stream xref; `data` son las filas sin comprimir.
    func xrefStreamPDF(dict: String, data: [UInt8], extra: [(Int, [UInt8])] = []) -> [UInt8] {
        var out = s("%PDF-1.5\n1 0 obj\n<< /Type /Catalog >>\nendobj\n")
        for (n, body) in extra { out += s("\(n) 0 obj\n") + body + s("\nendobj\n") }
        let at = out.count
        out += s("9 0 obj\n<< /Type /XRef /Root 1 0 R \(dict) /Length \(data.count) >>\nstream\n") + data
        out += s("\nendstream\nendobj\nstartxref\n\(at)\n%%EOF\n")
        return out
    }

    /// Filas de xref stream (W [1 2 1]) para: 0 libre, 1 catálogo, 2 comprimido en el ObjStm 3, 3 en su sitio.
    func objStmRows() -> [UInt8] {
        let head = s("%PDF-1.5\n1 0 obj\n<< /Type /Catalog >>\nendobj\n").count
        return [0, 0, 0, 255, 1, 0, 9, 0, 2, 0, 3, 0, 1, UInt8(head >> 8), UInt8(head & 255), 0]
    }

    func zlib(_ raw: [UInt8], capacity: Int? = nil) -> [UInt8] {
        let cap = capacity ?? raw.count + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&dst, cap, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + dst[0..<n] + [0, 0, 0, 0]
    }

    // MARK: 1. Recursión

    func testStreamLengthPointingToItselfTerminates() {
        let pdf = classicPDF(extra: [(4, s("<< /Length 4 0 R >>\nstream\nabcdef\nendstream"))])
        let r = timed { () -> Int? in
            guard let f = try? PDFRawFile(data: Data(pdf)) else { return nil }
            return f.parse(4)?.stream?.count
        }
        // Al no poder resolver /Length se recurre a buscar «endstream».
        XCTAssertEqual(r ?? nil, 6)
    }

    func testStreamLengthCycleBetweenObjectsTerminates() {
        let pdf = classicPDF(extra: [(4, s("<< /Length 5 0 R >>\nstream\nabc\nendstream")), (5, s("<< /Length 4 0 R >>\nstream\nxyz\nendstream"))])
        assertTerminates(pdf, "ciclo /Length 4↔5")
    }

    func testLengthChainDeeperThanLimitTerminates() {
        // Cada /Length apunta al objeto siguiente: sin límite de profundidad desbordaría la pila.
        var extra: [(Int, [UInt8])] = []
        for n in 4..<3000 { extra.append((n, s("<< /Length \(n + 1) 0 R >>\nstream\nab\nendstream"))) }
        extra.append((3000, s("<< /Length 2 >>\nstream\nab\nendstream")))
        assertTerminates(classicPDF(extra: extra), "cadena de /Length de 3000 objetos")
    }

    func testStreamLengthThroughObjectStreamCycleTerminates() {
        // Obj 3 es un ObjStm cuyo /Length apunta al obj 2, que vive comprimido dentro del propio ObjStm.
        let pdf = xrefStreamPDF(dict: "/W [1 2 1] /Size 4 /Index [0 4]", data: objStmRows(),
                                extra: [(3, s("<< /Type /ObjStm /N 1 /First 4 /Length 2 0 R >>\nstream\n2 0 << >>\nendstream"))])
        assertTerminates(pdf, "ciclo /Length vía ObjStm")
    }

    func testColorSpaceReferenceLoopTerminates() throws {
        let pdf = classicPDF(extra: [(6, s("6 0 R")), (7, s("8 0 R")), (8, s("7 0 R"))])
        let r = timed { () -> [Int?] in
            guard let f = try? PDFRawFile(data: Data(pdf)) else { return [] }
            return [PDFCompressor.components(.raw("6 0 R"), in: f), PDFCompressor.components(.raw("7 0 R"), in: f)]
        }
        XCTAssertEqual(r?.count, 2, "no terminó")
        XCTAssertEqual(r?.compactMap { $0 }.count, 0)
    }

    func testDeepNestingInLexerIsRejectedNotOverflowed() {
        let arrays = String(repeating: "[", count: 200_000), dicts = String(repeating: "<</A ", count: 100_000)
        for text in [arrays, dicts] {
            let parsed = timed { PDFLexer(Array(text.utf8)).value() != nil }
            XCTAssertEqual(parsed, false)
        }
        // Un nivel razonable sigue funcionando.
        XCTAssertNotNil(PDFLexer(s("[[[<</A [1 2]>>]]]")).value())
    }

    func testDeepNestingInsideObjectsDoesNotCrashCompressorPaths() {
        let pdf = classicPDF(extra: [(4, s("<< /A " + String(repeating: "[", count: 100_000)))])
        assertTerminates(pdf, "objeto con anidación enorme")
        let trailerBomb = classicPDF(trailer: "/X " + String(repeating: "[", count: 100_000))
        assertRejected(trailerBomb, "trailer con anidación enorme")
    }

    // MARK: 2. Índices y cuentas fuera de rango

    func testBadStartxrefValues() {
        for v in ["-5", "99999999999999999999", "4294967296", "0", "abc", "-9223372036854775808"] {
            assertRejected(classicPDF(startxref: v), "startxref \(v)")
        }
    }

    func testBadPrevAndXRefStmValues() {
        for (k, v) in [("Prev", "-1"), ("Prev", "99999999999"), ("Prev", "9223372036854775807"), ("XRefStm", "-7"), ("XRefStm", "99999999999")] {
            assertRejected(classicPDF(trailer: "/\(k) \(v)"), "/\(k) \(v)")
        }
    }

    func testPrevLoopsBackToItselfTerminates() {
        // /Prev apuntando a la propia sección: `seen` lo corta.
        let base = classicPDF()
        let text = String(decoding: base, as: UTF8.self)
        let at = text.range(of: "xref\n0 ")!.lowerBound.utf16Offset(in: text)
        assertTerminates(classicPDF(trailer: "/Prev \(at)"), "/Prev cíclico")
    }

    func testClassicXrefWithNegativeOrHugeCounts() {
        let one = "0000000009 00000 n \n"
        for section in [
            "xref\n0 -1\ntrailer\n<< /Root 1 0 R >>",
            "xref\n-3 1\n\(one)trailer\n<< /Root 1 0 R >>",
            "xref\n0 9999999999\n\(one)trailer\n<< /Root 1 0 R >>",
            "xref\n0 9223372036854775807\ntrailer\n<< /Root 1 0 R >>",
            "xref\n4000000000 1\n\(one)trailer\n<< /Root 1 0 R >>",
            "xref\n1000000 2\n\(one)\(one)trailer\n<< /Root 1 0 R >>",
            "xref\n9223372036854775807 5\n\(one)trailer\n<< /Root 1 0 R >>",
            "xref\n0 1\n-0000000010 00000 n \ntrailer\n<< /Root 1 0 R >>",
            "xref\n0 1\n0000000010 -0001 n \ntrailer\n<< /Root 1 0 R >>",
            "xref\n0 1\n99999999999999999999 00000 n \ntrailer\n<< /Root 1 0 R >>",
        ] {
            assertRejected(handXref(section), String(section.prefix(40)))
        }
    }

    func testTooManyObjectsIsRejectedQuickly() {
        let n = PDFLimits.maxObjects + 1
        let section = "xref\n0 \(n)\n" + String(repeating: "0000000009 00000 n \n", count: n) + "trailer\n<< /Root 1 0 R >>"
        assertRejected(handXref(section), "más de un millón de objetos")
    }

    func testObjectNumberAtLimitWritesBoundedTable() {
        // Un solo objeto con el número máximo permitido: la tabla resultante es acotada y la escritura termina.
        let section = "xref\n\(PDFLimits.maxObjectNumber) 1\n0000000009 00000 n \ntrailer\n<< /Root 1 0 R >>"
        let r = probe(handXref(section))
        XCTAssertNotEqual(r, .timeout)
    }

    func testXRefStreamBadIndexAndWidths() {
        let row: [UInt8] = [1, 0, 9, 0, 1, 0, 9, 0]
        let cases: [(String, String)] = [
            ("/W [1 2 1] /Size 2 /Index [0 -1]", "Index negativo"),
            ("/W [1 2 1] /Size 2 /Index [-4 1]", "inicio negativo"),
            ("/W [1 2 1] /Size 2 /Index [0 99999999999]", "Index enorme"),
            ("/W [1 2 1] /Size 2 /Index [9223372036854775807 2]", "inicio al límite de Int"),
            ("/W [1 2 1] /Size 2 /Index [4000000000 1]", "número de objeto gigante"),
            ("/W [1 2 1] /Size 2 /Index [0]", "Index impar"),
            ("/W [1 2 1] /Size 2 /Index [0 /A]", "Index no numérico"),
            ("/W [0 0 0] /Size 2 /Index [0 1000000000]", "W [0 0 0] con Index enorme"),
            ("/W [0 0 0] /Size 9999999999", "W [0 0 0] con Size gigante"),
            ("/W [-1 2 1] /Size 2", "ancho negativo"),
            ("/W [1 -2 1] /Size 2", "ancho negativo (2)"),
            ("/W [9 9 9] /Size 2", "anchos demasiado grandes"),
            ("/W [1 2 1] /Size 9999999999", "Size gigante"),
            ("/W [1 2 1] /Size -4", "Size negativo"),
            ("/W [1 2] /Size 2", "W incompleto"),
        ]
        for (dict, what) in cases { assertRejected(xrefStreamPDF(dict: dict, data: row), what) }
    }

    func testXRefStreamFieldsOverflowToNegative() {
        // Anchos de 8 bytes con el bit alto activo: el valor sería negativo.
        let row: [UInt8] = [1] + [UInt8](repeating: 0xFF, count: 8) + [0]
        assertRejected(xrefStreamPDF(dict: "/W [1 8 1] /Size 1", data: row), "campo negativo por desbordamiento")
        // Índice negativo en una entrada comprimida.
        let neg: [UInt8] = [2, 7] + [UInt8](repeating: 0xFF, count: 8)
        assertRejected(xrefStreamPDF(dict: "/W [1 1 8] /Size 1", data: neg), "idx comprimido negativo")
        // Número de ObjStm gigante en una entrada comprimida.
        let bigStm: [UInt8] = [2, 0xFF, 0xFF, 0xFF, 0xFF, 0]
        assertRejected(xrefStreamPDF(dict: "/W [1 4 1] /Size 1", data: bigStm), "ObjStm de número gigante")
    }

    func testCompressedEntryPointingNowhereIsHarmless() {
        let rows: [UInt8] = [0, 0, 0, 255, 1, 0, 9, 0, 2, 0, 1, 5]   // obj 2: idx 5 del objeto 1 (no es ObjStm)
        let r = probe(xrefStreamPDF(dict: "/W [1 2 1] /Size 3", data: rows))
        guard case .opened = r else { return XCTFail("\(r)") }
    }

    func testHostileObjectStreamHeaders() {
        let bodies: [(String, String)] = [
            ("/N -1 /First 0", "2 0 << >>"),
            ("/N 1000000000 /First 0", "2 0 << >>"),
            ("/N 9223372036854775807 /First 0", "2 0 << >>"),
            ("/N 1 /First -5", "2 0 << >>"),
            ("/N 1 /First 99999999", "2 0 << >>"),
            ("/N 1 /First 4", "2 -7 << >>"),
            ("/N 1 /First 4", "2 9223372036854775807 << >>"),
            ("/N 1 /First 9223372036854775807", "2 9223372036854775807 << >>"),
            ("/N 3 /First 4", "2 0 << >>"),
        ]
        for (dict, body) in bodies {
            let objStm = s("<< /Type /ObjStm \(dict) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
            let pdf = xrefStreamPDF(dict: "/W [1 2 1] /Size 4 /Index [0 4]", data: objStmRows(), extra: [(3, objStm)])
            let r = probe(pdf)
            XCTAssertNotEqual(r, .timeout, "ObjStm \(dict) \(body)")
            if case .rejected = r { XCTFail("ObjStm \(dict) \(body): el archivo debía abrirse (el objeto roto se ignora)") }
        }
    }

    func testHugeAndNegativeStreamLengths() {
        for len in ["9223372036854775807", "-1", "-9223372036854775808", "4611686018427387904", "99999999999"] {
            let pdf = classicPDF(extra: [(4, s("<< /Length \(len) >>\nstream\nabcdef\nendstream"))])
            let t = timed { () -> Int? in
                guard let f = try? PDFRawFile(data: Data(pdf)) else { return nil }
                return f.parse(4)?.stream?.count
            }
            XCTAssertEqual(t ?? nil, 6, "/Length \(len)")
        }
    }

    func testMissingEndstreamDoesNotCrash() {
        let pdf = classicPDF(extra: [(4, s("<< /Length 50 >>\nstream\nabcdef"))])
        assertTerminates(pdf, "stream sin endstream")
    }

    func testUnfilterPNGRejectsBadDimensions() {
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: -1, bpp: 1, rows: 1))
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: 2, bpp: 1, rows: -3))
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: 2, bpp: -1, rows: 1))
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: Int.max, bpp: 1, rows: 1))
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: 1 << 40, bpp: 1, rows: 1 << 40))
        XCTAssertNil(PDFCodec.unfilterPNG([0, 1, 2], rowBytes: 2, bpp: 1, rows: 2), "faltan datos")
        XCTAssertEqual(PDFCodec.unfilterPNG([0, 1, 2, 2, 1, 1], rowBytes: 2, bpp: 1, rows: 2), [1, 2, 2, 3])
    }

    // MARK: 3. Consumo ilimitado

    func testFlateBombIsCappedByLimit() {
        let bomb = zlib([UInt8](repeating: 0, count: 40 << 20), capacity: 1 << 20)
        XCTAssertLessThan(bomb.count, 200_000)
        let capped = timed { PDFCodec.inflate(bomb[...], limit: 1 << 20) }
        XCTAssertNotNil(capped)
        XCTAssertNil(capped ?? nil, "una salida mayor que el tope debe rechazarse")
        let ok = timed { PDFCodec.inflate(bomb[...], limit: 64 << 20)?.count }
        XCTAssertEqual(ok ?? nil, 40 << 20)
    }

    func testFlateBombAboveDefaultLimitIsRejected() {
        XCTAssertEqual(PDFLimits.maxInflatedBytes, 256 << 20)
        let bomb = zlib([UInt8](repeating: 0, count: PDFLimits.maxInflatedBytes + (4 << 20)), capacity: 1 << 22)
        let r = timed(60) { PDFCodec.inflate(bomb[...]) }
        XCTAssertNotNil(r, "no terminó")
        XCTAssertNil(r ?? nil)
    }

    func testInflateKeepsWorkingForNormalDataAndIgnoresLyingHint() {
        let raw = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let z = zlib(raw)
        XCTAssertEqual(PDFCodec.inflate(z[...]), raw)
        XCTAssertEqual(PDFCodec.inflate(z[...], hint: 1 << 40), raw, "un hint falso no debe reservar memoria")
        XCTAssertEqual(PDFCodec.inflate(z[...], hint: -5), raw)
        XCTAssertNil(PDFCodec.inflate([0x78, 0x9C, 1, 2, 3, 4, 5, 6, 7][...]), "datos corruptos")
        XCTAssertNil(PDFCodec.inflate([1, 2, 3][...]))
    }

    func testFlateXRefStreamBombIsRejected() {
        let bomb = zlib([UInt8](repeating: 0, count: PDFLimits.maxInflatedBytes + (1 << 20)), capacity: 1 << 22)
        let t0 = Date()
        let pdf = xrefStreamPDF(dict: "/W [1 2 1] /Size 2 /Filter /FlateDecode", data: bomb)
        assertRejected(pdf, "xref stream con bomba Flate")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
    }

    func testOversizedFileIsRejectedBeforeCopying() throws {
        let big = Data(count: PDFLimits.maxFileBytes + 1)   // memoria cero perezosa: no se toca
        XCTAssertThrowsError(try PDFRawFile(data: big)) { error in
            guard case .unsupported(let m)? = error as? CabrioError else { return XCTFail("\(error)") }
            XCTAssertFalse(m.isEmpty)
        }
    }

    func testManyStreamsWithBogusLengthStayLinear() {
        // Con N objetos de /Length falso, buscar «endstream» desde cada uno era O(N·tamaño).
        var extra: [(Int, [UInt8])] = []
        let filler = String(repeating: "x", count: 200)
        for n in 4..<20_004 { extra.append((n, s("<< /Length 999999999 >>\nstream\n\(filler)\nendstream"))) }
        let t0 = Date()
        let r = probe(classicPDF(extra: extra), seconds: 60)
        guard case .opened(let count) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(count, 20_003)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15)
    }

    func testStreamsWithoutAnyEndstreamStayFast() {
        var extra: [(Int, [UInt8])] = []
        for n in 4..<5_004 { extra.append((n, s("<< /Length 99999999 >>\nstream\n" + String(repeating: "y", count: 500)))) }
        let t0 = Date()
        assertTerminates(classicPDF(extra: extra), "streams sin endstream")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15)
    }

    func testHugeTokensAndStringsDoNotExplode() {
        let longName = "/" + String(repeating: "N", count: PDFLimits.maxToken + 10)
        assertTerminates(classicPDF(extra: [(4, s("<< \(longName) 1 >>"))]), "nombre gigante")
        assertTerminates(classicPDF(extra: [(4, s("<< /S (" + String(repeating: "\\", count: 100_001)))]), "cadena sin cerrar")
    }

    // MARK: Compresor: imágenes

    func imageFile(dict: String, stream: [UInt8]) throws -> (PDFRawFile, PDFCompressor.PDFImage) {
        let body = s("<< /Type /XObject /Subtype /Image \(dict) /Length \(stream.count) >>\nstream\n") + stream + s("\nendstream")
        let file = try PDFRawFile(data: Data(classicPDF(extra: [(4, body)])))
        let parsed = try XCTUnwrap(file.parse(4))
        let dictionary = try XCTUnwrap(parsed.value.dict)
        let img = PDFCompressor.PDFImage(number: 4, gen: 0, dict: dictionary, stream: try XCTUnwrap(parsed.stream))
        return (file, img)
    }

    func testDCTWithHugeDeclaredDimensionsIsRejectedBeforeDecoding() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0x03,
                             0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9]
        let (file, img) = try imageFile(dict: "/Width 65535 /Height 65535 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", stream: jpeg)
        let t0 = Date()
        XCTAssertNil(PDFCompressor.decode(img, in: file)?.cg)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testFlateImageWithFalseOrOverflowingDimensionsIsIgnored() throws {
        let tiny = zlib([1, 2, 3, 4, 5, 6, 7, 8])
        for (w, h) in [("20000", "20000"), ("3037000500", "3037000500"), ("9223372036854775807", "9223372036854775807"),
                       ("-5", "100000"), ("0", "0"), ("20001", "10"), ("100000", "1000")] {
            let (file, img) = try imageFile(dict: "/Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode", stream: tiny)
            let t0 = Date()
            XCTAssertNil(PDFCompressor.decode(img, in: file)?.cg, "\(w)x\(h)")
            XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "\(w)x\(h)")
        }
    }

    func testFlateImageWithLyingDimensionsAndBombIsIgnored() throws {
        // Declara 400x300 pero el stream descomprime a mucho más: se descarta al superar el tamaño esperado.
        let z = zlib([UInt8](repeating: 7, count: 8 << 20), capacity: 1 << 20)
        let (file, img) = try imageFile(dict: "/Width 400 /Height 300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode", stream: z)
        XCTAssertNil(PDFCompressor.decode(img, in: file)?.cg)
    }

    func testValidImagesStillDecode() throws {
        let raw = (0..<(400 * 300 * 3)).map { UInt8(truncatingIfNeeded: $0 / 3) }
        let (file, img) = try imageFile(dict: "/Width 400 /Height 300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode", stream: zlib(raw))
        let flate = try XCTUnwrap(PDFCompressor.decode(img, in: file))
        XCTAssertEqual(flate.cg.width, 400)
        XCTAssertFalse(flate.gray)

        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let (jfile, jimg) = try imageFile(dict: "/Width 64 /Height 48 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", stream: [UInt8](out as Data))
        XCTAssertEqual(PDFCompressor.decode(jimg, in: jfile)?.cg.width, 64)
    }

    // MARK: Motor completo con entradas hostiles

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hostil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testCompressWithHostileObjectsNeverCrashesOrHangs() async throws {
        let dir = try tempDir()
        let img = s("<< /Type /XObject /Subtype /Image /Width 400 /Height 400 /BitsPerComponent 8 /ColorSpace 6 0 R /Filter /FlateDecode /Length 10 >>\nstream\n0123456789\nendstream")
        let variants: [[(Int, [UInt8])]] = [
            [(4, s("<< /Length 4 0 R >>\nstream\nabc\nendstream")), (5, img), (6, s("6 0 R"))],
            [(5, img), (6, s("[ /ICCBased 7 0 R ]")), (7, s("<< /N 3 /Length 7 0 R >>\nstream\nabc\nendstream"))],
            [(4, s("<< /Length -1 >>\nstream\nabc\nendstream")), (5, s("<< /Length 9223372036854775807 >>\nstream\nabc\nendstream"))],
        ]
        for (i, extra) in variants.enumerated() {
            let src = dir.appendingPathComponent("h\(i).pdf")
            try Data(classicPDF(extra: extra)).write(to: src)
            let out = dir.appendingPathComponent("h\(i)_out.pdf")
            let t0 = Date()
            do { _ = try await PDFKitEngine().compress(src, target: .level(.high), output: out) { _ in } }
            catch is CabrioError { /* error controlado */ }
            XCTAssertLessThan(Date().timeIntervalSince(t0), 20, "variante \(i)")
        }
    }

    func testProtectAndUnlockRejectHostileFilesWithControlledError() async throws {
        let dir = try tempDir()
        let hostile: [[UInt8]] = [
            classicPDF(startxref: "-5"),
            classicPDF(trailer: "/Prev -1"),
            handXref("xref\n0 -1\ntrailer\n<< /Root 1 0 R >>"),
            xrefStreamPDF(dict: "/W [0 0 0] /Size 2 /Index [0 1000000000]", data: [1, 2]),
            Array("%PDF-1.4 basura sin xref".utf8),
        ]
        for (i, bytes) in hostile.enumerated() {
            let src = dir.appendingPathComponent("x\(i).pdf")
            try Data(bytes).write(to: src)
            let engine = PDFKitEngine()
            do { try await engine.protect(src, password: "p", output: dir.appendingPathComponent("p\(i).pdf")); XCTFail("protect \(i) debía fallar") }
            catch is CabrioError {}
            do { try await engine.unlock(src, password: "p", output: dir.appendingPathComponent("u\(i).pdf")); XCTFail("unlock \(i) debía fallar") }
            catch is CabrioError {}
        }
    }

    // MARK: Contraseña: aleatoriedad y fallos de AES

    func testRandomBytesAreRealAndAESFailuresAreReported() {
        let a = PDFPasswordTool.random(16), b = PDFPasswordTool.random(16)
        XCTAssertEqual(a?.count, 16)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, [UInt8](repeating: 0, count: 16))
        // Clave de longitud inválida: AES falla y el cifrado devuelve nil en vez de «iv + []».
        XCTAssertNil(PDFPasswordTool.aes(encrypt: true, key: [1, 2, 3], iv: [UInt8](repeating: 0, count: 16), [1, 2, 3]))
        let good = PDFPasswordTool.Cipher(key: [UInt8](repeating: 9, count: 16), method: .aes128)
        let enc = good.encrypt([1, 2, 3, 4], 5, 0)
        XCTAssertEqual(enc?.count, 32)
        XCTAssertEqual(good.decrypt(enc ?? [], 5, 0), [1, 2, 3, 4])
        XCTAssertEqual(PDFPasswordTool.rc4(key: [], [1, 2, 3]), [1, 2, 3], "clave vacía no debe causar un módulo por cero")
    }

    // MARK: Regresión: PDFs válidos

    func testValidClassicPDFRoundTrips() throws {
        let content = "BT /F1 12 Tf (Hola) Tj ET"
        let pdf = classicPDF(extra: [(4, s("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"))])
        let file = try PDFRawFile(data: Data(pdf))
        XCTAssertEqual(file.extents.map(\.number).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(file.parse(4)?.stream?.count, content.utf8.count)
        let out = file.serialized(replacing: [:])
        let again = try PDFRawFile(data: out)
        XCTAssertEqual(again.extents.count, 4)
        XCTAssertEqual(PDFDocument(data: out)?.pageCount, 1)
    }

    func testIndirectLengthStillResolves() throws {
        let pdf = classicPDF(extra: [(4, s("<< /Length 5 0 R >>\nstream\nabcde\nendstream")), (5, s("5"))])
        let file = try PDFRawFile(data: Data(pdf))
        XCTAssertEqual(file.parse(4)?.stream?.count, 5)
        XCTAssertEqual(file.intValue(of: .raw("5 0 R")), 5)
    }

    func testXRefStreamWithObjectStreamStillParses() throws {
        let body = "2 0 << /Type /Pages /Count 0 >>"
        let objStm = s("<< /Type /ObjStm /N 1 /First 4 /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
        let pdf = xrefStreamPDF(dict: "/W [1 2 1] /Size 4 /Index [0 4]", data: objStmRows(), extra: [(3, objStm)])
        let file = try PDFRawFile(data: Data(pdf))
        XCTAssertTrue(file.usesXRefStream)
        XCTAssertEqual(file.parse(2)?.value.dict?["Type"]?.name, "Pages")
        XCTAssertEqual(file.parse(1)?.value.dict?["Type"]?.name, "Catalog")
        // Reescritura: el objeto comprimido se conserva en la tabla nueva.
        let again = try PDFRawFile(data: file.serialized(replacing: [:]))
        XCTAssertEqual(again.parse(2)?.value.dict?["Type"]?.name, "Pages")
    }

    func testProtectThenUnlockBuiltPDFRoundTrips() async throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("a.pdf")
        let content = "BT (Hola) Tj ET"
        try Data(classicPDF(extra: [(4, s("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"))])).write(to: src)
        let locked = dir.appendingPathComponent("l.pdf"), free = dir.appendingPathComponent("f.pdf")
        try await PDFKitEngine().protect(src, password: "clave", output: locked)
        XCTAssertEqual(PDFDocument(url: locked)?.isLocked, true)
        try await PDFKitEngine().unlock(locked, password: "clave", output: free)
        XCTAssertEqual(PDFDocument(url: free)?.pageCount, 1)
    }
}
