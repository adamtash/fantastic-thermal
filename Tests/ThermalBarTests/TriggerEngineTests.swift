import XCTest
@testable import ThermalBarCore

final class TriggerEngineTests: XCTestCase {
    func testRuleActivatesAtThresholdAndClearsWithHysteresis() {
        let rule = TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU",
            thresholdC: 70,
            upperTemperatureC: 85,
            startPercent: 20,
            targetPercent: 55,
            hysteresisC: 3
        )
        var engine = TriggerEngine()

        let below = engine.evaluate(
            rules: [rule],
            temperatures: [reading(key: "TC0P", value: 69)]
        )
        XCTAssertEqual(below.targetPercent, 0)
        XCTAssertTrue(below.matchedRuleIDs.isEmpty)

        let active = engine.evaluate(
            rules: [rule],
            temperatures: [reading(key: "TC0P", value: 70)]
        )
        XCTAssertEqual(active.targetPercent, 20)
        XCTAssertEqual(active.matchedRuleIDs, [rule.id])

        let stillActive = engine.evaluate(
            rules: [rule],
            temperatures: [reading(key: "TC0P", value: 68)]
        )
        XCTAssertEqual(stillActive.targetPercent, 20)

        let cleared = engine.evaluate(
            rules: [rule],
            temperatures: [reading(key: "TC0P", value: 66.9)]
        )
        XCTAssertEqual(cleared.targetPercent, 0)
        XCTAssertTrue(cleared.matchedRuleIDs.isEmpty)
    }

    func testStrongestActiveRuleWinsAcrossSensors() {
        let cpu = TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU",
            thresholdC: 65,
            upperTemperatureC: 80,
            startPercent: 20,
            targetPercent: 40
        )
        let battery = TriggerRule(
            sensorKey: "TB0T",
            sensorName: "Battery",
            thresholdC: 40,
            upperTemperatureC: 55,
            startPercent: 20,
            targetPercent: 65
        )
        var engine = TriggerEngine()

        let result = engine.evaluate(
            rules: [cpu, battery],
            temperatures: [
                reading(key: "TC0P", value: 80),
                reading(key: "TB0T", value: 55)
            ]
        )

        XCTAssertEqual(result.targetPercent, 65)
        XCTAssertEqual(result.matchedRuleIDs, [cpu.id, battery.id])
    }

    func testRuleInterpolatesBetweenStartAndUpperTemperature() {
        let rule = TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU",
            thresholdC: 70,
            upperTemperatureC: 90,
            startPercent: 24,
            targetPercent: 72
        )
        var engine = TriggerEngine()

        XCTAssertEqual(
            engine.evaluate(rules: [rule], temperatures: [reading(key: "TC0P", value: 70)]).targetPercent,
            24
        )
        XCTAssertEqual(
            engine.evaluate(rules: [rule], temperatures: [reading(key: "TC0P", value: 80)]).targetPercent,
            48
        )
        XCTAssertEqual(
            engine.evaluate(rules: [rule], temperatures: [reading(key: "TC0P", value: 95)]).targetPercent,
            72
        )
    }

    func testMultipleCurvesUseHighestCalculatedRequestInsteadOfAdding() {
        let cpu = TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU",
            thresholdC: 60,
            upperTemperatureC: 90,
            startPercent: 20,
            targetPercent: 80
        )
        let battery = TriggerRule(
            sensorKey: "TB0T",
            sensorName: "Battery",
            thresholdC: 35,
            upperTemperatureC: 45,
            startPercent: 10,
            targetPercent: 90
        )
        var engine = TriggerEngine()

        let result = engine.evaluate(
            rules: [cpu, battery],
            temperatures: [
                reading(key: "TC0P", value: 75),
                reading(key: "TB0T", value: 40)
            ]
        )

        XCTAssertEqual(result.targetPercent, 50, accuracy: 0.001)
        XCTAssertNotEqual(result.targetPercent, 100)
        XCTAssertEqual(result.matchedRuleIDs, [cpu.id, battery.id])
    }

    func testLegacyStepRuleDecodesToSmoothRamp() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "sensorKey": "TB0T",
              "sensorName": "Battery",
              "thresholdC": 42,
              "targetPercent": 56
            }
            """.utf8
        )

        let rule = try JSONDecoder().decode(TriggerRule.self, from: data)

        XCTAssertEqual(rule.upperTemperatureC, 57)
        XCTAssertEqual(rule.startPercent, 20)
        XCTAssertEqual(rule.curve, .linear)
        XCTAssertEqual(rule.percent(at: 42), 20)
        XCTAssertEqual(rule.percent(at: 57), 56)
    }

    func testParabolicRampIsGentlerAtMidpoint() {
        let rule = TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU",
            thresholdC: 70,
            upperTemperatureC: 90,
            startPercent: 20,
            targetPercent: 80,
            curve: .parabolic
        )

        XCTAssertEqual(rule.percent(at: 70), 20, accuracy: 0.001)
        XCTAssertEqual(rule.percent(at: 80), 35, accuracy: 0.001)
        XCTAssertEqual(rule.percent(at: 90), 80, accuracy: 0.001)
    }

    func testMissingSensorDoesNotActivateRule() {
        let rule = TriggerRule(
            sensorKey: "TB0T",
            sensorName: "Battery",
            thresholdC: 40,
            targetPercent: 65
        )
        var engine = TriggerEngine()

        let result = engine.evaluate(
            rules: [rule],
            temperatures: [reading(key: "TC0P", value: 80)]
        )

        XCTAssertEqual(result.targetPercent, 0)
        XCTAssertTrue(result.matchedRuleIDs.isEmpty)
    }

    func testAutoPlusNeverDropsBelowObservedAutomaticFloor() {
        let fan = FanReading(
            id: 0,
            name: "Fan",
            currentRPM: 2_000,
            targetRPM: 2_000,
            minimumRPM: 1_500,
            maximumRPM: 5_000,
            mode: .manual
        )

        XCTAssertEqual(fan.targetRPM(forPercent: 0, floorRPM: 2_000), 2_000)
        XCTAssertGreaterThanOrEqual(fan.targetRPM(forPercent: 25, floorRPM: 3_800), 3_800)
        XCTAssertEqual(fan.targetRPM(forPercent: 100, floorRPM: 9_000), 5_000)
    }

    private func reading(key: String, value: Double) -> TemperatureReading {
        TemperatureReading(id: key, name: key, kind: .other, celsius: value)
    }
}
