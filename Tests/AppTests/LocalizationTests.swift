import XCTest
import CabrioDomain
@testable import CabrioApp

final class LocalizationTests: XCTestCase {
    /// Raíz del repositorio a partir de la ubicación de este archivo.
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func englishTable() throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    func specs(_ s: String) -> [String] {
        let r = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@d]")
        return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
    }

    /// Todas las claves que usa el código (L, tr y títulos del catálogo) tienen traducción al inglés.
    func testEveryKeyUsedInCodeHasAnEnglishTranslationWithSameFormatSpecifiers() throws {
        let table = try englishTable()
        var keys = Set<String>()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        let call = try NSRegularExpression(pattern: #"\b(?:L|tr)\("((?:[^"\\]|\\.)*)""#)
        let title = try NSRegularExpression(pattern: #"title: (?:many \? )?"((?:[^"\\]|\\.)*)"(?: : "((?:[^"\\]|\\.)*)")?"#)
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            let range = NSRange(s.startIndex..., in: s)
            for re in [call, title] {
                for m in re.matches(in: s, range: range) {
                    for g in 1..<m.numberOfRanges { if let r = Range(m.range(at: g), in: s) { keys.insert(String(s[r]).replacingOccurrences(of: "\\\"", with: "\"")) } }
                }
            }
        }
        XCTAssertGreaterThan(keys.count, 200)
        let missing = keys.filter { table[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "Sin traducción al inglés: \(missing)")
        for k in keys { if let v = table[k] { XCTAssertEqual(specs(k), specs(v), "Marcadores distintos en «\(k)»") } }
        let stale = table.keys.filter { !keys.contains($0) }.sorted()
        XCTAssertTrue(stale.isEmpty, "Traducciones que el código ya no usa: \(stale)")
    }

    func testEnglishBundleTranslatesAppAndCoreMessages() throws {
        let dir = root.appendingPathComponent("Resources/en.lproj")
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        Localization.bundle = bundle
        defer { Localization.bundle = .main }
        XCTAssertEqual(L("Comprimir"), "Compress")
        XCTAssertEqual(L("%d archivos", 3), "3 files")
        XCTAssertEqual(CabrioError.wrongPassword("a.pdf").localizedDescription, "The password for “a.pdf” is not correct.")
        XCTAssertEqual(CabrioError.cancelled.localizedDescription, "Operation cancelled.")
        XCTAssertEqual(CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")).localizedDescription,
                       "Could not save the result. Check that the folder allows writing.")
        XCTAssertThrowsError(try PageRanges.parse("9", pageCount: 3)) {
            XCTAssertEqual($0.localizedDescription, "The PDF has 3 pages and “9” goes past that.")
        }
        XCTAssertThrowsError(try RenameTemplate.render("{foo}", name: "a", parent: "p", index: 0, start: 1, created: nil, modified: nil)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("I don’t know the placeholder {foo}."), $0.localizedDescription)
        }
        XCTAssertEqual(Subfolder.byKind.name(for: .image, date: nil), "Images")
        // Sin el paquete inglés (idioma base) el texto sigue en español.
        Localization.bundle = .main
        XCTAssertEqual(L("Comprimir"), "Comprimir")
    }
}
