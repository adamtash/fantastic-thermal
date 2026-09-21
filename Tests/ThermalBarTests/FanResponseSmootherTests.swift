import XCTest
@testable import ThermalBarCore

final class FanResponseSmootherTests: XCTestCase {
    func testHeatingIsImmediateEvenDuringCooldown() {
        var response = FanResponseSmoother()
        XCTAssertEqual(response.target(for: 30, at: 0), 30)
        XCTAssertEqual(response.target(for: 80, at: 2), 80)
        XCTAssertEqual(response.target(for: 40, at: 4), 80)
        XCTAssertEqual(response.target(for: 100, at: 6), 100)
    }

    func testSustainedCoolingHoldsThenDecreasesGraduallyToMinimum() {
        var response = FanResponseSmoother()
        _ = response.target(for: 100, at: 0)
        var previous = 100.0
        var lastDecrease = -Double.infinity
        for second in stride(from: 2, through: 160, by: 2) {
            let output = response.target(for: 0, at: Double(second))
            if second < 27 { XCTAssertEqual(output, 100) }
            XCTAssertLessThanOrEqual(output, previous)
            XCTAssertLessThanOrEqual(previous - output, 5)
            if output < previous {
                XCTAssertGreaterThanOrEqual(Double(second) - lastDecrease, 5)
                lastDecrease = Double(second)
            }
            previous = output
        }
        XCTAssertEqual(previous, 0)
    }

    func testRepeatedHotCoolTemperatureCyclesDoNotPumpFanTargets() {
        let rule = TriggerRule(sensorKey: "CPU", sensorName: "CPU", thresholdC: 70,
                               upperTemperatureC: 90, startPercent: 0, targetPercent: 100)
        var engine = TriggerEngine()
        var response = FanResponseSmoother()
        for second in stride(from: 0, through: 120, by: 2) {
            let temperature = second % 12 < 4 ? 90.0 : 65.0
            let decision = engine.evaluate(rules: [rule], temperatures: [
                TemperatureReading(id: "CPU", name: "CPU", kind: .cpu, celsius: temperature)
            ])
            XCTAssertEqual(response.target(for: decision.targetPercent, at: Double(second)), 100)
        }
    }

    func testReheatingBelowHeldSpeedRestartsCooldown() {
        var response = FanResponseSmoother()
        _ = response.target(for: 100, at: 0)
        for second in stride(from: 2, through: 26, by: 2) {
            _ = response.target(for: 20, at: Double(second))
        }
        XCTAssertEqual(response.target(for: 40, at: 28), 100)
        for second in stride(from: 30, through: 52, by: 2) {
            XCTAssertEqual(response.target(for: 40, at: Double(second)), 100)
        }
        XCTAssertEqual(response.target(for: 40, at: 54), 95)
    }

    func testSmallDownwardNoiseDoesNotWriteNewTargets() {
        var response = FanResponseSmoother()
        _ = response.target(for: 50, at: 0)
        for second in 1...100 {
            XCTAssertEqual(response.target(for: second % 2 == 0 ? 49.3 : 49.8,
                                           at: Double(second)), 50)
        }
        XCTAssertEqual(response.target(for: 50.1, at: 101), 50.1)
    }

    func testCallFrequencyDoesNotAccelerateRamp() {
        var response = FanResponseSmoother()
        _ = response.target(for: 100, at: 0)
        _ = response.target(for: 0, at: 1)
        for tick in 11...1000 {
            let now = Double(tick) / 10
            let output = response.target(for: 0, at: now)
            let maximumDrop = max(0, floor((now - 21) / 5)) * 5
            XCTAssertEqual(output, 100 - maximumDrop, accuracy: 0.001)
        }
    }

    func testLongPauseAndClockResetDoNotCauseCatchUpDrop() {
        var response = FanResponseSmoother()
        _ = response.target(for: 100, at: 0)
        for second in stride(from: 2, through: 28, by: 2) {
            _ = response.target(for: 0, at: Double(second))
        }
        XCTAssertEqual(response.target(for: 0, at: 3_600), 95)
        XCTAssertEqual(response.target(for: 0, at: 1), 95)
        XCTAssertEqual(response.target(for: 100, at: 2), 100)
    }

    func testInvalidDemandRequestsMaximumAndTargetsStayBounded() {
        var response = FanResponseSmoother()
        XCTAssertEqual(response.target(for: -10, at: 0), 0)
        XCTAssertEqual(response.target(for: .nan, at: 1), 100)
        XCTAssertEqual(response.target(for: .infinity, at: 2), 100)
        XCTAssertEqual(response.target(for: 200, at: 3), 100)
    }
}
