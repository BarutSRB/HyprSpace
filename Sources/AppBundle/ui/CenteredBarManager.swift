import AppKit
import Common
import SwiftUI

// CENTERED BAR FEATURE
@MainActor
public class CenteredBarManager: ObservableObject {
    public static var shared: CenteredBarManager?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CenteredBarView>?
    private var screenObserver: Any?

    public init() {
        setupScreenChangeObserver()
    }

    public func setupCenteredBar(viewModel: TrayMenuModel) {
        guard CenteredBarSettings.shared.enabled else {
            removeCenteredBar()
            return
        }

        if panel == nil {
            panel = createCenteredPanel()
        }

        // Build content sized to menu bar height
        let screenForContent = resolveTargetScreen() ?? NSScreen.screens.first
        let barHeight = screenForContent.map(menuBarHeight(for:)).map { max($0, 24) } ?? 28
        let contentView = CenteredBarView(viewModel: viewModel, barHeight: barHeight)

        if hostingView == nil {
            hostingView = NSHostingView(rootView: contentView)
        } else {
            hostingView?.rootView = contentView
        }

        guard let panel,
              let hostingView else { return }

        // Set the hosting view as the panel's content view
        panel.contentView = hostingView

        // Apply settings and update the frame/position
        applySettingsToPanel(panel)
        updateFrameAndPosition()

        // Show the panel without taking key focus
        panel.orderFrontRegardless()
    }

    public func update(viewModel: TrayMenuModel) {
        guard CenteredBarSettings.shared.enabled else {
            removeCenteredBar()
            return
        }

        if panel == nil {
            setupCenteredBar(viewModel: viewModel)
        } else {
            // Update the content (recompute bar height for current screen)
            let screenForContent = resolveTargetScreen() ?? NSScreen.screens.first
            let barHeight = screenForContent.map(menuBarHeight(for:)).map { max($0, 24) } ?? 28
            hostingView?.rootView = CenteredBarView(viewModel: viewModel, barHeight: barHeight)
            if let panel {
                applySettingsToPanel(panel)
            }
            updateFrameAndPosition()
        }
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

    private func updateFrameAndPosition() {
        guard let panel,
              let hostingView else { return }

        // Calculate the required size
        let fittingSize = hostingView.fittingSize

        // Resolve target screen based on settings
        let screen = resolveTargetScreen()
        guard let screen else { return }

        // Use screen.frame for full screen including menu bar area
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame  // Keep for debug logging
        let barHeight = max(menuBarHeight(for: screen), 24)

        // Check if notch-aware positioning is enabled
        let notchAware = CenteredBarSettings.shared.notchAware
        let screenHasNotch = hasNotch(screen: screen)

        let width: CGFloat
        let x: CGFloat
        let height = barHeight  // Exactly match menu bar height
        let y = visibleFrame.maxY  // Bottom aligns with menu bar bottom

        if notchAware && screenHasNotch {
            // Notch-aware mode: position bar to the right of the notch
            // MacBook notches are ~200-220pt wide, so start at center + 120pt for clearance
            let notchClearance: CGFloat = 120
            x = screenFrame.midX + notchClearance

            // Calculate width from start position to right edge with padding
            let rightPadding: CGFloat = 20
            width = max(screenFrame.maxX - x - rightPadding, 100)  // Minimum 100px width
        } else {
            // Default centered mode
            width = max(fittingSize.width, 300)  // Force 300px minimum width
            x = screenFrame.midX - width / 2  // Center horizontally
        }

        // Set the panel frame
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        // Ensure SwiftUI content matches the new bar height
        let screenForContent = resolveTargetScreen() ?? NSScreen.screens.first
        let updatedBarHeight = screenForContent.map(menuBarHeight(for:)).map { max($0, 24) } ?? 28
        hostingView.rootView = CenteredBarView(viewModel: TrayMenuModel.shared, barHeight: updatedBarHeight)
    }

    func removeCenteredBar() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingView = nil
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
                self?.updateFrameAndPosition()
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

    private func resolveTargetScreen() -> NSScreen? {
        switch CenteredBarSettings.shared.targetDisplay {
            case .primary:
                let idx = mainMonitor.monitorAppKitNsScreenScreensId - 1
                return NSScreen.screens.indices.contains(idx) ? NSScreen.screens[idx] : NSScreen.screens.first
            case .mouse:
                let mouse = NSEvent.mouseLocation
                return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
            case .focused:
                let monitor = focus.workspace.workspaceMonitor
                let idx = monitor.monitorAppKitNsScreenScreensId - 1
                return NSScreen.screens.indices.contains(idx) ? NSScreen.screens[idx] : NSScreen.screens.first
        }
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
