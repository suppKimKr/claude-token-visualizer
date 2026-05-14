import Charts
import SwiftUI

struct StatsView: View {
    let stats: UsageStats

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if stats.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Scanning ~/.claude/projects/…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    section("Projects") {
                        if projectSlices.isEmpty {
                            empty("No project tokens yet.")
                        } else {
                            projectsDonut
                                .frame(height: 280)
                        }
                    }

                    section("Tools") {
                        if toolSlices.isEmpty {
                            empty("No tool usage yet.")
                        } else {
                            toolsChart
                                .frame(height: CGFloat(max(180, toolSlices.count * 28)))
                        }
                    }

                    section("Daily Activity") {
                        if dailySeries.isEmpty {
                            empty("No timestamped messages yet.")
                        } else {
                            timelineChart
                                .frame(height: 260)
                        }
                    }

                    section("Rhythm") {
                        if stats.messagesByHourOfWeek.isEmpty {
                            empty("No weekday/hour data yet.")
                        } else {
                            rhythmChart
                                .frame(height: 220)
                        }
                    }

                    section("Recent Prompts") {
                        if stats.recentPrompts.isEmpty {
                            empty("No user prompts yet.")
                        } else {
                            recentPromptsList
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Token Visualizer")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text("\(stats.totalMessages.formatted()) msgs · \(stats.projectCount) projects")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Projects

    private struct ProjectSlice: Hashable {
        let label: String
        let tokens: Int
    }

    // Top 8 projects by token total + an "Others" bucket. Anything beyond
    // 8 slices makes the donut illegible. Aggregation by pretty-name is
    // done in UsageStats so paperclip-style multi-workspace projects roll
    // up to one slice.
    private var projectSlices: [ProjectSlice] {
        stats.projectTokenSlices(topN: 8).map {
            ProjectSlice(label: $0.label, tokens: $0.tokens)
        }
    }

    private var projectsDonut: some View {
        let slices = projectSlices
        let totalTokens = slices.reduce(0) { $0 + $1.tokens }
        return Chart(slices, id: \.self) { slice in
            SectorMark(
                angle: .value("Tokens", slice.tokens),
                innerRadius: .ratio(0.6),
                angularInset: 2,
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Project", slice.label))
            .annotation(position: .overlay, alignment: .center) {
                let share = totalTokens > 0 ? Double(slice.tokens) / Double(totalTokens) : 0
                if share >= 0.06 {
                    Text(String(format: "%.0f%%", share * 100))
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
        }
        .chartLegend(position: .trailing, alignment: .top, spacing: 12)
    }

    // MARK: - Tools

    private struct ToolSlice: Hashable {
        let label: String
        let count: Int
    }

    // Same 8 + Others cap as Projects so the legend stays comparable.
    private var toolSlices: [ToolSlice] {
        stats.toolUsageSlices(topN: 8).map {
            ToolSlice(label: $0.label, count: $0.count)
        }
    }

    private var toolsChart: some View {
        let slices = toolSlices
        let orderedLabels = slices.map(\.label)
        return Chart(slices, id: \.self) { slice in
            BarMark(
                x: .value("Count", slice.count),
                y: .value("Tool", slice.label),
            )
            .cornerRadius(3)
            .foregroundStyle(Color.accentColor.gradient)
            .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                Text(slice.count.formatted())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Pin Y to the pre-sorted (descending) order so Charts doesn't
        // re-alphabetise the categorical axis.
        .chartYScale(domain: orderedLabels)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
            }
        }
    }

    // MARK: - Timeline

    private var dailySeries: [(date: Date, count: Int)] {
        stats.messagesByDay
            .map { (date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private var peakDays: [(date: Date, count: Int)] {
        Array(dailySeries.sorted { $0.count > $1.count }.prefix(3))
    }

    private var timelineChart: some View {
        Chart {
            ForEach(dailySeries, id: \.date) { point in
                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("Messages", point.count),
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                )

                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Messages", point.count),
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
            }

            ForEach(peakDays, id: \.date) { peak in
                PointMark(
                    x: .value("Day", peak.date),
                    y: .value("Messages", peak.count),
                )
                .foregroundStyle(Color.accentColor)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    Text(peak.count.formatted())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    // MARK: - Rhythm

    private struct RhythmCell: Hashable {
        let weekday: Int  // Calendar weekday: 1 = Sunday … 7 = Saturday
        let hour: Int
        let count: Int
    }

    // Apple's weekday is 1=Sunday … 7=Saturday. Keep the labels in that order
    // and pin Charts' Y axis to it so missing weekdays do not shuffle.
    private static let weekdayLabels: [String] = [
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
    ]

    private var rhythmCells: [RhythmCell] {
        var out: [RhythmCell] = []
        out.reserveCapacity(7 * 24)
        for weekday in 1...7 {
            for hour in 0..<24 {
                let count = stats.messagesByHourOfWeek[weekday]?[hour] ?? 0
                out.append(RhythmCell(weekday: weekday, hour: hour, count: count))
            }
        }
        return out
    }

    private var rhythmChart: some View {
        let cells = rhythmCells
        let maxCount = max(1, cells.map(\.count).max() ?? 1)
        return Chart {
            ForEach(cells, id: \.self) { cell in
                let intensity =
                    cell.count == 0
                    ? 0.04
                    : max(0.18, Double(cell.count) / Double(maxCount))
                RectangleMark(
                    xStart: .value("HourStart", Double(cell.hour)),
                    xEnd: .value("HourEnd", Double(cell.hour) + 1),
                    yStart: .value("DayStart", Double(cell.weekday)),
                    yEnd: .value("DayEnd", Double(cell.weekday) + 1),
                )
                .foregroundStyle(Color.accentColor.opacity(intensity))
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 1...8)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            // Place a label at the center of each weekday band (weekday + 0.5).
            AxisMarks(position: .leading, values: (1...7).map { Double($0) + 0.5 }) { value in
                if let raw = value.as(Double.self),
                    let idx = Int(exactly: (raw - 0.5).rounded()),
                    (1...7).contains(idx)
                {
                    AxisValueLabel(StatsView.weekdayLabels[idx - 1])
                }
            }
        }
    }

    // MARK: - Recent Prompts

    // Cap the visible feed at 20 even though UsageStats keeps up to 50 — any
    // more rows and the section dominates the window.
    private var recentPromptsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stats.recentPrompts.prefix(20), id: \.self) { prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stats.prettyName(prompt.projectDir))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(prompt.date, format: .relative(presentation: .numeric))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(prompt.snippet)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }
}
