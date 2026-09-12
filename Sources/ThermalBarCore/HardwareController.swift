import Foundation

public struct AppliedFanTarget: Equatable, Sendable {
    public let fanID: Int
    public let targetRPM: Int
    public let floorRPM: Int?

    public init(fanID: Int, targetRPM: Int, floorRPM: Int? = nil) {
        self.fanID = fanID
        self.targetRPM = targetRPM
        self.floorRPM = floorRPM
    }
}

public struct AppliedControl: Equatable, Sendable {
    public let mode: ControlMode
    public let targets: [AppliedFanTarget]

    public init(mode: ControlMode, targets: [AppliedFanTarget]) {
        self.mode = mode
        self.targets = targets
    }
}

/// Owns one serialized connection to AppleSMC and remembers the last system
/// targets observed while fans were in Auto. That snapshot is the floor used by
/// Auto+ once the app temporarily takes over.
public actor HardwareController {
    private var client: SMCClient?
    private let helperClient: (any FanControlClient)?
    private var lastAutoFloorRPM: [Int: Int] = [:]
    private var appliedTargets: [Int: Int] = [:]

    public init(usePrivilegedHelper: Bool = true) {
        helperClient = usePrivilegedHelper ? PrivilegedHelperClient() : nil
    }

    public init(controlClient: any FanControlClient) {
        helperClient = controlClient
    }

    public func verifyHelper() async throws {
        guard let helperClient else {
            throw HelperClientError.unavailable("Privileged helper is not configured")
        }
        try await helperClient.verifyConnection()
    }

    public func snapshot() throws -> HardwareSnapshot {
        let snapshot = try connectedClient().snapshot()

        for fan in snapshot.fans where fan.mode == .automatic || fan.mode == .system {
            let observed = max(fan.minimumRPM, fan.targetRPM ?? fan.currentRPM)
            lastAutoFloorRPM[fan.id] = observed
        }

        return snapshot
    }

    public func apply(
        configuration: ThermalConfiguration,
        snapshot: HardwareSnapshot,
        decision: TriggerDecision
    ) async throws -> AppliedControl {
        guard !snapshot.fans.isEmpty else { throw ThermalBarError.noFans }
        var targets: [AppliedFanTarget] = []

        switch configuration.mode {
        case .automatic:
            if !appliedTargets.isEmpty {
                try await releaseManualSession()
                appliedTargets.removeAll()
            }

        case .fixed, .autoPlus:
            var pendingTargets: [HelperFanTarget] = []
            pendingTargets.reserveCapacity(snapshot.fans.count)

            for fan in snapshot.fans {
                let requestedPercent: Double
                let floorRPM: Int?
                switch configuration.mode {
                case .fixed:
                    requestedPercent = configuration.fixedPercent
                    floorRPM = nil
                case .autoPlus:
                    requestedPercent = decision.targetPercent
                    floorRPM = lastAutoFloorRPM[fan.id] ?? fan.minimumRPM
                case .automatic:
                    requestedPercent = 0
                    floorRPM = nil
                }

                let targetRPM = fan.targetRPM(forPercent: requestedPercent, floorRPM: floorRPM)

                if appliedTargets[fan.id] != targetRPM || fan.mode != .manual ||
                    fan.targetRPM.map({ abs($0 - targetRPM) > 80 }) == true {
                    pendingTargets.append(HelperFanTarget(fan: fan, targetRPM: targetRPM))
                }
                targets.append(AppliedFanTarget(fanID: fan.id, targetRPM: targetRPM, floorRPM: floorRPM))
            }

            // Keep the watchdog lease alive even when no RPM write is needed.
            // A successful heartbeat is cheap and does not touch SMC.
            do {
                if pendingTargets.isEmpty {
                    let leaseTargets = zip(snapshot.fans, targets).map { fan, target in
                        HelperFanTarget(fan: fan, targetRPM: target.targetRPM)
                    }
                    try await helperClient?.renewLease(targets: leaseTargets)
                } else {
                    // Track all attempts so partial failure can be restored.
                    for target in pendingTargets { appliedTargets[target.fan.id] = target.targetRPM }
                    try await setTargetRPMs(pendingTargets)
                }
            } catch {
                do {
                    try await releaseManualSession()
                    appliedTargets.removeAll()
                } catch { /* Keep ownership for the next restore attempt. */ }
                throw error
            }
            for target in pendingTargets {
                appliedTargets[target.fan.id] = target.targetRPM
            }
        }

        return AppliedControl(mode: configuration.mode, targets: targets)
    }

    public func restoreAll() async {
        guard !appliedTargets.isEmpty else { return }
        do {
            try await releaseManualSession()
            appliedTargets.removeAll()
        } catch {
            // Preserve ownership for a later retry. The helper's lease also
            // expires independently if the app can no longer reach it.
        }
    }

    /// Emergency/local-development release path used when a fresh controller
    /// needs to hand back fans that may have been left manual by a prior run.
    /// The app itself normally uses restoreAll(), which only releases fans it
    /// explicitly claimed.
    public func restoreDetectedFans() async -> [String] {
        guard let smc = client else { return ["AppleSMC is not connected"] }
        guard let detected = try? smc.snapshot().fans else { return ["Could not read the current fan state"] }
        let fanIDs = Array(Set(appliedTargets.keys).union(
            detected.filter { $0.mode == .manual }.map(\.id)
        )).sorted()
        var errors: [String] = []
        for fanID in fanIDs {
            do {
                try await restoreAutomatic(
                    fanID: fanID,
                    endManualSession: fanID == fanIDs.last
                )
            } catch {
                errors.append("fan \(fanID + 1): \(String(describing: error))")
            }
        }
        try? await releaseManualSession()
        appliedTargets.removeAll()
        return errors
    }

    private func connectedClient() throws -> SMCClient {
        if let client { return client }
        let newClient = try SMCClient()
        client = newClient
        return newClient
    }

    private func setTargetRPMs(_ targets: [HelperFanTarget]) async throws {
        guard !targets.isEmpty else { return }
        if let helperClient {
            try await helperClient.setTargetRPMs(targets)
        } else {
            let smc = try connectedClient()
            for target in targets { try smc.setTargetRPM(target.targetRPM, fan: target.fan) }
        }
    }

    private func restoreAutomatic(fanID: Int, endManualSession: Bool) async throws {
        if let helperClient {
            try await helperClient.restoreAutomatic(fanID: fanID, endManualSession: endManualSession)
        } else {
            try connectedClient().restoreAutomatic(fanID: fanID, endManualSession: endManualSession)
        }
    }

    private func releaseManualSession() async throws {
        if let helperClient {
            try await helperClient.releaseManualSession()
        } else {
            for fanID in appliedTargets.keys {
                try connectedClient().restoreAutomatic(fanID: fanID, endManualSession: true)
            }
            client?.releaseManualSession()
        }
    }
}
