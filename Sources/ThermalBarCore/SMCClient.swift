import Foundation
import IOKit

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// The 80-byte request/response structure used by Apple's private SMC user
/// client. The layout is intentionally kept here rather than hiding it behind
/// a third-party dependency so the app can probe newer key spellings safely.
private struct SMCParamStruct {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    let key: String
    let type: String
    let size: Int
    let bytes: [UInt8]
}

/// Read-only information used by the development probe when validating new
/// AppleSMC firmware layouts. It is intentionally separate from write APIs.
public struct SMCKeyDiagnostic: Sendable {
    public let key: String
    public let type: String
    public let size: Int
    public let bytesHex: String
    public let numericValue: Double?

    public init(key: String, type: String, size: Int, bytesHex: String, numericValue: Double?) {
        self.key = key
        self.type = type
        self.size = size
        self.bytesHex = bytesHex
        self.numericValue = numericValue
    }
}

private struct SMCKeyInfo {
    let code: UInt32
    let type: String
    let size: Int
}

private struct FanMetadata {
    let id: Int
    let name: String
    let minimumRPM: Int
    let maximumRPM: Int
    let modeKey: String?
}

private struct TemperatureMetadata {
    let key: String
    let name: String
    let kind: SensorKind
}

/// Direct AppleSMC access, serialized by HardwareController's actor.
///
/// Reads are useful for monitoring. Writes are intentionally narrow: the
/// controller only calls them after clamping to firmware-reported fan bounds.
public final class SMCClient {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: SMCKeyInfo] = [:]
    private var missingKeys: Set<String> = []
    private var temperatureKeys: [String] = []
    private var temperatureMetadata: [TemperatureMetadata] = []
    private var fanMetadataCache: [FanMetadata]?
    private var fanModeKeyCache: [Int: String] = [:]
    private var hasDiscoveredKeys = false

    public init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw ThermalBarError.smcUnavailable
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == kIOReturnNotPrivileged || result == kIOReturnNotPermitted {
            throw ThermalBarError.accessDenied
        }
        guard result == kIOReturnSuccess else {
            throw ThermalBarError.ioFailure("Open AppleSMC", UInt32(bitPattern: result))
        }

        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            IOServiceClose(connection)
            connection = 0
            throw ThermalBarError.writeRejected("SMC communication structure size mismatch")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    public func snapshot() throws -> HardwareSnapshot {
        try discoverKeysIfNeeded()

        let fans = readFans()
        let readings = temperatureMetadata.compactMap { metadata -> TemperatureReading? in
            guard let value = try? readNumeric(metadata.key), value.isFinite, value > -20, value < 140 else {
                return nil
            }
            return TemperatureReading(
                id: metadata.key,
                name: metadata.name,
                kind: metadata.kind,
                celsius: value
            )
        }

        return HardwareSnapshot(
            fans: fans,
            temperatures: readings,
            isAvailable: true,
            statusMessage: fans.isEmpty ? "No controllable fans detected; monitoring only." : nil
        )
    }

    public func diagnostics(for keys: [String]) -> [SMCKeyDiagnostic] {
        keys.compactMap { key in
            guard let value = try? read(key) else { return nil }
            return SMCKeyDiagnostic(
                key: key,
                type: value.type,
                size: value.size,
                bytesHex: value.bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
                numericValue: decode(value)
            )
        }
    }

    public func setTargetRPM(_ rpm: Int, fan: FanReading) throws {
        let fan = try validateTargetRPM(rpm, fanID: fan.id)

        let targetKey = "F\(fan.id)Tg"
        let targetInfo = try keyInfo(targetKey)

        // Intel/T2 machines expose one global bitmask. The target write must
        // happen before claiming the individual fan bit.
        if let forceInfo = try? keyInfo("FS! ") {
            try write(targetKey, bytes: encode(number: Double(rpm), type: targetInfo.type, size: targetInfo.size))
            var mask = (try? unsignedInteger("FS! ")) ?? 0
            mask |= UInt64(1 << fan.id)
            try write("FS! ", bytes: encode(unsigned: mask, size: forceInfo.size))
            return
        }

        guard let modeKey = fanModeKey(for: fan.id) else {
            throw ThermalBarError.manualModeUnavailable(fan.id)
        }

        try enableManualMode(modeKey: modeKey, fanID: fan.id)
        try write(targetKey, bytes: encode(number: Double(rpm), type: targetInfo.type, size: targetInfo.size))

        // Firmware applies target values asynchronously. A read-back catches
        // a silently rejected write without treating a transient lag as fatal.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            if let readBack = try? readNumeric(targetKey), abs(readBack - Double(rpm)) <= 80 {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ContinuousClock.now < deadline
        throw ThermalBarError.writeRejected("fan \(fan.id + 1) did not accept the requested target")
    }

    /// Verify caller input without changing hardware state.
    public func validateTargetRPM(_ rpm: Int, fanID: Int) throws -> FanReading {
        let fan = try validatedFan(id: fanID)
        guard rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else {
            throw ThermalBarError.unsafeSpeed(requested: rpm, minimum: fan.minimumRPM, maximum: fan.maximumRPM)
        }
        return fan
    }

    public func restoreAutomatic(fanID: Int, endManualSession: Bool) throws {
        _ = try validatedFan(id: fanID)
        if let forceInfo = try? keyInfo("FS! ") {
            var mask = (try? unsignedInteger("FS! ")) ?? 0
            mask &= ~UInt64(1 << fanID)
            try write("FS! ", bytes: encode(unsigned: mask, size: forceInfo.size))
            return
        }

        guard let modeKey = fanModeKey(for: fanID) else {
            throw ThermalBarError.manualModeUnavailable(fanID)
        }

        if endManualSession, let forceInfo = try? keyInfo("Ftst") {
            // On Apple Silicon, ending Ftst first gives thermalmonitord back
            // its arbitration before the per-fan mode byte is cleared.
            try write("Ftst", bytes: encode(unsigned: 0, size: forceInfo.size))
        }
        try writeUnsigned(0, key: modeKey)
    }

    public func releaseManualSession() {
        guard let info = try? keyInfo("Ftst") else { return }
        try? write("Ftst", bytes: encode(unsigned: 0, size: info.size))
    }

    private func readFans() -> [FanReading] {
        guard let count = try? intValue("FNum"), count > 0, count < 16 else { return [] }
        let metadata = fanMetadata(for: count)

        return metadata.compactMap { fan in
            guard let current = try? intValue("F\(fan.id)Ac") else { return nil }
            let target = try? intValue("F\(fan.id)Tg")
            return FanReading(
                id: fan.id,
                name: fan.name,
                currentRPM: current,
                targetRPM: target,
                minimumRPM: fan.minimumRPM,
                maximumRPM: fan.maximumRPM,
                mode: fanMode(for: fan.modeKey, fanID: fan.id)
            )
        }
    }

    private func validatedFan(id: Int) throws -> FanReading {
        guard (0..<16).contains(id),
              let count = try? intValue("FNum"), count > id, count < 16,
              let metadata = fanMetadata(for: count).first(where: { $0.id == id }) else {
            throw ThermalBarError.writeRejected("Unknown fan identifier")
        }
        return FanReading(id: id, name: metadata.name, currentRPM: 0,
                          targetRPM: nil, minimumRPM: metadata.minimumRPM,
                          maximumRPM: metadata.maximumRPM, mode: .unknown)
    }

    private func fanMetadata(for count: Int) -> [FanMetadata] {
        if let cached = fanMetadataCache, cached.count == count {
            return cached
        }

        let metadata = (0..<count).compactMap { index -> FanMetadata? in
            guard
                let minimum = try? intValue("F\(index)Mn"),
                let maximum = try? intValue("F\(index)Mx"),
                minimum >= 0, maximum >= minimum, maximum > 0, maximum < 100_000
            else { return nil }

            let name = ((try? fanName(index)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return FanMetadata(
                id: index,
                name: name.isEmpty ? "Fan \(index + 1)" : name,
                minimumRPM: max(0, minimum),
                maximumRPM: max(minimum, maximum),
                modeKey: fanModeKey(for: index)
            )
        }

        if metadata.count == count {
            fanMetadataCache = metadata
        }
        return metadata
    }

    private func discoverKeysIfNeeded() throws {
        guard !hasDiscoveredKeys else { return }
        hasDiscoveredKeys = true

        guard let count = try? intValue("#KEY"), count > 0, count < 10_000 else {
            temperatureKeys = Self.fallbackTemperatureKeys
            rebuildTemperatureMetadata()
            return
        }

        var candidateKeys: [String] = []
        candidateKeys.reserveCapacity(64)
        for index in 0..<count {
            // Most keys are unrelated to temperature. Avoid a second kernel
            // round trip and a permanent cache entry for every unrelated key.
            guard let key = try? keyFromIndex(index), Self.isTemperatureKey(key),
                  let info = try? keyInfo(key) else { continue }
            if Self.isNumericTemperatureType(info.type) {
                candidateKeys.append(key)
            }
        }

        let candidateKeySet = Set(candidateKeys)
        let preferred = Self.fallbackTemperatureKeys.filter { candidateKeySet.contains($0) }
        let preferredKeySet = Set(preferred)
        let additional = candidateKeys
            .filter { !preferredKeySet.contains($0) }
            .sorted()
            .prefix(32)
        temperatureKeys = preferred + additional
        rebuildTemperatureMetadata()
    }

    private func rebuildTemperatureMetadata() {
        temperatureMetadata = temperatureKeys
            .map { key in
                TemperatureMetadata(
                    key: key,
                    name: Self.sensorName(for: key),
                    kind: Self.sensorKind(for: key)
                )
            }
            .sorted { lhs, rhs in
                let leftRank = Self.sensorRank(lhs.kind)
                let rightRank = Self.sensorRank(rhs.kind)
                if leftRank == rightRank { return lhs.key < rhs.key }
                return leftRank < rightRank
            }
    }

    private func fanMode(for modeKey: String?, fanID: Int) -> FanMode {
        if let mask = try? unsignedInteger("FS! ") {
            return mask & (UInt64(1) << fanID) == 0 ? .automatic : .manual
        }
        guard let modeKey, let raw = try? unsignedInteger(modeKey) else {
            return .unknown
        }
        switch raw {
        case 0: return .automatic
        case 1: return .manual
        case 3: return .system
        default: return .unknown
        }
    }

    private func fanModeKey(for index: Int) -> String? {
        if let cached = fanModeKeyCache[index] {
            return cached.isEmpty ? nil : cached
        }

        let key = ["F\(index)Md", "F\(index)md"].first { (try? keyInfo($0)) != nil }
        fanModeKeyCache[index] = key ?? ""
        return key
    }

    private func enableManualMode(modeKey: String, fanID: Int) throws {
        do {
            try writeUnsigned(1, key: modeKey)
            if try intValue(modeKey) == 1 { return }
        } catch {
            guard (try? keyInfo("Ftst")) != nil else { throw error }
        }

        // A successful write can still be overridden by thermalmonitord.
        // Confirm the mode byte and request arbitration when necessary.
        if let forceInfo = try? keyInfo("Ftst") {
            try write("Ftst", bytes: encode(unsigned: 1, size: forceInfo.size))
        }

        // Newer Apple Silicon firmware can require thermalmonitord to yield
        // after Ftst is asserted. Keep this bounded and fail closed.
        Thread.sleep(forTimeInterval: 0.35)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            do {
                try writeUnsigned(1, key: modeKey)
                if try intValue(modeKey) == 1 { return }
            } catch { /* Retry only during the bounded arbitration window. */ }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ThermalBarError.manualModeTimeout(fanID)
    }

    private func fanName(_ index: Int) throws -> String {
        let value = try read("F\(index)ID")
        guard value.bytes.count > 4 else { return "" }
        return String(bytes: value.bytes.dropFirst(4).prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private func intValue(_ key: String) throws -> Int {
        let number = try readNumeric(key).rounded()
        guard number >= Double(Int.min), number < Double(Int.max) else {
            throw ThermalBarError.malformedValue(key)
        }
        return Int(number)
    }

    private func unsignedInteger(_ key: String) throws -> UInt64 {
        let value = try read(key)
        return value.bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func keyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        if missingKeys.contains(key) { throw ThermalBarError.keyNotFound(key) }
        var input = SMCParamStruct()
        input.key = try fourCharCode(key)
        input.data8 = 9
        let output: SMCParamStruct
        do {
            output = try call(&input)
        } catch ThermalBarError.keyNotFound {
            missingKeys.insert(key)
            throw ThermalBarError.keyNotFound(key)
        }
        let info = SMCKeyInfo(
            code: input.key,
            type: string(from: output.keyInfo.dataType),
            size: Int(output.keyInfo.dataSize)
        )
        guard info.size > 0, info.size <= 32 else {
            throw ThermalBarError.malformedValue(key)
        }
        keyInfoCache[key] = info
        return info
    }

    private func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = info.code
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = 5
        let output = try call(&input)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCValue(key: key, type: info.type, size: info.size, bytes: bytes)
    }

    private func readNumeric(_ key: String) throws -> Double {
        // Polling decodes directly from the fixed 32-byte SMC response on the
        // stack; diagnostics alone need to allocate a byte array.
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = info.code
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = 5
        let output = try call(&input)
        let number = withUnsafeBytes(of: output.bytes) {
            SMCNumber.decode(type: info.type, bytes: UnsafeRawBufferPointer(rebasing: $0.prefix(info.size)))
        }
        guard let number, number.isFinite else {
            throw ThermalBarError.malformedValue(key)
        }
        return number
    }

    private func writeUnsigned(_ value: UInt64, key: String) throws {
        let info = try keyInfo(key)
        try write(key, bytes: encode(unsigned: value, size: info.size))
    }

    private func write(_ key: String, bytes: [UInt8]) throws {
        guard bytes.count <= 32 else { throw ThermalBarError.malformedValue(key) }
        var input = SMCParamStruct()
        if let cachedInfo = keyInfoCache[key] {
            input.key = cachedInfo.code
        } else {
            input.key = try fourCharCode(key)
        }
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        _ = try call(&input)
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        if result == kIOReturnNotPrivileged || result == kIOReturnNotPermitted {
            throw ThermalBarError.accessDenied
        }
        guard result == kIOReturnSuccess else {
            throw ThermalBarError.ioFailure("Access AppleSMC", UInt32(bitPattern: result))
        }
        guard outputSize == MemoryLayout<SMCParamStruct>.stride else {
            throw ThermalBarError.malformedValue(string(from: input.key))
        }
        if output.result == 132 {
            throw ThermalBarError.keyNotFound(string(from: input.key))
        }
        guard output.result == 0 else {
            throw ThermalBarError.writeRejected("SMC returned status \(output.result)")
        }
        return output
    }

    private func keyFromIndex(_ index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = 8
        input.data32 = UInt32(index)
        let output = try call(&input)
        return string(from: output.key)
    }

    private func decode(_ value: SMCValue) -> Double? {
        value.bytes.withUnsafeBytes { SMCNumber.decode(type: value.type, bytes: $0) }
    }

    private func encode(number: Double, type: String, size: Int) -> [UInt8] {
        switch type {
        case "flt ":
            let bits = Float(number).bitPattern
            return (0..<min(size, 4)).map { offset in UInt8((bits >> UInt32(offset * 8)) & 0xff) }
        case "fpe2":
            let raw = UInt16(max(0, min(Double(UInt16.max >> 2), number)).rounded()) << 2
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            return encode(unsigned: UInt64(max(0, number).rounded()), size: size)
        }
    }

    private func encode(unsigned: UInt64, size: Int) -> [UInt8] {
        (0..<size).map { offset in
            UInt8((unsigned >> UInt64((size - offset - 1) * 8)) & 0xff)
        }
    }

    private func fourCharCode(_ value: String) throws -> UInt32 {
        let bytes = Array(value.utf8)
        guard bytes.count == 4 else { throw ThermalBarError.invalidKey(value) }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(from code: UInt32) -> String {
        String(bytes: [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ], encoding: .ascii) ?? "????"
    }

    private static let fallbackTemperatureKeys = [
        "TC0P", "TC0D", "TC0F", "Tp0C", "Tp09", "Te0S",
        "TG0P", "TG0D", "Tg0C",
        "TB0T", "TB1T", "TB2T", "TB3T",
        "TW0P", "Ts0P", "TA0P", "Ta09", "Tm0P", "TH0P",
        "TPMP", "TPSP", "TIOP", "TDBP"
    ]

    private static func isNumericTemperatureType(_ type: String) -> Bool {
        ["sp78", "flt ", "fpe2", "ui8 ", "ui16", "ui32"].contains(type)
    }

    private static func isTemperatureKey(_ key: String) -> Bool {
        guard key.count == 4 else { return false }
        let prefixes = ["TA", "Ta", "TB", "TC", "TD", "TE", "Te", "TG", "Tg", "TH", "Th", "TI", "Tm", "TM", "TP", "Tp", "TS", "Ts", "TW", "TV", "TIO", "TDB"]
        return prefixes.contains { key.hasPrefix($0) }
    }

    private static func sensorKind(for key: String) -> SensorKind {
        if key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("TG") || key.hasPrefix("Tg") { return .gpu }
        if key.hasPrefix("TC") || key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
        if key.hasPrefix("TA") || key.hasPrefix("Ta") { return .ambient }
        if key.hasPrefix("TS") || key.hasPrefix("Ts") || key.hasPrefix("TH") || key.hasPrefix("Th") {
            return key.hasPrefix("TH") || key.hasPrefix("Th") ? .storage : .enclosure
        }
        if key.hasPrefix("TW") || key.hasPrefix("TM") || key.hasPrefix("Tm") || key.hasPrefix("TDB") {
            return .enclosure
        }
        return .other
    }

    private static func sensorName(for key: String) -> String {
        if let knownName = knownSensorNames[key] { return knownName }
        return "\(sensorKind(for: key).title) · \(key)"
    }

    private static let knownSensorNames: [String: String] = [
            "TC0P": "CPU proximity",
            "TC0D": "CPU diode",
            "TC0F": "CPU die",
            "Tp0C": "Performance cores",
            "Tp09": "SoC hotspot",
            "Te0S": "Efficiency cores",
            "TG0P": "GPU proximity",
            "TG0D": "GPU diode",
            "Tg0C": "GPU cores",
            "TB0T": "Battery",
            "TB1T": "Battery cell 2",
            "TB2T": "Battery cell 3",
            "TB3T": "Battery cell 4",
            "TW0P": "Wireless",
            "Ts0P": "Palm rest",
            "TA0P": "Ambient",
            "Ta09": "Ambient external",
            "Tm0P": "Mainboard",
            "TH0P": "Storage",
            "TPMP": "SoC package",
            "TPSP": "SoC surface",
            "TIOP": "Thunderbolt",
            "TDBP": "Display"
        ]

    private static func sensorRank(_ kind: SensorKind) -> Int {
        switch kind {
        case .cpu: return 0
        case .gpu: return 1
        case .battery: return 2
        case .enclosure: return 3
        case .storage: return 4
        case .ambient: return 5
        case .other: return 6
        }
    }
}
