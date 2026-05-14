import Foundation

enum KeychainError: Error, CustomStringConvertible {
    case securityCommandFailed(exitCode: Int32, stderr: String)
    case emptyOutput
    case malformedJSON(underlying: Error)
    case missingAccessToken

    var description: String {
        switch self {
        case .securityCommandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "security CLI exited \(code)"
            }
            return "security CLI exited \(code): \(trimmed)"
        case .emptyOutput:
            return "security CLI returned empty output"
        case .malformedJSON(let underlying):
            return "could not parse keychain payload as JSON: \(underlying.localizedDescription)"
        case .missingAccessToken:
            return "claudeAiOauth.accessToken missing from keychain payload"
        }
    }
}

// nonisolated because the decode happens on a detached task; the
// project-wide default isolation is @MainActor.
nonisolated private struct KeychainBlob: Decodable {
    let claudeAiOauth: ClaudeAiOauth

    nonisolated struct ClaudeAiOauth: Decodable {
        let accessToken: String
    }
}

enum KeychainService {
    // Reads the password payload of the "Claude Code-credentials" generic
    // keychain item and returns the embedded accessToken. Matches the M1
    // TypeScript probe's `readKeychainToken()` exactly: shell out to the
    // `security` CLI with `-w` to print only the password, which itself
    // is a JSON blob.
    //
    // The blocking Process work runs on a detached task so a locked
    // keychain or ACL prompt cannot stall the MainActor (popover UI).
    static func readClaudeCodeToken() async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            try runSecurityFindGenericPassword()
        }.value
    }

    nonisolated private static func runSecurityFindGenericPassword() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw KeychainError.securityCommandFailed(
                exitCode: process.terminationStatus,
                stderr: stderrString,
            )
        }

        let raw = String(data: stdoutData, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw KeychainError.emptyOutput
        }

        let parsed: KeychainBlob
        do {
            parsed = try JSONDecoder().decode(KeychainBlob.self, from: Data(trimmed.utf8))
        } catch {
            throw KeychainError.malformedJSON(underlying: error)
        }

        let token = parsed.claudeAiOauth.accessToken
        if token.isEmpty {
            throw KeychainError.missingAccessToken
        }
        return token
    }
}
