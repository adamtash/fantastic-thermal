import XCTest
@testable import ThermalBarCore

final class ConfigurationPersistenceTests: XCTestCase {
    func testConfigurationRoundTripsEveryUserSetting() throws {
        let rule = TriggerRule(
            sensorKey: "TB0T",
            sensorName: "Battery",
            thresholdC: 43,
            upperTemperatureC: 54,
            startPercent: 26,
            targetPercent: 78,
            curve: .parabolic,
            hysteresisC: 3,
            isEnabled: false
        )
        let original = ThermalConfiguration(
            mode: .autoPlus,
            fixedPercent: 63,
            triggers: [rule],
            selectedSensorKey: "TB0T"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ThermalConfiguration.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.mode, .autoPlus)
        XCTAssertEqual(restored.fixedPercent, 63)
        XCTAssertEqual(restored.triggers.first?.curve, .parabolic)
        XCTAssertEqual(restored.selectedSensorKey, "TB0T")
    }

    func testHelperHealthCheckRoundTripsAsANoOpRequest() throws {
        let request = HelperRequest(action: .healthCheck)
        let data = try JSONEncoder().encode(request)
        let restored = try JSONDecoder().decode(HelperRequest.self, from: data)

        XCTAssertEqual(restored.action, .healthCheck)
        XCTAssertNil(restored.fan)
        XCTAssertNil(restored.targetRPM)
    }
}
