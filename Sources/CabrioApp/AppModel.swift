import AppKit
import SwiftUI
import CabrioDomain
import CabrioApplication
import CabrioAdapters

enum PanelState: Equatable {
    case idle
    case running(String, Double?)
    case done([URL], undoID: UUID?, reports: [CompressionReport])
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var state: PanelState = .idle
    /// Acción que está pidiendo opciones (dividir, OCR) antes de ejecutarse.
    @Published var pending: ActionDef?
    @Published private(set) var lastWasRename = false
    var onOpenSettings: () -> Void = {}

    /// Muestra un error en el panel (p. ej. falta el permiso del Finder).
    func report(_ message: String) { if !isRunning { state = .failed(message) } }
    private let fileSystem = LocalFileSystem()

    /// Vista previa de un renombrado: pares «antes → después» o el mensaje de error de la plantilla.
    func renamePreview(_ spec: RenameSpec) -> Result<[FileMove], CabrioError> {
        do { return .success(try RenamePlanner(fileSystem: fileSystem).plan(items.map(\.url), spec: spec)) }
        catch let e as CabrioError { return .failure(e) }
        catch { return .failure(.writeFailed(error.localizedDescription)) }
    }

    private let detector = FileKindDetector()
    private let runner: RunOperation
    private let queue: JobQueue
    private let history: FileHistoryStore
    private var currentJob: UUID?
    private var lastInputs: [URL] = []
    private var listener: Task<Void, Never>?

    init() {
        let services = Services.shared
        self.history = services.history
        self.runner = services.operations
        self.queue = JobQueue(runner: services.operations)
        listener = Task { [weak self, queue] in
            for await job in queue.updates { await self?.handle(job) }
        }
    }

    var actions: [ActionDef] { ActionCatalog.actions(for: items) }
    var isRunning: Bool { if case .running = state { return true } else { return false } }

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let known = Set(items.map(\.url))
        for url in urls where !known.contains(url) { items.append(detector.item(for: url)) }
        state = .idle
    }

    func clear() {
        guard !isRunning else { return }
        items = []
        pending = nil
        state = .idle
    }

    func choose(_ action: ActionDef) {
        switch action.kind {
        case .immediate(let op): run(op, title: L(action.title))
        case .needsSplitOptions, .needsOCROptions, .needsCompressOptions, .needsProtectOptions, .needsUnlockOptions,
             .needsImageFormatOptions, .needsVideoOptions, .needsRenameOptions:
            pending = action
        }
    }

    func run(_ operation: CabrioOperation, title: String) {
        guard !isRunning, !items.isEmpty else { return }
        pending = nil
        state = .running(title, nil)
        if case .batchRename = operation { lastWasRename = true } else { lastWasRename = false }
        let inputs = items
        lastInputs = inputs.map(\.url)
        Task { currentJob = await queue.submit(operation, inputs: inputs) }
    }

    func cancel() {
        guard let id = currentJob else { return }
        Task { await queue.cancel(id) }
    }

    func undo() {
        guard case .done(_, let id?, _) = state else { return }
        Task {
            do { try await runner.undo(id); state = .idle } catch { state = .failed(error.localizedDescription) }
        }
    }

    /// Meta imposible: se retira el resultado y se vuelve a pedir la meta con los mismos archivos.
    func changeTarget() {
        guard case .done(_, let id, _) = state, let id else { return }
        let inputs = lastInputs
        Task {
            try? await runner.undo(id)
            items = inputs.map { detector.item(for: $0) }
            state = .idle
            pending = ActionCatalog.actions(for: items).first { $0.kind == .needsCompressOptions || $0.kind == .needsVideoOptions }
        }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func handle(_ job: Job) async {
        guard job.id == currentJob || currentJob == nil else { return }
        switch job.state {
        case .queued, .running: break
        case .progress(let f):
            if case .running(let title, _) = state { state = .running(title, f) }
        case .succeeded(let outputs):
            let entry = await history.recent(limit: 1).first
            state = .done(outputs, undoID: entry?.id, reports: entry?.reports ?? [])
            items = []
        case .failed(let message): state = .failed(message)
        case .cancelled: state = .idle
        }
    }
}
