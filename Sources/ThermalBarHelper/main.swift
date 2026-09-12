import Foundation
import ThermalBarCore

/// One serialized hardware owner. The lease returns claimed fans to macOS
/// after a lost connection or a stalled app, without polling SMC while idle.
private final class HelperService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thermalbar.app.helper.smc", qos: .utility)
    private var activeSession: UUID?
    private var client: SMCClient?
    private let journal = FanOwnershipJournal(url: URL(fileURLWithPath: "/var/run/com.thermalbar.app.fans.json"))
    private var knownTargets: [Int: Int] = [:]
    private var controlledFans: Set<Int> = []
    private var leaseDeadline = ContinuousClock.now
    private var watchdog: DispatchSourceTimer?

    init() {
        queue.async { [self] in
            controlledFans = (try? journal.load()) ?? []
            if !controlledFans.isEmpty {
                _ = try? connectedClient()
                renewLease()
                restoreOwnedFans()
            }
        }
    }

    func perform(_ requestData: Data, session: UUID, withReply reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            guard activeSession == nil || activeSession == session else {
                reply((try? JSONEncoder().encode(HelperResponse(error: "Another app connection owns fan control"))) ?? Data())
                return
            }
            activeSession = session
            let response: HelperResponse
            do {
                guard requestData.count <= 65_536 else {
                    throw ThermalBarError.writeRejected("Request exceeds the supported size")
                }
                let request = try JSONDecoder().decode(HelperRequest.self, from: requestData)
                response = try execute(request)
            } catch {
                // A partial batch or failed mode transition must not leave a
                // previously claimed fan running an unacknowledged target.
                restoreOwnedFans()
                response = HelperResponse(error: error.localizedDescription)
            }
            let data = (try? JSONEncoder().encode(response))
                ?? Data(#"{"protocolVersion":2,"error":"Failed to encode helper response"}"#.utf8)
            reply(data)
        }
    }

    func disconnected(session: UUID) {
        queue.async { [self] in
            guard activeSession == session else { return }
            restoreOwnedFans()
            activeSession = nil
        }
    }

    private func execute(_ request: HelperRequest) throws -> HelperResponse {
        switch request.action {
        case .healthCheck:
            renewLease()
        case .setTarget:
            guard let fan = request.fan, let rpm = request.targetRPM else {
                throw ThermalBarError.writeRejected("The target request is incomplete")
            }
            try setTarget(HelperFanTarget(fan: fan, targetRPM: rpm))
        case .renewLease:
            guard let targets = request.targets, !targets.isEmpty, targets.count <= 16 else {
                throw ThermalBarError.writeRejected("The lease request is invalid")
            }
            for target in targets where knownTargets[target.fan.id] != target.targetRPM {
                // Reclaim on a new helper process or after its watchdog fired.
                try setTarget(target)
            }
            renewLease()
        case .setTargets:
            guard let targets = request.targets, !targets.isEmpty, targets.count <= 16 else {
                throw ThermalBarError.writeRejected("The target batch is invalid")
            }
            for target in targets { try setTarget(target) }
        case .restoreAutomatic:
            guard let fan = request.fan, (0..<16).contains(fan.id) else {
                throw ThermalBarError.writeRejected("The restore request is invalid")
            }
            try connectedClient().restoreAutomatic(fanID: fan.id, endManualSession: request.endManualSession)
            controlledFans.remove(fan.id)
            knownTargets.removeValue(forKey: fan.id)
            try journal.save(controlledFans)
            stopWatchdogIfIdle()
        case .releaseManualSession:
            restoreOwnedFans()
            guard controlledFans.isEmpty else {
                throw ThermalBarError.writeRejected("Some fans could not be returned to automatic control")
            }
        }
        return HelperResponse()
    }

    private func setTarget(_ target: HelperFanTarget) throws {
        guard (0..<16).contains(target.fan.id) else {
            throw ThermalBarError.writeRejected("Unknown fan identifier")
        }
        // Track before writing: even a failed write may have claimed manual mode.
        let smc = try connectedClient()
        _ = try smc.validateTargetRPM(target.targetRPM, fanID: target.fan.id)
        if !controlledFans.contains(target.fan.id) {
            var next = controlledFans
            next.insert(target.fan.id)
            try journal.save(next)
            controlledFans = next
        }
        renewLease()
        try smc.setTargetRPM(target.targetRPM, fan: target.fan)
        knownTargets[target.fan.id] = target.targetRPM
        renewLease()
    }

    private func renewLease() {
        guard !controlledFans.isEmpty else { return }
        leaseDeadline = .now.advanced(by: .seconds(15))
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, ContinuousClock.now >= leaseDeadline else { return }
            restoreOwnedFans()
        }
        watchdog = timer
        timer.resume()
    }

    private func restoreOwnedFans() {
        guard let client else { return }
        for id in controlledFans.sorted() {
            do {
                try client.restoreAutomatic(fanID: id, endManualSession: controlledFans.count == 1)
                controlledFans.remove(id)
                knownTargets.removeValue(forKey: id)
                try journal.save(controlledFans)
            } catch {
                // Keep ownership so the watchdog can retry transient failures.
            }
        }
        client.releaseManualSession()
        stopWatchdogIfIdle()
    }

    private func stopWatchdogIfIdle() {
        if controlledFans.isEmpty {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    private func connectedClient() throws -> SMCClient {
        if let client { return client }
        let newClient = try SMCClient()
        client = newClient
        return newClient
    }
}

private final class HelperEndpoint: NSObject, ThermalBarHelperXPC, @unchecked Sendable {
    let session = UUID()
    let service: HelperService
    init(service: HelperService) { self.service = service }
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        service.perform(request, session: session, withReply: reply)
    }
    func disconnected() { service.disconnected(session: session) }
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    private let requirement = HelperTrust.requirement(identifier: "com.thermalbar.app")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        // NSXPC validates the sending process for each message, avoiding PID
        // reuse races and identifier-only signatures.
        connection.setCodeSigningRequirement(requirement)
        let endpoint = HelperEndpoint(service: service)
        connection.exportedInterface = NSXPCInterface(with: ThermalBarHelperXPC.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.disconnected() }
        connection.interruptionHandler = { endpoint.disconnected() }
        connection.resume()
        return true
    }
}

private let delegate = HelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: thermalBarHelperMachService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
