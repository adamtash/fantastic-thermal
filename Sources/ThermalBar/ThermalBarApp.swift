import AppKit
import SwiftUI

@MainActor
final class ThermalBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = ThermalStore(preview: CommandLine.arguments.contains("--preview"))
    private let popover = NSPopover()
    private let artwork = MenuBarArtwork()
    private var popoverController: NSHostingController<PopoverRootView>?
    private var statusItem: NSStatusItem?
    private var contextMenu = NSMenu()
    private var outsideClickMonitors: [Any] = []
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

        store.stopMonitoring {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configurePopover() {
        let controller = NSHostingController(rootView: PopoverRootView(store: store))
        controller.view.wantsLayer = true
        popoverController = controller
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 382, height: 610)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarArtwork.width)
        item.behavior = [.removalAllowed]

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseDown, .rightMouseUp])
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
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        guard !popover.isShown else { return }

        // LSUIElement apps do not normally become frontmost when a status
        // item opens a popover. Activate only for the panel session so
        // AppKit can deliver a real resign-active event when the user clicks
        // another app or the desktop.
        store.isPanelVisible = true
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.hidesOnDeactivate = true
        installOutsideClickMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
        if let globalMonitor {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func removeOutsideClickMonitor() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll(keepingCapacity: true)
    }

    func popoverDidClose(_ notification: Notification) {
        store.isPanelVisible = false
        removeOutsideClickMonitor()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        showPopover()
        return false
    }
}

@main
struct ThermalBarApp: App {
    @NSApplicationDelegateAdaptor(ThermalBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
