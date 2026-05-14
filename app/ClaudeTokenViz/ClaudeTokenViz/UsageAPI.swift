import Foundation

struct UsageBucket: Decodable, Sendable {
    let utilization: Double
    let resetsAt: String?
}

struct ExtraUsage: Decodable, Sendable {
    let isEnabled: Bool
    let monthlyLimit: Int
    let usedCredits: Double
    let utilization: Double?
    let currency: String
}

struct UsageResponse: Decodable, Sendable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    // `seven_day_omelette` is the API code name for what claude.ai surfaces
    // as "Claude Design" — a research-preview feature with its own weekly
    // quota that is *not* counted toward `seven_day`.
    let sevenDayOmelette: UsageBucket?
    let extraUsage: ExtraUsage?
}

enum UsageAPIError: Error, CustomStringConvertible {
    case badStatus(code: Int, body: String)
    case decodingFailed(underlying: Error)

    var description: String {
        switch self {
        case .badStatus(let code, let body):
            let prefix = body.prefix(200)
            return "Usage API \(code): \(prefix)"
        case .decodingFailed(let err):
            return "decode usage response: \(err.localizedDescription)"
        }
    }
}

enum UsageAPI {
    // Matches M1 fallback: `process.env.CLAUDE_CLI_VERSION ?? '2.1.140'`.
    private static let claudeCliVersion = "2.1.140"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetchUsage(token: String) async throws -> UsageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-cli/\(claudeCliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.badStatus(code: -1, body: "no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageAPIError.badStatus(code: http.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decodingFailed(underlying: error)
        }
    }
}
