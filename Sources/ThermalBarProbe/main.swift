import Foundation
import ThermalBarCore

let controller = HardwareController()

if CommandLine.arguments.contains("--benchmark") {
    let clock = ContinuousClock()
    let start = clock.now
    let first = try await controller.snapshot()
    let cold = start.duration(to: clock.now)
    var samples: [Double] = []
    for _ in 0..<100 {
        let tick = clock.now
        _ = try await controller.snapshot()
        let elapsed = tick.duration(to: clock.now).components
        samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }
    samples.sort()
    print("Cold discovery: \(cold)")
    print("Warm snapshot median: \(samples[50]) ms; p95: \(samples[95]) ms")
    print("Sensors: \(first.temperatures.count); fans: \(first.fans.count)")
    exit(0)
}

do {
    if CommandLine.arguments.contains("--helper-test") {
        do {
            try await PrivilegedHelperClient().releaseManualSession()
            print("Privileged helper request succeeded.")
        } catch {
            print("Privileged helper request failed: \(String(describing: error))")
        }
    }
    let snapshot = try await controller.snapshot()
    if CommandLine.arguments.contains("--restore") {
        let errors = await controller.restoreDetectedFans()
        if errors.isEmpty {
            print("Requested automatic mode for all detected manual fans.")
        } else {
            print("Restore errors: \(errors.joined(separator: "; "))")
        }
        let after = try await controller.snapshot()
        print("Fan modes after restore:", after.fans.map { "fan \($0.id + 1)=\($0.mode.rawValue)" }.joined(separator: ", "))
        exit(0)
    }
    print("AppleSMC available: \(snapshot.isAvailable)")
    print("Fans: \(snapshot.fans.count)")
    for fan in snapshot.fans {
        print("  fan \(fan.id + 1): \(fan.name), current=\(fan.currentRPM) rpm, range=\(fan.minimumRPM)-\(fan.maximumRPM), mode=\(fan.mode.rawValue)")
    }
    print("Temperatures: \(snapshot.temperatures.count)")
    for sensor in snapshot.temperatures.prefix(24) {
        print("  \(sensor.id)  \(sensor.name): \(String(format: "%.1f", sensor.celsius))°C")
    }
    if CommandLine.arguments.contains("--diagnostics") {
        let smc = try SMCClient()
        let keys = ["FS! ", "Ftst", "F0Md", "F0md", "F1Md", "F1md", "F0Tg", "F1Tg"]
        print("SMC fan-control diagnostics:")
        for diagnostic in smc.diagnostics(for: keys) {
            let numeric = diagnostic.numericValue.map { String(format: "%.3f", $0) } ?? "—"
            print("  \(diagnostic.key.debugDescription): type=\(diagnostic.type), size=\(diagnostic.size), bytes=[\(diagnostic.bytesHex)], numeric=\(numeric)")
        }
    }
    if let message = snapshot.statusMessage {
        print("Status: \(message)")
    }
} catch {
    print("ThermalBar probe failed: \(error.localizedDescription)")
    exit(1)
}
