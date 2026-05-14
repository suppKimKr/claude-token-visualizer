import SwiftUI

@main
struct ClaudeTokenVizApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text("--%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
