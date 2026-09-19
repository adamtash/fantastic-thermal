import SwiftUI
import ThermalBarCore

struct FanOutputRow: View {
    let fan: FanReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(fanColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Fan \(fan.id + 1)")
                        .font(.system(size: 11, weight: .semibold))
                    Text(fan.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: fan.currentPercent, total: 100)
                    .progressViewStyle(.linear)
                    .tint(fanColor)
                    .controlSize(.small)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(fan.currentRPM.formatted())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(rangeLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fanColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan \(fan.id + 1), \(fan.name)")
        .accessibilityValue(accessibilityValue)
    }

    private var fanColor: Color {
        fan.id == 0 ? .blue : .purple
    }

    private var isStopped: Bool {
        fan.currentRPM < max(1, fan.minimumRPM / 2)
    }

    private var rangeLabel: String {
        isStopped ? "Stopped" : "\(Int(fan.currentPercent.rounded()))% of range"
    }

    private var accessibilityValue: String {
        isStopped
            ? "Stopped, \(fan.currentRPM) RPM"
            : "\(fan.currentRPM) RPM, \(Int(fan.currentPercent.rounded())) percent of range"
    }
}
