import SwiftUI

@main
struct ClaudeTokenVizApp: App {
    @State private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text(model.headlineLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
