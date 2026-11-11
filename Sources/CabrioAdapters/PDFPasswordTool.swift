import Foundation
import CommonCrypto
import Security
import CabrioDomain

/// Contraseña de PDF sobre los bytes originales (manejador estándar V1–V4, RC4 y AES-128).
/// Reescribir con PDFKit dañaba el texto extraíble, así que aquí solo se cifran o descifran
/// cadenas y streams; el resto de cada objeto se conserva.
enum PDFPasswordTool {
    // MARK: Primitivas

    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    static func md5(_ d: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(d, CC_LONG(d.count), &out)
        return out
    }

    static func rc4(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 255
            s.swapAt(i, j)
        }
        var out = data
        var i = 0
        j = 0
        for k in 0..<out.count {
            i = (i + 1) & 255
            j = (j + Int(s[i])) & 255
            s.swapAt(i, j)
            out[k] ^= s[(Int(s[i]) + Int(s[j])) & 255]
        }
        return out
    }

    static func aes(encrypt: Bool, key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, data, data.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<moved])
    }

    /// Bytes aleatorios criptográficos; nil si el sistema no pudo generarlos (nunca se devuelven ceros).
    static func random(_ n: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess else { return nil }
        return b
    }

    // MARK: Cifrado estándar

    enum Method { case none, rc4, aes128 }

    struct Cipher {
        let key: [UInt8]
        let method: Method

        func objectKey(_ number: Int, _ gen: Int) -> [UInt8] {
            var d = key + [UInt8(number & 255), UInt8((number >> 8) & 255), UInt8((number >> 16) & 255),
                           UInt8(gen & 255), UInt8((gen >> 8) & 255)]
            if method == .aes128 { d += Array("sAlT".utf8) }
            return Array(md5(d).prefix(min(key.count + 5, 16)))
        }

        /// nil si falla el generador aleatorio o AES: el llamador aborta en vez de escribir un PDF corrupto.
        func encrypt(_ data: [UInt8], _ number: Int, _ gen: Int) -> [UInt8]? {
            switch method {
            case .none: return data
            case .rc4: return rc4(key: objectKey(number, gen), data)
            case .aes128:
                guard let iv = random(16), let body = aes(encrypt: true, key: objectKey(number, gen), iv: iv, data) else { return nil }
                return iv + body
            }
        }

        func decrypt(_ data: [UInt8], _ number: Int, _ gen: Int) -> [UInt8]? {
            switch method {
            case .none: return data
            case .rc4: return rc4(key: objectKey(number, gen), data)
            case .aes128:
                guard data.count >= 32, data.count % 16 == 0 else { return data.isEmpty ? [] : nil }
                return aes(encrypt: false, key: objectKey(number, gen), iv: Array(data[0..<16]), Array(data[16...]))
            }
        }
    }

    static func padded(_ pw: [UInt8]) -> [UInt8] { Array((pw + padding).prefix(32)) }

    /// Con contraseñas con tildes o ñ los lectores no coinciden (Latin-1 o UTF-8): al abrir se prueban las dos.
    static func passwordCandidates(_ s: String) -> [[UInt8]] {
        var list: [[UInt8]] = []
        if let l = s.data(using: .isoLatin1) { list.append([UInt8](l)) }
        let u = Array(s.utf8)
        if !list.contains(u) { list.append(u) }
        return list
    }

    /// Al proteger se usa Latin-1 (PDFDocEncoding) si se puede, que es lo que fija la especificación.
    static func passwordBytes(_ s: String) -> [UInt8] { passwordCandidates(s).first ?? Array(s.utf8) }

    static func fileKey(password: [UInt8], o: [UInt8], p: Int32, id0: [UInt8], r: Int, keyLength: Int,
                        encryptMetadata: Bool) -> [UInt8] {
        var d = padded(password) + o
        withUnsafeBytes(of: UInt32(bitPattern: p).littleEndian) { d += $0 }
        d += id0
        if r >= 4 && !encryptMetadata { d += [0xFF, 0xFF, 0xFF, 0xFF] }
        var h = md5(d)
        if r >= 3 { for _ in 0..<50 { h = md5(Array(h.prefix(keyLength))) } }
        return Array(h.prefix(keyLength))
    }

    static func ownerEntry(owner: [UInt8], user: [UInt8], r: Int, keyLength: Int) -> [UInt8] {
        var h = md5(padded(owner.isEmpty ? user : owner))
        if r >= 3 { for _ in 0..<50 { h = md5(h) } }
        let key = Array(h.prefix(keyLength))
        var x = rc4(key: key, padded(user))
        if r >= 3 { for i in 1...19 { x = rc4(key: key.map { $0 ^ UInt8(i) }, x) } }
        return x
    }

    static func userEntry(key: [UInt8], id0: [UInt8], r: Int) -> [UInt8] {
        if r == 2 { return rc4(key: key, padding) }
        var x = rc4(key: key, md5(padding + id0))
        for i in 1...19 { x = rc4(key: key.map { $0 ^ UInt8(i) }, x) }
        return x + [UInt8](repeating: 0, count: 16)
    }

    // MARK: Cadenas

    static func decodeString(_ token: String) -> [UInt8]? {
        let b = token.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        if token.hasPrefix("(") {
            var out: [UInt8] = []
            var i = 1
            let end = b.count - 1
            while i < end {
                let c = b[i]
                if c == UInt8(ascii: "\\"), i + 1 < end {
                    i += 1
                    let e = b[i]
                    switch e {
                    case UInt8(ascii: "n"): out.append(10)
                    case UInt8(ascii: "r"): out.append(13)
                    case UInt8(ascii: "t"): out.append(9)
                    case UInt8(ascii: "b"): out.append(8)
                    case UInt8(ascii: "f"): out.append(12)
                    case 13: if i + 1 < end, b[i + 1] == 10 { i += 1 }
                    case 10: break
                    case UInt8(ascii: "0")...UInt8(ascii: "7"):
                        var v = Int(e - 48)
                        var n = 1
                        while n < 3, i + 1 < end, b[i + 1] >= 48, b[i + 1] <= 55 { i += 1; v = v * 8 + Int(b[i] - 48); n += 1 }
                        out.append(UInt8(truncatingIfNeeded: v))
                    default: out.append(e)
                    }
                } else { out.append(c) }
                i += 1
            }
            return out
        }
        if token.hasPrefix("<") && !token.hasPrefix("<<") {
            let hex = token.dropFirst().dropLast().filter { !$0.isWhitespace }
            var padded = String(hex)
            if padded.count % 2 == 1 { padded += "0" }
            var out: [UInt8] = []
            var idx = padded.startIndex
            while idx < padded.endIndex {
                let next = padded.index(idx, offsetBy: 2)
                guard let v = UInt8(padded[idx..<next], radix: 16) else { return nil }
                out.append(v); idx = next
            }
            return out
        }
        return nil
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    /// Aplica `f` a todas las cadenas del valor. `changed` indica si hubo alguna.
    static func mapStrings(_ v: PDFValue, changed: inout Bool, _ f: ([UInt8]) -> [UInt8]?) -> PDFValue? {
        switch v {
        case .raw(let s):
            guard s.hasPrefix("(") || (s.hasPrefix("<") && !s.hasPrefix("<<")) else { return v }
            guard let bytes = decodeString(s), let out = f(bytes) else { return nil }
            changed = true
            return .raw(hexString(out))
        case .array(let a):
            var r: [PDFValue] = []
            for x in a { guard let m = mapStrings(x, changed: &changed, f) else { return nil }; r.append(m) }
            return .array(r)
        case .dict(let d):
            var r: [String: PDFValue] = [:]
            for (k, x) in d { guard let m = mapStrings(x, changed: &changed, f) else { return nil }; r[k] = m }
            return .dict(r)
        }
    }

    /// Reescribe los objetos de `file` aplicando `transform` a cadenas y streams.
    /// `transform(bytes, número, gen)` devuelve nil si falla (p. ej. contraseña o datos inválidos).
    static func rewriteObjects(_ file: PDFRawFile, skip: Set<Int>, skipMetadataStreams: Bool,
                               _ transform: ([UInt8], Int, Int) -> [UInt8]?) throws -> [Int: [UInt8]] {
        let fail = CabrioError.unsupported(tr("Este PDF usa una estructura que Cabrio todavía no sabe procesar."))
        var out: [Int: [UInt8]] = [:]
        for e in file.extents where !skip.contains(e.number) {
            guard let (value, range) = file.parse(e.number) else { throw fail }
            var changed = false
            guard let mapped = mapStrings(value, changed: &changed, { transform($0, e.number, e.gen) }) else { throw fail }
            guard var dict = mapped.dict, let range else {
                if changed { out[e.number] = Array("\(e.number) \(e.gen) obj\n\(mapped.serialized)\nendobj\n".utf8) }
                continue
            }
            if dict["Type"]?.name == "XRef" { continue }
            if skipMetadataStreams, dict["Type"]?.name == "Metadata" {
                if changed { out[e.number] = Array("\(e.number) \(e.gen) obj\n\(mapped.serialized)\nstream\n".utf8) + Array(file.bytes[range]) + Array("\nendstream\nendobj\n".utf8) }
                continue
            }
            if PDFCodec.filterNames(dict).contains("Crypt") { throw fail }
            guard let data = transform(Array(file.bytes[range]), e.number, e.gen) else { throw fail }
            dict["Length"] = .raw("\(data.count)")
            out[e.number] = Array("\(e.number) \(e.gen) obj\n\(PDFValue.dict(dict).serialized)\nstream\n".utf8) + data
                + Array("\nendstream\nendobj\n".utf8)
        }
        return out
    }

    // MARK: Proteger

    static func protect(input: URL, password: String, output: URL) throws {
        let name = input.lastPathComponent
        let data = try readOriginal(input)
        let file: PDFRawFile
        do { file = try PDFRawFile(data: data) } catch { throw CabrioError.unsupported(tr("No se pudo proteger «%@».", name)) }
        guard !file.isEncrypted else {
            throw CabrioError.unsupported(tr("«%@» ya tiene contraseña. Quítala primero si quieres poner otra.", name))
        }
        let pw = passwordBytes(password)
        guard let id0 = random(16), let id1 = random(16) else {
            throw CabrioError.unsupported(tr("No se pudo generar el cifrado de forma segura. Inténtalo de nuevo."))
        }
        let permissions: Int32 = -4
        let o = ownerEntry(owner: pw, user: pw, r: 4, keyLength: 16)
        let key = fileKey(password: pw, o: o, p: permissions, id0: id0, r: 4, keyLength: 16, encryptMetadata: true)
        let u = userEntry(key: key, id0: id0, r: 4)
        let cipher = Cipher(key: key, method: .aes128)

        let replacements = try rewriteObjects(file, skip: [], skipMetadataStreams: false) { cipher.encrypt($0, $1, $2) }
        let encryptNumber = max(file.maxObjectNumber, 0) + 1
        let encrypt = "\(encryptNumber) 0 obj\n<</Filter /Standard /V 4 /R 4 /Length 128 /P \(permissions) "
            + "/O \(hexString(o)) /U \(hexString(u)) /StmF /StdCF /StrF /StdCF "
            + "/CF <</StdCF <</AuthEvent /DocOpen /CFM /AESV2 /Length 16>>>>>>\nendobj\n"
        let result = file.serialized(
            replacing: replacements, extra: [encryptNumber: Array(encrypt.utf8)],
            trailerOverrides: ["ID": .array([.raw(hexString(id0)), .raw(hexString(id1))]),
                               "Encrypt": .raw("\(encryptNumber) 0 R")])
        try write(result, to: output)
    }

    // MARK: Quitar

    static func unlock(input: URL, password: String, output: URL) throws {
        let name = input.lastPathComponent
        let data = try readOriginal(input)
        let file: PDFRawFile
        do { file = try PDFRawFile(data: data) } catch { throw CabrioError.unsupported(tr("No se pudo abrir «%@».", name)) }
        guard let (encryptNumber, enc) = file.encryptionDictionary() else {
            throw CabrioError.unsupported(tr("«%@» no tiene contraseña.", name))
        }
        let unsupported = CabrioError.unsupported(tr("«%@» usa un cifrado que Cabrio todavía no sabe quitar (AES de 256 bits).", name))
        guard enc["Filter"]?.name == "Standard", let v = enc["V"]?.int, let r = enc["R"]?.int, v <= 4, r <= 4,
              let oTok = enc["O"], case .raw(let oRaw) = oTok, let o = decodeString(oRaw),
              case .raw(let uRaw)? = enc["U"], let u = decodeString(uRaw), let p = enc["P"]?.int else { throw unsupported }

        var method = Method.rc4
        var keyLength = r == 2 ? 5 : ((enc["Length"]?.int ?? 40) / 8)
        if v >= 4 {
            let stm = enc["StmF"]?.name ?? "Identity", str = enc["StrF"]?.name ?? "Identity"
            guard stm == str else { throw unsupported }
            if stm == "Identity" { method = .none } else {
                let cf = enc["CF"]?.dict?[stm]?.dict
                switch cf?["CFM"]?.name {
                case "V2": method = .rc4
                case "AESV2": method = .aes128
                case "None": method = .none
                default: throw unsupported
                }
                keyLength = 16
            }
        }
        keyLength = max(5, min(keyLength, 16))
        let encryptMetadata = !(enc["EncryptMetadata"].map { $0.serialized == "false" } ?? false)

        // ID[0] del trailer.
        var id0: [UInt8] = []
        if case .array(let ids)? = file.trailer["ID"], case .raw(let t)? = ids.first, let b = decodeString(t) { id0 = b }

        func authenticate(_ user: [UInt8]) -> [UInt8]? {
            let k = fileKey(password: user, o: o, p: Int32(truncatingIfNeeded: p), id0: id0, r: r,
                            keyLength: keyLength, encryptMetadata: encryptMetadata)
            let check = userEntry(key: k, id0: id0, r: r)
            let n = r == 2 ? 32 : 16
            return u.count >= n && Array(check.prefix(n)) == Array(u.prefix(n)) ? k : nil
        }
        var key: [UInt8]?
        for pw in passwordCandidates(password) where key == nil {
            key = authenticate(pw)
            if key != nil { break }
            // ¿es la contraseña del propietario? (algoritmo 7)
            var h = md5(padded(pw))
            if r >= 3 { for _ in 0..<50 { h = md5(h) } }
            let ownerKey = Array(h.prefix(keyLength))
            var userPw = o
            if r == 2 { userPw = rc4(key: ownerKey, o) }
            else { for i in stride(from: 19, through: 0, by: -1) { userPw = rc4(key: ownerKey.map { $0 ^ UInt8(i) }, userPw) } }
            key = authenticate(userPw)
        }
        guard let key else { throw CabrioError.wrongPassword(name) }

        let cipher = Cipher(key: key, method: method)
        let replacements = try rewriteObjects(file, skip: encryptNumber.map { [$0] } ?? [],
                                              skipMetadataStreams: !encryptMetadata) { cipher.decrypt($0, $1, $2) }
        let result = file.serialized(replacing: replacements, omit: encryptNumber.map { [$0] } ?? [])
        try write(result, to: output)
    }

    private static func readOriginal(_ url: URL) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > PDFLimits.maxFileBytes {
            throw CabrioError.unsupported(tr("Este PDF es demasiado grande para procesarlo (1 GB como máximo)."))
        }
        do { return try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw CabrioError.unreadableFile(url.lastPathComponent) }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) }
        catch { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
    }
}
