import Foundation
import CabrioDomain
import CabrioPorts

public enum RuleEvent: Sendable {
    case applied(HistoryEntry)
    case failed(String)
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
    private let now: @Sendable () -> Date
    private let stability: Duration
    private let sweepInterval: Duration

    private var rules: [Rule] = []
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var sweepTask: Task<Void, Never>?
    private var inFlight = Set<String>()
    private var enabled = true

    public nonisolated let events: AsyncStream<RuleEvent>
    private let continuation: AsyncStream<RuleEvent>.Continuation

    public init(store: RuleStore, fileSystem: FileSystem, detector: FileKindDetecting, image: ImageEngine,
                history: HistoryStore, watcher: FolderWatcher, now: @escaping @Sendable () -> Date = { Date() },
                stability: Duration = .seconds(2), sweepInterval: Duration = .seconds(1800)) {
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
        rules = (try? store.load()) ?? []
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
        var done: [HistoryEntry] = []
        for url in matches(for: rule) {
            if let entry = await apply(rule, to: url) { done.append(entry) }
        }
        return done
    }

    func sweepAgeRules() async {
        for rule in rules where rule.isEnabled && rule.isAgeBased { await runNow(rule) }
    }

    private func handle(_ url: URL, in folder: URL) async {
        let key = url.path
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
        guard let rule = rules.first(where: { r in
            r.isEnabled && r.folder.standardizedFileURL.path == folderPath
                && r.condition.matches(name: url.lastPathComponent, kind: item.kind, size: attrs.size,
                                       created: attrs.created, modified: attrs.modified, now: current)
        }) else { return }
        _ = await apply(rule, to: url)
    }

    /// Ejecuta las acciones de la regla en orden y anota lo hecho para poder deshacerlo.
    func apply(_ rule: Rule, to original: URL) async -> HistoryEntry? {
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

    private func record(_ rule: Rule, _ original: URL, _ moves: [FileMove], _ outputs: [URL]) async -> HistoryEntry? {
        guard !moves.isEmpty || !outputs.isEmpty else { return nil }
        let entry = HistoryEntry(operation: .folderRule(name: rule.name), inputs: [original],
                                 outputs: moves.map(\.to) + outputs, moves: moves)
        await history.record(entry)
        continuation.yield(.applied(entry))
        return entry
    }
}
