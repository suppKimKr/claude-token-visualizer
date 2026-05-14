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
}

// Walks ~/.claude/projects/ recursively, parses every *.jsonl line into
// a ScannedMessage, and returns the lot. Designed to be called from a
// detached task — none of this work touches the main actor.
nonisolated enum JSONLScanner {
    static let projectsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    static func scanAll() -> [ScannedMessage] {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var out: [ScannedMessage] = []
        for fileURL in jsonlFiles(under: projectsDir) {
            let projectDir = projectDirName(for: fileURL)
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8) else { continue }
                if let record = try? decoder.decode(MessageRecord.self, from: data) {
                    out.append(ScannedMessage(record: record, projectDir: projectDir))
                }
            }
        }
        return out
    }

    // Returns the first path component under ~/.claude/projects/ for the
    // given file -- i.e., the on-disk project key Claude Code uses.
    private static func projectDirName(for file: URL) -> String {
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
