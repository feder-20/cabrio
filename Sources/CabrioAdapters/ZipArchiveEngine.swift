import Foundation
import Compression
import CabrioDomain
import CabrioPorts

// MARK: - CRC32

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}

// MARK: - Deflate crudo (el que usa ZIP)

final class Deflater {
    private var stream: compression_stream
    private let dst: UnsafeMutablePointer<UInt8>
    private let dummy: UnsafeMutablePointer<UInt8>
    private let dstSize = 64 * 1024

    init() throws {
        dummy = .allocate(capacity: 1)
        dst = .allocate(capacity: dstSize)
        stream = compression_stream(dst_ptr: dst, dst_size: dstSize, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            dummy.deallocate(); dst.deallocate()
            throw CabrioError.writeFailed(tr("No se pudo iniciar la compresión."))
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        dummy.deallocate()
        dst.deallocate()
    }

    func process(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dummy)
            stream.src_size = input.count
            let flags = finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.dst_ptr = dst
                stream.dst_size = dstSize
                let status = compression_stream_process(&stream, flags)
                let produced = dstSize - stream.dst_size
                if produced > 0 { try emit(Data(bytes: dst, count: produced)) }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { throw CabrioError.writeFailed(tr("Falló la compresión.")) }
                if !finish && stream.src_size == 0 && stream.dst_size > 0 { return }
            }
        }
    }
}

// MARK: - Escritor ZIP en streaming (descriptores de datos; sin ZIP64)

final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let csize: UInt32
        let usize: UInt32
        let offset: UInt32
        let method: UInt16
        let isDir: Bool
        let time: UInt16
        let date: UInt16
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CabrioError.writeFailed(tr("No hay permiso para escribir en esa carpeta."))
        }
        handle = try FileHandle(forWritingTo: url)
    }

    private func write(_ d: Data) throws {
        try handle.write(contentsOf: d)
        offset += UInt64(d.count)
    }

    private static func dos(_ d: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let y: Int = max((c.year ?? 1980) - 1980, 0)
        let mo: Int = c.month ?? 1
        let da: Int = c.day ?? 1
        let h: Int = c.hour ?? 0
        let mi: Int = c.minute ?? 0
        let se: Int = (c.second ?? 0) / 2
        let date: Int = (y << 9) | (mo << 5) | da
        let time: Int = (h << 11) | (mi << 5) | se
        return (UInt16(time), UInt16(date))
    }

    private func checkOffset() throws {
        if offset > UInt64(UInt32.max) - 1_000_000 { throw CabrioError.tooLarge("El ZIP") }
    }

    func addDirectory(name: String, modified: Date) throws {
        try checkOffset()
        let nameData = Data((name + "/").utf8)
        let (t, d) = Self.dos(modified)
        var h = Data()
        h.le32(0x04034b50); h.le16(20); h.le16(0x0800); h.le16(0); h.le16(t); h.le16(d)
        h.le32(0); h.le32(0); h.le32(0); h.le16(UInt16(nameData.count)); h.le16(0)
        h.append(nameData)
        let off = UInt32(offset)
        try write(h)
        entries.append(Entry(name: nameData, crc: 0, csize: 0, usize: 0, offset: off, method: 0, isDir: true, time: t, date: d))
    }

    func addFile(name: String, at url: URL, modified: Date) throws {
        try checkOffset()
        let nameData = Data(name.utf8)
        let (t, d) = Self.dos(modified)
        var h = Data()
        // Bit 3: tamaños y CRC van en un descriptor tras los datos. Bit 11: nombres UTF-8.
        h.le32(0x04034b50); h.le16(20); h.le16(0x0808); h.le16(8); h.le16(t); h.le16(d)
        h.le32(0); h.le32(0); h.le32(0); h.le16(UInt16(nameData.count)); h.le16(0)
        h.append(nameData)
        let off = UInt32(offset)
        try write(h)

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let deflater = try Deflater()
        var crc: UInt32 = 0
        var usize: UInt64 = 0
        var csize: UInt64 = 0
        let emit: (Data) throws -> Void = { [self] out in
            try write(out)
            csize += UInt64(out.count)
        }
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            crc = CRC32.update(crc, chunk)
            usize += UInt64(chunk.count)
            try deflater.process(chunk, finish: false, emit: emit)
        }
        try deflater.process(Data(), finish: true, emit: emit)
        guard usize <= UInt64(UInt32.max), csize <= UInt64(UInt32.max) else {
            throw CabrioError.tooLarge(url.lastPathComponent)
        }
        var dd = Data()
        dd.le32(0x08074b50); dd.le32(crc); dd.le32(UInt32(csize)); dd.le32(UInt32(usize))
        try write(dd)
        entries.append(Entry(name: nameData, crc: crc, csize: UInt32(csize), usize: UInt32(usize),
                             offset: off, method: 8, isDir: false, time: t, date: d))
    }

    func finish() throws {
        let cdStart = offset
        for e in entries {
            var c = Data()
            c.le32(0x02014b50)
            c.le16(20)                       // versión creada: 2.0, host MS-DOS (compatible con Windows)
            c.le16(20)
            c.le16(e.isDir ? 0x0800 : 0x0808)
            c.le16(e.method); c.le16(e.time); c.le16(e.date)
            c.le32(e.crc); c.le32(e.csize); c.le32(e.usize)
            c.le16(UInt16(e.name.count)); c.le16(0); c.le16(0)
            c.le16(0); c.le16(0)
            c.le32(e.isDir ? 0x10 : 0)
            c.le32(e.offset)
            c.append(e.name)
            try write(c)
        }
        let cdSize = offset - cdStart
        guard entries.count < 0xFFFF, cdStart <= UInt64(UInt32.max) else { throw CabrioError.tooLarge("El ZIP") }
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(cdSize)); end.le32(UInt32(cdStart)); end.le16(0)
        try write(end)
        try handle.close()
    }

    func abort() { try? handle.close() }
}

// MARK: - Motor

public struct ZipArchiveEngine: ArchiveEngine {
    public init() {}

    static let excludedNames: Set<String> = [
        ".DS_Store", "__MACOSX", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    static func isExcluded(_ name: String) -> Bool {
        excludedNames.contains(name) || name.hasPrefix("._")
    }

    public func cleanZip(_ inputs: [URL], output: URL) async throws {
        let fm = FileManager.default
        let writer = try ZipWriter(url: output)
        do {
            var seen = Set<String>()
            func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

            for root in inputs {
                let rootName = root.lastPathComponent
                if Self.isExcluded(rootName) { continue }
                let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true {
                    let base = norm(rootName)
                    if seen.insert(base + "/").inserted { try writer.addDirectory(name: base, modified: values?.contentModificationDate ?? Date()) }
                    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                                                 options: []) else { continue }
                    var items: [URL] = []
                    while let next = en.nextObject() {
                        guard let url = next as? URL else { continue }
                        if Self.isExcluded(url.lastPathComponent) { en.skipDescendants(); continue }
                        items.append(url)
                    }
                    items.sort { $0.path < $1.path }
                    let rootPath = root.standardizedFileURL.path
                    for url in items {
                        try Task.checkCancellation()
                        let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
                        var rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
                        if rel.hasPrefix("/") { rel.removeFirst() }
                        let name = norm(base + "/" + rel)
                        if rv.isDirectory == true {
                            if seen.insert(name + "/").inserted { try writer.addDirectory(name: name, modified: rv.contentModificationDate ?? Date()) }
                        } else if rv.isRegularFile == true, seen.insert(name).inserted {
                            try writer.addFile(name: name, at: url, modified: rv.contentModificationDate ?? Date())
                        }
                    }
                } else {
                    let name = norm(rootName)
                    if seen.insert(name).inserted {
                        try writer.addFile(name: name, at: root, modified: values?.contentModificationDate ?? Date())
                    }
                }
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }
}
