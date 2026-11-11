import XCTest
import CabrioDomain
import CabrioPorts
import CabrioApplication

// Dobles de los puertos (sin tocar el disco ni los frameworks de Apple).
final class FakeFS: FileSystem, @unchecked Sendable {
    var files: Set<String> = []
    var trashed: [String] = []
    func exists(_ url: URL) -> Bool { files.contains(url.path) || folders.contains(url.path) }
    var directories: [String] = []
    var folders: Set<String> = []
    var failMoveTo: String?
    var moveLog: [String] = []
    let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14
    var sizes: [String: Int64] = [:]
    var createdOverride: [String: Date] = [:]
    func attributes(of url: URL) -> FileAttributes {
        FileAttributes(isDirectory: folders.contains(url.path), created: createdOverride[url.path] ?? date, modified: date, size: sizes[url.path] ?? 100)
    }
    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        files.union(folders).filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == url.path }.sorted().map { URL(fileURLWithPath: $0) }
    }
    func moveItem(from: URL, to: URL) throws {
        if to.lastPathComponent == failMoveTo { throw CabrioError.writeFailed("falla simulada") }
        guard files.contains(from.path) else { throw CabrioError.unreadableFile(from.lastPathComponent) }
        if files.contains(to.path) && from.path.lowercased() != to.path.lowercased() { throw CabrioError.writeFailed("existe") }
        files.remove(from.path); files.insert(to.path); moveLog.append("\(from.lastPathComponent)>\(to.lastPathComponent)")
    }
    func createDirectory(_ url: URL) throws { folders.insert(url.path); directories.append(url.path) }
    @discardableResult func moveToTrash(_ url: URL) throws -> URL? {
        files.remove(url.path); trashed.append(url.path)
        let t = URL(fileURLWithPath: "/.Trash/\(url.lastPathComponent)")
        files.insert(t.path)
        return t
    }
}

struct FakeEngines: PDFEngine, ImageEngine, ArchiveEngine, OCREngine, MediaEngine {
    let fs: FakeFS
    var failOnImage: String?

    func merge(_ inputs: [URL], into output: URL) async throws { fs.files.insert(output.path) }
    func makePDF(fromImages images: [URL], output: URL) async throws { fs.files.insert(output.path) }
    func convert(_ input: URL, to format: ImageFormat, quality: Double, maxSide: Int?, output: URL) async throws {
        fs.files.insert(output.path)
        if input.lastPathComponent == failOnImage { throw CabrioError.unreadableFile(input.lastPathComponent) }
    }
    var pages = 5
    func removeBackground(_ input: URL, output: URL) async throws { fs.files.insert(output.path) }
    func compressVideo(_ input: URL, target: VideoTarget, hevc: Bool, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionReport {
        fs.files.insert(output.path); progress(1)
        if case .maxBytes(let m) = target { return CompressionReport(originalBytes: 1000, resultBytes: 400, targetBytes: m, reachedTarget: 400 <= m) }
        return CompressionReport(originalBytes: 1000, resultBytes: 400)
    }
    func audioToM4A(_ input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws { fs.files.insert(output.path); progress(1) }
    func protect(_ input: URL, password: String, output: URL) async throws {
        if password == "mala" { throw CabrioError.wrongPassword(input.lastPathComponent) }
        fs.files.insert(output.path)
    }
    func unlock(_ input: URL, password: String, output: URL) async throws {
        if password != "ok" { throw CabrioError.wrongPassword(input.lastPathComponent) }
        fs.files.insert(output.path)
    }
    func compress(_ input: URL, target: CompressionTarget, output: URL, progress: @Sendable (Double) -> Void) async throws -> CompressionReport {
        fs.files.insert(output.path)
        progress(1)
        if case .maxBytes(let m) = target { return CompressionReport(originalBytes: 100, resultBytes: 40, targetBytes: m, reachedTarget: 40 <= m) }
        return CompressionReport(originalBytes: 100, resultBytes: 40)
    }
    func pageCount(of input: URL) async throws -> Int { pages }
    func split(_ input: URL, ranges: [ClosedRange<Int>], outputs: [URL]) async throws {
        outputs.forEach { fs.files.insert($0.path) }
    }
    func makeSearchable(_ input: URL, languages: [String], output: URL, progress: @Sendable (Double) -> Void) async throws {
        progress(0.5); fs.files.insert(output.path); progress(1)
    }
    func cleanZip(_ inputs: [URL], output: URL) async throws { fs.files.insert(output.path) }
}

final class FakeHistory: HistoryStore, @unchecked Sendable {
    var items: [HistoryEntry] = []
    func record(_ entry: HistoryEntry) async { items.insert(entry, at: 0) }
    func entry(id: UUID) async -> HistoryEntry? { items.first { $0.id == id } }
    func remove(id: UUID) async { items.removeAll { $0.id == id } }
    func recent(limit: Int) async -> [HistoryEntry] { Array(items.prefix(limit)) }
}

final class RunOperationTests: XCTestCase {
    func make(failOnImage: String? = nil) -> (RunOperation, FakeFS, FakeHistory) {
        let fs = FakeFS(), h = FakeHistory()
        let e = FakeEngines(fs: fs, failOnImage: failOnImage)
        return (RunOperation(pdf: e, image: e, archive: e, media: e, ocr: e, fileSystem: fs, history: h), fs, h)
    }
    let dir = URL(fileURLWithPath: "/tmp/x")

    func testMergeNamesOutputNextToFirstInputWithSuffix() async throws {
        let (run, fs, _) = make()
        let out = try await run(.mergePDFs, inputs: [dir.appendingPathComponent("a.pdf"), dir.appendingPathComponent("b.pdf")])
        XCTAssertEqual(out, [dir.appendingPathComponent("a_cabrio.pdf")])
        XCTAssertTrue(fs.exists(out[0]))
    }

    func testExistingOutputGetsNumericSuffix() async throws {
        let (run, fs, _) = make()
        fs.files.insert(dir.appendingPathComponent("a_cabrio.pdf").path)
        fs.files.insert(dir.appendingPathComponent("a_cabrio-2.pdf").path)
        let out = try await run(.mergePDFs, inputs: [dir.appendingPathComponent("a.pdf"), dir.appendingPathComponent("b.pdf")])
        XCTAssertEqual(out.first?.lastPathComponent, "a_cabrio-3.pdf")
    }

    func testMergeNeedsTwoFiles() async {
        let (run, _, _) = make()
        do { _ = try await run(.mergePDFs, inputs: [dir.appendingPathComponent("a.pdf")]); XCTFail() }
        catch { XCTAssertEqual(error as? CabrioError, .notEnoughFiles) }
    }

    func testSameBaseNamesInBatchDoNotCollide() async throws {
        let (run, _, _) = make()
        let out = try await run(.convertImage(to: .jpg, quality: 0.9),
                                inputs: [dir.appendingPathComponent("f.png"), dir.appendingPathComponent("f.heic")])
        XCTAssertEqual(Set(out.map(\.lastPathComponent)), ["f_cabrio.jpg", "f_cabrio-2.jpg"])
    }

    func testFailureTrashesOnlyPartialOutputsAndRecordsNothing() async {
        let (run, fs, h) = make(failOnImage: "b.png")
        do {
            _ = try await run(.convertImage(to: .jpg, quality: 0.9),
                              inputs: [dir.appendingPathComponent("a.png"), dir.appendingPathComponent("b.png")])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? CabrioError, .unreadableFile("b.png"))
        }
        XCTAssertEqual(Set(fs.trashed), [dir.appendingPathComponent("a_cabrio.jpg").path, dir.appendingPathComponent("b_cabrio.jpg").path])
        XCTAssertTrue(h.items.isEmpty)
    }

    func testUndoMovesOutputsToTrashAndClearsHistory() async throws {
        let (run, fs, h) = make()
        let out = try await run(.cleanZip(name: "Informe"), inputs: [dir.appendingPathComponent("Informe")])
        XCTAssertEqual(out.first?.lastPathComponent, "Informe.zip")
        let id = h.items[0].id
        try await run.undo(id)
        XCTAssertEqual(fs.trashed, [out[0].path])
        XCTAssertTrue(h.items.isEmpty)
    }

    func testSplitEveryPageCreatesFolderWithPaddedNames() async throws {
        let (run, fs, _) = make()
        let out = try await run(.splitPDF(.everyPage), inputs: [dir.appendingPathComponent("doc.pdf")])
        XCTAssertEqual(out, [dir.appendingPathComponent("doc_cabrio")])
        XCTAssertEqual(fs.directories, [out[0].path])
        XCTAssertTrue(fs.files.contains(out[0].appendingPathComponent("doc_p5.pdf").path))
        XCTAssertEqual(fs.files.filter { $0.hasSuffix(".pdf") }.count, 5)
    }

    func testSplitByRangesNamesAndValidation() async throws {
        let (run, fs, _) = make()
        _ = try await run(.splitPDF(.ranges("1-2, 4-")), inputs: [dir.appendingPathComponent("doc.pdf")])
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("doc_cabrio/doc_p1-2.pdf").path))
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("doc_cabrio/doc_p4-5.pdf").path))
        do { _ = try await run(.splitPDF(.ranges("9")), inputs: [dir.appendingPathComponent("doc.pdf")]); XCTFail() }
        catch { XCTAssertTrue((error as? CabrioError).map { if case .unsupported = $0 { true } else { false } } ?? false) }
    }

    func testPageRangesParser() throws {
        XCTAssertEqual(try PageRanges.parse("1-3, 5; 8-", pageCount: 10), [1...3, 5...5, 8...10])
        XCTAssertEqual(try PageRanges.parse("2,2", pageCount: 3), [2...2])
        for bad in ["", "0", "3-1", "a", "1-2-3", "11"] {
            XCTAssertThrowsError(try PageRanges.parse(bad, pageCount: 10), bad)
        }
    }

    func testOCRNamesOutputsPerInputAndReportsProgress() async throws {
        let (run, _, _) = make()
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let out = try await run(.ocr(languages: ["es"]),
                                inputs: [dir.appendingPathComponent("a.pdf"), dir.appendingPathComponent("b.pdf")]) { box.values.append($0) }
        XCTAssertEqual(out.map(\.lastPathComponent), ["a_cabrio.pdf", "b_cabrio.pdf"])
        XCTAssertEqual(box.values.last, 1)
        XCTAssertEqual(box.values.first, 0.25)
    }

    func testCompressRecordsReportsInHistoryAndNamesOutputs() async throws {
        let (run, _, h) = make()
        let out = try await run(.compressPDF(.maxBytes(10)),
                                inputs: [dir.appendingPathComponent("a.pdf"), dir.appendingPathComponent("b.pdf")])
        XCTAssertEqual(out.map(\.lastPathComponent), ["a_cabrio.pdf", "b_cabrio.pdf"])
        XCTAssertEqual(h.items[0].reports.count, 2)
        XCTAssertTrue(h.items[0].reports.allSatisfy { !$0.reachedTarget })
    }

    func testProtectAndUnlockNameOutputsAndDoNotLeakPassword() async throws {
        let (run, _, h) = make()
        let out = try await run(.protectPDF(password: SecretRef("ok")), inputs: [dir.appendingPathComponent("a.pdf")])
        XCTAssertEqual(out.first?.lastPathComponent, "a_cabrio.pdf")
        let entry = h.items[0]
        XCTAssertFalse("\(entry.operation) \(entry)".contains("ok\""), "la contraseña no debe verse en descripciones")
        let json = String(decoding: try JSONEncoder().encode(entry.operation), as: UTF8.self)
        XCTAssertFalse(json.contains("ok"), json)
        // En memoria tampoco se conserva: el historial guarda la operación con la contraseña vacía.
        guard case .protectPDF(let kept) = entry.operation else { return XCTFail("operación inesperada") }
        XCTAssertEqual(kept.value, "")
        do { _ = try await run(.unlockPDF(password: SecretRef("x")), inputs: [dir.appendingPathComponent("b.pdf")]); XCTFail() }
        catch { XCTAssertEqual(error as? CabrioError, .wrongPassword("b.pdf")) }
    }

    func testMediaOperationsNameOutputsByType() async throws {
        let (run, _, h) = make()
        let v = try await run(.compressVideo(.maxBytes(100), hevc: true), inputs: [dir.appendingPathComponent("clip.MOV")])
        XCTAssertEqual(v.first?.lastPathComponent, "clip_cabrio.mp4")
        XCTAssertEqual(h.items[0].reports.first?.reachedTarget, false)
        let a = try await run(.audioToM4A, inputs: [dir.appendingPathComponent("clip.MOV"), dir.appendingPathComponent("voz.wav")])
        XCTAssertEqual(a.map(\.lastPathComponent), ["clip_cabrio.m4a", "voz_cabrio.m4a"])
        let p = try await run(.removeBackground, inputs: [dir.appendingPathComponent("foto.heic")])
        XCTAssertEqual(p.first?.lastPathComponent, "foto_cabrio.png")
        let c = try await run(.compressImage(.high), inputs: [dir.appendingPathComponent("otra.PNG")])
        XCTAssertEqual(c.first?.lastPathComponent, "otra_cabrio.png")
    }

    // MARK: Renombrar por lotes

    func seed(_ fs: FakeFS, _ names: [String]) { names.forEach { fs.files.insert(dir.appendingPathComponent($0).path) } }
    func urls(_ names: [String]) -> [URL] { names.map { dir.appendingPathComponent($0) } }

    func testTemplateTokens() throws {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        func r(_ t: String, i: Int = 0, start: Int = 1) throws -> String {
            try RenameTemplate.render(t, name: "IMG_01", parent: "Viaje", index: i, start: start, created: d, modified: d)
        }
        XCTAssertEqual(try r("{name}-{n:3}"), "IMG_01-001")
        XCTAssertEqual(try r("{n}", i: 4, start: 10), "14")
        XCTAssertEqual(try r("{parent} {date}"), "Viaje 2023-11-14")
        XCTAssertEqual(try r("{date:yyyyMMdd}_{created:yy}"), "20231114_23")
        XCTAssertEqual(try r("sin marcadores"), "sin marcadores")
        for bad in ["{foo}", "{name", "{n:0}", "{n:99}"] { XCTAssertThrowsError(try r(bad), bad) }
        XCTAssertEqual(try RenameTemplate.sanitize("a/b:c  "), "a-b-c")
        XCTAssertEqual(try RenameTemplate.sanitize("...oculto"), "oculto")
        XCTAssertThrowsError(try RenameTemplate.sanitize("   "))
    }

    func testPlannerOrdersNaturallyKeepsExtensionsAndHandlesFolders() throws {
        let fs = FakeFS()
        fs.folders.insert(dir.appendingPathComponent("Carpeta.v2").path)
        let plan = try RenamePlanner(fileSystem: fs).plan(
            urls(["img10.JPG", "img2.JPG", "img1.JPG", "Carpeta.v2"]), spec: RenameSpec(template: "Foto {n:2}"))
        let map = Dictionary(uniqueKeysWithValues: plan.map { ($0.from.lastPathComponent, $0.to.lastPathComponent) })
        XCTAssertEqual(map["img1.JPG"], "Foto 02.JPG")   // «Carpeta.v2» va primero por orden alfabético
        XCTAssertEqual(map["img2.JPG"], "Foto 03.JPG")
        XCTAssertEqual(map["img10.JPG"], "Foto 04.JPG")
        XCTAssertEqual(map["Carpeta.v2"], "Foto 01", "una carpeta no tiene extensión")
    }

    func testPlannerCaseFindReplaceAndConflicts() throws {
        let fs = FakeFS()
        seed(fs, ["a.txt", "b.txt", "x-1.txt"])   // «x-1.txt» ya existe y no es del lote
        let spec = RenameSpec(template: "x-{n}", start: 1)
        let plan = try RenamePlanner(fileSystem: fs).plan(urls(["a.txt", "b.txt"]), spec: spec)
        XCTAssertEqual(plan.map(\.to.lastPathComponent), ["x-1-2.txt", "x-2.txt"])

        let same = try RenamePlanner(fileSystem: fs).plan(urls(["a.txt", "b.txt"]), spec: RenameSpec(template: "dup"))
        XCTAssertEqual(same.map(\.to.lastPathComponent), ["dup.txt", "dup-2.txt"], "dos con el mismo nombre no se pisan")

        let styled = try RenamePlanner(fileSystem: fs).plan(urls(["a.txt"]), spec: RenameSpec(template: "{name} final", find: "a", replaceWith: "hola mundo", caseStyle: .title))
        XCTAssertEqual(styled.first?.to.lastPathComponent, "Hola Mundo Final.txt")
        let noop = try RenamePlanner(fileSystem: fs).plan(urls(["a.txt"]), spec: RenameSpec(template: "{name}"))
        XCTAssertTrue(noop.isEmpty)
    }

    func testRenameRunsRecordsAndUndoes() async throws {
        let (run, fs, h) = make()
        seed(fs, ["a.jpg", "b.jpg"])
        let out = try await run(.batchRename(RenameSpec(template: "Viaje-{n:2}")), inputs: urls(["a.jpg", "b.jpg"]))
        XCTAssertEqual(out.map(\.lastPathComponent), ["Viaje-01.jpg", "Viaje-02.jpg"])
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("Viaje-01.jpg").path))
        XCTAssertFalse(fs.files.contains(dir.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(fs.trashed.isEmpty)
        try await run.undo(h.items[0].id)
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("b.jpg").path))
        XCTAssertTrue(h.items.isEmpty)
        XCTAssertTrue(fs.trashed.isEmpty, "renombrar y deshacer nunca usa la Papelera")
    }

    func testRenameSwapUsesTemporaryNames() async throws {
        let (run, fs, _) = make()
        seed(fs, ["a.txt", "b.txt"])
        // «{n}» con inicio 2 invertido por fecha no aplica; se fuerza el cruce con un plan manual vía find/replace:
        let plan = [FileMove(from: dir.appendingPathComponent("a.txt"), to: dir.appendingPathComponent("b.txt")),
                    FileMove(from: dir.appendingPathComponent("b.txt"), to: dir.appendingPathComponent("a.txt"))]
        _ = plan
        // Lote real donde un destino es el nombre actual de otro archivo: 1.txt y 2.txt con plantilla {n} y start 2.
        seed(fs, ["1.txt", "2.txt"])
        let out = try await run(.batchRename(RenameSpec(template: "{n}", start: 2)), inputs: urls(["1.txt", "2.txt"]))
        XCTAssertEqual(out.map(\.lastPathComponent), ["2.txt", "3.txt"])
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("3.txt").path))
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("2.txt").path))
        XCTAssertFalse(fs.files.contains(dir.appendingPathComponent("1.txt").path))
        XCTAssertTrue(fs.moveLog.contains { $0.hasPrefix("1.txt>.cabrio-") }, "pasó por nombre temporal: \(fs.moveLog)")
    }

    func testRenameFailureRollsBackEverything() async {
        let (run, fs, h) = make()
        seed(fs, ["a.txt", "b.txt", "c.txt"])
        fs.failMoveTo = "Z-3.txt"
        do { _ = try await run(.batchRename(RenameSpec(template: "Z-{n}")), inputs: urls(["a.txt", "b.txt", "c.txt"])); XCTFail() }
        catch { XCTAssertEqual(error as? CabrioError, .writeFailed("falla simulada")) }
        XCTAssertEqual(fs.files.filter { $0.hasSuffix(".txt") }.count, 3)
        for n in ["a.txt", "b.txt", "c.txt"] { XCTAssertTrue(fs.files.contains(dir.appendingPathComponent(n).path), n) }
        XCTAssertTrue(fs.trashed.isEmpty, "un renombrado fallido jamás manda archivos a la Papelera")
        XCTAssertTrue(h.items.isEmpty)
    }

    func testUndoRefusesWhenOldNameIsTakenOrFileMoved() async throws {
        let (run, fs, h) = make()
        seed(fs, ["a.txt"])
        _ = try await run(.batchRename(RenameSpec(template: "nuevo")), inputs: urls(["a.txt"]))
        seed(fs, ["a.txt"])    // alguien creó otro «a.txt»
        do { try await run.undo(h.items[0].id); XCTFail() } catch {}
        XCTAssertTrue(fs.files.contains(dir.appendingPathComponent("nuevo.txt").path), "no se pisa nada")
        fs.files.remove(dir.appendingPathComponent("nuevo.txt").path)   // y el renombrado ya no está
        fs.files.remove(dir.appendingPathComponent("a.txt").path)
        do { try await run.undo(h.items[0].id); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("ya no está"))
        }
    }

    func testSuffixComesFromSettingsAndIsReadPerOperation() async throws {
        final class Box: @unchecked Sendable { var value = "_listo" }
        let box = Box()
        let fs = FakeFS(), h = FakeHistory(), e = FakeEngines(fs: fs, failOnImage: nil)
        let run = RunOperation(pdf: e, image: e, archive: e, media: e, ocr: e, fileSystem: fs, history: h, suffix: { box.value })
        let a = try await run(.mergePDFs, inputs: urls(["a.pdf", "b.pdf"]))
        XCTAssertEqual(a.first?.lastPathComponent, "a_listo.pdf")
        box.value = ""
        seed(fs, ["c.pdf"])
        let b = try await run(.compressPDF(.level(.low)), inputs: urls(["c.pdf"]))
        XCTAssertEqual(b.first?.lastPathComponent, "c-2.pdf", "con sufijo vacío nunca se pisa el original")
        XCTAssertEqual(OutputNaming.sanitizeSuffix("../x:y\u{0}z"), "..xyz")
        XCTAssertEqual(OutputNaming.sanitizeSuffix(String(repeating: "a", count: 50)).count, 24)
    }

    func testCatalogByKind() {
        func item(_ n: String, _ k: FileKind) -> FileItem { FileItem(url: URL(fileURLWithPath: "/t/\(n)"), kind: k, byteSize: 1) }
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.pdf", .pdf), item("b.pdf", .pdf)]).map(\.id), ["compress", "merge", "ocr", "protect", "unlock", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.pdf", .pdf)]).map(\.id), ["compress", "split", "ocr", "protect", "unlock", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.heic", .image)]).map(\.id), ["convert", "icompress", "resize", "bg", "topdf", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("Carpeta", .folder)]).map(\.id), ["zip", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.mov", .video)]).map(\.id), ["vcompress", "tomp4", "extract", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.wav", .audio), item("b.mp3", .audio)]).map(\.id), ["tom4a", "rename"])
        XCTAssertEqual(ActionCatalog.actions(for: [item("a.pdf", .pdf), item("b.png", .image)]).map(\.id), ["zip", "rename"])
    }

    func testJobQueueRunsAndPublishesStates() async throws {
        let (run, _, _) = make()
        let queue = JobQueue(runner: run)
        let item = FileItem(url: dir.appendingPathComponent("a.png"), kind: .image, byteSize: 1)
        let id = await queue.submit(.convertImage(to: .png, quality: 1), inputs: [item])
        var states: [JobState] = []
        for await job in queue.updates where job.id == id {
            states.append(job.state)
            if case .succeeded = job.state { break }
        }
        XCTAssertEqual(states.first, .queued)
        XCTAssertTrue(states.contains(.running))
    }
}
