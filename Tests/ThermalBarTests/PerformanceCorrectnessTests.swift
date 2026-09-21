import XCTest
@testable import ThermalBarCore

final class PerformanceCorrectnessTests: XCTestCase {
    func testFixedWidthSMCDecoding() {
        func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
            bytes.withUnsafeBytes { SMCNumber.decode(type: type, bytes: $0) }
        }
        XCTAssertEqual(decode("sp78", [0x2a, 0x80]), 42.5)
        XCTAssertEqual(decode("sp78", [0xff, 0x80]), -0.5)
        XCTAssertEqual(decode("fpe2", [0x1f, 0x40]), 2000)
        XCTAssertEqual(decode("flt ", [0, 0, 0x28, 0x42]), 42)
        XCTAssertEqual(decode("ui16", [0x12, 0x34]), 4660)
        XCTAssertNil(decode("flt ", [0, 0, 0x80, 0x7f])) // infinity
        XCTAssertNil(decode("flt ", [0, 0, 0xc0, 0x7f])) // NaN
        XCTAssertNil(decode("sp78", [42]))
        XCTAssertNil(decode("ui8 ", [1, 2]))
        XCTAssertNil(decode("abcd", [1, 2]))
    }

    func testDownsamplingRetainsNarrowSpikesAndEndpoints() {
        var values = Array(repeating: 40.0, count: 10_800)
        values[431] = 105
        values[9173] = -5
        let result = PlotSampling.extremaIndices(in: values, maximumPoints: 600, value: { $0 })
        XCTAssertLessThanOrEqual(result.count, 600)
        XCTAssertEqual(result.first, 0)
        XCTAssertEqual(result.last, 10799)
        XCTAssertTrue(result.contains(431))
        XCTAssertTrue(result.contains(9173))
        XCTAssertEqual(result, result.sorted())
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testDownsamplingSupportsNonzeroSliceIndicesAndEmptyInputs() {
        let values = Array(0..<1000).map(Double.init)
        let slice = values[300..<900]
        let result = PlotSampling.extremaIndices(in: slice, maximumPoints: 40, value: { $0 })
        XCTAssertEqual(result.first, 300)
        XCTAssertEqual(result.last, 899)
        XCTAssertLessThanOrEqual(result.count, 40)
        XCTAssertEqual(PlotSampling.extremaIndices(in: [Double](), maximumPoints: 600, value: { $0 }), [])
        XCTAssertEqual(PlotSampling.extremaIndices(in: [1.0, 2], maximumPoints: 600, value: { $0 }), [0, 1])
    }
}

private actor RecordingFanClient: FanControlClient {
    var writes: [[HelperFanTarget]] = []
    var heartbeats = 0
    var releases = 0
    var failWrite = false
    var failRelease = false

    func verifyConnection() async throws { heartbeats += 1 }
    func renewLease(targets: [HelperFanTarget]) async throws { heartbeats += 1 }
    func setTargetRPMs(_ targets: [HelperFanTarget]) async throws {
        writes.append(targets)
        if failWrite { throw HelperClientError.rejected("simulated partial failure") }
    }
    func restoreAutomatic(fanID: Int, endManualSession: Bool) async throws {}
    func releaseManualSession() async throws {
        releases += 1
        if failRelease { throw HelperClientError.timedOut }
    }
    func failures(write: Bool = false, release: Bool = false) { failWrite = write; failRelease = release }
    func counts() -> [Int] { [writes.count, heartbeats, releases] }
}

final class HardwareControlTests: XCTestCase, @unchecked Sendable {
    func testAutoPlusCooldownRenewsLeaseWithoutRepeatingWrites() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        let profile = ControlProfile(mode: .autoPlus)
        _ = try await controller.apply(profile: profile, snapshot: snapshot(rpm: 5000),
            decision: TriggerDecision(targetPercent: 100, matchedRuleIDs: []), now: 0)
        for second in stride(from: 2, through: 26, by: 2) {
            let applied = try await controller.apply(profile: profile, snapshot: snapshot(rpm: 5000),
                decision: TriggerDecision(targetPercent: 0, matchedRuleIDs: []), now: Double(second))
            XCTAssertEqual(applied.targets.first?.targetRPM, 5000)
        }
        let counts = await client.counts()
        XCTAssertEqual(counts, [1, 13, 0])
        let cooled = try await controller.apply(profile: profile, snapshot: snapshot(rpm: 5000),
            decision: TriggerDecision(targetPercent: 0, matchedRuleIDs: []), now: 28)
        XCTAssertEqual(cooled.targets.first?.targetRPM, 4800)
    }

    func testFixedModeAndAutoReleaseBypassCoolingHold() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        _ = try await controller.apply(profile: ControlProfile(mode: .autoPlus), snapshot: snapshot(),
            decision: TriggerDecision(targetPercent: 100, matchedRuleIDs: []), now: 0)
        let fixed = try await controller.apply(profile: ControlProfile(mode: .fixed, fixedPercent: 0),
            snapshot: snapshot(), decision: decision, now: 1)
        XCTAssertEqual(fixed.targets.first?.targetRPM, 1000)
        let auto = try await controller.apply(profile: ControlProfile(mode: .automatic),
            snapshot: snapshot(), decision: decision, now: 2)
        XCTAssertTrue(auto.targets.isEmpty)
        let counts = await client.counts()
        XCTAssertEqual(counts[2], 1)
    }

    func testProfileChangeAndRecoveryResetCoolingHistory() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        var profile = ControlProfile(mode: .autoPlus)
        let high = TriggerDecision(targetPercent: 100, matchedRuleIDs: [])
        let low = TriggerDecision(targetPercent: 0, matchedRuleIDs: [])
        _ = try await controller.apply(profile: profile, snapshot: snapshot(), decision: high, now: 0)
        profile.triggers = []
        let edited = try await controller.apply(profile: profile, snapshot: snapshot(), decision: low, now: 1)
        XCTAssertEqual(edited.targets.first?.targetRPM, 1000)
        _ = try await controller.apply(profile: profile, snapshot: snapshot(), decision: high, now: 2)
        await controller.restoreAll()
        let recovered = try await controller.apply(profile: profile, snapshot: snapshot(), decision: low, now: 3)
        XCTAssertEqual(recovered.targets.first?.targetRPM, 1000)
    }

    func testFailedAutoPlusWriteDoesNotLeavePhantomHighTarget() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        let profile = ControlProfile(mode: .autoPlus)
        await client.failures(write: true)
        do {
            _ = try await controller.apply(profile: profile, snapshot: snapshot(),
                decision: TriggerDecision(targetPercent: 100, matchedRuleIDs: []), now: 0)
            XCTFail("Expected write failure")
        } catch {}
        await client.failures()
        let recovered = try await controller.apply(profile: profile, snapshot: snapshot(),
            decision: TriggerDecision(targetPercent: 0, matchedRuleIDs: []), now: 2)
        XCTAssertEqual(recovered.targets.first?.targetRPM, 1000)
    }

    private let decision = TriggerDecision(targetPercent: 40, matchedRuleIDs: [])
    private func snapshot(mode: FanMode = .manual, rpm: Int = 2600) -> HardwareSnapshot {
        HardwareSnapshot(fans: [FanReading(id: 0, name: "Test fan", currentRPM: rpm, targetRPM: rpm,
                                          minimumRPM: 1000, maximumRPM: 5000, mode: mode)], isAvailable: true)
    }

    func testStableTargetsRenewLeaseWithoutRepeatingHardwareWrites() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        let configuration = ThermalConfiguration(mode: .fixed, fixedPercent: 40)
        _ = try await controller.apply(configuration: configuration, snapshot: snapshot(), decision: decision)
        _ = try await controller.apply(configuration: configuration, snapshot: snapshot(), decision: decision)
        let counts = await client.counts()
        XCTAssertEqual(counts, [1, 1, 0])
    }

    func testWakeOrFirmwareResetReappliesUnchangedDesiredTarget() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        let configuration = ThermalConfiguration(mode: .fixed, fixedPercent: 40)
        _ = try await controller.apply(configuration: configuration, snapshot: snapshot(), decision: decision)
        _ = try await controller.apply(configuration: configuration, snapshot: snapshot(mode: .automatic), decision: decision)
        _ = try await controller.apply(configuration: configuration, snapshot: snapshot(rpm: 1000), decision: decision)
        let counts = await client.counts()
        XCTAssertEqual(counts[0], 3)
    }

    func testAutoReleasesOnceAndIdleControllerDoesNotContactHelper() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        await controller.restoreAll()
        var counts = await client.counts()
        XCTAssertEqual(counts, [0, 0, 0])
        _ = try await controller.apply(configuration: ThermalConfiguration(mode: .fixed), snapshot: snapshot(), decision: decision)
        for _ in 0..<3 {
            _ = try await controller.apply(configuration: ThermalConfiguration(mode: .automatic), snapshot: snapshot(), decision: decision)
        }
        counts = await client.counts()
        XCTAssertEqual(counts[2], 1)
    }

    func testFailedRestoreRemainsOwnedAndIsRetried() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        _ = try await controller.apply(configuration: ThermalConfiguration(mode: .fixed), snapshot: snapshot(), decision: decision)
        await client.failures(release: true)
        await controller.restoreAll()
        await client.failures()
        await controller.restoreAll()
        await controller.restoreAll()
        let counts = await client.counts()
        XCTAssertEqual(counts[2], 2)
    }

    func testPartialWriteFailureReleasesBeforeRetry() async throws {
        let client = RecordingFanClient()
        let controller = HardwareController(controlClient: client)
        await client.failures(write: true)
        do {
            _ = try await controller.apply(configuration: ThermalConfiguration(mode: .fixed), snapshot: snapshot(), decision: decision)
            XCTFail("Expected write failure")
        } catch {}
        let counts = await client.counts()
        XCTAssertEqual(counts, [1, 0, 1])
    }
}

final class FanOwnershipJournalTests: XCTestCase {
    func testCrashRecoveryRemembersOnlyOwnedFans() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = FanOwnershipJournal(url: folder.appendingPathComponent("fans.json"))
        XCTAssertEqual(try journal.load(), [])
        try journal.save([0, 1])
        let restartedJournal = FanOwnershipJournal(url: journal.url)
        XCTAssertEqual(try restartedJournal.load(), [0, 1])
        try restartedJournal.save([1])
        XCTAssertEqual(try journal.load(), [1])
        try journal.save([])
        XCTAssertEqual(try restartedJournal.load(), [])
    }

    func testInvalidJournalCannotProduceAnOutOfRangeFanID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = FanOwnershipJournal(url: url)
        XCTAssertThrowsError(try journal.save([-1]))
        try Data("[99]".utf8).write(to: url)
        XCTAssertThrowsError(try journal.load())
    }
}

final class ProfileValidationTests: XCTestCase {
    func testCorruptRangesAreBoundedAndDuplicateRulesAreRemoved() {
        let rule = TriggerRule(sensorKey: "TEST", sensorName: "Test", thresholdC: 1e200,
                               upperTemperatureC: -1e200, startPercent: -1e200,
                               targetPercent: 1e200, hysteresisC: 1e200)
        let result = ThermalConfiguration(fixedPercent: .infinity, triggers: [rule, rule]).normalized
        XCTAssertEqual(result.fixedPercent, 40)
        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertEqual(result.triggers[0].thresholdC, 105)
        XCTAssertEqual(result.triggers[0].upperTemperatureC, 106)
        XCTAssertEqual(result.triggers[0].startPercent, 0)
        XCTAssertEqual(result.triggers[0].targetPercent, 100)
        XCTAssertEqual(result.triggers[0].hysteresisC, 10)
    }

    func testInvalidAndDuplicateSensorReadingsDoNotCrashTriggerEvaluation() {
        let rule = TriggerRule(sensorKey: "TEST", sensorName: "Test", thresholdC: 70, targetPercent: 80)
        var engine = TriggerEngine()
        let reading = TemperatureReading(id: "TEST", name: "Test", kind: .cpu, celsius: 90)
        XCTAssertEqual(engine.evaluate(rules: [rule], temperatures: [reading, reading]).targetPercent, 80)
        XCTAssertEqual(engine.evaluate(rules: [rule], temperatures: [TemperatureReading(id: "TEST", name: "Test", kind: .cpu, celsius: .nan)]).targetPercent, 0)
        XCTAssertEqual(engine.evaluate(rules: [], temperatures: [reading]).matchedRuleIDs, [])
    }
}
