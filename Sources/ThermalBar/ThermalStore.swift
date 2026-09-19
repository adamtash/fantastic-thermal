import Foundation
import AppKit
import Observation
import ServiceManagement
import ThermalBarCore

enum HelperVerificationState: Equatable {
    case idle
    case reinstalling
    case verifying
    case verified
    case needsApproval
    case failed(String)
}

@MainActor
@Observable
final class ThermalStore {
    private static let configurationKey = "thermalbar.configuration.v1"
    private static let configurationRecoveryKey = "thermalbar.configuration.recovery"
    private static let maximumHistoryPointCount = 10_800 // About six hours at two-second samples.

    var configuration: ThermalConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            if mode != editingProfile.mode { mode = editingProfile.mode }
            scheduleConfigurationSave()
            scheduleControl()
        }
    }

    private(set) var mode: ControlMode = .automatic
    private(set) var snapshot: HardwareSnapshot = .unavailable
    private(set) var lastRefreshDate: Date?
    // ArraySlice makes dropping the oldest sample O(1). Periodic compaction
    // keeps the retained backing storage bounded over multi-day sessions.
    private(set) var history: ArraySlice<ThermalHistoryPoint>
    private(set) var triggerDecision = TriggerDecision(targetPercent: 0, matchedRuleIDs: [])
    private(set) var appliedControl: AppliedControl?
    private(set) var isRefreshing = false
    private(set) var controlError: String?
    private(set) var sensorError: String?
    var lastError: String? { sensorError ?? controlError }
    private(set) var isPreview: Bool
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    private(set) var helperVerification: HelperVerificationState = .idle
    private(set) var editingProfileKind: PowerProfileKind = .adapter
    private(set) var powerSource: PowerSource = .adapter
    private(set) var hasInternalBattery = false

    var isPanelVisible = false
    @ObservationIgnored var onSnapshot: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var controlRequestTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var controlPending = false
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var isInteractiveControlEdit = false
    @ObservationIgnored private let hardware = HardwareController()
    private let helperService: SMAppService
    @ObservationIgnored private var triggerEngine = TriggerEngine()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var powerMonitor: PowerSourceMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var powerSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var isPowerSwitchPending = false
    private var didAdaptDefaultSensors = false
    @ObservationIgnored private var nextAutomaticHelperCheck = Date.distantPast
    @ObservationIgnored private var nextHelperStatusCheck = Date.distantPast
    private var sensorIndex: [String: TemperatureReading] = [:]

    init(preview: Bool = false) {
        self.isPreview = preview
        self.history = []
        self.helperService = SMAppService.daemon(plistName: "com.thermalbar.app.helper.plist")
        if preview {
            self.configuration = ThermalConfiguration(
                adapterProfile: ControlProfile(
                    mode: .autoPlus,
                    fixedPercent: 42,
                    triggers: [
                        TriggerRule(sensorKey: "TC0P", sensorName: "CPU proximity", thresholdC: 70, upperTemperatureC: 86, startPercent: 0, targetPercent: 72),
                        TriggerRule(sensorKey: "TB0T", sensorName: "Battery", thresholdC: 42, upperTemperatureC: 52, startPercent: 18, targetPercent: 56)
                    ]
                ),
                batteryProfile: ControlProfile(mode: .automatic),
                usesSeparatePowerProfiles: true,
                selectedSensorKey: "TC0P"
            )
            self.snapshot = Self.previewSnapshot
            self.lastRefreshDate = .now
            self.sensorIndex = Dictionary(uniqueKeysWithValues: self.snapshot.temperatures.map { ($0.id, $0) })
            self.history = ArraySlice(ThermalHistoryPoint.previewSamples)
            self.triggerDecision = TriggerDecision(targetPercent: 45, matchedRuleIDs: [self.configuration.triggers[0].id])
            self.appliedControl = AppliedControl(
                mode: .autoPlus,
                targets: [AppliedFanTarget(fanID: 0, targetRPM: 2_340, floorRPM: 1_720)]
            )
            self.helperStatus = .enabled
            self.hasInternalBattery = true
        } else {
            // Restore the complete profile, including the last control mode.
            // The first monitoring refresh applies it to the detected fans.
            self.configuration = Self.loadConfiguration()
            self.helperStatus = helperService.status
        }
        self.mode = configuration.profile(for: editingProfileKind).mode
    }

    var editingProfile: ControlProfile {
        configuration.profile(for: editingProfileKind)
    }

    var activeProfileKind: PowerProfileKind {
        configuration.usesSeparatePowerProfiles ? powerSource.profileKind : .adapter
    }

    var activeProfile: ControlProfile {
        configuration.profile(for: activeProfileKind)
    }

    var activeMode: ControlMode { activeProfile.mode }

    var canUseSeparatePowerProfiles: Bool {
        hasInternalBattery || powerSource == .ups
    }

    var primaryTemperature: TemperatureReading? {
        if let selected = configuration.selectedSensorKey,
           let reading = sensorIndex[selected] {
            return reading
        }
        return snapshot.temperatures.first(where: { $0.kind == .cpu }) ?? snapshot.temperatures.first
    }

    var batteryTemperature: TemperatureReading? {
        snapshot.temperatures.first(where: { $0.kind == .battery })
    }

    var hottestTemperature: TemperatureReading? {
        snapshot.temperatures.max { $0.celsius < $1.celsius }
    }

    var primaryFan: FanReading? {
        snapshot.fans.first
    }

    var activeTriggerCount: Int {
        triggerDecision.matchedRuleIDs.count
    }

    var menuBarMetrics: [MenuBarMetric] {
        var metrics: [MenuBarMetric] = []

        if let temperature = batteryTemperature {
            let value = Int(temperature.celsius.rounded())
            metrics.append(
                MenuBarMetric(
                    id: "current-battery-\(temperature.id)",
                    title: "B \(value)°",
                    menuBarLabel: "BAT",
                    accessibilityLabel: "Current battery temperature, \(value) degrees Celsius",
                    symbolName: "thermometer.medium",
                    kind: .temperature
                )
            )
        }

        if let fan = snapshot.fans.first {
            let percent = Int(fan.currentPercent.rounded())
            let isStopped = fan.currentRPM < max(1, fan.minimumRPM / 2)
            metrics.append(
                MenuBarMetric(
                    id: "fan-after-battery-\(fan.id)",
                    title: isStopped ? "F OFF" : "F \(percent)%",
                    menuBarLabel: "FAN",
                    accessibilityLabel: isStopped ? "Fan stopped" : "Fan, \(percent) percent of range",
                    symbolName: "fanblades.fill",
                    kind: .fanPercentage
                )
            )
        }

        if let temperature = snapshot.temperatures.first(where: { $0.kind == .cpu }) {
            let value = Int(temperature.celsius.rounded())
            metrics.append(
                MenuBarMetric(
                    id: "current-cpu-\(temperature.id)",
                    title: "C \(value)°",
                    menuBarLabel: "CPU",
                    accessibilityLabel: "Current \(temperature.name), \(value) degrees Celsius",
                    symbolName: "thermometer.medium",
                    kind: .temperature
                )
            )
        }

        if metrics.isEmpty {
            return [
                MenuBarMetric(
                    id: "unavailable",
                    title: "—",
                    menuBarLabel: "",
                    accessibilityLabel: "Fantastic Thermal is waiting for sensor data",
                    symbolName: "fanblades.fill",
                    kind: .fanPercentage
                )
            ]
        }
        return metrics
    }

    var modeDescription: String {
        switch activeProfile.mode {
        case .automatic:
            return configuration.usesSeparatePowerProfiles
                ? "macOS controls the fans on \(powerSource.title.lowercased())"
                : "macOS controls the fans"
        case .fixed:
            if !isPreview && !isControlling { return "Target \(Int(activeProfile.fixedPercent.rounded()))% · waiting for control" }
            return "Fixed at \(Int(activeProfile.fixedPercent.rounded()))%"
        case .autoPlus:
            if !isPreview && !isControlling { return "Waiting for fan control" }
            if activeTriggerCount == 0 { return "Auto floor active" }
            return "\(activeTriggerCount) trigger\(activeTriggerCount == 1 ? "" : "s") active"
        }
    }

    var isControlling: Bool {
        activeProfile.mode != .automatic && appliedControl?.mode == activeProfile.mode && !snapshot.fans.isEmpty
    }

    var helperIsEnabled: Bool {
        helperStatus == .enabled
    }

    var helperStatusText: String {
        switch helperStatus {
        case .enabled:
            "Privileged control enabled"
        case .requiresApproval:
            "Approve helper in System Settings"
        case .notFound:
            "Helper not found in this app bundle"
        case .notRegistered:
            "Helper not installed yet"
        @unknown default:
            "Fan-control helper needs attention"
        }
    }

    var helperVerificationText: String? {
        switch helperVerification {
        case .idle:
            nil
        case .reinstalling:
            "Reinstalling helper…"
        case .verifying:
            "Verifying helper connection…"
        case .verified:
            "Helper verified and responding"
        case .needsApproval:
            "Approve the helper in System Settings"
        case .failed(let message):
            message
        }
    }

    var shouldShowHelperCard: Bool {
        switch helperVerification {
        case .idle, .verified:
            false
        case .reinstalling, .verifying, .needsApproval, .failed:
            true
        }
    }

    var canReinstallHelper: Bool {
        switch helperVerification {
        case .needsApproval, .failed:
            true
        case .idle, .reinstalling, .verifying, .verified:
            false
        }
    }

    var helperVerificationIsPositive: Bool {
        if case .verified = helperVerification { return true }
        return false
    }

    var helperVerificationInProgress: Bool {
        switch helperVerification {
        case .reinstalling, .verifying:
            true
        default:
            false
        }
    }

    func startMonitoring() {
        guard !isPreview, monitorTask == nil else { return }
        isStopping = false
        let monitor = PowerSourceMonitor { [weak self] source in
            self?.powerSourceChanged(to: source)
        }
        powerMonitor = monitor
        powerSource = monitor.source
        hasInternalBattery = monitor.hasInternalBattery
        if !configuration.usesSeparatePowerProfiles {
            editingProfileKind = .adapter
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerMonitor?.refresh()
            }
        }
        monitorTask = Task(priority: .utility) { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func stopMonitoring(completion: @escaping () -> Void = {}) {
        isStopping = true
        persistConfiguration()
        saveTask?.cancel()
        controlRequestTask?.cancel()
        powerSwitchTask?.cancel()
        isPowerSwitchPending = false
        powerMonitor?.stop()
        powerMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        let stoppedTask = monitorTask
        let stoppedControl = controlTask
        stoppedTask?.cancel()
        stoppedControl?.cancel()
        monitorTask = nil
        Task { [hardware] in
            _ = await stoppedTask?.value
            _ = await stoppedControl?.value
            await hardware.restoreAll()
            completion()
        }
    }

    func refresh() async {
        guard !isRefreshing, !isPreview, !isStopping else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        powerMonitor?.refresh()
        if let powerMonitor {
            hasInternalBattery = powerMonitor.hasInternalBattery
        }

        do {
            let nextSnapshot = try await hardware.snapshot()
            guard !Task.isCancelled else { return }
            snapshot = nextSnapshot
            lastRefreshDate = .now
            sensorIndex = Dictionary(uniqueKeysWithValues: nextSnapshot.temperatures.map { ($0.id, $0) })
            appendHistoryPoint(for: nextSnapshot)
            sensorError = nil
            adaptDefaultSensorsIfNeeded(in: nextSnapshot)
            onSnapshot?()
            enqueueControl()

        } catch {
            sensorError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            snapshot = HardwareSnapshot(isAvailable: false, statusMessage: sensorError)
            sensorIndex.removeAll(keepingCapacity: true)
            appliedControl = nil
            onSnapshot?()
            enqueueControl()
        }
    }

    private func powerSourceChanged(to source: PowerSource) {
        powerSource = source
        guard configuration.usesSeparatePowerProfiles else { return }
        isPowerSwitchPending = true
        powerSwitchTask?.cancel()
        powerSwitchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, !Task.isCancelled, self.powerSource == source else { return }
            self.isPowerSwitchPending = false
            self.triggerEngine.reset()
            self.enqueueControl()
        }
    }

    func setMode(_ mode: ControlMode) {
        guard editingProfile.mode != mode else { return }
        updateEditingProfile { $0.mode = mode }
        triggerEngine.reset()
        applySoon()
    }

    func setEditingProfileKind(_ kind: PowerProfileKind) {
        guard editingProfileKind != kind else { return }
        editingProfileKind = kind
        mode = editingProfile.mode
    }

    func setUsesSeparatePowerProfiles(_ enabled: Bool) {
        guard configuration.usesSeparatePowerProfiles != enabled else { return }
        configuration.usesSeparatePowerProfiles = enabled
        if !enabled {
            editingProfileKind = .adapter
            mode = editingProfile.mode
        }
        isPowerSwitchPending = false
        powerSwitchTask?.cancel()
        triggerEngine.reset()
        applySoon()
    }

    func requestHelperSetup() {
        registerHelperIfNeeded()
        if helperStatus != .enabled {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func reinstallHelper() async {
        guard !isPreview, !helperVerificationInProgress else { return }

        helperVerification = .reinstalling
        controlError = nil
        appliedControl = nil
        // Finish any outstanding write before replacing its helper process.
        await controlTask?.value
        await hardware.restoreAll()

        do {
            helperStatus = helperService.status
            if helperStatus == .enabled || helperStatus == .requiresApproval {
                try await helperService.unregister()
                try await Task.sleep(for: .seconds(1))
            }

            // Service Management can briefly reject registration after its
            // asynchronous bootout completes. Keep this bounded and off the UI.
            for attempt in 0..<3 {
                do {
                    try helperService.register()
                    break
                } catch {
                    let failure = error as NSError
                    guard attempt < 2, failure.domain == "SMAppServiceErrorDomain", failure.code == 1 else { throw error }
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
            helperStatus = helperService.status

            guard helperStatus == .enabled else {
                helperVerification = .needsApproval
                if helperStatus == .requiresApproval || helperStatus == .notRegistered {
                    SMAppService.openSystemSettingsLoginItems()
                }
                return
            }

            try await verifyRegisteredHelper()
            helperVerification = .verified
            nextAutomaticHelperCheck = .distantFuture
            enqueueControl()
        } catch {
            helperStatus = helperService.status
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            helperVerification = .failed(message)
            controlError = message
            nextAutomaticHelperCheck = Date().addingTimeInterval(10)
        }
    }

    func setFixedPercent(_ percent: Double) {
        updateEditingProfile { $0.fixedPercent = min(100, max(0, percent)) }
    }

    func setInteractiveControlEdit(_ editing: Bool) {
        guard isInteractiveControlEdit != editing else { return }
        isInteractiveControlEdit = editing
        if !editing { applySoon() }
    }

    func applyPreset(_ preset: QuickPreset) {
        updateEditingProfile {
            $0.mode = .fixed
            $0.fixedPercent = preset.percent
        }
        triggerEngine.reset()
        applySoon()
    }

    func setSelectedSensor(_ sensor: TemperatureReading) {
        configuration.selectedSensorKey = sensor.id
        // A primary line must not connect readings from two different sensors.
        history = []
    }

    func addTrigger() {
        guard editingProfile.triggers.count < 32 else { return }
        let sensor = snapshot.temperatures.first(where: { $0.kind == .cpu }) ?? snapshot.temperatures.first
        let rule = TriggerRule(
            sensorKey: sensor?.id ?? "TC0P",
            sensorName: sensor?.name ?? "CPU proximity",
            thresholdC: max(50, min(90, (sensor?.celsius ?? 60) + 8)),
            upperTemperatureC: max(65, min(105, (sensor?.celsius ?? 60) + 23)),
            startPercent: 20,
            targetPercent: 56
        )
        updateEditingProfile { $0.triggers.append(rule) }
    }

    func removeTrigger(_ rule: TriggerRule) {
        updateEditingProfile { $0.triggers.removeAll { $0.id == rule.id } }
        triggerDecision = TriggerDecision(
            targetPercent: triggerDecision.targetPercent,
            matchedRuleIDs: triggerDecision.matchedRuleIDs.subtracting([rule.id])
        )
    }

    func updateTrigger(_ rule: TriggerRule, mutate: (inout TriggerRule) -> Void) {
        guard let index = editingProfile.triggers.firstIndex(where: { $0.id == rule.id }) else { return }
        var updated = editingProfile.triggers[index]
        mutate(&updated)
        let activationChanged = updated.sensorKey != rule.sensorKey
            || updated.thresholdC != rule.thresholdC
            || updated.hysteresisC != rule.hysteresisC
            || updated.isEnabled != rule.isEnabled
        updated.thresholdC = min(105, max(25, updated.thresholdC))
        updated.upperTemperatureC = min(110, max(updated.thresholdC + 1, updated.upperTemperatureC))
        updated.startPercent = min(100, max(0, updated.startPercent))
        updated.targetPercent = min(100, max(updated.startPercent, updated.targetPercent))
        updateEditingProfile { $0.triggers[index] = updated }
        if activationChanged { triggerEngine.reset() }
    }

    private func updateEditingProfile(_ mutate: (inout ControlProfile) -> Void) {
        var profile = editingProfile
        mutate(&profile)
        configuration.setProfile(profile, for: editingProfileKind)
        mode = profile.mode
    }

    func sensor(for rule: TriggerRule) -> TemperatureReading? {
        sensorIndex[rule.sensorKey]
    }

    private func applySoon() {
        controlRequestTask?.cancel()
        enqueueControl()
    }

    private func scheduleControl() {
        guard !isPreview, !isStopping, !isInteractiveControlEdit else { return }
        controlRequestTask?.cancel()
        controlRequestTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.enqueueControl()
        }
    }

    private func enqueueControl() {
        guard !isPreview, !isStopping else { return }
        controlPending = true
        guard controlTask == nil else { return }
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer { controlTask = nil }
            while controlPending && !Task.isCancelled && !isStopping {
                controlPending = false
                await applyLatestControl()
            }
        }
    }

    private func applyLatestControl() async {
        // Control runs independently of polling and serially across edits.
        // New settings replace queued work; an in-flight write is followed by
        // the latest setting, so rapid Auto / Fixed toggles cannot race.
        guard helperVerification != .reinstalling else { return }
        guard !isPowerSwitchPending else { return }
        guard snapshot.isAvailable else {
            await hardware.restoreAll()
            appliedControl = nil
            return
        }
        guard !snapshot.fans.isEmpty else {
            await hardware.restoreAll()
            appliedControl = nil
            return
        }
        do {
            let requested = activeProfile
            if requested.mode != .automatic {
                await prepareHelperAutomatically()
                guard !Task.isCancelled, !isStopping else { return }
                guard helperStatus == .enabled, helperVerification == .verified else {
                    appliedControl = nil
                    return
                }
            } else {
                helperVerification = .idle
                nextAutomaticHelperCheck = .distantPast
            }
            triggerDecision = triggerEngine.evaluate(rules: requested.triggers, temperatures: snapshot.temperatures)
            let result = try await hardware.apply(profile: requested, snapshot: snapshot, decision: triggerDecision)
            if activeProfile == requested {
                appliedControl = result
                controlError = nil
            } else {
                controlPending = true
            }
        } catch {
            appliedControl = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            controlError = message
            if error is HelperClientError {
                helperVerification = .failed(message)
                nextAutomaticHelperCheck = Date().addingTimeInterval(10)
            }
        }
    }

    private func scheduleConfigurationSave() {
        guard !isPreview else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persistConfiguration()
        }
    }

    private func appendHistoryPoint(for snapshot: HardwareSnapshot) {
        guard snapshot.isAvailable,
              !snapshot.temperatures.isEmpty || !snapshot.fans.isEmpty else { return }

        if let last = history.last, snapshot.timestamp <= last.timestamp { history = [] }
        history.append(
            ThermalHistoryPoint(
                snapshot: snapshot,
                selectedSensorKey: configuration.selectedSensorKey
            )
        )

        if history.count > Self.maximumHistoryPointCount {
            history.removeFirst(history.count - Self.maximumHistoryPointCount)
            if history.startIndex > 2_048 {
                history = ArraySlice(Array(history))
            }
        }
    }

    private func registerHelperIfNeeded() {
        helperStatus = helperService.status
        guard helperStatus != .enabled else { return }
        do {
            try helperService.register()
        } catch {
            controlError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        helperStatus = helperService.status
    }

    private func prepareHelperAutomatically() async {
        guard activeProfile.mode != .automatic, helperVerification != .reinstalling else { return }

        if Date() >= nextHelperStatusCheck {
            updateHelperStatus()
            nextHelperStatusCheck = Date().addingTimeInterval(helperStatus == .enabled ? 30 : 10)
        }
        if helperStatus == .notRegistered, Date() >= nextAutomaticHelperCheck {
            registerHelperIfNeeded()
            if helperStatus != .enabled { nextAutomaticHelperCheck = Date().addingTimeInterval(10) }
        }
        await updateHelperVerificationAutomatically()
    }

    private func updateHelperVerificationAutomatically(force: Bool = false) async {
        guard !isPreview, activeProfile.mode != .automatic else {
            helperVerification = .idle
            return
        }

        guard helperStatus == .enabled else {
            if helperVerification != .reinstalling {
                helperVerification = .needsApproval
            }
            return
        }

        guard !helperVerificationInProgress else { return }
        guard force || Date() >= nextAutomaticHelperCheck else { return }

        helperVerification = .verifying
        do {
            try await verifyRegisteredHelper()
            helperVerification = .verified
            nextAutomaticHelperCheck = .distantFuture
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            helperVerification = .failed(message)
            controlError = message
            nextAutomaticHelperCheck = Date().addingTimeInterval(10)
        }
    }

    private func updateHelperStatus() {
        let currentStatus = helperService.status
        if currentStatus != helperStatus {
            helperStatus = currentStatus
            if currentStatus == .enabled, helperVerification != .verified {
                helperVerification = .idle
                nextAutomaticHelperCheck = .distantPast
            }
        }
    }

    private func verifyRegisteredHelper() async throws {
        try await hardware.verifyHelper()
    }

    private func adaptDefaultSensorsIfNeeded(in snapshot: HardwareSnapshot) {
        guard !didAdaptDefaultSensors else { return }
        guard let firstCPU = snapshot.temperatures.first(where: { $0.kind == .cpu }) else { return }
        didAdaptDefaultSensors = true
        if configuration.selectedSensorKey == nil {
            configuration.selectedSensorKey = firstCPU.id
        }

        // TC0P is a common Intel key but is absent on many Apple Silicon Macs.
        // Move only the stock CPU rule to the first discovered CPU sensor; a
        // user-created rule keeps its explicit key even when unavailable.
        let availableSensorKeys = Set(snapshot.temperatures.map(\.id))
        for kind in PowerProfileKind.allCases {
            var profile = configuration.profile(for: kind)
            var changed = false
            for index in profile.triggers.indices {
                let rule = profile.triggers[index]
                if rule.sensorKey == "TC0P", !availableSensorKeys.contains(rule.sensorKey), rule.sensorName == "CPU proximity" {
                    var updated = rule
                    updated.sensorKey = firstCPU.id
                    updated.sensorName = firstCPU.name
                    profile.triggers[index] = updated
                    changed = true
                }
            }
            if changed { configuration.setProfile(profile, for: kind) }
        }
    }

    private func persistConfiguration() {
        guard !isPreview else { return }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configurationKey)
    }

    private static func loadConfiguration() -> ThermalConfiguration {
        guard let data = UserDefaults.standard.data(forKey: configurationKey) else {
            return ThermalConfiguration()
        }
        do {
            return try JSONDecoder().decode(ThermalConfiguration.self, from: data).normalized
        } catch {
            // Preserve the original bytes so a future build or support tool can
            // recover the profile instead of silently destroying it on quit.
            UserDefaults.standard.set(data, forKey: configurationRecoveryKey)
            return ThermalConfiguration()
        }
    }

    private static let previewSnapshot = HardwareSnapshot(
        timestamp: .now,
        fans: [
            FanReading(
                id: 0,
                name: "Left fan",
                currentRPM: 2_080,
                targetRPM: 2_340,
                minimumRPM: 1_700,
                maximumRPM: 5_500,
                mode: .manual
            ),
            FanReading(
                id: 1,
                name: "Right fan",
                currentRPM: 1_980,
                targetRPM: 2_340,
                minimumRPM: 1_700,
                maximumRPM: 5_500,
                mode: .manual
            )
        ],
        temperatures: [
            TemperatureReading(id: "TC0P", name: "CPU proximity", kind: .cpu, celsius: 72),
            TemperatureReading(id: "TG0P", name: "GPU proximity", kind: .gpu, celsius: 61),
            TemperatureReading(id: "TB0T", name: "Battery", kind: .battery, celsius: 39),
            TemperatureReading(id: "Ts0P", name: "Palm rest", kind: .enclosure, celsius: 32)
        ],
        isAvailable: true
    )
}
