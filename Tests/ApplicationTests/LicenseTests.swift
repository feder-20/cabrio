import XCTest
import CryptoKit
import CabrioDomain
import CabrioPorts
import CabrioApplication

final class LicenseTests: XCTestCase {
    // MARK: Utilidades

    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Bogota")!
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0, tz: String = "America/Bogota") -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }
    /// Primer arranque de referencia: 11 de noviembre de 2026 (D0). Último día de uso: 8 de febrero de 2027 (D0+89).
    var first: Date { date(2026, 11, 11, 15) }
    func state(_ now: Date, first f: Date? = nil, lastSeen: Date? = nil, licensed: Bool = false, calendar: Calendar? = nil) -> TrialState {
        TrialPolicy.state(now: now, firstLaunch: f ?? first, lastSeen: lastSeen, licensed: licensed, calendar: calendar ?? cal)
    }
    /// Almacén con `firstLaunch` ya guardado (como si la app se hubiera abierto antes).
    func seeded(_ f: Date? = nil) -> InMemoryPreferenceStore {
        let s = InMemoryPreferenceStore(); s.set(String((f ?? first).timeIntervalSince1970), forKey: "trial.firstLaunch"); return s
    }

    let priv = P256.Signing.PrivateKey()
    func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func makeKey(app: String = "cabrio", prefix: String? = nil, name: String = "Ana", signer: P256.Signing.PrivateKey? = nil) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["app": app, "name": name, "issued": "2026-11-11T10:00:00Z"], options: [.sortedKeys])
        let sig = try! (signer ?? priv).signature(for: payload).rawRepresentation
        return "\(prefix ?? app.uppercased()).\(b64url(payload)).\(b64url(sig))"
    }
    func verify(_ key: String, app: String = "cabrio", pub: P256.Signing.PublicKey? = nil) -> Result<LicensePayload, LicenseError> {
        LicenseVerifier.verify(key, forApp: app, publicKey: pub ?? priv.publicKey)
    }

    // MARK: TrialPolicy

    func testStatesAndBoundaries() {
        XCTAssertEqual(state(date(2026, 11, 11, 15)), .trial(daysLeft: 90), "día 1")
        XCTAssertEqual(state(date(2026, 11, 11, 0, 0, 0)), .trial(daysLeft: 90))
        XCTAssertEqual(state(date(2027, 1, 25)), .trial(daysLeft: 15))
        XCTAssertEqual(state(date(2027, 1, 26, 0, 0, 0)), .lastDays(daysLeft: 14))
        XCTAssertEqual(state(date(2027, 2, 7)), .lastDays(daysLeft: 2))
        XCTAssertEqual(state(date(2027, 2, 8, 0, 0, 0)), .lastDays(daysLeft: 1), "día 90 = último día")
        XCTAssertEqual(state(date(2027, 2, 8, 23, 59, 59)), .lastDays(daysLeft: 1))
        XCTAssertEqual(state(date(2027, 2, 9, 0, 0, 0)), .expired, "día 91")
        XCTAssertEqual(state(date(2028, 1, 1)), .expired)
    }

    func testMidnightBoundary() {
        XCTAssertEqual(state(date(2027, 1, 25, 23, 59, 59)), .trial(daysLeft: 15))
        XCTAssertEqual(state(date(2027, 1, 26, 0, 0, 1)), .lastDays(daysLeft: 14))
    }

    func testEndDateIsLastDayOfUse() {
        XCTAssertEqual(TrialPolicy.endDate(firstLaunch: first, calendar: cal), date(2027, 2, 8, 0, 0, 0))
        XCTAssertEqual(TrialPolicy.trialEndDay(firstLaunch: first, calendar: cal), date(2027, 2, 9, 0, 0, 0))
        XCTAssertEqual(LicenseConfig.trialDays, 90)
    }

    func testClockGoingBackDoesNotReviveTrial() {
        XCTAssertEqual(state(date(2026, 11, 12), lastSeen: date(2027, 3, 1)), .expired)
        XCTAssertEqual(state(date(2027, 2, 1), lastSeen: date(2027, 2, 6)), .lastDays(daysLeft: 3))
    }

    func testFirstLaunchInTheFutureIsClamped() {
        // Guardado «dentro de un año» (manipulado): no da más de 90 días ni rompe el estado.
        XCTAssertEqual(state(date(2026, 12, 1), first: date(2027, 12, 1)), .trial(daysLeft: 90))
        XCTAssertEqual(state(date(2027, 3, 1), first: date(2030, 1, 1), lastSeen: date(2027, 3, 1)), .trial(daysLeft: 90))
    }

    func testLicensedBeatsExpired() {
        XCTAssertEqual(state(date(2030, 1, 1), licensed: true), .licensed)
        XCTAssertEqual(state(date(2026, 11, 11), lastSeen: date(2030, 1, 1), licensed: true), .licensed)
    }

    func testTimeZoneAndDSTDoNotShiftDaysByOne() {
        for tz in ["America/New_York", "Europe/Madrid", "Asia/Tokyo", "Pacific/Auckland", "America/Bogota"] {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!
            let f = date(2026, 11, 11, 15, tz: tz)
            XCTAssertEqual(state(date(2027, 2, 8, 23, 59, 59, tz: tz), first: f, calendar: c), .lastDays(daysLeft: 1), tz)
            XCTAssertEqual(state(date(2027, 2, 9, 0, 0, 0, tz: tz), first: f, calendar: c), .expired, tz)
            XCTAssertEqual(state(date(2027, 1, 26, 0, 0, 0, tz: tz), first: f, calendar: c), .lastDays(daysLeft: 14), tz)
            XCTAssertEqual(state(date(2027, 1, 25, 23, 0, 0, tz: tz), first: f, calendar: c), .trial(daysLeft: 15), tz)
            // Pruebas que cruzan el cambio de horario (marzo y octubre/noviembre): siguen siendo 90 días de calendario.
            let g = date(2026, 3, 1, 23, 30, tz: tz)
            XCTAssertEqual(state(g, first: g, calendar: c), .trial(daysLeft: 90), tz)
            XCTAssertEqual(state(date(2026, 5, 29, 23, 59, 59, tz: tz), first: g, calendar: c), .lastDays(daysLeft: 1), tz)
            XCTAssertEqual(state(date(2026, 5, 30, 0, 0, 0, tz: tz), first: g, calendar: c), .expired, tz)
            let h = date(2026, 10, 1, 1, 0, tz: tz)
            XCTAssertEqual(state(date(2026, 12, 29, 23, 59, tz: tz), first: h, calendar: c), .lastDays(daysLeft: 1), tz)
            XCTAssertEqual(state(date(2026, 12, 30, 0, 0, tz: tz), first: h, calendar: c), .expired, tz)
        }
    }

    // MARK: Verificación de claves

    func testValidKeyAndAllKey() {
        XCTAssertEqual(try verify(makeKey()).get().name, "Ana")
        XCTAssertEqual(try verify(makeKey(app: "all")).get().app, "all")
        XCTAssertEqual(try verify(makeKey(app: "all"), app: "ferry").get().app, "all")
    }

    func testWrongApp() {
        XCTAssertEqual(verify(makeKey(app: "ferry")), .failure(.wrongApp))
        XCTAssertEqual(verify(makeKey(app: "convoy")), .failure(.wrongApp))
    }

    func testTamperedPayloadOrSignatureAndMismatchedPrefix() {
        let k = makeKey()
        var p = k.split(separator: ".").map(String.init)
        let altered = Data(base64Encoded: p[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==".prefix((4 - p[1].count % 4) % 4))!
        let evil = String(data: altered, encoding: .utf8)!.replacingOccurrences(of: "Ana", with: "Eva")
        XCTAssertEqual(verify("\(p[0]).\(b64url(Data(evil.utf8))).\(p[2])"), .failure(.invalid))
        var sig = Data(base64Encoded: p[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==")!
        sig[0] ^= 0xFF
        p[2] = b64url(sig)
        XCTAssertEqual(verify(p.joined(separator: ".")), .failure(.invalid))
        XCTAssertEqual(verify(makeKey(prefix: "FERRY")), .failure(.invalid), "el prefijo debe coincidir con el payload")
        XCTAssertEqual(verify(makeKey(prefix: "ALL")), .failure(.invalid))
    }

    func testGarbageTruncatedAndEmpty() {
        let k = makeKey()
        for bad in ["", "   ", "basura", "CABRIO..", "CABRIO.abc.def", String(k.dropLast(20)), String(k.prefix(30)), "a.b", "a.b.c.d", ".\(k)"] {
            XCTAssertEqual(verify(bad), .failure(.invalid), bad)
        }
    }

    func testWhitespaceAndPaddingVariants() {
        let k = makeKey()
        XCTAssertNoThrow(try verify("  \(k)\n").get())
        let mid = k.index(k.startIndex, offsetBy: 40)
        XCTAssertNoThrow(try verify(String(k[..<mid]) + "\n  " + String(k[mid...])).get())
        let parts = k.split(separator: ".").map(String.init)
        func padded(_ s: String) -> String { s + String(repeating: "=", count: (4 - s.count % 4) % 4) }
        XCTAssertNoThrow(try verify("\(parts[0]).\(padded(parts[1])).\(padded(parts[2]))").get(), "con relleno")
    }

    func testDifferentPublicKeyRejects() {
        XCTAssertEqual(verify(makeKey(), pub: P256.Signing.PrivateKey().publicKey), .failure(.invalid))
        XCTAssertEqual(verify(makeKey(signer: P256.Signing.PrivateKey())), .failure(.invalid))
    }

    func testEmbeddedPublicKeyIsValid() {
        XCTAssertNotNil(LicenseConfig.publicKey())
        XCTAssertEqual(LicenseConfig.priceText, "10 USD")
        XCTAssertEqual(LicenseConfig.purchaseURL.absoluteString, "https://chocolitossoft.com/premium")
    }

    // MARK: LicenseManager

    final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    func manager(_ clock: Clock, store: PreferenceStore? = nil, backup: PreferenceStore = InMemoryPreferenceStore()) -> LicenseManager {
        LicenseManager(publicKey: priv.publicKey, store: store ?? seeded(), backup: backup, now: { clock.now }, calendar: cal)
    }

    func testManagerActivationPersistenceAndRemoval() throws {
        let clock = Clock(date(2027, 3, 1)), store = seeded()
        let m = manager(clock, store: store)
        XCTAssertEqual(m.state(), .expired)
        XCTAssertThrowsError(try m.check()) { XCTAssertEqual($0 as? CabrioError, .trialExpired) }
        XCTAssertThrowsError(try m.activate(makeKey(app: "ferry"))) { XCTAssertEqual($0 as? LicenseError, .wrongApp) }
        XCTAssertThrowsError(try m.activate("basura")) { XCTAssertEqual($0 as? LicenseError, .invalid) }
        let good = makeKey()
        XCTAssertEqual(try m.activate(good), "Ana")
        XCTAssertEqual(m.state(), .licensed)
        XCTAssertNoThrow(try m.check())
        XCTAssertThrowsError(try m.activate(good)) { XCTAssertEqual($0 as? LicenseError, .alreadyActivated) }
        // «Reinicio»: otro gestor con el mismo almacén vuelve a verificar la clave guardada.
        XCTAssertEqual(manager(clock, store: store).state(), .licensed)
        XCTAssertEqual(manager(clock, store: store).license?.name, "Ana")
        // Una clave alterada en las preferencias no cuenta.
        let tampered = seeded(); tampered.set(makeKey(signer: P256.Signing.PrivateKey()), forKey: "license.key")
        XCTAssertEqual(manager(clock, store: tampered).state(), .expired)
        m.removeLicense()
        XCTAssertEqual(m.state(), .expired)
    }

    func testManagerLastSeenBlocksClockRollback() {
        let clock = Clock(date(2027, 2, 5)), store = seeded()
        XCTAssertEqual(manager(clock, store: store).state(), .lastDays(daysLeft: 4))
        clock.now = date(2027, 2, 12); XCTAssertEqual(manager(clock, store: store).state(), .expired)
        clock.now = date(2026, 11, 1); XCTAssertEqual(manager(clock, store: store).state(), .expired, "atrasar el reloj no revive la prueba")
    }

    func ts(_ s: PreferenceStore) -> Double? { s.string(forKey: "trial.firstLaunch").flatMap(Double.init) }

    func testFirstRunStartsNinetyDaysAndWritesBothRecords() {
        let clock = Clock(date(2026, 11, 11, 15)), store = InMemoryPreferenceStore(), backup = InMemoryPreferenceStore()
        let m = manager(clock, store: store, backup: backup)
        XCTAssertEqual(m.state(), .trial(daysLeft: 90))
        XCTAssertEqual(ts(store), clock.now.timeIntervalSince1970)
        XCTAssertEqual(ts(backup), clock.now.timeIntervalSince1970)
        XCTAssertEqual(m.trialEndDate(), date(2027, 2, 8, 0, 0, 0))
        clock.now = date(2027, 2, 8, 22); XCTAssertEqual(m.state(), .lastDays(daysLeft: 1))
        clock.now = date(2027, 2, 9, 0, 0, 1); XCTAssertEqual(m.state(), .expired)
        XCTAssertThrowsError(try m.check())
    }

    func testFirstLaunchRedundancyUsesOldestAndRecreatesMissing() {
        let old = date(2026, 9, 1, 10), recent = date(2026, 11, 1, 10)
        // Borran las preferencias: el archivo conserva la fecha y se recrea.
        let backup = seeded(old), clock = Clock(date(2026, 11, 20))
        let store = InMemoryPreferenceStore()
        XCTAssertEqual(manager(clock, store: store, backup: backup).state(), .lastDays(daysLeft: 10))
        XCTAssertEqual(ts(store), old.timeIntervalSince1970)
        // Borran el archivo: las preferencias lo recrean.
        let backup2 = InMemoryPreferenceStore(), store2 = seeded(old)
        _ = manager(clock, store: store2, backup: backup2).state()
        XCTAssertEqual(ts(backup2), old.timeIntervalSince1970)
        // Si difieren, gana el más antiguo y se unifican.
        let s3 = seeded(recent), b3 = seeded(old)
        _ = manager(clock, store: s3, backup: b3).state()
        XCTAssertEqual(ts(s3), old.timeIntervalSince1970); XCTAssertEqual(ts(b3), old.timeIntervalSince1970)
        let s4 = seeded(old), b4 = seeded(recent)
        _ = manager(clock, store: s4, backup: b4).state()
        XCTAssertEqual(ts(b4), old.timeIntervalSince1970)
        // Con ambos del pasado lejano la prueba ya venció aunque se borre una copia.
        XCTAssertEqual(manager(Clock(date(2027, 3, 1)), store: InMemoryPreferenceStore(), backup: seeded(old)).state(), .expired)
    }

    func testMigrationFromFixedDateVersionGivesFullNinetyDays() {
        // 0.10.0: sin firstLaunch pero con noticeSeen y lastSeen guardados. Al actualizar empieza una prueba completa.
        let store = InMemoryPreferenceStore()
        store.set("1", forKey: "trial.noticeSeen")
        store.set(String(date(2027, 1, 20).timeIntervalSince1970), forKey: "trial.lastSeen")
        let clock = Clock(date(2027, 1, 22, 9))
        let m = manager(clock, store: store)
        XCTAssertEqual(m.state(), .trial(daysLeft: 90))
        XCTAssertTrue(m.noticeSeen, "no se repite la bienvenida")
        XCTAssertEqual(m.trialEndDate(), date(2027, 4, 21, 0, 0, 0))
        // Incluso pasada la fecha fija antigua (9 feb 2027) sigue en prueba.
        clock.now = date(2027, 3, 1); XCTAssertEqual(m.state(), .trial(daysLeft: 52))
    }

    func testManagerFixesFutureFirstLaunchAndClockRollbackKeepsOldest() {
        let clock = Clock(date(2026, 12, 1)), store = seeded(date(2028, 1, 1)), backup = InMemoryPreferenceStore()
        let m = manager(clock, store: store, backup: backup)
        XCTAssertEqual(m.state(), .trial(daysLeft: 90))
        XCTAssertEqual(ts(store), clock.now.timeIntervalSince1970, "el valor futuro se corrige")
        // Reloj atrás tras haber vencido: sigue vencida y firstLaunch no se «reinicia».
        clock.now = date(2027, 6, 1); XCTAssertEqual(m.state(), .expired)
        clock.now = date(2026, 12, 2); XCTAssertEqual(m.state(), .expired)
        XCTAssertEqual(ts(store), date(2026, 12, 1).timeIntervalSince1970)
    }

    func testNoticeAndDailyReminder() {
        let clock = Clock(date(2026, 12, 1)), m: LicenseManager
        m = manager(clock, store: InMemoryPreferenceStore())   // primer arranque: 1 dic 2026 → últimos días desde el 15 feb 2027
        XCTAssertFalse(m.noticeSeen); m.markNoticeSeen(); XCTAssertTrue(m.noticeSeen)
        XCTAssertFalse(m.takeDailyReminder(), "fuera de los últimos días no hay recordatorio")
        _ = m.state()
        clock.now = date(2027, 2, 20, 9)
        XCTAssertTrue(m.takeDailyReminder())
        clock.now = date(2027, 2, 20, 20)
        XCTAssertFalse(m.takeDailyReminder(), "una vez por día")
        clock.now = date(2027, 2, 21, 8)
        XCTAssertTrue(m.takeDailyReminder())
        clock.now = date(2027, 3, 1)
        XCTAssertFalse(m.takeDailyReminder(), "vencida: no es recordatorio")
    }

    // MARK: Bloqueo de ejecución

    func testRunOperationRejectedWhenExpiredWithoutTouchingDisk() async throws {
        let clock = Clock(date(2027, 3, 1))
        let m = manager(clock)
        let fs = FakeFS(), h = FakeHistory(), e = FakeEngines(fs: fs)
        let dir = URL(fileURLWithPath: "/tmp/x")
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        fs.files = [a.path, b.path]
        let run = RunOperation(pdf: e, image: e, archive: e, media: e, ocr: e, fileSystem: fs, history: h, gate: m)
        let before = fs.files
        for op: CabrioOperation in [.mergePDFs, .compressImage(.medium), .removeBackground] {
            do { _ = try await run(op, inputs: [a, b]); XCTFail("debía rechazarse") }
            catch { XCTAssertEqual(error as? CabrioError, .trialExpired) }
        }
        XCTAssertEqual(fs.files, before); XCTAssertTrue(fs.directories.isEmpty); XCTAssertTrue(fs.moveLog.isEmpty); XCTAssertTrue(h.items.isEmpty)
        // También con renombrado (mueve archivos) y por la cola de trabajos.
        do { _ = try await run(.mergePDFs, inputs: []); XCTFail() } catch { XCTAssertEqual(error as? CabrioError, .trialExpired) }
        let queue = JobQueue(runner: run)
        var it = queue.updates.makeAsyncIterator()
        await queue.submit(.mergePDFs, inputs: [FileItem(url: a, kind: .pdf, byteSize: 1), FileItem(url: b, kind: .pdf, byteSize: 1)])
        var last: JobState = .queued
        while let j = await it.next() { last = j.state; if case .failed = j.state { break } }
        XCTAssertEqual(last, .failed(CabrioError.trialExpired.localizedDescription))
        XCTAssertEqual(fs.files, before)
        // Con licencia se ejecuta.
        try m.activate(makeKey())
        let out = try await run(.mergePDFs, inputs: [a, b])
        XCTAssertTrue(fs.exists(out[0]))
    }

    func testRunOperationAllowedDuringTrialAndLastDays() async throws {
        for d in [date(2026, 11, 11), date(2027, 2, 8, 23, 59, 59)] {
            let m = manager(Clock(d))
            let fs = FakeFS(), e = FakeEngines(fs: fs), dir = URL(fileURLWithPath: "/tmp/x")
            let run = RunOperation(pdf: e, image: e, archive: e, media: e, ocr: e, fileSystem: fs, history: FakeHistory(), gate: m)
            let out = try await run(.mergePDFs, inputs: [dir.appendingPathComponent("a.pdf"), dir.appendingPathComponent("b.pdf")])
            XCTAssertTrue(fs.exists(out[0]))
        }
    }

    func testRulesStopActingWhenTrialExpiresAndKeepRules() async throws {
        let downloads = URL(fileURLWithPath: "/Users/x/Descargas"), docs = URL(fileURLWithPath: "/Users/x/Documentos")
        let rule = Rule(name: "Capturas", folder: downloads, condition: RuleCondition(kinds: [.image], nameContains: ["Captura"]),
                        actions: [.moveTo(folder: docs.appendingPathComponent("Capturas"), subfolder: .none)])
        let fs = FakeFS(), store = FakeRuleStore(), history = FakeHistory(), watcher = FakeWatcher()
        store.rules = [rule]
        let clock = Clock(date(2027, 2, 8, 23, 59, 0))
        let m = manager(clock)
        let runner = RuleRunner(store: store, fileSystem: fs, detector: FakeDetector(), image: FakeEngines(fs: fs), history: history,
                                watcher: watcher, stability: .milliseconds(5), sweepInterval: .seconds(3600), gate: m)
        await runner.reload()
        try await Task.sleep(for: .milliseconds(20))

        let one = downloads.appendingPathComponent("Captura 1.png"), two = downloads.appendingPathComponent("Captura 2.png")
        fs.files.insert(one.path); watcher.send(one, in: downloads)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fs.files.contains(docs.appendingPathComponent("Capturas/Captura 1.png").path), "en prueba la regla actúa")

        clock.now = date(2027, 2, 9, 0, 0, 1)   // vence
        fs.files.insert(two.path); watcher.send(two, in: downloads)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fs.files.contains(two.path), "vencida: el archivo no se mueve")
        let ran = await runner.runNow(rule)
        XCTAssertTrue(ran.isEmpty); XCTAssertTrue(fs.files.contains(two.path))
        XCTAssertEqual(store.rules.count, 1, "las reglas no se pierden")
        XCTAssertEqual(history.items.count, 1, "el historial se conserva")
        XCTAssertTrue(fs.trashed.isEmpty)

        try m.activate(makeKey())   // con licencia vuelve a actuar
        let again = await runner.runNow(rule)
        XCTAssertEqual(again.count, 1)
        await runner.stop()
    }

    // MARK: Extremo a extremo con la herramienta de emisión

    func issue(_ app: String) throws -> String? {
        let script = "/Users/federicotrujillo/DesarrollosRECA/ChocolitosLicense/issue-license.swift"
        guard FileManager.default.isExecutableFile(atPath: script) else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: script)
        p.arguments = [app, "Prueba"]
        p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testEndToEndWithIssuedKeyAndEmbeddedPublicKey() throws {
        guard let cabrio = try issue("cabrio"), let ferry = try issue("ferry") else { throw XCTSkip("herramienta de emisión no disponible") }
        let pub = try XCTUnwrap(LicenseConfig.publicKey())
        XCTAssertEqual(try LicenseVerifier.verify(cabrio, forApp: "cabrio", publicKey: pub).get().name, "Prueba")
        XCTAssertEqual(LicenseVerifier.verify(ferry, forApp: "cabrio", publicKey: pub), .failure(.wrongApp))
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let m = LicenseManager(publicKey: pub, store: InMemoryPreferenceStore(), backup: InMemoryPreferenceStore(), now: { clock.now })
        XCTAssertEqual(m.state(), .trial(daysLeft: 90))
        clock.now = clock.now.addingTimeInterval(91 * 86_400)
        XCTAssertEqual(m.state(), .expired)
        XCTAssertThrowsError(try m.activate(ferry))
        XCTAssertEqual(m.state(), .expired)
        XCTAssertEqual(try m.activate(cabrio), "Prueba")
        XCTAssertEqual(m.state(), .licensed)
    }
}
