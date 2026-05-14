import SwiftUI

@main
struct ClaudeTokenVizApp: App {
    @State private var model = UsageModel()
    @State private var stats = UsageStats()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model, stats: stats)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text(model.headlineLabel)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Stats", id: "stats") {
            StatsView(stats: stats)
        }
        .defaultSize(width: 820, height: 520)
    }
}
