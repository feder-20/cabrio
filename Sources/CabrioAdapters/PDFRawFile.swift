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

final class PDFLexer {
    let b: [UInt8]
    var p: Int

    init(_ bytes: [UInt8], at position: Int = 0) { b = bytes; p = position }

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
        let u = Array(s.utf8)
        guard p + u.count <= b.count else { return false }
        return Array(b[p..<(p + u.count)]) == u
    }

    func token() -> String? {
        skipWS()
        guard p < b.count else { return nil }
        let start = p
        if Self.isDelim(b[p]) { p += 1 } else {
            while p < b.count, !Self.isWS(b[p]), !Self.isDelim(b[p]) { p += 1 }
        }
        return String(decoding: b[start..<p], as: UTF8.self)
    }

    func value() -> PDFValue? {
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
    /// Flate de PDF (zlib). `hint` es el tamaño esperado si se conoce.
    static func inflate(_ data: ArraySlice<UInt8>, hint: Int = 0) -> [UInt8]? {
        guard data.count > 6 else { return nil }
        let b0 = Int(data[data.startIndex]), b1 = Int(data[data.startIndex + 1])
        guard b0 & 0x0F == 8, (b0 * 256 + b1) % 31 == 0, b1 & 0x20 == 0 else { return nil }
        var cap = max(hint, data.count * 4, 1024)
        while cap <= (1 << 30) {
            var out = [UInt8](repeating: 0, count: cap)
            let n = data.dropFirst(2).withUnsafeBufferPointer { src in
                compression_decode_buffer(&out, cap, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
            if n == 0 { return nil }
            if n < cap { return Array(out[0..<n]) }
            cap *= 2
        }
        return nil
    }

    static func unfilterPNG(_ data: [UInt8], rowBytes: Int, bpp: Int, rows: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rowBytes * rows)
        for y in 0..<rows {
            let filter = data[y * (rowBytes + 1)]
            let src = y * (rowBytes + 1) + 1
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
final class PDFRawFile {
    enum Slot { case offset(Int, gen: Int), compressed(stream: Int, index: Int) }
    struct Extent { let number: Int; let gen: Int; let offset: Int; var end: Int }

    let bytes: [UInt8]
    private(set) var slots: [Int: Slot] = [:]
    private(set) var extents: [Extent] = []
    private(set) var trailer: [String: PDFValue] = [:]
    private(set) var usesXRefStream = false
    private var objStmCache: [Int: (numbers: [Int], offsets: [Int], first: Int, data: [UInt8])] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        let fail = CabrioError.unsupported(tr("Este PDF no se pudo reescribir para comprimirlo."))
        let tail = bytes.count > 2048 ? bytes.count - 2048 : 0
        guard let r = Data(bytes[tail...]).range(of: Data("startxref".utf8), options: .backwards) else { throw fail }
        let lex = PDFLexer(bytes, at: tail + r.upperBound)
        guard let t = lex.token(), var next: Int = Int(t), next < bytes.count else { throw fail }

        var seen = Set<Int>()
        var shadowed = Set<Int>()   // números ya definidos por una sección más nueva (incluye libres)
        var first = true
        var pending: [Int] = [next]
        while let offset = pending.first {
            pending.removeFirst()
            guard seen.insert(offset).inserted else { continue }
            let (entries, tr, isStream) = try readSection(at: offset, fail: fail)
            if first { trailer = tr; usesXRefStream = isStream; first = false }
            for (number, slot) in entries where !shadowed.contains(number) {
                shadowed.insert(number)
                if let slot { slots[number] = slot }
            }
            if let x = tr["XRefStm"]?.int { pending.insert(x, at: 0) }
            if let prev = tr["Prev"]?.int { pending.append(prev) }
        }
        next = 0
        guard trailer["Root"] != nil else { throw fail }
        if slots.values.contains(where: { if case .compressed = $0 { return true } else { return false } }) { usesXRefStream = true }
        computeExtents()
    }

    // MARK: Secciones xref

    private func readSection(at offset: Int, fail: CabrioError) throws -> ([(Int, Slot?)], [String: PDFValue], Bool) {
        let lex = PDFLexer(bytes, at: offset)
        lex.skipWS()
        var entries: [(Int, Slot?)] = []
        if lex.hasPrefix("xref") {
            _ = lex.token()
            while true {
                lex.skipWS()
                if lex.hasPrefix("trailer") { _ = lex.token(); break }
                guard let s = lex.token(), let start = Int(s), let c = lex.token(), let count = Int(c) else { throw fail }
                for i in 0..<count {
                    guard let o = lex.token(), let off = Int(o), let g = lex.token(), let gen = Int(g), let kind = lex.token() else { throw fail }
                    entries.append((start + i, kind == "n" ? .offset(off, gen: gen) : nil))
                }
            }
            guard case .dict(let tr)? = lex.value() else { throw fail }
            return (entries, tr, false)
        }
        // Xref stream: «n g obj << … >> stream»
        guard lex.token() != nil, lex.token() != nil, lex.token() == "obj", case .dict(let d)? = lex.value() else { throw fail }
        guard let (_, range) = streamRange(after: lex, dict: d, objectEnd: bytes.count),
              case .array(let w)? = d["W"], w.count == 3, let w0 = w[0].int, let w1 = w[1].int, let w2 = w[2].int,
              let size = d["Size"]?.int else { throw fail }
        var data = Array(bytes[range])
        let filters = PDFCodec.filterNames(d)
        if filters == ["FlateDecode"] {
            guard let out = PDFCodec.inflate(bytes[range]) else { throw fail }
            data = out
            let parms = PDFCodec.decodeParms(d)
            if let pred = parms["Predictor"]?.int, pred >= 10 {
                let row = w0 + w1 + w2
                guard row > 0, data.count % (row + 1) == 0 else { throw fail }
                data = PDFCodec.unfilterPNG(data, rowBytes: row, bpp: 1, rows: data.count / (row + 1))
            }
        } else if !filters.isEmpty { throw fail }

        var index: [Int] = [0, size]
        if case .array(let a)? = d["Index"] { index = a.compactMap(\.int) }
        var pos = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = (v << 8) | Int(data[pos]); pos += 1 }
            return v
        }
        var k = 0
        while k + 1 < index.count {
            for i in 0..<index[k + 1] {
                guard pos + w0 + w1 + w2 <= data.count else { throw fail }
                let type = w0 == 0 ? 1 : field(w0)
                let f2 = field(w1), f3 = field(w2)
                switch type {
                case 1: entries.append((index[k] + i, .offset(f2, gen: f3)))
                case 2: entries.append((index[k] + i, .compressed(stream: f2, index: f3)))
                default: entries.append((index[k] + i, nil))
                }
            }
            k += 2
        }
        return (entries, d, true)
    }

    /// Rango de datos del stream que sigue al diccionario; el lexer queda al final de los datos.
    private func streamRange(after lex: PDFLexer, dict d: [String: PDFValue], objectEnd: Int) -> (Void, Range<Int>)? {
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
        if let length, start + length <= bytes.count {
            let probe = PDFLexer(bytes, at: start + length)
            probe.skipWS()
            if probe.hasPrefix("endstream") { lex.p = start + length; return ((), start..<(start + length)) }
        }
        // Longitud ausente o rota: se busca «endstream».
        let marker = Array("endstream".utf8)
        var i = start
        while i + marker.count <= bytes.count {
            if bytes[i] == marker[0], Array(bytes[i..<(i + marker.count)]) == marker {
                var e = i
                if e > start, bytes[e - 1] == 10 { e -= 1 }
                if e > start, bytes[e - 1] == 13 { e -= 1 }
                lex.p = e
                return ((), start..<e)
            }
            i += 1
        }
        return nil
    }

    // MARK: Objetos

    /// Valor de un objeto (también si vive dentro de un ObjStm) y, si es stream suelto, sus datos.
    func parse(_ number: Int) -> (value: PDFValue, stream: Range<Int>?)? {
        switch slots[number] {
        case .offset(let off, _)?:
            let lex = PDFLexer(bytes, at: off)
            guard lex.token() != nil, lex.token() != nil, lex.token() == "obj", let v = lex.value() else { return nil }
            guard case .dict(let d) = v, let (_, range) = streamRange(after: lex, dict: d, objectEnd: bytes.count) else { return (v, nil) }
            return (v, range)
        case .compressed(let stm, let idx)?:
            guard let o = objStm(stm), idx < o.numbers.count else { return nil }
            let lex = PDFLexer(o.data, at: o.first + (o.offsets[idx]))
            guard let v = lex.value() else { return nil }
            return (v, nil)
        case nil: return nil
        }
    }

    private func objStm(_ number: Int) -> (numbers: [Int], offsets: [Int], first: Int, data: [UInt8])? {
        if let cached = objStmCache[number] { return cached }
        guard case .offset? = slots[number], let (value, range) = parse(number), case .dict(let d) = value, let range,
              d["Type"]?.name == "ObjStm", let n = d["N"]?.int, let first = d["First"]?.int else { return nil }
        let filters = PDFCodec.filterNames(d)
        var data: [UInt8]
        if filters.isEmpty { data = Array(bytes[range]) }
        else if filters == ["FlateDecode"], let out = PDFCodec.inflate(bytes[range]) { data = out }
        else { return nil }
        let lex = PDFLexer(data, at: 0)
        var nums: [Int] = [], offs: [Int] = []
        for _ in 0..<n {
            guard let a = lex.token(), let num = Int(a), let b = lex.token(), let off = Int(b) else { return nil }
            nums.append(num); offs.append(off)
        }
        let result = (numbers: nums, offsets: offs, first: first, data: data)
        objStmCache[number] = result
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
            guard offset < bytes.count else { continue }
            let nextOffset = i + 1 < list.count ? list[i + 1].2 : bytes.count
            let lex = PDFLexer(bytes, at: offset)
            guard lex.token() != nil, lex.token() != nil, lex.token() == "obj" else { continue }
            var end = nextOffset
            var skip = false
            if let v = lex.value() {
                if case .dict(let d) = v {
                    if d["Type"]?.name == "XRef" || d["Linearized"] != nil { skip = true }
                    _ = streamRange(after: lex, dict: d, objectEnd: nextOffset)
                }
                lex.skipWS()
                if lex.hasPrefix("endstream") { lex.p += 9; lex.skipWS() }
                if lex.hasPrefix("endobj") { end = min(lex.p + 6, nextOffset) }
            }
            if !skip { extents.append(Extent(number: number, gen: gen, offset: offset, end: end)) }
        }
    }

    // MARK: Escritura

    /// Archivo nuevo con todos los objetos copiados tal cual, salvo `replacements` (número → bytes del objeto).
    func serialized(replacing replacements: [Int: [UInt8]], extra: [Int: [UInt8]] = [:], omit: Set<Int> = [],
                    trailerOverrides: [String: PDFValue] = [:]) -> Data {
        let headerEnd = bytes.firstIndex(of: 10) ?? 7
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
        let size = max(maxObjectNumber, extra.keys.max() ?? 0) + 1
        var tr: [String: PDFValue] = [:]
        for k in ["Root", "Info", "ID"] { if let v = trailer[k] { tr[k] = v } }
        for (k, v) in trailerOverrides { tr[k] = v }

        if usesXRefStream {
            let xrefNumber = size
            let xrefOffset = out.count
            var table: [UInt8] = []
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
