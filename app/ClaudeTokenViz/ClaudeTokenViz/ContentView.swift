import SwiftUI

struct ContentView: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Token Visualizer")
                    .font(.headline)
                Spacer()
                if model.isFetching {
                    ProgressView().controlSize(.mini)
                }
                if let updated = model.lastUpdated {
                    Text(updated, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            mainContent

            if model.snapshot != nil, let err = model.lastError, let errAt = model.lastErrorAt {
                let banner =
                    Text("⚠ failed ")
                    + Text(errAt, format: .relative(presentation: .numeric))
                    + Text(" — \(shortError(err))")
                banner
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderless)
                .disabled(model.isFetching)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let snapshot = model.snapshot {
            usageRows(snapshot)
        } else if model.isFetching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Fetching usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let err = model.lastError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func usageRows(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bucket = usage.fiveHour {
                Text("5h:  \(remainingString(bucket.utilization))")
            }
            if let bucket = usage.sevenDay {
                Text("7d:  \(remainingString(bucket.utilization))")
            }
            if let bucket = usage.sevenDayOpus {
                Text("  └ Opus    \(remainingString(bucket.utilization))")
                    .foregroundStyle(.secondary)
            }
            if let bucket = usage.sevenDaySonnet {
                Text("  └ Sonnet  \(remainingString(bucket.utilization))")
                    .foregroundStyle(.secondary)
            }
            if let bucket = usage.sevenDayOmelette {
                Text("Design (7d): \(remainingString(bucket.utilization))")
            }
            if let extra = usage.extraUsage {
                let pct =
                    extra.monthlyLimit > 0
                    ? 100 - (extra.usedCredits / Double(extra.monthlyLimit)) * 100
                    : 100
                Text(
                    "Overage: \(String(format: "%.1f%%", pct)) ($\(String(format: "%.2f", extra.usedCredits)) / $\(extra.monthlyLimit))",
                )
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private func remainingString(_ utilization: Double) -> String {
        String(format: "%5.1f%% remaining", max(0, 100 - utilization))
    }

    private func shortError(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "..."
    }
}
