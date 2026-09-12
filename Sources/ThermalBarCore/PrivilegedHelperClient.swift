import Foundation

/// Small NSXPC client used only for fan writes. Sensor reads remain local so
/// the menu-bar app can still monitor a machine while the helper is awaiting
/// approval in System Settings.
public final class PrivilegedHelperClient: FanControlClient, @unchecked Sendable {
    private final class ConnectionBox: @unchecked Sendable {
        let connection: NSXPCConnection
        private let lock = NSLock()
        private var handlers: [UUID: @Sendable (HelperClientError) -> Void] = [:]
        private var failure: HelperClientError?

        init(_ connection: NSXPCConnection) {
            self.connection = connection
        }

        func register(_ id: UUID, handler: @escaping @Sendable (HelperClientError) -> Void) {
            lock.lock()
            if let failure {
                lock.unlock()
                handler(failure)
            } else {
                handlers[id] = handler
                lock.unlock()
            }
        }

        func remove(_ id: UUID) {
            lock.lock()
            handlers.removeValue(forKey: id)
            lock.unlock()
        }

        func fail(_ error: HelperClientError) {
            lock.lock()
            failure = error
            let pending = handlers
            handlers.removeAll()
            lock.unlock()
            for handler in pending.values { handler(error) }
        }
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HelperResponse, Error>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<HelperResponse, Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<HelperResponse, Error>) {
            lock.lock()
            let continuation = continuation
            let timeoutTask = timeoutTask
            self.continuation = nil
            self.timeoutTask = nil
            lock.unlock()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            if continuation == nil {
                lock.unlock()
                task.cancel()
            } else {
                timeoutTask = task
                lock.unlock()
            }
        }

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }
    }

    private let connectionLock = NSLock()
    private var activeConnection: ConnectionBox?

    public init() {}

    deinit { activeConnection?.connection.invalidate() }

    /// Verifies that the approved helper is registered, reachable over XPC,
    /// and able to answer a no-op request. This deliberately does not touch
    /// fan state.
    public func verifyConnection() async throws {
        try await perform(HelperRequest(action: .healthCheck))
    }

    public func renewLease(targets: [HelperFanTarget]) async throws {
        try await perform(HelperRequest(action: .renewLease, targets: targets))
    }

    public func setTargetRPM(_ rpm: Int, fan: FanReading) async throws {
        try await perform(HelperRequest(action: .setTarget, fan: fan, targetRPM: rpm))
    }

    public func setTargetRPMs(_ targets: [HelperFanTarget]) async throws {
        guard !targets.isEmpty else { return }
        try await perform(HelperRequest(action: .setTargets, targets: targets))
    }

    public func restoreAutomatic(fanID: Int, endManualSession: Bool) async throws {
        let fan = FanReading(
            id: fanID,
            name: "Fan \(fanID + 1)",
            currentRPM: 0,
            targetRPM: nil,
            minimumRPM: 0,
            maximumRPM: Int.max,
            mode: .manual
        )
        try await perform(HelperRequest(
            action: .restoreAutomatic,
            fan: fan,
            endManualSession: endManualSession
        ))
    }

    public func releaseManualSession() async throws {
        try await perform(HelperRequest(action: .releaseManualSession))
    }

    public func perform(_ request: HelperRequest) async throws {
        let data = try JSONEncoder().encode(request)
        let timeout: Duration = request.action == .setTarget || request.action == .setTargets || request.action == .renewLease ? .seconds(20) : .seconds(2)
        let response = try await send(data, timeout: timeout)
        guard response.protocolVersion == thermalBarHelperProtocolVersion else {
            throw HelperClientError.rejected("Update the fan-control helper using Reinstall.")
        }
        if let error = response.error {
            throw HelperClientError.rejected(error)
        }
    }

    private func send(_ data: Data, timeout: Duration) async throws -> HelperResponse {
        let connectionBox = try connection()
        return try await withCheckedThrowingContinuation { continuation in
            let replyBox = ReplyBox(continuation)
            let requestID = UUID()
            connectionBox.register(requestID) { error in
                replyBox.resume(with: .failure(error))
            }

            let timeoutTask = Task { [weak self, weak connectionBox, weak replyBox] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let connectionBox, let replyBox, replyBox.isPending else { return }
                connectionBox.fail(.timedOut)
                self?.discard(connectionBox, invalidate: true)
            }
            replyBox.setTimeoutTask(timeoutTask)

            guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                connectionBox.remove(requestID)
                self?.discard(connectionBox, invalidate: true)
                replyBox.resume(with: .failure(HelperClientError.unavailable(error.localizedDescription)))
            }) as? ThermalBarHelperXPC else {
                connectionBox.remove(requestID)
                discard(connectionBox, invalidate: true)
                replyBox.resume(with: .failure(HelperClientError.unavailable("Unable to create an XPC proxy")))
                return
            }

            proxy.perform(data) { [weak self, weak connectionBox] responseData in
                do {
                    let response = try JSONDecoder().decode(HelperResponse.self, from: responseData)
                    connectionBox?.remove(requestID)
                    replyBox.resume(with: .success(response))
                } catch {
                    if let connectionBox {
                        connectionBox.remove(requestID)
                        self?.discard(connectionBox, invalidate: true)
                    }
                    replyBox.resume(with: .failure(HelperClientError.invalidResponse))
                }
            }
        }
    }

    private func connection() throws -> ConnectionBox {
        connectionLock.lock()
        if let activeConnection {
            connectionLock.unlock()
            return activeConnection
        }

        guard let requirement = HelperTrust.requirement(identifier: thermalBarHelperMachService) else {
            connectionLock.unlock()
            throw HelperClientError.unavailable("Fan control requires a Developer ID signed app.")
        }
        let connection = NSXPCConnection(
            machServiceName: thermalBarHelperMachService,
            options: .privileged
        )
        connection.setCodeSigningRequirement(requirement)
        let box = ConnectionBox(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: ThermalBarHelperXPC.self)
        connection.interruptionHandler = { [weak self, weak box] in
            guard let box else { return }
            box.fail(.unavailable("The privileged helper connection was interrupted."))
            self?.discard(box, invalidate: true)
        }
        connection.invalidationHandler = { [weak self, weak box] in
            guard let box else { return }
            box.fail(.unavailable("The privileged helper connection was invalidated."))
            self?.discard(box, invalidate: false)
        }
        activeConnection = box
        connectionLock.unlock()
        connection.resume()
        return box
    }

    private func discard(_ connectionBox: ConnectionBox, invalidate: Bool) {
        connectionLock.lock()
        if activeConnection === connectionBox {
            activeConnection = nil
        }
        connectionLock.unlock()

        if invalidate {
            connectionBox.fail(.unavailable("The helper connection closed."))
            connectionBox.connection.invalidate()
        }
    }
}
