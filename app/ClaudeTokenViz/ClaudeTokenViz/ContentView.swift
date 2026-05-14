import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Token Visualizer")
                .font(.headline)
            Text("M2.1 skeleton — no data yet")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 240)
    }
}

#Preview {
    ContentView()
}
