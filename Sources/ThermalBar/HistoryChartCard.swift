import Foundation
import SwiftUI
import ThermalBarCore

struct HistoryChartCard: View {
    let store: ThermalStore

    @AppStorage("thermalbar.historyWindow.v1") private var selectedWindowRawValue = HistoryWindow.tenMinutes.rawValue


    var body: some View {
        let prepared = preparedHistory

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Thermal history", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Temperature + fan response")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Picker("History window", selection: Binding(
                    get: { selectedWindow },
                    set: { selectedWindowRawValue = $0.rawValue }
                )) {
                    ForEach(HistoryWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .accessibilityLabel("History window")
            }

            if prepared.visibleHistory.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Collecting readings…")
                        .font(.system(size: 11, weight: .semibold))
                        Text("The selected window will fill as Fantastic Thermal runs.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 178)
                .background(plotBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                historyPlot(prepared)
                .frame(height: 178)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Temperature and fan history")
                .accessibilityValue(prepared.accessibilitySummary)
            }

            HStack(spacing: 8) {
                HistoryLegendItem(color: .orange, title: "Primary °C")
                HistoryLegendItem(color: .red, title: "Peak °C")
                if prepared.hasBatteryHistory {
                    HistoryLegendItem(color: .green, title: "Battery °C")
                }
                if prepared.hasFanHistory {
                    HistoryLegendItem(color: .blue, title: "Fan 1 %", isDashed: true)
                }
                if prepared.hasSecondFan {
                    HistoryLegendItem(color: .purple, title: "Fan 2 %", isDashed: true)
                }
            }
            .lineLimit(1)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                Text(prepared.coverageLabel)
                Spacer(minLength: 8)
                Text("2s samples")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func historyPlot(_ prepared: PreparedHistory) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                VStack {
                    ForEach(0..<5) { index in
                        let value = prepared.temperatureDomain.upperBound - Double(index) *
                            (prepared.temperatureDomain.upperBound - prepared.temperatureDomain.lowerBound) / 4
                        Text("\(Int(value.rounded()))°")
                        if index < 4 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 29, alignment: .trailing)

                Canvas { context, size in
                    var grid = Path()
                    for index in 0..<5 {
                        let y = size.height * Double(index) / 4
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)
                    let duration = prepared.timeDomain.upperBound.timeIntervalSince(prepared.timeDomain.lowerBound)
                    let span = prepared.temperatureDomain.upperBound - prepared.temperatureDomain.lowerBound
                    func draw(_ value: (ThermalHistoryPoint) -> Double?, color: Color,
                              dash: [CGFloat] = [], fan: Bool = false) {
                        let indices = PlotSampling.extremaIndices(in: prepared.visibleHistory, maximumPoints: 600, value: value)
                        var path = Path()
                        var connected = false
                        var previousDate: Date?
                        for index in indices {
                            let sample = prepared.visibleHistory[index]
                            guard let value = value(sample) else { connected = false; continue }
                            let x = sample.timestamp.timeIntervalSince(prepared.timeDomain.lowerBound) / duration * size.width
                            let normalized = fan ? value / 100 : (value - prepared.temperatureDomain.lowerBound) / span
                            let point = CGPoint(x: x, y: (1 - min(1, max(0, normalized))) * size.height)
                            // Break at sleep / unavailable intervals instead of inventing a ramp.
                            if let previousDate, sample.timestamp.timeIntervalSince(previousDate) > max(10, duration / 50) {
                                connected = false
                            }
                            if connected { path.addLine(to: point) } else { path.move(to: point) }
                            connected = true
                            previousDate = sample.timestamp
                        }
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dash))
                    }
                    draw({ $0.primaryTemperatureC }, color: .orange)
                    draw({ $0.shouldShowHottestLine ? $0.hottestTemperatureC : nil }, color: .red, dash: [4, 3])
                    draw({ $0.batteryTemperatureC }, color: .green, dash: [2, 3])
                    draw({ $0.fans.first?.currentPercent }, color: .blue, dash: [5, 3], fan: true)
                    if prepared.hasSecondFan {
                        draw({ $0.fans.count > 1 ? $0.fans[1].currentPercent : nil }, color: .purple, dash: [1, 3], fan: true)
                    }
                }
                .clipped()

                VStack {
                    ForEach(0..<5) { index in
                        Text("\(100 - index * 25)")
                        if index < 4 { Spacer(minLength: 0) }
                    }
                }
                .foregroundStyle(.blue)
                .opacity(prepared.hasFanHistory ? 1 : 0)
                .frame(width: 22, alignment: .leading)
            }
            HStack {
                Text(prepared.timeDomain.lowerBound, format: .dateTime.hour().minute())
                Spacer()
                Text(prepared.timeDomain.upperBound, format: .dateTime.hour().minute())
            }
            .padding(.leading, 33)
            .padding(.trailing, 26)
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .background(plotBackground)
    }

    private var selectedWindow: HistoryWindow {
        HistoryWindow(rawValue: selectedWindowRawValue) ?? .tenMinutes
    }

    private var preparedHistory: PreparedHistory {
        guard let latest = store.history.last else { return .empty }

        let cutoff = latest.timestamp.addingTimeInterval(-selectedWindow.duration)
        let windowStart = lowerBound(in: store.history, for: cutoff)
        let windowedHistory = store.history[windowStart...]
        let visibleHistory = windowedHistory

        let timeDomain: ClosedRange<Date>
        if let first = visibleHistory.first?.timestamp,
           let last = visibleHistory.last?.timestamp,
           first < last {
            timeDomain = first...last
        } else {
            let now = Date()
            timeDomain = now...now.addingTimeInterval(1)
        }

        var minimum = Double.infinity
        var maximum = -Double.infinity
        for point in visibleHistory {
            if let value = point.primaryTemperatureC { minimum = min(minimum, value); maximum = max(maximum, value) }
            if let value = point.hottestTemperatureC { minimum = min(minimum, value); maximum = max(maximum, value) }
            if let value = point.batteryTemperatureC { minimum = min(minimum, value); maximum = max(maximum, value) }
        }
        if !minimum.isFinite { minimum = 30; maximum = 90 }
        let lower = floor((minimum - 4) / 5) * 5
        let upper = max(lower + 15, ceil((maximum + 4) / 5) * 5)
        let temperatureDomain = lower...upper

        let seconds = windowedHistory.first.flatMap { first in
            windowedHistory.last.map { max(0, $0.timestamp.timeIntervalSince(first.timestamp)) }
        }
        let coverageLabel: String
        if let seconds {
            if seconds < 60 {
                coverageLabel = "Last \(max(1, Int(seconds.rounded())))s"
            } else if seconds < 3_600 {
                coverageLabel = "Last \(max(1, Int((seconds / 60).rounded())))m"
            } else {
                coverageLabel = "Last \(max(1, Int((seconds / 3_600).rounded())))h"
            }
        } else {
            coverageLabel = "Waiting for data"
        }

        let latestPoint = visibleHistory.last
        let temperature = latestPoint?.primaryTemperatureC.map {
            "primary temperature \(Int($0.rounded())) degrees Celsius"
        } ?? "no primary temperature"
        let fan = latestPoint?.fans.first.map {
            "fan 1 \(Int($0.currentPercent.rounded())) percent"
        } ?? "no fan readings"

        var hasFanHistory = false
        var hasSecondFan = false
        var hasBatteryHistory = false
        for point in visibleHistory {
            hasFanHistory = hasFanHistory || !point.fans.isEmpty
            hasSecondFan = hasSecondFan || point.fans.count > 1
            hasBatteryHistory = hasBatteryHistory || point.batteryTemperatureC != nil
            if hasFanHistory && hasSecondFan && hasBatteryHistory { break }
        }

        return PreparedHistory(
            visibleHistory: visibleHistory,
            timeDomain: timeDomain,
            temperatureDomain: temperatureDomain,
            hasFanHistory: hasFanHistory,
            hasSecondFan: hasSecondFan,
            hasBatteryHistory: hasBatteryHistory,
            coverageLabel: coverageLabel,
            accessibilitySummary: "\(coverageLabel). Latest: \(temperature), \(fan)"
        )
    }

    private func lowerBound(
        in values: ArraySlice<ThermalHistoryPoint>,
        for timestamp: Date
    ) -> ArraySlice<ThermalHistoryPoint>.Index {
        var lower = values.startIndex
        var upper = values.endIndex

        while lower < upper {
            let distance = values.distance(from: lower, to: upper)
            let middle = values.index(lower, offsetBy: distance / 2)
            if values[middle].timestamp < timestamp {
                lower = values.index(after: middle)
            } else {
                upper = middle
            }
        }
        return lower
    }

    private var plotBackground: Color {
        Color.primary.opacity(0.035)
    }

    private struct PreparedHistory {
        let visibleHistory: ArraySlice<ThermalHistoryPoint>
        let timeDomain: ClosedRange<Date>
        let temperatureDomain: ClosedRange<Double>
        let hasFanHistory: Bool
        let hasSecondFan: Bool
        let hasBatteryHistory: Bool
        let coverageLabel: String
        let accessibilitySummary: String

        static var empty: PreparedHistory {
            let now = Date()
            return PreparedHistory(
                visibleHistory: [],
                timeDomain: now...now.addingTimeInterval(1),
                temperatureDomain: 30...90,
                hasFanHistory: false,
                hasSecondFan: false,
                hasBatteryHistory: false,
                coverageLabel: "Waiting for data",
                accessibilitySummary: "No readings yet"
            )
        }
    }
}

private enum HistoryWindow: String, CaseIterable, Identifiable {
    case tenMinutes = "10m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case threeHours = "3h"
    case sixHours = "6h"

    var id: String { rawValue }

    var title: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .threeHours: 3 * 60 * 60
        case .sixHours: 6 * 60 * 60
        }
    }
}

private struct HistoryLegendItem: View {
    let color: Color
    let title: String
    var isDashed = false

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: isDashed ? 10 : 7, height: 3)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
