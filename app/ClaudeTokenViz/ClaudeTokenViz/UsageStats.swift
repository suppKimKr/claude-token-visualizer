import Foundation
import Observation

// Aggregated view over every JSONL message under ~/.claude/projects/.
// On launch a one-shot scan ingests every existing line; afterwards an
// FSEvents-backed JSONLWatcher tails the same files and feeds appends
// straight back into `ingest`.
@MainActor
@Observable
final class UsageStats {
    private(set) var totalMessages: Int = 0

    // Keyed by the immediate subdirectory under ~/.claude/projects/
    // (Claude Code's encoded project key). Pretty-name resolution via
    // ~/.claude/homunculus/projects.json is deferred until the charts
    // need readable labels.
    private(set) var projectMessageCounts: [String: Int] = [:]
    private(set) var projectTokens: [String: Int] = [:]

    private(set) var modelCounts: [String: Int] = [:]

    // Tool-use blocks counted by their `name` (Bash, Read, Edit, …).
    private(set) var toolCounts: [String: Int] = [:]

    // Most-recent user prompts, sorted newest first, capped at `recentPromptCap`.
    private(set) var recentPrompts: [RecentPrompt] = []
    private let recentPromptCap = 50

    nonisolated struct RecentPrompt: Sendable, Hashable {
        let date: Date
        let projectDir: String
        let snippet: String
    }

    // Day key = Calendar's start-of-day in the user's current timezone.
    private(set) var messagesByDay: [Date: Int] = [:]

    // weekday (1=Sunday … 7=Saturday) × hour (0..23) → message count.
    private(set) var messagesByHourOfWeek: [Int: [Int: Int]] = [:]

    private(set) var isLoading: Bool = false

    private let projectNames: [String: String]
    private var watcher: JSONLWatcher?

    init() {
        self.projectNames = UsageStats.loadProjectNames()
        Task {
            await initialScan()
        }
    }

    // Resolves a Claude Code project dir key to a readable name.
    //
    //   1. Exact match in homunculus -> use the name.
    //   2. Longest homunculus key that is a path-segment prefix of the
    //      project dir -> use that parent's name. Catches sub-directory
    //      sessions of a registered project (e.g. .claude/state inside
    //      a known repo).
    //   3. Decode heuristic: the encoder maps both '/' and '.' to '-',
    //      so a `--` boundary in the key implies the next segment was
    //      a hidden dir (e.g. paperclip from /Users/<u>/.paperclip/...).
    //      Use that segment -- works well for tool dirs that group many
    //      UUID workspaces under one root.
    //   4. Trailing hyphen-segment -> last-ditch fallback.
    func prettyName(_ projectDir: String) -> String {
        if let name = projectNames[projectDir] { return name }

        var bestKey: String?
        for key in projectNames.keys where projectDir.hasPrefix(key + "-") {
            if bestKey == nil || key.count > bestKey!.count {
                bestKey = key
            }
        }
        if let bestKey, let name = projectNames[bestKey] {
            return name
        }

        if let hidden = UsageStats.firstHiddenDirName(in: projectDir) {
            return hidden
        }

        return projectDir.split(separator: "-").last.map(String.init) ?? projectDir
    }

    // Detects the first `/.<name>/` boundary in an encoded project key
    // (which appears as `--<name>-` because both delimiters collapse to
    // `-`) and returns the hidden dir name without the leading dot.
    private nonisolated static func firstHiddenDirName(in encoded: String) -> String? {
        let parts = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return nil }
        for i in 1..<(parts.count - 1) where parts[i].isEmpty && !parts[i + 1].isEmpty {
            return parts[i + 1]
        }
        return nil
    }

    // Untyped JSON read so the Decodable conformance does not need to
    // cross the project's default-@MainActor isolation barrier.
    private nonisolated static func loadProjectNames() -> [String: String] {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/homunculus/projects.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any]
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for (_, value) in dict {
            guard
                let entry = value as? [String: Any],
                let name = entry["name"] as? String,
                let root = entry["root"] as? String
            else { continue }
            result[encodeProjectDir(root)] = name
        }
        return result
    }

    // Mirrors Claude Code's encoding for project dir names under
    // ~/.claude/projects/: replace both '/' and '.' with '-'.
    private nonisolated static func encodeProjectDir(_ path: String) -> String {
        path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    func initialScan() async {
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) {
            JSONLScanner.scanAll()
        }.value
        let calendar = Calendar.current
        for item in result.messages {
            ingest(item, calendar: calendar)
        }
        trimRecentPrompts()

        let w = JSONLWatcher { [weak self] messages in
            self?.ingestAppended(messages)
        }
        w.start(root: JSONLScanner.projectsDir, initialOffsets: result.offsets)
        watcher = w
    }

    func ingestAppended(_ messages: [ScannedMessage]) {
        let calendar = Calendar.current
        for item in messages {
            ingest(item, calendar: calendar)
        }
        trimRecentPrompts()
    }

    private func trimRecentPrompts() {
        recentPrompts.sort { $0.date > $1.date }
        if recentPrompts.count > recentPromptCap {
            recentPrompts = Array(recentPrompts.prefix(recentPromptCap))
        }
    }

    private func ingest(_ item: ScannedMessage, calendar: Calendar) {
        totalMessages += 1

        let projectDir = item.projectDir
        if !projectDir.isEmpty {
            projectMessageCounts[projectDir, default: 0] += 1
            if let usage = item.record.message?.usage {
                projectTokens[projectDir, default: 0] += usage.total
            }
        }

        if let model = item.record.message?.model {
            modelCounts[model, default: 0] += 1
        }

        if let blocks = item.record.message?.content {
            for block in blocks where block.type == "tool_use" {
                if let name = block.name {
                    toolCounts[name, default: 0] += 1
                }
            }
        }

        if !item.isSubagent,
            let date = item.record.timestampDate,
            let raw = item.record.message?.userPromptText
        {
            let snippet =
                raw
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                let capped = snippet.count > 200 ? String(snippet.prefix(200)) + "…" : snippet
                recentPrompts.append(
                    RecentPrompt(date: date, projectDir: item.projectDir, snippet: capped),
                )
            }
        }

        if let date = item.record.timestampDate {
            let startOfDay = calendar.startOfDay(for: date)
            messagesByDay[startOfDay, default: 0] += 1

            let comps = calendar.dateComponents([.weekday, .hour], from: date)
            if let weekday = comps.weekday, let hour = comps.hour {
                messagesByHourOfWeek[weekday, default: [:]][hour, default: 0] += 1
            }
        }
    }

    var projectCount: Int { projectMessageCounts.count }

    // Aggregates project tokens by their pretty-name label (so e.g.
    // every paperclip UUID workspace rolls into a single "paperclip"
    // slice) and returns the top `n` plus an "Others" remainder.
    func projectTokenSlices(topN n: Int) -> [(label: String, tokens: Int)] {
        var byLabel: [String: Int] = [:]
        for (dir, tokens) in projectTokens {
            byLabel[prettyName(dir), default: 0] += tokens
        }
        let sorted = byLabel.sorted { $0.value > $1.value }
        let head = Array(sorted.prefix(n))
        let othersTotal = sorted.dropFirst(n).reduce(0) { $0 + $1.value }
        var out = head.map { (label: $0.key, tokens: $0.value) }
        if othersTotal > 0 {
            out.append((label: "Others", tokens: othersTotal))
        }
        return out
    }

    func toolUsageSlices(topN n: Int) -> [(label: String, count: Int)] {
        let sorted = toolCounts.sorted { $0.value > $1.value }
        let head = Array(sorted.prefix(n))
        let othersTotal = sorted.dropFirst(n).reduce(0) { $0 + $1.value }
        var out = head.map { (label: $0.key, count: $0.value) }
        if othersTotal > 0 {
            out.append((label: "Others", count: othersTotal))
        }
        return out
    }
}
