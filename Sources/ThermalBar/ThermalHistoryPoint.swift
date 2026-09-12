import Foundation
import ThermalBarCore

struct ThermalHistoryPoint: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let primaryTemperatureC: Double?
    let hottestTemperatureC: Double?
    let batteryTemperatureC: Double?
    let fans: [FanReading]

    var id: Date { timestamp }

    init(snapshot: HardwareSnapshot, selectedSensorKey: String?) {
        timestamp = snapshot.timestamp

        var firstTemperature: Double?
        var firstCPUTemperature: Double?
        var selectedTemperature: Double?
        var hottestTemperature: Double?
        var batteryTemperature: Double?

        for reading in snapshot.temperatures {
            firstTemperature = firstTemperature ?? reading.celsius
            if firstCPUTemperature == nil, reading.kind == .cpu {
                firstCPUTemperature = reading.celsius
            }
            if selectedTemperature == nil, reading.id == selectedSensorKey {
                selectedTemperature = reading.celsius
            }
            if hottestTemperature == nil || reading.celsius > hottestTemperature! {
                hottestTemperature = reading.celsius
            }
            if batteryTemperature == nil, reading.kind == .battery {
                batteryTemperature = reading.celsius
            }
        }

        primaryTemperatureC = selectedTemperature ?? firstCPUTemperature ?? firstTemperature
        hottestTemperatureC = hottestTemperature
        batteryTemperatureC = batteryTemperature
        fans = snapshot.fans
    }

    var shouldShowHottestLine: Bool {
        guard let primaryTemperatureC, let hottestTemperatureC else { return false }
        return abs(primaryTemperatureC - hottestTemperatureC) >= 0.5
    }

}

extension ThermalHistoryPoint {
    static var previewSamples: [ThermalHistoryPoint] {
        let now = Date()

        return (0..<48).map { index in
            let phase = Double(index) / 7.0
            let cpu = 68 + sin(phase) * 4 + (index > 28 ? 4 : 0)
            let battery = 38 + sin(phase / 2) * 1.5
            let fanPercent = min(88, max(24, 28 + (cpu - 66) * 4))
            let fans = [
                FanReading(
                    id: 0,
                    name: "Left fan",
                    currentRPM: rpm(for: fanPercent, minimum: 1_700, maximum: 5_500),
                    targetRPM: rpm(for: fanPercent + 4, minimum: 1_700, maximum: 5_500),
                    minimumRPM: 1_700,
                    maximumRPM: 5_500,
                    mode: .manual
                ),
                FanReading(
                    id: 1,
                    name: "Right fan",
                    currentRPM: rpm(for: max(20, fanPercent - 3), minimum: 1_700, maximum: 5_500),
                    targetRPM: rpm(for: fanPercent, minimum: 1_700, maximum: 5_500),
                    minimumRPM: 1_700,
                    maximumRPM: 5_500,
                    mode: .manual
                )
            ]
            let snapshot = HardwareSnapshot(
                timestamp: now.addingTimeInterval(Double(index - 47) * 2),
                fans: fans,
                temperatures: [
                    TemperatureReading(id: "TC0P", name: "CPU proximity", kind: .cpu, celsius: cpu),
                    TemperatureReading(id: "TG0P", name: "GPU proximity", kind: .gpu, celsius: cpu - 7),
                    TemperatureReading(id: "TB0T", name: "Battery", kind: .battery, celsius: battery)
                ],
                isAvailable: true
            )
            return ThermalHistoryPoint(snapshot: snapshot, selectedSensorKey: "TC0P")
        }
    }

    private static func rpm(for percent: Double, minimum: Int, maximum: Int) -> Int {
        Int((Double(minimum) + (percent / 100) * Double(maximum - minimum)).rounded())
    }
}
