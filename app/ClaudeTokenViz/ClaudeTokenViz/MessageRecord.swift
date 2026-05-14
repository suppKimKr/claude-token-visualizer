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
        let role: String?
        let model: String?
        let usage: TokenUsage?
        // At most one of `content` / `contentString` is non-nil. Assistant
        // outputs use the block array; some user inputs (notably paperclip
        // subagent kickoffs) use a plain string. Both are nil when the key
        // is missing or neither shape decodes.
        let content: [ContentBlock]?
        let contentString: String?

        enum CodingKeys: String, CodingKey { case role, model, usage, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try c.decodeIfPresent(String.self, forKey: .role)
            self.model = try c.decodeIfPresent(String.self, forKey: .model)
            self.usage = try c.decodeIfPresent(TokenUsage.self, forKey: .usage)
            if let blocks = try? c.decode([ContentBlock].self, forKey: .content) {
                self.content = blocks
                self.contentString = nil
            } else if let str = try? c.decode(String.self, forKey: .content) {
                self.content = nil
                self.contentString = str
            } else {
                self.content = nil
                self.contentString = nil
            }
        }

        // First chunk of human-readable text in a user message, or nil if
        // this isn't a user message or it only carries non-text blocks
        // (e.g. tool_result delivery back to the model).
        var userPromptText: String? {
            guard role == "user" else { return nil }
            if let s = contentString, !s.isEmpty { return s }
            if let blocks = content {
                for block in blocks where block.type == "text" {
                    if let t = block.text, !t.isEmpty { return t }
                }
            }
            return nil
        }
    }

    // Subset of the Anthropic content-block schema; input / id / tool_use_id
    // are intentionally unmodelled — downstream charts don't read them.
    nonisolated struct ContentBlock: Decodable, Sendable {
        let type: String
        let name: String?
        let text: String?
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
