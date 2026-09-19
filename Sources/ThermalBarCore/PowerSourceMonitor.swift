import Foundation
import IOKit.ps

public enum PowerSource: String, Codable, CaseIterable, Sendable {
    case adapter
    case battery
    case ups

    public var profileKind: PowerProfileKind {
        self == .adapter ? .adapter : .battery
    }

    public var title: String {
        switch self {
        case .adapter: "Power Adapter"
        case .battery: "Battery"
        case .ups: "UPS"
        }
    }
}

public enum PowerSourceReader {
    public static func current() -> PowerSource {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return .adapter }

        switch type as String {
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return .adapter
        }
    }

    public static func hasInternalBattery() -> Bool {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if description[kIOPSIsPresentKey] as? Bool == false { continue }
            return true
        }
        return false
    }
}

/// Delivers adapter/battery transitions on the main run loop. Callers may
/// also invoke refresh() after wake or from a slow poll to heal missed events.
@MainActor
public final class PowerSourceMonitor {
    public private(set) var source: PowerSource
    public private(set) var hasInternalBattery: Bool
    public private(set) var isLive = false

    private let onChange: @MainActor (PowerSource) -> Void

    private final class CallbackBox {
        weak var owner: PowerSourceMonitor?
    }

    private let callbackBox = CallbackBox()
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var rawContext: UnsafeMutableRawPointer?

    public init(onChange: @escaping @MainActor (PowerSource) -> Void) {
        source = PowerSourceReader.current()
        hasInternalBattery = PowerSourceReader.hasInternalBattery()
        self.onChange = onChange
        callbackBox.owner = self
        start()
    }

    public func refresh() {
        hasInternalBattery = PowerSourceReader.hasInternalBattery()
        let updated = PowerSourceReader.current()
        guard updated != source else { return }
        source = updated
        onChange(updated)
    }

    public func stop() {
        teardown()
        isLive = false
    }

    private func start() {
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        guard let unmanagedSource = IOPSCreateLimitedPowerNotification({ rawContext in
            guard let rawContext else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(rawContext).takeUnretainedValue()
            MainActor.assumeIsolated {
                box.owner?.refresh()
            }
        }, context) else {
            Unmanaged<CallbackBox>.fromOpaque(context).release()
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        rawContext = context
        isLive = true
    }

    private nonisolated func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }
        if let context = rawContext {
            Unmanaged<CallbackBox>.fromOpaque(context).release()
            rawContext = nil
        }
    }

    deinit {
        teardown()
    }
}
