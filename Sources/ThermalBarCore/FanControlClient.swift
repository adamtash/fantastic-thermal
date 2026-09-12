import Foundation

/// The hardware policy can be verified without changing a real Mac's fans.
public protocol FanControlClient: Sendable {
    func verifyConnection() async throws
    func renewLease(targets: [HelperFanTarget]) async throws
    func setTargetRPMs(_ targets: [HelperFanTarget]) async throws
    func restoreAutomatic(fanID: Int, endManualSession: Bool) async throws
    func releaseManualSession() async throws
}
