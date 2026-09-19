import Foundation

public enum ControlMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case autoPlus
    case fixed

    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .autoPlus: "Auto+"
        case .fixed: "Fixed"
        }
    }

}

public enum PowerProfileKind: String, Codable, CaseIterable, Sendable {
    case adapter
    case battery

    public var title: String {
        switch self {
        case .adapter: "Power Adapter"
        case .battery: "Battery"
        }
    }
}

public enum SensorKind: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
    case battery
    case enclosure
    case storage
    case ambient
    case other

    public var title: String {
        switch self {
        case .cpu: "CPU / SoC"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .enclosure: "Enclosure"
        case .storage: "Storage"
        case .ambient: "Ambient"
        case .other: "Other"
        }
    }

    public var iconName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .battery: "battery.75percent"
        case .enclosure: "macbook.and.iphone"
        case .storage: "internaldrive"
        case .ambient: "thermometer.sun"
        case .other: "waveform.path.ecg"
        }
    }
}

public struct TemperatureReading: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: SensorKind
    public var celsius: Double

    public init(id: String, name: String, kind: SensorKind, celsius: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.celsius = celsius
    }
}

public enum FanMode: String, Codable, Sendable {
    case automatic
    case manual
    case system
    case unknown
}

public struct FanReading: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let currentRPM: Int
    public let targetRPM: Int?
    public let minimumRPM: Int
    public let maximumRPM: Int
    public let mode: FanMode

    public init(
        id: Int,
        name: String,
        currentRPM: Int,
        targetRPM: Int?,
        minimumRPM: Int,
        maximumRPM: Int,
        mode: FanMode
    ) {
        self.id = id
        self.name = name
        self.currentRPM = currentRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.mode = mode
    }

    public var currentPercent: Double {
        guard maximumRPM > minimumRPM else { return 0 }
        return min(100, max(0, Double(currentRPM - minimumRPM) / Double(maximumRPM - minimumRPM) * 100))
    }

    public func rpm(forPercent percent: Double) -> Int {
        let bounded = min(100, max(0, percent)) / 100
        let value = Double(minimumRPM) + bounded * Double(maximumRPM - minimumRPM)
        return Int(value.rounded())
    }

    public func targetRPM(forPercent percent: Double, floorRPM: Int? = nil) -> Int {
        return min(
            maximumRPM,
            max(minimumRPM, max(rpm(forPercent: percent), floorRPM ?? minimumRPM))
        )
    }
}

public struct HardwareSnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let fans: [FanReading]
    public let temperatures: [TemperatureReading]
    public let isAvailable: Bool
    public let statusMessage: String?

    public init(
        timestamp: Date = .now,
        fans: [FanReading] = [],
        temperatures: [TemperatureReading] = [],
        isAvailable: Bool,
        statusMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.fans = fans
        self.temperatures = temperatures
        self.isAvailable = isAvailable
        self.statusMessage = statusMessage
    }

    public static let unavailable = HardwareSnapshot(
        isAvailable: false,
        statusMessage: "AppleSMC is unavailable on this Mac."
    )
}

public enum TriggerCurve: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case linear
    case parabolic

    public var title: String {
        switch self {
        case .linear: "Linear"
        case .parabolic: "Parabolic"
        }
    }
}

public struct TriggerRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var sensorKey: String
    public var sensorName: String
    public var thresholdC: Double
    public var upperTemperatureC: Double
    public var startPercent: Double
    public var targetPercent: Double
    public var curve: TriggerCurve
    public var hysteresisC: Double
    public var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case sensorKey
        case sensorName
        case thresholdC
        case upperTemperatureC
        case startPercent
        case targetPercent
        case curve
        case hysteresisC
        case isEnabled
    }

    public init(
        id: UUID = UUID(),
        sensorKey: String,
        sensorName: String,
        thresholdC: Double,
        upperTemperatureC: Double? = nil,
        startPercent: Double? = nil,
        targetPercent: Double,
        curve: TriggerCurve = .linear,
        hysteresisC: Double = 2,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sensorKey = sensorKey
        self.sensorName = sensorName
        self.thresholdC = thresholdC
        self.upperTemperatureC = upperTemperatureC ?? thresholdC + 15
        self.startPercent = startPercent ?? min(20, targetPercent)
        self.targetPercent = targetPercent
        self.curve = curve
        self.hysteresisC = hysteresisC
        self.isEnabled = isEnabled
    }

    /// Keeps profiles written by older builds usable. Older rules represented
    /// a step target; they become a sensible 15°C ramp on first load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sensorKey = try values.decode(String.self, forKey: .sensorKey)
        sensorName = try values.decode(String.self, forKey: .sensorName)
        thresholdC = try values.decode(Double.self, forKey: .thresholdC)
        targetPercent = try values.decode(Double.self, forKey: .targetPercent)
        upperTemperatureC = try values.decodeIfPresent(Double.self, forKey: .upperTemperatureC) ?? thresholdC + 15
        startPercent = try values.decodeIfPresent(Double.self, forKey: .startPercent) ?? min(20, targetPercent)
        curve = try values.decodeIfPresent(TriggerCurve.self, forKey: .curve) ?? .linear
        hysteresisC = try values.decodeIfPresent(Double.self, forKey: .hysteresisC) ?? 2
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public var summary: String {
        "\(Int(thresholdC.rounded()))°–\(Int(upperTemperatureC.rounded()))° · \(Int(startPercent.rounded()))→\(Int(targetPercent.rounded()))%"
    }

    /// Maps the current sensor temperature to the configured fan range using
    /// the selected curve. Values outside the range are clamped so the fan
    /// does not jump backwards when a sensor briefly overshoots or cools down.
    public func percent(at temperatureC: Double) -> Double {
        let lowerTemperature = min(thresholdC, upperTemperatureC)
        let upperTemperature = max(thresholdC, upperTemperatureC)
        guard upperTemperature > lowerTemperature else {
            return min(100, max(0, targetPercent))
        }

        let progress = min(1, max(0, (temperatureC - lowerTemperature) / (upperTemperature - lowerTemperature)))
        let shapedProgress: Double
        switch curve {
        case .linear:
            shapedProgress = progress
        case .parabolic:
            shapedProgress = progress * progress
        }
        let value = startPercent + shapedProgress * (targetPercent - startPercent)
        return min(100, max(0, value))
    }

    public static let defaults: [TriggerRule] = [
        TriggerRule(
            sensorKey: "TC0P",
            sensorName: "CPU proximity",
            thresholdC: 70,
            upperTemperatureC: 86,
            startPercent: 24,
            targetPercent: 72
        ),
        TriggerRule(
            sensorKey: "TB0T",
            sensorName: "Battery",
            thresholdC: 42,
            upperTemperatureC: 52,
            startPercent: 18,
            targetPercent: 56
        )
    ]
}

public struct ControlProfile: Codable, Equatable, Sendable {
    public var mode: ControlMode
    public var fixedPercent: Double
    public var triggers: [TriggerRule]

    public init(
        mode: ControlMode = .automatic,
        fixedPercent: Double = 40,
        triggers: [TriggerRule] = TriggerRule.defaults
    ) {
        self.mode = mode
        self.fixedPercent = fixedPercent
        self.triggers = triggers
    }
}

public struct ThermalConfiguration: Codable, Equatable, Sendable {
    public var adapterProfile: ControlProfile
    public var batteryProfile: ControlProfile
    public var usesSeparatePowerProfiles: Bool
    public var selectedSensorKey: String?

    public init(
        adapterProfile: ControlProfile,
        batteryProfile: ControlProfile = ControlProfile(),
        usesSeparatePowerProfiles: Bool = false,
        selectedSensorKey: String? = nil
    ) {
        self.adapterProfile = adapterProfile
        self.batteryProfile = batteryProfile
        self.usesSeparatePowerProfiles = usesSeparatePowerProfiles
        self.selectedSensorKey = selectedSensorKey
    }

    /// Source-compatible convenience initializer for callers and profiles
    /// written before per-power-source settings were introduced.
    public init(
        mode: ControlMode = .automatic,
        fixedPercent: Double = 40,
        triggers: [TriggerRule] = TriggerRule.defaults,
        selectedSensorKey: String? = nil
    ) {
        adapterProfile = ControlProfile(
            mode: mode,
            fixedPercent: fixedPercent,
            triggers: triggers
        )
        batteryProfile = ControlProfile(mode: .automatic)
        usesSeparatePowerProfiles = false
        self.selectedSensorKey = selectedSensorKey
    }

    public func profile(for kind: PowerProfileKind) -> ControlProfile {
        kind == .adapter ? adapterProfile : batteryProfile
    }

    public mutating func setProfile(_ profile: ControlProfile, for kind: PowerProfileKind) {
        switch kind {
        case .adapter: adapterProfile = profile
        case .battery: batteryProfile = profile
        }
    }

    /// These aliases preserve the original adapter-profile API for probes,
    /// tests, and older call sites while persisted data uses explicit profiles.
    public var mode: ControlMode {
        get { adapterProfile.mode }
        set { adapterProfile.mode = newValue }
    }

    public var fixedPercent: Double {
        get { adapterProfile.fixedPercent }
        set { adapterProfile.fixedPercent = newValue }
    }

    public var triggers: [TriggerRule] {
        get { adapterProfile.triggers }
        set { adapterProfile.triggers = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case adapterProfile
        case batteryProfile
        case usesSeparatePowerProfiles
        case selectedSensorKey
        // Legacy v1 fields.
        case mode
        case fixedPercent
        case triggers
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedSensorKey = try values.decodeIfPresent(String.self, forKey: .selectedSensorKey)
        usesSeparatePowerProfiles = try values.decodeIfPresent(Bool.self, forKey: .usesSeparatePowerProfiles) ?? false

        if let adapter = try values.decodeIfPresent(ControlProfile.self, forKey: .adapterProfile) {
            adapterProfile = adapter
            batteryProfile = try values.decodeIfPresent(ControlProfile.self, forKey: .batteryProfile)
                ?? ControlProfile(mode: .automatic)
        } else {
            adapterProfile = ControlProfile(
                mode: try values.decodeIfPresent(ControlMode.self, forKey: .mode) ?? .automatic,
                fixedPercent: try values.decodeIfPresent(Double.self, forKey: .fixedPercent) ?? 40,
                triggers: try values.decodeIfPresent([TriggerRule].self, forKey: .triggers) ?? TriggerRule.defaults
            )
            batteryProfile = ControlProfile(mode: .automatic)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(adapterProfile, forKey: .adapterProfile)
        try values.encode(batteryProfile, forKey: .batteryProfile)
        try values.encode(usesSeparatePowerProfiles, forKey: .usesSeparatePowerProfiles)
        try values.encodeIfPresent(selectedSensorKey, forKey: .selectedSensorKey)
    }
}

extension ThermalConfiguration {
    /// Bound persisted input before it reaches sliders or integer labels.
    public var normalized: ThermalConfiguration {
        var result = self
        func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        func normalize(_ profile: ControlProfile) -> ControlProfile {
            var profile = profile
            profile.fixedPercent = bounded(profile.fixedPercent, 0...100, fallback: 40)
            var seen: Set<UUID> = []
            profile.triggers = profile.triggers.prefix(32).compactMap { source in
                guard seen.insert(source.id).inserted else { return nil }
                var rule = source
                rule.thresholdC = bounded(rule.thresholdC, 25...105, fallback: 70)
                rule.upperTemperatureC = bounded(rule.upperTemperatureC, (rule.thresholdC + 1)...110, fallback: min(110, rule.thresholdC + 15))
                rule.startPercent = bounded(rule.startPercent, 0...100, fallback: 20)
                rule.targetPercent = bounded(rule.targetPercent, rule.startPercent...100, fallback: max(56, rule.startPercent))
                rule.hysteresisC = bounded(rule.hysteresisC, 0...10, fallback: 2)
                return rule
            }
            return profile
        }
        result.adapterProfile = normalize(adapterProfile)
        result.batteryProfile = normalize(batteryProfile)
        return result
    }
}

public enum QuickPreset: String, CaseIterable, Sendable {
    case quiet
    case balanced
    case cool
    case max

    public var title: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .cool: "Cool"
        case .max: "Max"
        }
    }

    public var percent: Double {
        switch self {
        case .quiet: 20
        case .balanced: 40
        case .cool: 65
        case .max: 100
        }
    }

    public var iconName: String {
        switch self {
        case .quiet: "moon.zzz.fill"
        case .balanced: "circle.lefthalf.filled"
        case .cool: "snowflake"
        case .max: "bolt.fill"
        }
    }
}

public struct TriggerDecision: Equatable, Sendable {
    public let targetPercent: Double
    public let matchedRuleIDs: Set<UUID>

    public init(targetPercent: Double, matchedRuleIDs: Set<UUID>) {
        self.targetPercent = targetPercent
        self.matchedRuleIDs = matchedRuleIDs
    }
}

/// Stateful threshold evaluation with a small amount of hysteresis so fans do
/// not constantly jump between two targets around a boundary.
public struct TriggerEngine: Sendable {
    private var activeRuleIDs: Set<UUID> = []

    public init() {}

    public mutating func reset() {
        activeRuleIDs.removeAll()
    }

    public mutating func evaluate(
        rules: [TriggerRule],
        temperatures: [TemperatureReading]
    ) -> TriggerDecision {
        var readings: [String: Double] = [:]
        readings.reserveCapacity(temperatures.count)
        for reading in temperatures where reading.celsius.isFinite { readings[reading.id] = reading.celsius }
        var nextActive: Set<UUID> = []
        var requested = 0.0
        for rule in rules {
            guard rule.isEnabled, let temperature = readings[rule.sensorKey] else { continue }
            let active = activeRuleIDs.contains(rule.id)
                ? temperature > rule.thresholdC - max(0, rule.hysteresisC)
                : temperature >= rule.thresholdC
            if active {
                nextActive.insert(rule.id)
                requested = max(requested, rule.percent(at: temperature))
            }
        }
        activeRuleIDs = nextActive
        return TriggerDecision(targetPercent: min(100, max(0, requested)), matchedRuleIDs: nextActive)
    }
}

public enum ThermalBarError: LocalizedError, Sendable {
    case smcUnavailable
    case accessDenied
    case noFans
    case invalidKey(String)
    case keyNotFound(String)
    case malformedValue(String)
    case unsafeSpeed(requested: Int, minimum: Int, maximum: Int)
    case manualModeUnavailable(Int)
    case manualModeTimeout(Int)
    case writeRejected(String)
    case ioFailure(String, UInt32)

    public var errorDescription: String? {
        switch self {
        case .smcUnavailable:
            "AppleSMC is unavailable. This Mac may be fanless or may not expose the SMC interface."
        case .accessDenied:
            "The current process cannot access AppleSMC. Fan writes may require a privileged helper."
        case .noFans:
            "No controllable fans were detected."
        case .invalidKey(let key):
            "Invalid SMC key: \(key)."
        case .keyNotFound(let key):
            "This Mac does not support SMC key \(key)."
        case .malformedValue(let key):
            "SMC key \(key) returned malformed data."
        case .unsafeSpeed(let requested, let minimum, let maximum):
            "Unsafe speed \(requested) RPM was rejected; allowed range: \(minimum)–\(maximum) RPM."
        case .manualModeUnavailable(let fan):
            "Fan \(fan + 1) has no supported manual-mode key."
        case .manualModeTimeout(let fan):
            "Timed out waiting for fan \(fan + 1) to enter manual mode."
        case .writeRejected(let detail):
            "The fan-control write was rejected: \(detail)"
        case .ioFailure(let operation, let code):
            "\(operation) failed (IOKit 0x\(String(format: "%08X", code)))."
        }
    }
}
