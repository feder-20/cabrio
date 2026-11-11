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

    func rig(rules: [Rule], now: Date = Date(timeIntervalSince1970: 1_800_000_000), failImage: String? = nil, ownTTL: TimeInterval = 120) -> Rig {
        let fs = FakeFS(), store = FakeRuleStore(), history = FakeHistory(), watcher = FakeWatcher()
        store.rules = rules
        let e = FakeEngines(fs: fs, failOnImage: failImage)
        let runner = RuleRunner(store: store, fileSystem: fs, detector: FakeDetector(), image: e, history: history, watcher: watcher,
                                now: { now }, stability: .milliseconds(5), sweepInterval: .seconds(3600), ownOutputTTL: ownTTL)
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
        let rule = Rule(name: "Viejos", folder: downloads, condition: RuleCondition(extensions: ["zip"], olderThanDays: 30), actions: [.moveToTrash], isApproved: true)
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

    // MARK: Seguridad: autodisparo, ciclos y aprobación

    func convertRule() -> Rule {
        Rule(name: "Imágenes a JPG", folder: downloads, condition: RuleCondition(kinds: [.image]), actions: [.convertImage(.jpg)])
    }

    func testConvertImageSkipsFilesAlreadyInTargetFormat() async throws {
        let rule = convertRule()
        let r = rig(rules: [rule])
        seed(r, ["a.jpg", "b.JPEG", "c.png"])
        let done = await r.runner.runNow(rule)
        XCTAssertEqual(done.count, 1, "solo c.png se convierte")
        XCTAssertTrue(has(r, downloads.appendingPathComponent("c.jpg").path))
        XCTAssertFalse(has(r, downloads.appendingPathComponent("a-2.jpg").path))
        XCTAssertFalse(has(r, downloads.appendingPathComponent("b-2.jpg").path))
    }

    func testConvertImageDoesNotRetriggerOnItsOwnOutput() async throws {
        let r = rig(rules: [convertRule()])
        seed(r, ["a.png"])
        await r.runner.reload()
        r.watcher.send(downloads.appendingPathComponent("a.png"), in: downloads)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(has(r, downloads.appendingPathComponent("a.jpg").path))
        // FSEvents reporta la salida como archivo nuevo, varias veces.
        for _ in 0..<3 {
            r.watcher.send(downloads.appendingPathComponent("a.jpg"), in: downloads)
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertEqual(r.fs.files.filter { $0.hasPrefix(downloads.path) }.sorted(),
                       [downloads.appendingPathComponent("a.jpg").path, downloads.appendingPathComponent("a.png").path].sorted())
        XCTAssertEqual(r.history.items.count, 1)
        await r.runner.stop()
    }

    func testConvertImageWithoutOwnPathGuardStillStopsOnSameFormat() async throws {
        // Aun con el registro de salidas propias desactivado, la regla no se autodispara.
        let r = rig(rules: [convertRule()], ownTTL: 0)
        seed(r, ["a.png"])
        await r.runner.reload()
        r.watcher.send(downloads.appendingPathComponent("a.png"), in: downloads)
        try await Task.sleep(for: .milliseconds(100))
        r.watcher.send(downloads.appendingPathComponent("a.jpg"), in: downloads)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(has(r, downloads.appendingPathComponent("a-2.jpg").path))
        await r.runner.stop()
    }

    func pingPongRules() -> (Rule, Rule, URL, URL) {
        let a = URL(fileURLWithPath: "/Users/x/A"), b = URL(fileURLWithPath: "/Users/x/B")
        let ab = Rule(name: "A a B", folder: a, condition: RuleCondition(kinds: [.pdf]), actions: [.moveTo(folder: b, subfolder: .none)])
        let ba = Rule(name: "B a A", folder: b, condition: RuleCondition(kinds: [.pdf]), actions: [.moveTo(folder: a, subfolder: .none)])
        return (ab, ba, a, b)
    }

    func testPingPongBetweenWatchedFoldersIgnoresOwnMoves() async throws {
        let (ab, ba, a, b) = pingPongRules()
        let r = rig(rules: [ab, ba])
        seed(r, ["x.pdf"], in: a)
        await r.runner.reload()
        r.watcher.send(a.appendingPathComponent("x.pdf"), in: a)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(has(r, b.appendingPathComponent("x.pdf").path))
        r.watcher.send(b.appendingPathComponent("x.pdf"), in: b)   // el evento de la propia llegada
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(has(r, b.appendingPathComponent("x.pdf").path), "no regresa a A")
        XCTAssertEqual(r.fs.moveLog.count, 1)
        await r.runner.stop()
    }

    func testCycleCapStopsAfterThreeRunsAndWarns() async throws {
        let (ab, ba, a, b) = pingPongRules()
        let r = rig(rules: [ab, ba], ownTTL: 0)   // sin registro de salidas: solo actúa el tope de ciclos
        seed(r, ["x.pdf"], in: a)
        await r.runner.reload()
        for _ in 0..<8 {
            let inA = has(r, a.appendingPathComponent("x.pdf").path)
            let dir = inA ? a : b
            r.watcher.send(dir.appendingPathComponent("x.pdf"), in: dir)
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTAssertEqual(r.fs.moveLog.count, 3, "tope de 3 procesos por archivo en 60 s: \(r.fs.moveLog)")
        let warnings = await r.runner.ruleWarnings
        XCTAssertFalse(warnings.isEmpty, "queda un aviso en el estado de la regla")
        XCTAssertTrue(warnings.values.first?.contains("x.pdf") == true)
        await r.runner.stop()
    }

    func testAgeRuleIsNotTriggeredByFileEvent() async throws {
        let rule = Rule(name: "Instaladores viejos", folder: downloads,
                        condition: RuleCondition(extensions: ["dmg"], olderThanDays: 14), actions: [.moveToTrash], isApproved: true)
        let now = created.addingTimeInterval(400 * 86_400)
        let r = rig(rules: [rule], now: now)
        await r.runner.reload()
        try await Task.sleep(for: .milliseconds(60))   // deja pasar el barrido inicial (no encuentra nada)
        seed(r, ["recien-copiado.dmg"])    // creado en 2023 según el fake: «viejo» para la regla
        r.watcher.send(downloads.appendingPathComponent("recien-copiado.dmg"), in: downloads)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(r.fs.trashed.isEmpty, "el evento de un archivo nuevo no activa reglas por antigüedad")
        XCTAssertTrue(has(r, downloads.appendingPathComponent("recien-copiado.dmg").path))
        await r.runner.stop()
    }

    func testUnapprovedAgeAndTrashRulesDoNotActAutomatically() async throws {
        let age = Rule(name: "Viejos", folder: downloads, condition: RuleCondition(extensions: ["zip"], olderThanDays: 30), actions: [.moveToTrash])
        let trash = Rule(name: "Papelera", folder: docs, condition: RuleCondition(extensions: ["dmg"]), actions: [.moveToTrash])
        XCTAssertTrue(age.requiresApproval && trash.requiresApproval)
        let now = created.addingTimeInterval(400 * 86_400)
        let r = rig(rules: [age, trash], now: now)
        seed(r, ["viejo.zip"])
        seed(r, ["app.dmg"], in: docs)
        await r.runner.reload()    // el barrido inicial no debe actuar
        r.watcher.send(docs.appendingPathComponent("app.dmg"), in: docs)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(r.fs.trashed.isEmpty, "sin aprobar no actúa: \(r.fs.trashed)")
        await r.runner.stop()

        // Aprobadas, sí actúan.
        var approvedAge = age; approvedAge.isApproved = true
        var approvedTrash = trash; approvedTrash.isApproved = true
        let r2 = rig(rules: [approvedAge, approvedTrash], now: now)
        seed(r2, ["viejo.zip"])
        seed(r2, ["app.dmg"], in: docs)
        await r2.runner.reload()
        r2.watcher.send(docs.appendingPathComponent("app.dmg"), in: docs)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(r2.fs.trashed), [downloads.appendingPathComponent("viejo.zip").path, docs.appendingPathComponent("app.dmg").path])
        await r2.runner.stop()
    }

    func testRuleDecodedWithoutApprovalFieldIsNotApproved() throws {
        let rule = Rule(name: "Viejas", folder: downloads, condition: RuleCondition(extensions: ["dmg"], olderThanDays: 14),
                        actions: [.moveToTrash], isApproved: true)
        let data = try JSONEncoder().encode(rule)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["isApproved"] as? Bool, true)
        obj.removeValue(forKey: "isApproved")   // archivo de una versión anterior
        let old = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(old.isApproved)
        XCTAssertFalse(old.mayRunUnattended)
        XCTAssertEqual(try JSONDecoder().decode(Rule.self, from: data).isApproved, true)
        XCTAssertTrue(Rule(name: "M", folder: downloads, condition: RuleCondition(kinds: [.pdf]), actions: [.moveTo(folder: docs, subfolder: .none)]).mayRunUnattended,
                      "mover/convertir no exige aprobación")
    }

    func testForbiddenWatchedFolders() {
        let home = URL(fileURLWithPath: "/Users/x")
        for p in ["/", "/Users/x", "/Applications", "/System", "/System/Library", "/Library", "/Library/Caches", "/Users/x/Library",
                  "/Users/x/Library/Mail", "/usr/local", "/Users/x/"] {
            XCTAssertTrue(RuleFolderPolicy.isForbidden(URL(fileURLWithPath: p), home: home), p)
        }
        for p in ["/Users/x/Downloads", "/Users/x/Escritorio", "/Users/x/Documents/Facturas", "/Volumes/Datos", "/Users/x/Libraryfoo"] {
            XCTAssertFalse(RuleFolderPolicy.isForbidden(URL(fileURLWithPath: p), home: home), p)
        }
    }
}
