import Foundation
import CabrioDomain
import CabrioPorts

public enum RuleEvent: Sendable {
    case applied(HistoryEntry)
    case failed(String)
    /// Algo que Cabrio dejó de hacer a propósito (por ejemplo, un ciclo entre reglas): el usuario debe enterarse.
    case warning(String)
}

/// Vigila las carpetas de las reglas activas y las aplica sin intervención. Todo lo que hace queda en el
/// historial y se puede deshacer; jamás borra de forma permanente (como máximo, a la Papelera).
public actor RuleRunner {
    private let store: RuleStore
    private let fs: FileSystem
    private let detector: FileKindDetecting
    private let image: ImageEngine
    private let history: HistoryStore
    private let watcher: FolderWatcher
    private let gate: ExecutionGate
    private let now: @Sendable () -> Date
    private let stability: Duration
    private let sweepInterval: Duration
    private let ownOutputTTL: TimeInterval
    private let cycleLimit: Int
    private let cycleWindow: TimeInterval

    private var rules: [Rule] = []
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var sweepTask: Task<Void, Never>?
    private var inFlight = Set<String>()
    private var enabled = true
    /// Rutas que generó o movió el propio runner, con su caducidad: FSEvents las reporta como archivos nuevos.
    private var ownPaths: [String: Date] = [:]
    /// Instantes en que reglas actuaron sobre un archivo (la cuenta viaja con él cuando se mueve o convierte).
    private var passes: [String: [Date]] = [:]
    private var cycleWarned: [String: Date] = [:]
    /// Último aviso por regla (por ejemplo, ciclo detenido); se limpia al recargar las reglas.
    public private(set) var ruleWarnings: [UUID: String] = [:]

    public nonisolated let events: AsyncStream<RuleEvent>
    private let continuation: AsyncStream<RuleEvent>.Continuation

    public init(store: RuleStore, fileSystem: FileSystem, detector: FileKindDetecting, image: ImageEngine,
                history: HistoryStore, watcher: FolderWatcher, now: @escaping @Sendable () -> Date = { Date() },
                stability: Duration = .seconds(2), sweepInterval: Duration = .seconds(1800),
                ownOutputTTL: TimeInterval = 120, cycleLimit: Int = 3, cycleWindow: TimeInterval = 60,
                gate: ExecutionGate = OpenGate()) {
        self.gate = gate
        self.ownOutputTTL = ownOutputTTL
        self.cycleLimit = cycleLimit
        self.cycleWindow = cycleWindow
        self.store = store
        self.fs = fileSystem
        self.detector = detector
        self.image = image
        self.history = history
        self.watcher = watcher
        self.now = now
        self.stability = stability
        self.sweepInterval = sweepInterval
        let (stream, cont) = AsyncStream<RuleEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    // MARK: Ciclo de vida

    /// Relee las reglas y reinicia la vigilancia.
    public func reload() {
        // Una carpeta demasiado amplia o del sistema nunca se vigila, ni aunque la regla venga de un archivo antiguo.
        rules = ((try? store.load()) ?? []).filter { !RuleFolderPolicy.isForbidden($0.folder) }
        ruleWarnings = [:]
        for t in watchTasks.values { t.cancel() }
        watchTasks = [:]
        sweepTask?.cancel()
        sweepTask = nil
        guard enabled else { return }

        let folders = Set(rules.filter(\.isEnabled).map { $0.folder.standardizedFileURL.path })
        for path in folders {
            let folder = URL(fileURLWithPath: path)
            let stream = watcher.events(for: folder)
            watchTasks[path] = Task { [weak self] in
                for await url in stream {
                    if Task.isCancelled { break }
                    await self?.handle(url, in: folder)
                }
            }
        }
        if rules.contains(where: { $0.isEnabled && $0.isAgeBased }) {
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sweepAgeRules()
                    guard let interval = await self?.sweepInterval else { return }
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        reload()
    }

    public func stop() { setEnabled(false) }

    // MARK: Consultas (vista previa)

    /// Archivos de la carpeta que esta regla tocaría ahora mismo.
    public func matches(for rule: Rule) -> [URL] {
        guard let files = try? fs.contentsOfDirectory(rule.folder) else { return [] }
        let current = now()
        return files.filter { url in
            guard !RuleFileFilter.isIgnorable(url.lastPathComponent) else { return false }
            let attrs = fs.attributes(of: url)
            guard !attrs.isDirectory else { return false }
            let item = detector.item(for: url)
            return rule.condition.matches(name: url.lastPathComponent, kind: item.kind, size: attrs.size,
                                          created: attrs.created, modified: attrs.modified, now: current)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Ejecución

    /// Aplica la regla a lo que ya hay en la carpeta («Ejecutar ahora»).
    @discardableResult
    public func runNow(_ rule: Rule) async -> [HistoryEntry] {
        guard !RuleFolderPolicy.isForbidden(rule.folder) else { return [] }
        var done: [HistoryEntry] = []
        for url in matches(for: rule) {
            if let entry = await apply(rule, to: url) { done.append(entry) }
        }
        return done
    }

    func sweepAgeRules() async {
        // Solo las aprobadas: una regla por antigüedad sin confirmar no actúa nunca por su cuenta.
        for rule in rules where rule.isEnabled && rule.isAgeBased && rule.mayRunUnattended { await runNow(rule) }
    }

    private func handle(_ url: URL, in folder: URL) async {
        let key = url.path
        // Lo que acaba de crear o mover una regla no se vuelve a procesar (evita bucles y ping-pong entre carpetas).
        guard !isOwnOutput(url) else { return }
        guard !inFlight.contains(key), !RuleFileFilter.isIgnorable(url.lastPathComponent), fs.exists(url),
              !fs.attributes(of: url).isDirectory else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // Una descarga o copia en curso cambia de tamaño: se espera a que se estabilice.
        var last = fs.attributes(of: url).size
        for _ in 0..<30 {
            try? await Task.sleep(for: stability)
            if Task.isCancelled || !fs.exists(url) { return }
            let size = fs.attributes(of: url).size
            if size == last { break }
            last = size
        }

        let attrs = fs.attributes(of: url)
        let item = detector.item(for: url)
        let current = now()
        let folderPath = folder.standardizedFileURL.path
        // Las reglas por antigüedad solo se aplican en el barrido programado o con «Ejecutar ahora»: un archivo recién
        // llegado puede traer una fecha antigua.
        guard let rule = rules.first(where: { r in
            r.isEnabled && !r.isAgeBased && r.folder.standardizedFileURL.path == folderPath
                && r.condition.matches(name: url.lastPathComponent, kind: item.kind, size: attrs.size,
                                       created: attrs.created, modified: attrs.modified, now: current)
        }), rule.mayRunUnattended else { return }

        // Tope de ciclos: un mismo archivo no se procesa más de `cycleLimit` veces en `cycleWindow` segundos.
        let stamps = recentPasses(for: key, at: current)
        if stamps.count >= cycleLimit {
            warnCycle(rule, url, at: current)
            return
        }
        guard let entry = await apply(rule, to: url) else { return }
        let updated = stamps + [current]
        passes[key] = updated
        for out in entry.outputs { passes[out.standardizedFileURL.path] = updated }
    }

    private func isOwnOutput(_ url: URL) -> Bool {
        let t = now()
        ownPaths = ownPaths.filter { $0.value > t }
        return ownPaths[url.standardizedFileURL.path] != nil
    }

    private func markOwn(_ url: URL) {
        ownPaths[url.standardizedFileURL.path] = now().addingTimeInterval(ownOutputTTL)
    }

    private func recentPasses(for path: String, at t: Date) -> [Date] {
        let recent = (passes[path] ?? []).filter { t.timeIntervalSince($0) < cycleWindow }
        if recent.isEmpty { passes[path] = nil } else { passes[path] = recent }
        return recent
    }

    private func warnCycle(_ rule: Rule, _ url: URL, at t: Date) {
        let path = url.standardizedFileURL.path
        if let last = cycleWarned[path], t.timeIntervalSince(last) < cycleWindow { return }
        cycleWarned[path] = t
        let message = tr("«%@» se dejó de procesar: las reglas lo han movido o convertido demasiadas veces seguidas (posible ciclo entre reglas). Revisa «%@».",
                         url.lastPathComponent, rule.name)
        ruleWarnings[rule.id] = message
        continuation.yield(.warning(message))
    }

    /// Ejecuta las acciones de la regla en orden y anota lo hecho para poder deshacerlo.
    func apply(_ rule: Rule, to original: URL) async -> HistoryEntry? {
        // Prueba terminada: los vigilantes siguen puestos pero no actúan; reglas, historial y archivos quedan intactos.
        guard (try? gate.check()) != nil else { return nil }
        var current = original
        var moves: [FileMove] = []
        var outputs: [URL] = []
        do {
            for action in rule.actions {
                switch action {
                case .moveTo(let folder, let sub):
                    let item = detector.item(for: current)
                    let attrs = fs.attributes(of: current)
                    var dest = folder
                    if let name = sub.name(for: item.kind, date: attrs.created ?? attrs.modified) {
                        dest = folder.appendingPathComponent(name)
                    }
                    if dest.standardizedFileURL.path == current.deletingLastPathComponent().standardizedFileURL.path { continue }
                    try fs.createDirectory(dest)
                    let ext = current.pathExtension
                    let name = OutputNaming.firstFree(base: current.deletingPathExtension().lastPathComponent, suffix: "", ext: ext) {
                        fs.exists(dest.appendingPathComponent($0))
                    }
                    let target = dest.appendingPathComponent(name)
                    try fs.moveItem(from: current, to: target)
                    moves.append(FileMove(from: current, to: target))
                    current = target

                case .moveToTrash:
                    if let trashed = try fs.moveToTrash(current) { moves.append(FileMove(from: current, to: trashed)) }
                    return await record(rule, original, moves, outputs)

                case .convertImage(let format):
                    guard detector.item(for: current).kind == .image else { continue }
                    // Ya está en el formato destino: convertir crearía «a-2.jpg» y, al vigilarse la carpeta, un bucle sin fin.
                    if Self.isSameFormat(current.pathExtension, format) { continue }
                    let dir = current.deletingLastPathComponent()
                    let name = OutputNaming.firstFree(base: current.deletingPathExtension().lastPathComponent, suffix: "",
                                                      ext: format.fileExtension) { fs.exists(dir.appendingPathComponent($0)) }
                    let out = dir.appendingPathComponent(name)
                    outputs.append(out)
                    try await image.convert(current, to: format, quality: 0.9, maxSide: nil, output: out)
                }
            }
        } catch {
            for out in outputs where fs.exists(out) { _ = try? fs.moveToTrash(out) }
            continuation.yield(.failed(tr("«%@» no pudo procesar «%@»: %@", rule.name, original.lastPathComponent, error.localizedDescription)))
            // Lo que sí se movió antes del fallo se deja registrado, para poder deshacerlo.
            return await record(rule, original, moves, [])
        }
        return await record(rule, original, moves, outputs)
    }

    private static func isSameFormat(_ ext: String, _ format: ImageFormat) -> Bool {
        let e = ext.lowercased()
        switch format {
        case .jpg: return e == "jpg" || e == "jpeg"
        case .png: return e == "png"
        case .heic: return e == "heic" || e == "heif"
        }
    }

    private func record(_ rule: Rule, _ original: URL, _ moves: [FileMove], _ outputs: [URL]) async -> HistoryEntry? {
        guard !moves.isEmpty || !outputs.isEmpty else { return nil }
        for m in moves { markOwn(m.to) }
        for o in outputs { markOwn(o) }
        let entry = HistoryEntry(operation: .folderRule(name: rule.name), inputs: [original],
                                 outputs: moves.map(\.to) + outputs, moves: moves)
        await history.record(entry)
        continuation.yield(.applied(entry))
        return entry
    }
}
