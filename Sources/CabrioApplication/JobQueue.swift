import Foundation
import CabrioDomain

/// Cola de trabajos: se ejecutan de uno en uno, son cancelables y publican su estado.
public actor JobQueue {
    private let runner: RunOperation
    private var tail: Task<Void, Never>?
    private var running: [UUID: Task<Void, Never>] = [:]
    private let continuation: AsyncStream<Job>.Continuation
    public nonisolated let updates: AsyncStream<Job>

    public init(runner: RunOperation) {
        self.runner = runner
        let (stream, cont) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        self.updates = stream
        self.continuation = cont
    }

    @discardableResult
    public func submit(_ operation: CabrioOperation, inputs: [FileItem]) -> UUID {
        var job = Job(inputs: inputs, operation: operation)
        let id = job.id
        continuation.yield(job)
        let previous = tail
        let runner = self.runner
        let continuation = self.continuation
        let task = Task { [weak self] in
            await previous?.value
            if Task.isCancelled {
                job.state = .cancelled; continuation.yield(job)
            } else {
                job.state = .running; continuation.yield(job)
                do {
                    let base = job
                    let outputs = try await runner(operation, inputs: inputs.map(\.url)) { fraction in
                        var j = base
                        j.state = .progress(fraction)
                        continuation.yield(j)
                    }
                    job.state = .succeeded(outputs)
                } catch CabrioError.cancelled {
                    job.state = .cancelled
                } catch {
                    job.state = .failed(error.localizedDescription)
                }
                continuation.yield(job)
            }
            await self?.finished(id)
        }
        running[id] = task
        tail = task
        return id
    }

    public func cancel(_ id: UUID) {
        running[id]?.cancel()
    }

    private func finished(_ id: UUID) {
        running[id] = nil
    }
}
