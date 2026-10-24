import AppKit
import SwiftUI

final class MenuBarPanelController: NSObject, NSPopoverDelegate {
    private let actions: DashboardActions
    private let popover = NSPopover()
    private var hostingController: NSHostingController<MenuBarPanelView>?
    private var latestModel: DashboardModel?
    private weak var anchorButton: NSStatusBarButton?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var dismissalObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(actions: DashboardActions) {
        self.actions = actions
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(
            width: MenuBarPanelMetrics.width,
            height: MenuBarPanelMetrics.height
        )
    }

    func toggle(relativeTo button: NSStatusBarButton, model: DashboardModel) {
        if popover.isShown {
            close()
            return
        }

        show(relativeTo: button, model: model)
    }

    private func show(relativeTo button: NSStatusBarButton, model: DashboardModel) {
        update(model: model)
        configureHostingControllerIfNeeded()
        anchorButton = button
        startEventMonitors()
        // Own dismissal when both event streams are available. In particular,
        // an accessory app may already be inactive when another app is clicked.
        // Keep AppKit's transient behavior as a fallback if a monitor fails.
        popover.behavior = localMouseMonitor != nil && globalMouseMonitor != nil ? .applicationDefined : .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else { stopDismissalMonitoring(); return }
        startDismissalObservers()
    }

    func close() {
        stopDismissalMonitoring()
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissalMonitoring()
    }

    deinit {
        stopDismissalMonitoring()
    }

    private func startEventMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if let window = event.window, window === self.popover.contentViewController?.view.window { return event }
            if let button = self.anchorButton, event.window === button.window,
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return event }
            self.close()
            // Dismissal must not consume the click intended for another window.
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            // Clicking the positioning item is handled by its mouse-up toggle.
            if let button = self.anchorButton, let window = button.window {
                let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                if frame.contains(NSEvent.mouseLocation) { return }
            }
            self.close()
        }
    }

    private func startDismissalObservers() {
        let center = NotificationCenter.default
        dismissalObservers.append((center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.close()
        }))
        if let window = popover.contentViewController?.view.window {
            dismissalObservers.append((center, center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.close()
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        dismissalObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }))
        dismissalObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.close()
        }))
    }

    private func stopDismissalMonitoring() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        for (center, observer) in dismissalObservers { center.removeObserver(observer) }
        dismissalObservers.removeAll()
        anchorButton = nil
    }

    func update(model: DashboardModel) {
        latestModel = model
        guard let hostingController else { return }
        hostingController.rootView = makeRootView(model: model)
    }

    private func configureHostingControllerIfNeeded() {
        guard hostingController == nil, let latestModel else { return }
        let controller = NSHostingController(rootView: makeRootView(model: latestModel))
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: MenuBarPanelMetrics.width,
            height: MenuBarPanelMetrics.height
        )
        popover.contentViewController = controller
        hostingController = controller
    }

    private func makeRootView(model: DashboardModel) -> MenuBarPanelView {
        MenuBarPanelView(
            model: model,
            dispatcher: DashboardActionDispatcher(actions: actions)
        )
    }
}
