import AppKit
import OSLog
import SwiftUI

@MainActor
final class ThermalBarAppDelegate: NSObject, NSApplicationDelegate {
    private let store = ThermalStore(preview: CommandLine.arguments.contains("--preview"))
    private let popover = NSPopover()
    private let artwork = MenuBarArtwork()
    private let interactionLogger = Logger(subsystem: "com.thermalbar.app", category: "Interaction")
    private var popoverController: NSHostingController<PopoverView>?
    private var popoverWindow: NSWindow?
    private var popoverWindowOffsetFromAnchor: NSPoint?
    private var isPanelPresented = false
    private var statusItem: NSStatusItem?
    private var contextMenu = NSMenu()
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var statusUpdateTask: Task<Void, Never>?
    private var metricIndex = 0
    private var lastMetric: MenuBarMetric?
    private var previewWindow: NSWindow?
    private var isTerminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopover()
        configureStatusItem()
        configureContextMenu()
        installOutsideClickMonitor()
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        store.onSnapshot = { [weak self] in self?.updateStatusItem() }
        store.startMonitoring()
        if store.isPreview {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 382, height: 610),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Fantastic Thermal — Preview"
            window.contentView = NSHostingView(rootView: PopoverView(store: store))
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        updateStatusItem()
        startStatusUpdates()
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                if self.prewarmPopover() {
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        statusUpdateTask?.cancel()
        closePopover()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }

        store.stopMonitoring {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configurePopover() {
        let controller = NSHostingController(rootView: PopoverView(store: store))
        controller.view.frame = NSRect(x: 0, y: 0, width: 382, height: 610)
        controller.view.wantsLayer = true
        // Pay SwiftUI's construction and layout cost once during launch. The
        // click path then reveals an already-built, continuously current view.
        controller.view.layoutSubtreeIfNeeded()
        popoverController = controller
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 382, height: 610)
        // Keep the native backing window alive for the lifetime of the app.
        // Dismissal is handled explicitly without destroying that window.
        popover.behavior = .applicationDefined
        // A status-item panel should feel attached to the click. AppKit's
        // popover animation adds noticeable latency before the first frame.
        popover.animates = false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarArtwork.width)
        item.behavior = [.removalAllowed]

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemAction(_:))
        // Open on mouse-down so the panel responds at the start of the click
        // instead of waiting for the complete press/release gesture.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.alignment = .center
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
        button.cell?.wraps = true
        button.cell?.isScrollable = false
        button.cell?.lineBreakMode = .byWordWrapping
        button.setAccessibilityTitle("Fantastic Thermal")
        statusItem = item
    }

    private func configureContextMenu() {
        contextMenu.autoenablesItems = false

        let openItem = NSMenuItem(
            title: "Open Fantastic Thermal",
            action: #selector(openFromContextMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        contextMenu.addItem(openItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Fantastic Thermal",
            action: #selector(quitFromContextMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    @discardableResult
    private func prewarmPopover() -> Bool {
        guard popoverWindow == nil else { return true }
        guard let button = statusItem?.button, button.window != nil else { return false }

        // NSPopover creates its backing window lazily on first presentation.
        // Create and retain it during launch so every real click uses the
        // already-built native window.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let window = popover.contentViewController?.view.window else { return false }
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        popoverWindow = window
        let visibleOrigin = window.frame.origin
        if let anchor = statusItemAnchor(for: button) {
            popoverWindowOffsetFromAnchor = NSPoint(
                x: visibleOrigin.x - anchor.x,
                y: visibleOrigin.y - anchor.y
            )
        }
        // Render at normal opacity because AppKit skips fully transparent
        // content, but keep the window far outside every display while doing
        // so. Restore its anchored position only after it is ordered out.
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.displayIfNeeded()
        window.alphaValue = 0
        window.orderOut(nil)
        window.setFrameOrigin(visibleOrigin)
        return true
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func statusItemAnchor(for button: NSStatusBarButton) -> NSPoint? {
        guard let window = button.window else { return nil }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        return NSPoint(x: buttonRectOnScreen.midX, y: buttonRectOnScreen.minY)
    }

    private func startStatusUpdates() {
        statusUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3), tolerance: .milliseconds(200)) } catch { return }
                guard let self else { return }
                let count = store.menuBarMetrics.count
                metricIndex = (metricIndex + 1) % max(1, count)
                updateStatusItem()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let metrics = store.menuBarMetrics
        if metricIndex >= metrics.count {
            metricIndex = 0
        }

        let metric = metrics[metricIndex]
        guard metric != lastMetric else { return }
        lastMetric = metric
        button.title = ""
        button.image = artwork.image(for: metric)
        button.toolTip = "Fantastic Thermal · \(metric.accessibilityLabel)"
        button.setAccessibilityTitle("Fantastic Thermal, \(metric.accessibilityLabel)")
    }

    @objc private func statusItemAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        performStatusItemAction(for: event, sender: sender)
    }

    private func performStatusItemAction(for event: NSEvent, sender: NSStatusBarButton) {

        // Leave Command-drag entirely to NSStatusItem so users can still
        // reposition or remove the menu-bar item.
        if event.type == .leftMouseDown, event.modifierFlags.contains(.command) {
            return
        }

        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            closePopover()
            contextMenu.popUp(
                positioning: nil,
                at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY),
                in: sender
            )
        } else if event.type == .rightMouseUp {
            // The menu is presented on mouse-down so AppKit can own the
            // complete secondary-click tracking session.
            return
        } else {
            togglePopover()
        }
    }

    @objc private func openFromContextMenu(_ sender: NSMenuItem) {
        showPopover()
    }

    @objc private func quitFromContextMenu(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func togglePopover() {
        if isPanelPresented {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        guard !isPanelPresented else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime

        if popoverWindow == nil { prewarmPopover() }
        guard let window = popoverWindow else { return }
        if let anchor = statusItemAnchor(for: button),
           let offset = popoverWindowOffsetFromAnchor {
            window.setFrameOrigin(NSPoint(x: anchor.x + offset.x, y: anchor.y + offset.y))
        }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        window.displayIfNeeded()
        isPanelPresented = true
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        interactionLogger.debug(
            "Panel first frame committed in \(elapsedMilliseconds, format: .fixed(precision: 2), privacy: .public) ms"
        )
        // Keep activation and keyboard focus off the first-frame path.
        DispatchQueue.main.async { [weak self, weak window] in
            NSApp.activate(ignoringOtherApps: true)
            if self?.isPanelPresented == true {
                window?.makeKey()
            }
        }
    }

    private func closePopover() {
        guard isPanelPresented, let window = popoverWindow else { return }
        isPanelPresented = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        showPopover()
        return false
    }
}

@main
@MainActor
enum ThermalBarApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = ThermalBarAppDelegate()
        application.delegate = delegate

        // The app's only interface is its status item and popover. Running
        // AppKit directly avoids registering an unused SwiftUI Settings scene,
        // which macOS could otherwise restore or open as an empty window.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
