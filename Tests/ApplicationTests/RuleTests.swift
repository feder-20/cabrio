import XCTest
import CabrioDomain
import CabrioPorts
import CabrioApplication

final class FakeDetector: FileKindDetecting, @unchecked Sendable {
    func item(for url: URL) -> FileItem {
        let kind: FileKind
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "heic": kind = .image
        case "pdf": kind = .pdf
        case "mov", "mp4": kind = .video
        case "dmg", "zip": kind = .archive
        default: kind = .other
        }
        return FileItem(url: url, kind: kind, byteSize: 100)
    }
}

final class FakeRuleStore: RuleStore, @unchecked Sendable {
    var rules: [Rule] = []
    func load() throws -> [Rule] { rules }
    func save(_ rules: [Rule]) throws { self.rules = rules }
}

final class FakeWatcher: FolderWatcher, @unchecked Sendable {
    private var continuations: [String: AsyncStream<URL>.Continuation] = [:]
    func events(for folder: URL) -> AsyncStream<URL> {
        AsyncStream { c in continuations[folder.standardizedFileURL.path] = c }
    }
    func send(_ url: URL, in folder: URL) { continuations[folder.standardizedFileURL.path]?.yield(url) }
    var watching: Set<String> { Set(continuations.keys) }
}

final class RuleTests: XCTestCase {
    let downloads = URL(fileURLWithPath: "/Users/x/Descargas")
    let docs = URL(fileURLWithPath: "/Users/x/Documentos")
    let created = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14

    struct Rig {
        let runner: RuleRunner; let fs: FakeFS; let store: FakeRuleStore; let history: FakeHistory
        let watcher: FakeWatcher; let engines: FakeEngines; let run: RunOperation
    }

    func rig(rules: [Rule], now: Date = Date(timeIntervalSince1970: 1_800_000_000), failImage: String? = nil) -> Rig {
        let fs = FakeFS(), store = FakeRuleStore(), history = FakeHistory(), watcher = FakeWatcher()
        store.rules = rules
        let e = FakeEngines(fs: fs, failOnImage: failImage)
        let runner = RuleRunner(store: store, fileSystem: fs, detector: FakeDetector(), image: e, history: history, watcher: watcher,
                                now: { now }, stability: .milliseconds(5), sweepInterval: .seconds(3600))
        let run = RunOperation(pdf: e, image: e, archive: e, media: e, ocr: e, fileSystem: fs, history: history)
        return Rig(runner: runner, fs: fs, store: store, history: history, watcher: watcher, engines: e, run: run)
    }

    func seed(_ r: Rig, _ names: [String], in dir: URL? = nil) {
        names.forEach { r.fs.files.insert((dir ?? downloads).appendingPathComponent($0).path) }
    }
    func has(_ r: Rig, _ path: String) -> Bool { r.fs.files.contains(path) }

    // MARK: Condiciones

    func testConditionMatrix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func m(_ c: RuleCondition, _ name: String = "Captura de pantalla 2026.png", kind: FileKind = .image, size: Int64 = 1000, created: Date? = nil) -> Bool {
            c.matches(name: name, kind: kind, size: size, created: created, modified: created, now: now)
        }
        XCTAssertFalse(m(RuleCondition()), "una regla vacía no coincide con nada")
        XCTAssertTrue(m(RuleCondition(kinds: [.image])))
        XCTAssertFalse(m(RuleCondition(kinds: [.pdf])))
        XCTAssertTrue(m(RuleCondition(extensions: [".PNG", " jpg "])))
        XCTAssertFalse(m(RuleCondition(extensions: ["pdf"])))
        XCTAssertTrue(m(RuleCondition(nameContains: ["captura DE pantalla"])))
        XCTAssertTrue(m(RuleCondition(nameContains: ["screenshot", "pantalla"])), "basta una de las palabras")
        XCTAssertTrue(m(RuleCondition(nameContains: ["CAPTURA"]), "Captúra de pantalla.png"), "sin distinguir tildes")
        XCTAssertFalse(m(RuleCondition(nameContains: ["factura"])))
        XCTAssertTrue(m(RuleCondition(olderThanDays: 30), created: now.addingTimeInterval(-31 * 86_400)))
        XCTAssertFalse(m(RuleCondition(olderThanDays: 30), created: now.addingTimeInterval(-29 * 86_400)))
        XCTAssertFalse(m(RuleCondition(olderThanDays: 30), created: nil), "sin fecha no se asume antigüedad")
        XCTAssertTrue(m(RuleCondition(largerThanBytes: 500)))
        XCTAssertFalse(m(RuleCondition(largerThanBytes: 1000)))
        XCTAssertFalse(m(RuleCondition(kinds: [.image], nameContains: ["factura"])), "los criterios se combinan con Y")
        XCTAssertEqual(Subfolder.byMonth.name(for: .pdf, date: created), "2023-11")
        XCTAssertEqual(Subfolder.byKind.name(for: .image, date: nil), "Imágenes")
        XCTAssertNil(Subfolder.none.name(for: .pdf, date: nil))
        XCTAssertTrue(RuleFileFilter.isIgnorable(".DS_Store") && RuleFileFilter.isIgnorable("a.crdownload") && RuleFileFilter.isIgnorable("~$doc.docx"))
        XCTAssertFalse(RuleFileFilter.isIgnorable("foto.png"))
    }

    // MARK: Ejecución

    func screenshotRule(sub: Subfolder = .byYear, enabled: Bool = true) -> Rule {
        Rule(name: "Capturas", folder: downloads, condition: RuleCondition(kinds: [.image], nameContains: ["Captura de pantalla"]),
             actions: [.moveTo(folder: docs.appendingPathComponent("Capturas"), subfolder: sub)], isEnabled: enabled)
    }

    func testMoveRuleMovesToSubfolderNamesUniquelyAndLeavesOthersAlone() async throws {
        let r = rig(rules: [screenshotRule()])
        seed(r, ["Captura de pantalla 1.png", "Captura de pantalla 2.png", "factura.pdf", ".DS_Store", "x.png.crdownload"])
        r.fs.files.insert(docs.appendingPathComponent("Capturas/2023/Captura de pantalla 1.png").path)   // ya existe uno igual
        let done = await r.runner.runNow(r.store.rules[0])
        XCTAssertEqual(done.count, 2)
        XCTAssertTrue(has(r, docs.appendingPathComponent("Capturas/2023/Captura de pantalla 1-2.png").path), "nunca pisa")
        XCTAssertTrue(has(r, docs.appendingPathComponent("Capturas/2023/Captura de pantalla 2.png").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("factura.pdf").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent(".DS_Store").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("x.png.crdownload").path))
        XCTAssertEqual(r.history.items.count, 2)
        XCTAssertTrue(r.fs.trashed.isEmpty)
    }

    func testMoveIsUndoable() async throws {
        let r = rig(rules: [screenshotRule(sub: .none)])
        seed(r, ["Captura de pantalla 1.png"])
        _ = await r.runner.runNow(r.store.rules[0])
        XCTAssertFalse(has(r, downloads.appendingPathComponent("Captura de pantalla 1.png").path))
        try await r.run.undo(r.history.items[0].id)
        XCTAssertTrue(has(r, downloads.appendingPathComponent("Captura de pantalla 1.png").path))
        XCTAssertTrue(r.history.items.isEmpty)
    }

    func testTrashRuleGoesToTrashAndRestoresOnUndo() async throws {
        let rule = Rule(name: "Instaladores", folder: downloads, condition: RuleCondition(extensions: ["dmg"]), actions: [.moveToTrash])
        let r = rig(rules: [rule])
        seed(r, ["app.dmg", "otro.pdf"])
        let done = await r.runner.runNow(rule)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(r.fs.trashed, [downloads.appendingPathComponent("app.dmg").path])
        XCTAssertFalse(has(r, downloads.appendingPathComponent("app.dmg").path))
        try await r.run.undo(r.history.items[0].id)
        XCTAssertTrue(has(r, downloads.appendingPathComponent("app.dmg").path), "se recupera de la Papelera")
        XCTAssertFalse(has(r, "/.Trash/app.dmg"))
    }

    func testConvertRuleKeepsOriginalAndUndoTrashesCopy() async throws {
        let rule = Rule(name: "HEIC a JPG", folder: downloads, condition: RuleCondition(extensions: ["heic"]), actions: [.convertImage(.jpg)])
        let r = rig(rules: [rule])
        seed(r, ["IMG_1.heic", "IMG_1.jpg"])   // ya hay un IMG_1.jpg
        _ = await r.runner.runNow(rule)
        XCTAssertTrue(has(r, downloads.appendingPathComponent("IMG_1.heic").path), "el original se conserva")
        XCTAssertTrue(has(r, downloads.appendingPathComponent("IMG_1-2.jpg").path))
        try await r.run.undo(r.history.items[0].id)
        XCTAssertFalse(has(r, downloads.appendingPathComponent("IMG_1-2.jpg").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("IMG_1.heic").path))
    }

    func testConvertThenMoveUndoRestoresOriginalAndTrashesCopy() async throws {
        let rule = Rule(name: "Fotos", folder: downloads, condition: RuleCondition(extensions: ["heic"]),
                        actions: [.convertImage(.jpg), .moveTo(folder: docs, subfolder: .none)])
        let r = rig(rules: [rule])
        seed(r, ["IMG_2.heic"])
        _ = await r.runner.runNow(rule)
        XCTAssertTrue(has(r, docs.appendingPathComponent("IMG_2.heic").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("IMG_2.jpg").path))
        try await r.run.undo(r.history.items[0].id)
        XCTAssertTrue(has(r, downloads.appendingPathComponent("IMG_2.heic").path))
        XCTAssertFalse(has(r, downloads.appendingPathComponent("IMG_2.jpg").path))
    }

    func testFirstMatchingRuleWinsAndDisabledOrEmptyRulesNeverRun() async throws {
        let empty = Rule(name: "Vacía", folder: downloads, condition: RuleCondition(), actions: [.moveToTrash])
        let off = screenshotRule(enabled: false)
        let a = Rule(name: "A", folder: downloads, condition: RuleCondition(kinds: [.pdf]), actions: [.moveTo(folder: docs.appendingPathComponent("A"), subfolder: .none)])
        let b = Rule(name: "B", folder: downloads, condition: RuleCondition(kinds: [.pdf]), actions: [.moveTo(folder: docs.appendingPathComponent("B"), subfolder: .none)])
        let r = rig(rules: [empty, off, a, b])
        seed(r, ["x.pdf", "Captura de pantalla 9.png"])
        r.store.rules.forEach { _ in }
        await r.runner.reload()
        r.watcher.send(downloads.appendingPathComponent("x.pdf"), in: downloads)
        r.watcher.send(downloads.appendingPathComponent("Captura de pantalla 9.png"), in: downloads)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(has(r, docs.appendingPathComponent("A/x.pdf").path), "gana la primera que coincide")
        XCTAssertFalse(has(r, docs.appendingPathComponent("B/x.pdf").path))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("Captura de pantalla 9.png").path), "regla desactivada")
        XCTAssertTrue(r.fs.trashed.isEmpty, "la regla vacía no toca nada")
        await r.runner.stop()
    }

    func testWatcherWaitsForGrowingFileAndIgnoresTemporariesAndSubfolders() async throws {
        let r = rig(rules: [screenshotRule(sub: .none)])
        let name = "Captura de pantalla 5.png"
        seed(r, [name, "Captura de pantalla 6.png.crdownload"])
        let url = downloads.appendingPathComponent(name)
        r.fs.sizes[url.path] = 10
        await r.runner.reload()
        r.watcher.send(url, in: downloads)
        try await Task.sleep(for: .milliseconds(1))
        r.fs.sizes[url.path] = 500   // sigue creciendo durante la espera
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(has(r, docs.appendingPathComponent("Capturas/\(name)").path))
        r.watcher.send(downloads.appendingPathComponent("Captura de pantalla 6.png.crdownload"), in: downloads)
        r.watcher.send(downloads.appendingPathComponent("sub/Captura de pantalla 7.png"), in: downloads)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("Captura de pantalla 6.png.crdownload").path))
        await r.runner.stop()
    }

    func testDisabledRunnerWatchesNothingAndOnlyEnabledFoldersAreWatched() async throws {
        let other = Rule(name: "Otra", folder: docs, condition: RuleCondition(kinds: [.pdf]), actions: [.moveToTrash], isEnabled: false)
        let r = rig(rules: [screenshotRule(), other])
        await r.runner.reload()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(r.watcher.watching, [downloads.standardizedFileURL.path])
        await r.runner.setEnabled(false)
        r.watcher.send(downloads.appendingPathComponent("Captura de pantalla 1.png"), in: downloads)
        seed(r, ["Captura de pantalla 1.png"])
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("Captura de pantalla 1.png").path), "con el interruptor apagado no se hace nada")
    }

    func testAgeRulesAreSweptAndOnlyWhenOldEnough() async throws {
        let rule = Rule(name: "Viejos", folder: downloads, condition: RuleCondition(extensions: ["zip"], olderThanDays: 30), actions: [.moveToTrash])
        let now = created.addingTimeInterval(31 * 86_400)
        let r = rig(rules: [rule], now: now)
        seed(r, ["viejo.zip", "nuevo.zip"])
        r.fs.createdOverride[downloads.appendingPathComponent("nuevo.zip").path] = now.addingTimeInterval(-86_400)
        let preview = await r.runner.matches(for: rule)
        XCTAssertEqual(preview.map(\.lastPathComponent), ["viejo.zip"])
        await r.runner.reload()          // arranca el barrido de reglas por antigüedad
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(r.fs.trashed, [downloads.appendingPathComponent("viejo.zip").path])
        await r.runner.stop()
    }

    func testFailureIsReportedAndCleansPartialOutput() async throws {
        let rule = Rule(name: "HEIC", folder: downloads, condition: RuleCondition(extensions: ["heic"]), actions: [.convertImage(.jpg)])
        let r = rig(rules: [rule], failImage: "malo.heic")
        seed(r, ["malo.heic"])
        let done = await r.runner.runNow(rule)
        XCTAssertTrue(done.isEmpty)
        XCTAssertFalse(has(r, downloads.appendingPathComponent("malo.jpg").path), "no queda la copia a medias")
        XCTAssertTrue(has(r, downloads.appendingPathComponent("malo.heic").path))
        var first: RuleEvent?
        for await e in r.runner.events { first = e; break }
        guard case .failed(let m)? = first else { return XCTFail("\(String(describing: first))") }
        XCTAssertTrue(m.contains("malo.heic"))
    }
}
