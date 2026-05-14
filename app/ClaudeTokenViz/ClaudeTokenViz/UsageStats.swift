import Foundation
import Observation

// Aggregated view over every JSONL message under ~/.claude/projects/.
// M3.1 scope: one-shot initial scan on launch, no file watching yet.
// Future milestones (M3.x) will layer FSEvents on top to keep the
// aggregations live as Claude Code appends new lines.
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

    // Day key = Calendar's start-of-day in the user's current timezone.
    private(set) var messagesByDay: [Date: Int] = [:]

    // weekday (1=Sunday … 7=Saturday) × hour (0..23) → message count.
    private(set) var messagesByHourOfWeek: [Int: [Int: Int]] = [:]

    private(set) var isLoading: Bool = false

    init() {
        Task {
            await initialScan()
        }
    }

    func initialScan() async {
        isLoading = true
        defer { isLoading = false }
        let scanned = await Task.detached(priority: .userInitiated) {
            JSONLScanner.scanAll()
        }.value
        let calendar = Calendar.current
        for item in scanned {
            ingest(item, calendar: calendar)
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

    var topProjects: [(projectDir: String, tokens: Int)] {
        projectTokens
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (projectDir: $0.key, tokens: $0.value) }
    }
}
