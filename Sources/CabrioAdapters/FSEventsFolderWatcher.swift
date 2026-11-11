import Foundation
import CoreServices
import CabrioDomain
import CabrioPorts

/// Vigilancia de carpetas con FSEvents: avisa de archivos creados, movidos o modificados directamente en la carpeta.
public struct FSEventsFolderWatcher: FolderWatcher {
    public init() {}

    public func events(for folder: URL) -> AsyncStream<URL> {
        AsyncStream { continuation in
            let box = StreamBox(folder: folder.resolvingSymlinksInPath(), continuation: continuation)
            box.start()
            continuation.onTermination = { _ in box.stop() }
        }
    }
}

private final class StreamBox: @unchecked Sendable {
    private let folder: URL
    private let continuation: AsyncStream<URL>.Continuation
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.chocolitossoft.cabrio.fsevents")

    init(folder: URL, continuation: AsyncStream<URL>.Continuation) {
        self.folder = folder
        self.continuation = continuation
    }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count { if let p = list[i] as? String { box.handle(p, flags[i]) } }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            continuation.finish()
            return
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    fileprivate func handle(_ path: String, _ flags: FSEventStreamEventFlags) {
        let f = Int(flags)
        guard f & kFSEventStreamEventFlagItemIsFile != 0,
              f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0,
              f & kFSEventStreamEventFlagItemRemoved == 0 else { return }
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path else { return }   // solo hijos directos
        continuation.yield(url)
    }
}
