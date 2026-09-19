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
            adapterProfile: ControlProfile(mode: .autoPlus, fixedPercent: 63, triggers: [rule]),
            batteryProfile: ControlProfile(mode: .automatic, fixedPercent: 27, triggers: []),
            usesSeparatePowerProfiles: true,
            selectedSensorKey: "TB0T"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ThermalConfiguration.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.mode, .autoPlus)
        XCTAssertEqual(restored.fixedPercent, 63)
        XCTAssertEqual(restored.triggers.first?.curve, .parabolic)
        XCTAssertEqual(restored.selectedSensorKey, "TB0T")
        XCTAssertTrue(restored.usesSeparatePowerProfiles)
        XCTAssertEqual(restored.batteryProfile.mode, .automatic)
        XCTAssertEqual(restored.batteryProfile.fixedPercent, 27)
    }

    func testLegacyConfigurationMigratesToAdapterProfile() throws {
        let data = Data(
            #"{"mode":"fixed","fixedPercent":35,"triggers":[],"selectedSensorKey":"TC0P"}"#.utf8
        )

        let restored = try JSONDecoder().decode(ThermalConfiguration.self, from: data)

        XCTAssertEqual(restored.adapterProfile.mode, .fixed)
        XCTAssertEqual(restored.adapterProfile.fixedPercent, 35)
        XCTAssertEqual(restored.batteryProfile.mode, .automatic)
        XCTAssertFalse(restored.usesSeparatePowerProfiles)
        XCTAssertEqual(restored.selectedSensorKey, "TC0P")
    }

    func testPowerSourceMapsUPSOutagesToBatteryProfile() {
        XCTAssertEqual(PowerSource.adapter.profileKind, .adapter)
        XCTAssertEqual(PowerSource.battery.profileKind, .battery)
        XCTAssertEqual(PowerSource.ups.profileKind, .battery)
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
