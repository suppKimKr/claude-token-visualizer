import Foundation

// Live tail for ~/.claude/projects/*.jsonl. `@unchecked Sendable` because
// every mutation of `offsets` / `fsWatcher` happens on the private serial
// `queue` -- the type has no MainActor surface of its own.
nonisolated final class JSONLWatcher: @unchecked Sendable {
    typealias Sink = @Sendable @MainActor ([ScannedMessage]) -> Void

    private let queue = DispatchQueue(label: "claudetokenviz.jsonlwatcher", qos: .userInitiated)
    private let sink: Sink
    private let decoder: JSONDecoder

    // Mutated only on `queue`.
    private var offsets: [URL: UInt64] = [:]
    private var fsWatcher: FSEventsWatcher?

    init(sink: @escaping Sink) {
        self.sink = sink
        self.decoder = JSONLScanner.makeDecoder()
    }

    deinit { stop() }

    // Files not in `initialOffsets` are treated as brand new (offset 0).
    func start(root: URL, initialOffsets: [URL: UInt64]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.offsets = initialOffsets
            let fs = FSEventsWatcher(queue: self.queue) { [weak self] url in
                self?.handleEvent(url)
            }
            fs.start(watching: root)
            self.fsWatcher = fs
        }
    }

    func stop() {
        queue.sync {
            fsWatcher?.stop()
            fsWatcher = nil
        }
    }

    private func handleEvent(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let sizeNum = attrs?[.size] as? NSNumber else {
            // File vanished — drop tracking, nothing else to do.
            offsets.removeValue(forKey: url)
            return
        }
        let size = sizeNum.uint64Value
        let prev = offsets[url] ?? 0

        if size < prev {
            // Truncation / rewrite. Don't try to re-ingest from byte 0
            // because we'd double-count everything we already have. Skip
            // the lost bytes by aligning offset to the new EOF.
            offsets[url] = size
            return
        }
        if size == prev { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: prev)
        let toRead = Int(size - prev)
        guard
            let chunk = try? handle.read(upToCount: toRead),
            !chunk.isEmpty
        else { return }

        let projectDir = JSONLScanner.projectDirName(for: url)
        let isSubagent = JSONLScanner.isSubagentFile(url)
        let parsed = JSONLScanner.parseChunk(
            chunk,
            projectDir: projectDir,
            isSubagent: isSubagent,
            decoder: decoder,
        )
        offsets[url] = prev + UInt64(parsed.consumedBytes)
        guard !parsed.messages.isEmpty else { return }

        let sink = self.sink
        Task { @MainActor in
            sink(parsed.messages)
        }
    }
}
