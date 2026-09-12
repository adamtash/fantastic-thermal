import Foundation

public let thermalBarHelperMachService = "com.thermalbar.app.helper"
public let thermalBarHelperProtocolVersion = 2

@objc public protocol ThermalBarHelperXPC {
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public enum HelperAction: String, Codable, Sendable {
    case healthCheck
    case renewLease
    case setTarget
    case setTargets
    case restoreAutomatic
    case releaseManualSession
}

public struct HelperFanTarget: Codable, Sendable {
    public let fan: FanReading
    public let targetRPM: Int

    public init(fan: FanReading, targetRPM: Int) {
        self.fan = fan
        self.targetRPM = targetRPM
    }
}

public struct HelperRequest: Codable, Sendable {
    public let action: HelperAction
    public let fan: FanReading?
    public let targetRPM: Int?
    public let targets: [HelperFanTarget]?
    public let endManualSession: Bool

    public init(
        action: HelperAction,
        fan: FanReading? = nil,
        targetRPM: Int? = nil,
        targets: [HelperFanTarget]? = nil,
        endManualSession: Bool = true
    ) {
        self.action = action
        self.fan = fan
        self.targetRPM = targetRPM
        self.targets = targets
        self.endManualSession = endManualSession
    }
}

public struct HelperResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let error: String?

    public init(protocolVersion: Int = thermalBarHelperProtocolVersion, error: String? = nil) {
        self.protocolVersion = protocolVersion
        self.error = error
    }
}

public enum HelperClientError: LocalizedError, Sendable {
    case unavailable(String)
    case rejected(String)
    case invalidResponse
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Privileged helper unavailable: \(detail)"
        case .rejected(let detail):
            detail
        case .invalidResponse:
            "Privileged helper returned an invalid response."
        case .timedOut:
            "Privileged helper did not respond in time."
        }
    }
}
