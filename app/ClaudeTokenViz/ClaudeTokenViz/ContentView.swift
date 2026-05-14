import SwiftUI

struct ContentView: View {
    @State private var loadState: LoadState = .loading

    enum LoadState {
        case loading
        case loaded(UsageResponse)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Token Visualizer")
                .font(.headline)
            Text("M2.2 — live data")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            switch loadState {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching usage…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let usage):
                usageRows(usage)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    Task { await fetch() }
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 280)
        .task {
            await fetch()
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

    private func fetch() async {
        loadState = .loading
        do {
            let token = try KeychainService.readClaudeCodeToken()
            let usage = try await UsageAPI.fetchUsage(token: token)
            loadState = .loaded(usage)
        } catch {
            loadState = .failed(String(describing: error))
        }
    }
}

#Preview {
    ContentView()
}
