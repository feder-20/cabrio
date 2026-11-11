import Foundation
import Compression
import CabrioDomain

// Lector mínimo de PDF con tabla xref clásica (la que produce PDFKit al reescribir un documento).
// Solo entiende lo necesario para localizar imágenes y copiar el resto de objetos byte a byte.

indirect enum PDFValue {
    case raw(String)               // número, nombre (/N), referencia («12 0 R»), cadena, true/false/null
    case dict([String: PDFValue])  // claves sin la barra
    case array([PDFValue])

    var serialized: String {
        switch self {
        case .raw(let s): return s
        case .array(let a): return "[" + a.map(\.serialized).joined(separator: " ") + "]"
        case .dict(let d):
            return "<<" + d.sorted { $0.key < $1.key }.map { "/\($0.key) \($0.value.serialized)" }.joined(separator: " ") + ">>"
        }
    }

    var int: Int? { if case .raw(let s) = self { return Int(s) } else { return nil } }
    var name: String? { if case .raw(let s) = self, s.hasPrefix("/") { return String(s.dropFirst()) } else { return nil } }
    var dict: [String: PDFValue]? { if case .dict(let d) = self { return d } else { return nil } }
    /// Número de objeto de una referencia «n g R».
    var refNumber: Int? {
        guard case .raw(let s) = self, s.hasSuffix(" R") else { return nil }
        return Int(s.split(separator: " ")[0])
    }
}

/// Topes con los que se rechaza un PDF hostil o malformado antes de que agote CPU, memoria o pila.
enum PDFLimits {
    static let maxFileBytes = 1 << 30            // 1 GiB
    static let maxObjects = 1_000_000
    static let maxObjectNumber = 1_000_000
    static let maxXRefEntries = 2_000_000        // entradas xref sumando todas las secciones
    static let maxXRefSections = 4096            // cadena de /Prev y /XRefStm
    static let maxInflatedBytes = 256 << 20      // 256 MiB de salida por stream Flate
    static let maxObjStmCacheBytes = 64 << 20    // total de ObjStm descomprimidos en caché
    static let maxNesting = 64                   // profundidad de [ y << en el lexer
    static let maxNodes = 2_000_000              // valores por objeto de nivel superior
    static let maxToken = 1 << 20                // longitud de un token o nombre
    static let maxParseDepth = 32                // resoluciones anidadas de objetos (/Length, espacios de color)
    static let maxPixels = 100_000_000           // 100 megapíxeles
    static let maxSide = 20_000
    static let maxPageInches = 200.0             // máximo de la especificación: 14 400 pt
    static let maxEndstreamMarks = 2_000_000
}

final class PDFLexer {
    let b: [UInt8]
    var p: Int
    private var depth = 0
    private var nodes = 0

    init(_ bytes: [UInt8], at position: Int = 0) { b = bytes; p = max(0, min(position, bytes.count)) }

    static func isWS(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

    func skipWS() {
        while p < b.count {
            if Self.isWS(b[p]) { p += 1 }
            else if b[p] == UInt8(ascii: "%") { while p < b.count, b[p] != 10, b[p] != 13 { p += 1 } }
            else { break }
        }
    }

    func hasPrefix(_ s: String) -> Bool {
        var i = p
        for c in s.utf8 {
            guard i < b.count, b[i] == c else { return false }
            i += 1
        }
        return true
    }

    func token() -> String? {
        skipWS()
        guard p < b.count else { return nil }
        let start = p
        if Self.isDelim(b[p]) { p += 1 } else {
            while p < b.count, !Self.isWS(b[p]), !Self.isDelim(b[p]) { p += 1 }
        }
        guard p - start <= PDFLimits.maxToken else { return nil }
        return String(decoding: b[start..<p], as: UTF8.self)
    }

    /// Lee un valor. Devuelve nil si está truncado, supera la profundidad máxima o tiene demasiados nodos.
    func value() -> PDFValue? {
        if depth == 0 { nodes = 0 }
        depth += 1
        defer { depth -= 1 }
        nodes += 1
        guard depth <= PDFLimits.maxNesting, nodes <= PDFLimits.maxNodes else { return nil }
        return parseValue()
    }

    private func parseValue() -> PDFValue? {
        skipWS()
        guard p < b.count else { return nil }
        let c = b[p]
        switch c {
        case UInt8(ascii: "<"):
            if p + 1 < b.count, b[p + 1] == UInt8(ascii: "<") {
                p += 2
                var d: [String: PDFValue] = [:]
                while true {
                    skipWS()
                    guard p < b.count else { return nil }
                    if hasPrefix(">>") { p += 2; return .dict(d) }
                    guard b[p] == UInt8(ascii: "/"), case .raw(let key)? = value(), let v = value() else { return nil }
                    d[String(key.dropFirst())] = v
                }
            }
            let start = p
            while p < b.count, b[p] != UInt8(ascii: ">") { p += 1 }
            p += 1
            return .raw(String(decoding: b[start..<min(p, b.count)], as: UTF8.self))
        case UInt8(ascii: "["):
            p += 1
            var a: [PDFValue] = []
            while true {
                skipWS()
                guard p < b.count else { return nil }
                if b[p] == UInt8(ascii: "]") { p += 1; return .array(a) }
                guard let v = value() else { return nil }
                a.append(v)
            }
        case UInt8(ascii: "("):
            let start = p
            var depth = 0
            while p < b.count {
                let ch = b[p]
                if ch == UInt8(ascii: "\\") { p += 2; continue }
                if ch == UInt8(ascii: "(") { depth += 1 }
                if ch == UInt8(ascii: ")") { depth -= 1; if depth == 0 { p += 1; break } }
                p += 1
            }
            // Latin-1: cada byte es un carácter, así las cadenas binarias (cifradas) no se corrompen.
            return .raw(String(String.UnicodeScalarView(b[start..<min(p, b.count)].map { Unicode.Scalar($0) })))
        case UInt8(ascii: "/"):
            let start = p
            p += 1
            while p < b.count, !Self.isWS(b[p]), !Self.isDelim(b[p]) { p += 1 }
            guard p - start <= PDFLimits.maxToken else { return nil }
            return .raw(String(decoding: b[start..<p], as: UTF8.self))
        default:
            guard let t = token() else { return nil }
            if let n = Int(t), n >= 0 {
                let save = p
                if let g = token(), let gen = Int(g), gen >= 0, let r = token(), r == "R" { return .raw("\(n) \(gen) R") }
                p = save
            }
            return .raw(t)
        }
    }
}

enum PDFCodec {
    /// Flate de PDF (zlib). `hint` es el tamaño esperado si se conoce; `limit` es el máximo de bytes de salida
    /// (una bomba de descompresión devuelve nil en vez de agotar la memoria). Se descomprime en trozos
    /// directamente sobre el resultado, sin duplicar buffers.
    static func inflate(_ data: ArraySlice<UInt8>, hint: Int = 0, limit: Int = PDFLimits.maxInflatedBytes) -> [UInt8]? {
        guard data.count > 6, limit > 0 else { return nil }
        let b0 = Int(data[data.startIndex]), b1 = Int(data[data.startIndex + 1])
        guard b0 & 0x0F == 8, (b0 * 256 + b1) % 31 == 0, b1 & 0x20 == 0 else { return nil }

        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        var out: [UInt8] = []
        // El hint puede mentir: la reserva se acota por la razón máxima de compresión de deflate (~1032:1).
        let (ratio, overflow) = data.count.multipliedReportingOverflow(by: 1032)
        out.reserveCapacity(max(0, min(hint, min(limit, overflow ? limit : ratio))))

        return data.dropFirst(2).withUnsafeBufferPointer { src -> [UInt8]? in
            guard let base = src.baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    guard out.count <= limit - produced else { return nil }
                    out.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                }
                if status == COMPRESSION_STATUS_END { return out.isEmpty ? nil : out }
                if status == COMPRESSION_STATUS_OK {
                    if produced == 0 && stream.src_size == 0 { return out.isEmpty ? nil : out }   // flujo truncado
                    continue
                }
                return nil
            }
        }
    }

    /// Deshace el predictor PNG. Devuelve nil si las dimensiones no son válidas o faltan datos.
    static func unfilterPNG(_ data: [UInt8], rowBytes: Int, bpp: Int, rows: Int) -> [UInt8]? {
        guard rowBytes >= 0, bpp >= 0, rows >= 0 else { return nil }
        let (stride, o1) = rowBytes.addingReportingOverflow(1)
        let (needed, o2) = rows.multipliedReportingOverflow(by: stride)
        let (total, o3) = rows.multipliedReportingOverflow(by: rowBytes)
        guard !o1, !o2, !o3, needed <= data.count, total <= PDFLimits.maxInflatedBytes else { return nil }
        var out = [UInt8](repeating: 0, count: total)
        for y in 0..<rows {
            let filter = data[y * stride]
            let src = y * stride + 1
            let dst = y * rowBytes
            for x in 0..<rowBytes {
                let a = x >= bpp ? Int(out[dst + x - bpp]) : 0
                let b = y > 0 ? Int(out[dst - rowBytes + x]) : 0
                let c = (x >= bpp && y > 0) ? Int(out[dst - rowBytes + x - bpp]) : 0
                let v = Int(data[src + x])
                let r: Int
                switch filter {
                case 1: r = v + a
                case 2: r = v + b
                case 3: r = v + (a + b) / 2
                case 4:
                    let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                    r = v + ((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c))
                default: r = v
                }
                out[dst + x] = UInt8(truncatingIfNeeded: r)
            }
        }
        return out
    }

    static func filterNames(_ d: [String: PDFValue]) -> [String] {
        switch d["Filter"] {
        case .raw(let s)?: return [String(s.dropFirst())]
        case .array(let a)?: return a.compactMap(\.name)
        default: return []
        }
    }

    static func decodeParms(_ d: [String: PDFValue]) -> [String: PDFValue] {
        switch d["DecodeParms"] {
        case .dict(let p)?: return p
        case .array(let a)?: return a.first?.dict ?? [:]
        default: return [:]
        }
    }
}

/// Lector de PDF sobre el archivo original: tablas xref clásicas o de tipo stream, con actualizaciones
/// incrementales y objetos comprimidos. Permite copiar byte a byte todo salvo los objetos que se sustituyan.
/// Está pensado para entradas hostiles: todo valor leído del archivo se valida y los topes de `PDFLimits`
/// evitan recursión, desbordes aritméticos y consumo ilimitado de memoria o CPU.
final class PDFRawFile {
    enum Slot { case offset(Int, gen: Int), compressed(stream: Int, index: Int) }
    struct Extent { let number: Int; let gen: Int; let offset: Int; var end: Int }
    typealias ObjStmData = (numbers: [Int], offsets: [Int], first: Int, data: [UInt8])

    let bytes: [UInt8]
    private(set) var slots: [Int: Slot] = [:]
    private(set) var extents: [Extent] = []
    private(set) var trailer: [String: PDFValue] = [:]
    private(set) var usesXRefStream = false
    private var objStmCache: [Int: ObjStmData] = [:]
    private var objStmCacheBytes = 0
    private var inProgress = Set<Int>()       // objetos que se están resolviendo: corta ciclos
    private var xrefEntryCount = 0

    private static var tooLarge: CabrioError { .unsupported(tr("Este PDF es demasiado grande para procesarlo (1 GB como máximo).")) }
    private static var corrupt: CabrioError { .unsupported(tr("Este PDF está dañado o tiene una estructura no válida.")) }

    init(data: Data) throws {
        guard data.count <= PDFLimits.maxFileBytes else { throw Self.tooLarge }
        bytes = [UInt8](data)
        let fail = CabrioError.unsupported(tr("Este PDF no se pudo reescribir para comprimirlo."))
        let tail = bytes.count > 2048 ? bytes.count - 2048 : 0
        guard let r = Data(bytes[tail...]).range(of: Data("startxref".utf8), options: .backwards) else { throw fail }
        let lex = PDFLexer(bytes, at: tail + r.upperBound)
        guard let t = lex.token(), let next: Int = Int(t), next >= 0, next < bytes.count else { throw fail }

        var seen = Set<Int>()
        var shadowed = Set<Int>()   // números ya definidos por una sección más nueva (incluye libres)
        var first = true
        var pending: [Int] = [next]
        while let offset = pending.first {
            pending.removeFirst()
            guard seen.insert(offset).inserted else { continue }
            guard seen.count <= PDFLimits.maxXRefSections else { throw Self.corrupt }
            guard offset >= 0, offset < bytes.count else { throw Self.corrupt }
            let (entries, tr, isStream) = try readSection(at: offset, fail: fail)
            if first { trailer = tr; usesXRefStream = isStream; first = false }
            for (number, slot) in entries where !shadowed.contains(number) {
                shadowed.insert(number)
                if let slot { slots[number] = slot }
            }
            guard slots.count <= PDFLimits.maxObjects else { throw Self.corrupt }
            if let x = tr["XRefStm"]?.int { pending.insert(x, at: 0) }
            if let prev = tr["Prev"]?.int { pending.append(prev) }
        }
        guard trailer["Root"] != nil else { throw fail }
        if slots.values.contains(where: { if case .compressed = $0 { return true } else { return false } }) { usesXRefStream = true }
        computeExtents()
    }

    // MARK: Secciones xref

    private func readSection(at offset: Int, fail: CabrioError) throws -> ([(Int, Slot?)], [String: PDFValue], Bool) {
        let lex = PDFLexer(bytes, at: offset)
        lex.skipWS()
        var entries: [(Int, Slot?)] = []
        let maxNumber = PDFLimits.maxObjectNumber
        if lex.hasPrefix("xref") {
            _ = lex.token()
            while true {
                lex.skipWS()
                if lex.hasPrefix("trailer") { _ = lex.token(); break }
                guard let s = lex.token(), let start = Int(s), let c = lex.token(), let count = Int(c) else { throw fail }
                guard start >= 0, start <= maxNumber, count >= 0, count <= maxNumber + 1 - start,
                      count <= PDFLimits.maxXRefEntries - xrefEntryCount else { throw Self.corrupt }
                xrefEntryCount += count
                for i in 0..<count {
                    guard let o = lex.token(), let off = Int(o), let g = lex.token(), let gen = Int(g), let kind = lex.token() else { throw fail }
                    guard off >= 0, gen >= 0 else { throw Self.corrupt }
                    entries.append((start + i, kind == "n" ? .offset(off, gen: gen) : nil))
                }
            }
            guard case .dict(let tr)? = lex.value() else { throw fail }
            return (entries, tr, false)
        }
        // Xref stream: «n g obj << … >> stream»
        guard lex.token() != nil, lex.token() != nil, lex.token() == "obj", case .dict(let d)? = lex.value() else { throw fail }
        guard let range = streamRange(after: lex, dict: d),
              case .array(let w)? = d["W"], w.count == 3, let w0 = w[0].int, let w1 = w[1].int, let w2 = w[2].int,
              let size = d["Size"]?.int else { throw fail }
        guard (0...8).contains(w0), (0...8).contains(w1), (0...8).contains(w2), w0 + w1 + w2 > 0,
              size >= 0, size <= maxNumber + 1 else { throw Self.corrupt }
        let row = w0 + w1 + w2
        let filters = PDFCodec.filterNames(d)
        var data: [UInt8]
        if filters == ["FlateDecode"] {
            guard let out = PDFCodec.inflate(bytes[range]) else { throw fail }
            data = out
            let parms = PDFCodec.decodeParms(d)
            if let pred = parms["Predictor"]?.int, pred >= 10 {
                guard data.count % (row + 1) == 0,
                      let un = PDFCodec.unfilterPNG(data, rowBytes: row, bpp: 1, rows: data.count / (row + 1)) else { throw fail }
                data = un
            }
        } else if !filters.isEmpty { throw fail }
        else { data = Array(bytes[range]) }

        var index: [Int] = [0, size]
        if case .array(let a)? = d["Index"] {
            index = a.compactMap(\.int)
            guard index.count == a.count, index.count % 2 == 0 else { throw Self.corrupt }
        }
        var pos = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = (v << 8) | Int(data[pos]); pos += 1 }
            return v
        }
        var k = 0
        while k + 1 < index.count {
            let start = index[k], count = index[k + 1]
            guard start >= 0, start <= maxNumber, count >= 0, count <= maxNumber + 1 - start,
                  count <= PDFLimits.maxXRefEntries - xrefEntryCount,
                  count <= (data.count - pos) / row else { throw Self.corrupt }
            xrefEntryCount += count
            for i in 0..<count {
                let type = w0 == 0 ? 1 : field(w0)
                let f2 = field(w1), f3 = field(w2)
                guard f2 >= 0, f3 >= 0 else { throw Self.corrupt }
                switch type {
                case 1: entries.append((start + i, .offset(f2, gen: f3)))
                case 2:
                    guard f2 <= maxNumber else { throw Self.corrupt }
                    entries.append((start + i, .compressed(stream: f2, index: f3)))
                default: entries.append((start + i, nil))
                }
            }
            k += 2
        }
        return (entries, d, true)
    }

    // MARK: Búsqueda de «endstream»

    /// Posiciones de todas las apariciones de «endstream» (una sola pasada con memmem): cada consulta es
    /// una búsqueda binaria en vez de un barrido O(tamaño) por objeto.
    private lazy var endstreamOffsets: [Int] = {
        var result: [Int] = []
        let needle: [UInt8] = Array("endstream".utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count >= needle.count else { return }
            var pos = 0
            while pos + needle.count <= raw.count, result.count < PDFLimits.maxEndstreamMarks,
                  let hit = memmem(base + pos, raw.count - pos, needle, needle.count) {
                let off = UnsafeRawPointer(hit) - base
                result.append(off)
                pos = off + 1
            }
        }
        return result
    }()

    private func firstEndstream(atOrAfter start: Int) -> Int? {
        let list = endstreamOffsets
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid] < start { lo = mid + 1 } else { hi = mid }
        }
        return lo < list.count ? list[lo] : nil
    }

    /// Rango de datos del stream que sigue al diccionario; el lexer queda al final de los datos.
    private func streamRange(after lex: PDFLexer, dict d: [String: PDFValue]) -> Range<Int>? {
        lex.skipWS()
        guard lex.hasPrefix("stream") else { return nil }
        lex.p += 6
        if lex.p < bytes.count, bytes[lex.p] == 13 { lex.p += 1 }
        if lex.p < bytes.count, bytes[lex.p] == 10 { lex.p += 1 }
        let start = lex.p
        var length: Int?
        if let l = d["Length"] {
            length = l.int
            if length == nil, let ref = l.refNumber, let inner = parse(ref)?.value { length = inner.int }
        }
        if let length, length >= 0 {
            let (end, overflow) = start.addingReportingOverflow(length)
            if !overflow, end <= bytes.count {
                let probe = PDFLexer(bytes, at: end)
                probe.skipWS()
                if probe.hasPrefix("endstream") { lex.p = end; return start..<end }
            }
        }
        // Longitud ausente, negativa o rota: se busca «endstream».
        guard let i = firstEndstream(atOrAfter: start) else { return nil }
        var e = i
        if e > start, bytes[e - 1] == 10 { e -= 1 }
        if e > start, bytes[e - 1] == 13 { e -= 1 }
        lex.p = e
        return start..<e
    }

    // MARK: Objetos

    /// Valor de un objeto (también si vive dentro de un ObjStm) y, si es stream suelto, sus datos.
    /// Un objeto que ya se está resolviendo (ciclo) o una cadena de resoluciones demasiado profunda devuelven nil.
    func parse(_ number: Int) -> (value: PDFValue, stream: Range<Int>?)? {
        guard inProgress.count < PDFLimits.maxParseDepth, inProgress.insert(number).inserted else { return nil }
        defer { inProgress.remove(number) }
        switch slots[number] {
        case .offset(let off, _)?:
            let lex = PDFLexer(bytes, at: off)
            guard lex.token() != nil, lex.token() != nil, lex.token() == "obj", let v = lex.value() else { return nil }
            guard case .dict(let d) = v, let range = streamRange(after: lex, dict: d) else { return (v, nil) }
            return (v, range)
        case .compressed(let stm, let idx)?:
            guard idx >= 0, let o = objStm(stm), idx < o.numbers.count else { return nil }
            let (pos, overflow) = o.first.addingReportingOverflow(o.offsets[idx])
            guard !overflow, pos >= 0, pos < o.data.count else { return nil }
            let lex = PDFLexer(o.data, at: pos)
            guard let v = lex.value() else { return nil }
            return (v, nil)
        case nil: return nil
        }
    }

    private func objStm(_ number: Int) -> ObjStmData? {
        if let cached = objStmCache[number] { return cached }
        guard case .offset? = slots[number], let (value, range) = parse(number), case .dict(let d) = value, let range,
              d["Type"]?.name == "ObjStm", let n = d["N"]?.int, let first = d["First"]?.int,
              n >= 0, n <= PDFLimits.maxObjects, first >= 0 else { return nil }
        let filters = PDFCodec.filterNames(d)
        var data: [UInt8]
        if filters.isEmpty { data = Array(bytes[range]) }
        else if filters == ["FlateDecode"], let out = PDFCodec.inflate(bytes[range]) { data = out }
        else { return nil }
        guard first <= data.count, n <= data.count / 2 else { return nil }   // cada par ocupa al menos 4 bytes
        let lex = PDFLexer(data, at: 0)
        var nums: [Int] = [], offs: [Int] = []
        nums.reserveCapacity(n); offs.reserveCapacity(n)
        for _ in 0..<n {
            guard let a = lex.token(), let num = Int(a), let b = lex.token(), let off = Int(b), num >= 0, off >= 0 else { return nil }
            nums.append(num); offs.append(off)
        }
        let result: ObjStmData = (numbers: nums, offsets: offs, first: first, data: data)
        // Caché con tope de tamaño total: si no cabe se purga; si un solo ObjStm excede el tope no se guarda.
        if data.count <= PDFLimits.maxObjStmCacheBytes {
            if objStmCacheBytes + data.count > PDFLimits.maxObjStmCacheBytes { objStmCache.removeAll(); objStmCacheBytes = 0 }
            objStmCache[number] = result
            objStmCacheBytes += data.count
        }
        return result
    }

    func intValue(of v: PDFValue?) -> Int? {
        guard let v else { return nil }
        if let n = v.int { return n }
        if let ref = v.refNumber, let n = parse(ref)?.value.int { return n }
        return nil
    }

    var maxObjectNumber: Int { slots.keys.max() ?? 0 }
    var isEncrypted: Bool { trailer["Encrypt"] != nil }

    /// Diccionario de cifrado y, si es un objeto indirecto, su número.
    func encryptionDictionary() -> (number: Int?, dict: [String: PDFValue])? {
        switch trailer["Encrypt"] {
        case .dict(let d)?: return (nil, d)
        case .raw(let r)? where r.hasSuffix(" R"):
            guard let n = PDFValue.raw(r).refNumber, let d = parse(n)?.value.dict else { return nil }
            return (n, d)
        default: return nil
        }
    }

    private func computeExtents() {
        var list: [(Int, Int, Int)] = []   // número, gen, offset
        for (n, slot) in slots { if case .offset(let off, let gen) = slot { list.append((n, gen, off)) } }
        list.sort { $0.2 < $1.2 }
        for (i, item) in list.enumerated() {
            let (number, gen, offset) = item
            guard offset >= 0, offset < bytes.count else { continue }
            let nextOffset = i + 1 < list.count ? list[i + 1].2 : bytes.count
            let lex = PDFLexer(bytes, at: offset)
            guard lex.token() != nil, lex.token() != nil, lex.token() == "obj" else { continue }
            var end = nextOffset
            var skip = false
            if let v = lex.value() {
                if case .dict(let d) = v {
                    if d["Type"]?.name == "XRef" || d["Linearized"] != nil { skip = true }
                    _ = streamRange(after: lex, dict: d)
                }
                lex.skipWS()
                if lex.hasPrefix("endstream") { lex.p += 9; lex.skipWS() }
                if lex.hasPrefix("endobj") { end = min(lex.p + 6, nextOffset) }
            }
            if !skip { extents.append(Extent(number: number, gen: gen, offset: offset, end: max(end, offset))) }
        }
    }

    // MARK: Escritura

    /// Archivo nuevo con todos los objetos copiados tal cual, salvo `replacements` (número → bytes del objeto).
    func serialized(replacing replacements: [Int: [UInt8]], extra: [Int: [UInt8]] = [:], omit: Set<Int> = [],
                    trailerOverrides: [String: PDFValue] = [:]) -> Data {
        let headerEnd = bytes.firstIndex(of: 10) ?? min(7, bytes.count)
        var out = Array(bytes[0..<headerEnd])
        out += [10, 37, 0xE2, 0xE3, 0xCF, 0xD3, 10]
        var offsets: [Int: (Int, Int)] = [:]
        for e in extents where !omit.contains(e.number) {
            offsets[e.number] = (out.count, e.gen)
            if let r = replacements[e.number] { out += r } else {
                out += bytes[e.offset..<e.end]
                if let last = out.last, last != 10, last != 13 { out.append(10) }
            }
        }
        for n in extra.keys.sorted() {
            offsets[n] = (out.count, 0)
            out += extra[n]!
            if let last = out.last, last != 10, last != 13 { out.append(10) }
        }
        // Los números de objeto están acotados al leer (PDFLimits.maxObjectNumber), así que size no se desborda
        // ni obliga a escribir tablas gigantes.
        let size = max(maxObjectNumber, extra.keys.max() ?? 0) + 1
        var tr: [String: PDFValue] = [:]
        for k in ["Root", "Info", "ID"] { if let v = trailer[k] { tr[k] = v } }
        for (k, v) in trailerOverrides { tr[k] = v }

        if usesXRefStream {
            let xrefNumber = size
            let xrefOffset = out.count
            var table: [UInt8] = []
            table.reserveCapacity((size + 2) * 9)
            func put(_ type: UInt8, _ a: Int, _ b: Int) {
                table.append(type)
                for shift in stride(from: 24, through: 0, by: -8) { table.append(UInt8((a >> shift) & 0xFF)) }
                for shift in stride(from: 24, through: 0, by: -8) { table.append(UInt8((b >> shift) & 0xFF)) }
            }
            for n in 0...size {
                if n == xrefNumber { put(1, xrefOffset, 0) }
                else if let (off, gen) = offsets[n] { put(1, off, gen) }
                else if !omit.contains(n), case .compressed(let stm, let idx)? = slots[n] { put(2, stm, idx) }
                else { put(0, 0, n == 0 ? 65535 : 0) }
            }
            tr["Type"] = .raw("/XRef"); tr["Size"] = .raw("\(size + 1)")
            tr["W"] = .array([.raw("1"), .raw("4"), .raw("4")]); tr["Length"] = .raw("\(table.count)")
            out += Array("\(xrefNumber) 0 obj\n\(PDFValue.dict(tr).serialized)\nstream\n".utf8)
            out += table
            out += Array("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        } else {
            let xrefStart = out.count
            var xref = "xref\n0 \(size)\n"
            for n in 0..<size {
                if let (off, gen) = offsets[n] { xref += String(format: "%010d %05d n \n", off, gen) }
                else { xref += "0000000000 65535 f \n" }
            }
            tr["Size"] = .raw("\(size)")
            xref += "trailer\n\(PDFValue.dict(tr).serialized)\nstartxref\n\(xrefStart)\n%%EOF\n"
            out += Array(xref.utf8)
        }
        return Data(out)
    }
}
