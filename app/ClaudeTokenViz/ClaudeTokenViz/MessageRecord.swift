import Foundation

// One line of a Claude Code session JSONL. Files live under
// ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl and may also live
// under .../<sessionId>/subagents/agent-<id>.jsonl for sub-agent fan-out.
//
// The schema is partial on purpose -- we only model fields the stats
// pipeline actually reads. Unknown keys are tolerated by Decodable.
// New fields are added as later milestones need them.
//
// nonisolated because JSONLScanner decodes records on a detached task;
// the project-wide default isolation is @MainActor.
nonisolated struct MessageRecord: Decodable, Sendable {
    private let timestamp: String?
    let message: InnerMessage?

    nonisolated struct InnerMessage: Decodable, Sendable {
        let model: String?
        let usage: TokenUsage?
    }

    nonisolated struct TokenUsage: Decodable, Sendable {
        let inputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let outputTokens: Int?

        var total: Int {
            (inputTokens ?? 0)
                + (cacheCreationInputTokens ?? 0)
                + (cacheReadInputTokens ?? 0)
                + (outputTokens ?? 0)
        }
    }

    var timestampDate: Date? {
        guard let timestamp else { return nil }
        return MessageRecord.iso8601Formatter.date(from: timestamp)
    }

    // ISO8601 with fractional seconds (CLI writes `.236Z` style).
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
