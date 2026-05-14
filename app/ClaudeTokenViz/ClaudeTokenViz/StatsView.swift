import Charts
import SwiftUI

struct StatsView: View {
    let stats: UsageStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily Activity")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(stats.totalMessages.formatted()) msgs · \(stats.projectCount) projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if stats.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning ~/.claude/projects/…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if dailySeries.isEmpty {
                Text("No timestamped messages yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timelineChart
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 460)
    }

    // Sorted (date, count) pairs across every observed day.
    private var dailySeries: [(date: Date, count: Int)] {
        stats.messagesByDay
            .map { (date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // Top 3 days by message count -- used to annotate peaks on the chart.
    private var peakDays: [(date: Date, count: Int)] {
        dailySeries
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
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
            AxisMarks(values: .stride(by: .month)) { value in
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
}
