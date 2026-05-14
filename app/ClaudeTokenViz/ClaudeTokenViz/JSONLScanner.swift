import Foundation

// One MessageRecord paired with the project directory it came from.
// The project directory is the immediate child of ~/.claude/projects/,
// matching how Claude Code organises sessions on disk. We carry it
// alongside the record because the `cwd` field inside a message is
// the shell cwd at the time the message was written -- it can vary
// freely if the user `cd`s around inside a project, which inflates
// the apparent project count.
nonisolated struct ScannedMessage: Sendable {
    let record: MessageRecord
    let projectDir: String
    // True when the file lives under `.../<sessionId>/subagents/agent-*.jsonl`.
    // The Recent Prompts feed uses this to skip system-injected subagent
    // kickoffs that aren't really "things the human typed".
    let isSubagent: Bool
}

// JSONL parsing and walking primitives shared by the one-shot initial scan
// and the live JSONLWatcher tail. Everything here is `nonisolated` so the
// scan can run from a detached task.
nonisolated enum JSONLScanner {
    static let projectsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct ScanResult: Sendable {
        let messages: [ScannedMessage]
        // File byte-offset *just past the last successfully parsed line* for
        // each scanned file. JSONLWatcher resumes from these so an in-flight
        // partial line at scan time is re-read once it finishes writing.
        let offsets: [URL: UInt64]
    }

    static func scanAll() -> ScanResult {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return ScanResult(messages: [], offsets: [:])
        }
        let decoder = makeDecoder()
        var out: [ScannedMessage] = []
        var offsets: [URL: UInt64] = [:]
        for fileURL in jsonlFiles(under: projectsDir) {
            let projectDir = projectDirName(for: fileURL)
            let isSubagent = isSubagentFile(fileURL)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let parsed = parseChunk(
                data,
                projectDir: projectDir,
                isSubagent: isSubagent,
                decoder: decoder,
            )
            out.append(contentsOf: parsed.messages)
            offsets[fileURL] = UInt64(parsed.consumedBytes)
        }
        return ScanResult(messages: out, offsets: offsets)
    }

    // Parse a chunk of bytes (always at a line boundary on the *left*) and
    // return everything up to the last '\n' inside it. The trailing partial
    // line — if any — is intentionally left unread so the next call can pick
    // it up after the writer flushes the closing '\n'.
    static func parseChunk(
        _ data: Data,
        projectDir: String,
        isSubagent: Bool,
        decoder: JSONDecoder,
    ) -> (messages: [ScannedMessage], consumedBytes: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return ([], 0)
        }
        let endExclusive = data.index(after: lastNewline)
        let consumedBytes = endExclusive - data.startIndex

        var messages: [ScannedMessage] = []
        var cursor = data.startIndex
        while cursor < endExclusive {
            let nl = data[cursor..<endExclusive].firstIndex(of: 0x0A) ?? endExclusive
            if nl > cursor {
                let line = data[cursor..<nl]
                if let record = try? decoder.decode(MessageRecord.self, from: line) {
                    messages.append(
                        ScannedMessage(
                            record: record,
                            projectDir: projectDir,
                            isSubagent: isSubagent,
                        ),
                    )
                }
            }
            cursor = nl < endExclusive ? data.index(after: nl) : endExclusive
        }
        return (messages, consumedBytes)
    }

    // Subagent fan-out files live at .../<sessionId>/subagents/agent-*.jsonl.
    static func isSubagentFile(_ file: URL) -> Bool {
        file.standardizedFileURL.pathComponents.contains("subagents")
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // Returns the first path component under ~/.claude/projects/ for the
    // given file -- i.e., the on-disk project key Claude Code uses.
    static func projectDirName(for file: URL) -> String {
        let rootCount = projectsDir.standardizedFileURL.pathComponents.count
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > rootCount else { return "" }
        return fileComponents[rootCount]
    }

    private static func jsonlFiles(under root: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
            )
        else {
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }
}
