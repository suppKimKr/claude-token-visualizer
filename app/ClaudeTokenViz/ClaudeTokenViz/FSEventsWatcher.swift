import CoreServices
import Foundation

// We only ever watch a single root, so the API is intentionally narrow.
// `kFSEventStreamCreateFlagFileEvents` is what makes the callback fire per
// affected file path; without it FSEvents only reports parent directories.
nonisolated final class FSEventsWatcher {
    typealias Handler = @Sendable (URL) -> Void

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let handler: Handler

    init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start(watching root: URL, latency: TimeInterval = 0.5) {
        let paths = [root.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes,
        )
        guard
            let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                FSEventsWatcher.callback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags,
            )
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // Flags are ignored: the downstream watcher re-stats the file anyway,
    // so an explicit Modified / Created / Removed split would just duplicate
    // the size-check it already does.
    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray
        for i in 0..<count {
            guard
                let path = cfPaths[i] as? String,
                path.hasSuffix(".jsonl")
            else { continue }
            watcher.handler(URL(fileURLWithPath: path))
        }
    }
}
