import AppKit
import Common
import SwiftUI

// CENTERED BAR FEATURE
@MainActor
private struct MonitorBarInstance {
    let monitorId: Int
    let panel: NSPanel
    let hostingView: NSHostingView<CenteredBarView>
}

@MainActor
public class CenteredBarManager: ObservableObject {
    public static var shared: CenteredBarManager?

    // Multi-panel support: keyed by monitorAppKitNsScreenScreensId
    private var barsByMonitor: [Int: MonitorBarInstance] = [:]
    private var screenObserver: Any?

    public init() {
        setupScreenChangeObserver()
    }

    public func setupCenteredBar(viewModel: TrayMenuModel) {
        guard CenteredBarSettings.shared.enabled else {
            removeCenteredBar()
            return
        }

        setupBars(viewModel: viewModel)
    }

    private func setupBars(viewModel: TrayMenuModel) {
        let currentMonitors = monitors
        var existingMonitorIds = Set(barsByMonitor.keys)

        // Create or update bars for each monitor
        for monitor in currentMonitors {
            let monitorId = monitor.monitorAppKitNsScreenScreensId
            existingMonitorIds.remove(monitorId)

            if let existing = barsByMonitor[monitorId] {
                // Update existing bar
                updateBarForMonitor(monitor, instance: existing, viewModel: viewModel)
            } else {
                // Create new bar
                createBarForMonitor(monitor, viewModel: viewModel)
            }
        }

        // Remove bars for disconnected monitors
        for monitorId in existingMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor, viewModel: TrayMenuModel) {
        let panel = createCenteredPanel()
        let barHeight = max(menuBarHeight(for: resolveNSScreen(for: monitor) ?? NSScreen.screens.first!), 24)
        let contentView = CenteredBarView(viewModel: viewModel, barHeight: barHeight, monitor: monitor)
        let hostingView = NSHostingView(rootView: contentView)

        panel.contentView = hostingView
        applySettingsToPanel(panel)

        let instance = MonitorBarInstance(
            monitorId: monitor.monitorAppKitNsScreenScreensId,
            panel: panel,
            hostingView: hostingView
        )
        barsByMonitor[monitor.monitorAppKitNsScreenScreensId] = instance

        updateBarFrameAndPosition(for: monitor, instance: instance)
        panel.orderFrontRegardless()
    }

    private func updateBarForMonitor(_ monitor: Monitor, instance: MonitorBarInstance, viewModel: TrayMenuModel) {
        let barHeight = max(menuBarHeight(for: resolveNSScreen(for: monitor) ?? NSScreen.screens.first!), 24)
        instance.hostingView.rootView = CenteredBarView(viewModel: viewModel, barHeight: barHeight, monitor: monitor)
        applySettingsToPanel(instance.panel)
        updateBarFrameAndPosition(for: monitor, instance: instance)
    }

    private func removeBarForMonitor(_ monitorId: Int) {
        if let instance = barsByMonitor[monitorId] {
            instance.panel.orderOut(nil)
            instance.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    public func update(viewModel: TrayMenuModel) {
        guard CenteredBarSettings.shared.enabled else {
            removeCenteredBar()
            return
        }

        // Always call setup which handles create/update
        setupCenteredBar(viewModel: viewModel)
    }

    private func createCenteredPanel() -> NSPanel {
        // Use custom panel subclass to bypass menu bar constraint
        let panel = CenteredBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Level and behaviors are applied from settings below
        // Show on all Spaces and during fullscreen as an auxiliary overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Visuals and interaction
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false  // Keep interactive
        // Panel behavior
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        // Apply current settings (level etc.)
        applySettingsToPanel(panel)
        return panel
    }

    private func updateBarFrameAndPosition(for monitor: Monitor, instance: MonitorBarInstance) {
        guard let screen = resolveNSScreen(for: monitor) else { return }

        let fittingSize = instance.hostingView.fittingSize
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let barHeight = max(menuBarHeight(for: screen), 24)

        // Check if notch-aware positioning is enabled
        let notchAware = CenteredBarSettings.shared.notchAware
        let screenHasNotch = hasNotch(screen: screen)

        let width: CGFloat
        let x: CGFloat
        let height = barHeight

        // Position bar based on position setting
        let position = CenteredBarSettings.shared.position
        let y: CGFloat
        if position == .belowMenuBar {
            y = visibleFrame.maxY - barHeight
        } else {
            y = visibleFrame.maxY
        }

        if notchAware && screenHasNotch {
            let notchClearance: CGFloat = 120
            x = screenFrame.midX + notchClearance
            let rightPadding: CGFloat = 20
            width = max(screenFrame.maxX - x - rightPadding, 100)
        } else {
            width = max(fittingSize.width, 300)
            x = screenFrame.midX - width / 2
        }

        instance.panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func removeCenteredBar() {
        // Clean up per-monitor bars
        for (_, instance) in barsByMonitor {
            instance.panel.orderOut(nil)
            instance.panel.close()
        }
        barsByMonitor.removeAll()
    }

    public func toggleCenteredBar(viewModel: TrayMenuModel) {
        if CenteredBarSettings.shared.enabled {
            setupCenteredBar(viewModel: viewModel)
        } else {
            removeCenteredBar()
        }
    }

    private func setupScreenChangeObserver() {
        // Listen for screen configuration changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                // Re-setup bars on screen change (handles monitor connect/disconnect)
                self.setupBars(viewModel: TrayMenuModel.shared)
            }
        }
    }

    func cleanup() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        removeCenteredBar()
    }

    // MARK: - Helpers
    private func applySettingsToPanel(_ panel: NSPanel) {
        panel.level = CenteredBarSettings.shared.windowLevel.nsWindowLevel
    }

    private func resolveNSScreen(for monitor: Monitor) -> NSScreen? {
        let idx = monitor.monitorAppKitNsScreenScreensId - 1
        return NSScreen.screens.indices.contains(idx) ? NSScreen.screens[idx] : nil
    }

    private func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : 28 // fallback
    }

    private func hasNotch(screen: NSScreen) -> Bool {
        // Detect notch via safeAreaInsets.top > 0
        // Available on macOS 12+ (Monterey and later)
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }
}
