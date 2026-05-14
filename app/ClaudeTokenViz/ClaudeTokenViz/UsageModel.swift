import Foundation
import Observation

@MainActor
@Observable
final class UsageModel {
    // The last successful fetch. Stays around even if a subsequent fetch
    // fails so the popover and menubar label keep showing real data
    // instead of an error placeholder.
    var snapshot: UsageResponse?

    // When `snapshot` was set. Drives the relative timestamp in the header.
    var lastUpdated: Date?

    // The most recent fetch error message. Cleared on the next success
    // and also cleared at the start of a manual refresh so the user gets
    // immediate visual feedback that a new attempt is in flight.
    var lastError: String?

    // When `lastError` was set. Lets the banner show a relative timestamp
    // ("1m ago") so the user can tell a fresh failure from a stuck stale
    // one between polls.
    var lastErrorAt: Date?

    // True while a fetch is in flight. Drives the Refresh button's
    // disabled state and the small spinner in the popover header.
    var isFetching: Bool = false

    private var pollTask: Task<Void, Never>?

    // Consecutive failed fetches. Drives exponential backoff so we do not
    // hold the 429 rate limit open by polling at full cadence while the
    // window is closed. Reset on success.
    private var consecutiveFailures: Int = 0

    init() {
        start()
    }

    // 60s base cadence was picked after a 5-second poll triggered the
    // usage endpoint's 429 rate limit. Usage numbers are aggregated
    // server-side on the order of minutes, so a faster cadence does not
    // give better data. On consecutive failures we back off exponentially
    // (60s, 60s, 120s, 240s, ...) capped at 10 minutes; success resets.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchOnce()
                let interval = self.nextPollInterval()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func nextPollInterval() -> Double {
        let base: Double = 60
        let cap: Double = 600
        if consecutiveFailures <= 1 { return base }
        let factor = pow(2.0, Double(consecutiveFailures - 1))
        return min(base * factor, cap)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Optimistic clear so the user sees the banner disappear the moment
        // they click. If the new fetch also fails, it will reappear with a
        // fresh timestamp.
        lastError = nil
        lastErrorAt = nil
        await fetchOnce()
    }

    private func fetchOnce() async {
        if isFetching { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let token = try await KeychainService.readClaudeCodeToken()
            let usage = try await UsageAPI.fetchUsage(token: token)
            snapshot = usage
            lastUpdated = Date()
            lastError = nil
            lastErrorAt = nil
            consecutiveFailures = 0
        } catch {
            lastError = String(describing: error)
            lastErrorAt = Date()
            consecutiveFailures += 1
        }
    }

    // Headline string used in the menubar label. Prefers the last good
    // 5-hour remaining percentage so a transient API failure does not
    // disrupt the icon. When we genuinely have no data yet, fall back
    // to "--%" rather than a noisy "ERR" — the popover already surfaces
    // the error in full and an alarming menubar adds nothing.
    var headlineLabel: String {
        if let snap = snapshot, let bucket = snap.fiveHour {
            let remaining = max(0, 100 - bucket.utilization)
            return "\(Int(remaining.rounded()))%"
        }
        return "--%"
    }
}
