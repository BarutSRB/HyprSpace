// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct WorldView {
    private let controller: WMController
    private let borderFrameResolver: ((Int) -> CGRect?)?
    private let liveBoundsProvider: ((Int) -> CGRect?)?

    /// Creates a world view over the window-manager controller.
    /// - Parameters:
    ///   - controller: The window manager this view reads state from.
    ///   - borderFrameResolver: Optional override for resolving the border frame.
    ///   - liveBoundsProvider: Injectable source of live window bounds (defaults to
    ///     querying the WindowServer); lets tests supply synthetic bounds.
    init(
        controller: WMController,
        borderFrameResolver: ((Int) -> CGRect?)? = nil,
        liveBoundsProvider: ((Int) -> CGRect?)? = nil
    ) {
        self.controller = controller
        self.borderFrameResolver = borderFrameResolver
        self.liveBoundsProvider = liveBoundsProvider
    }

    var hasStartedServices: Bool {
        controller.hasStartedServices
    }

    var monitors: [Monitor] {
        controller.workspaceManager.monitors
    }

    var renderableFocusToken: WindowToken? {
        controller.workspaceManager.renderableFocusToken
    }

    var borderFocusToken: WindowToken? {
        controller.workspaceManager.borderFocusToken
    }

    var suppressedFocusToken: WindowToken? {
        controller.workspaceManager.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        controller.workspaceManager.systemModalFocusToken
    }

    func hasPendingNativeFullscreenTransition(for token: WindowToken) -> Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition(for: token)
    }

    func hasPendingNativeFullscreenTransition(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition(in: workspaceId)
    }

    var spaceTopology: SpaceTopology {
        controller.workspaceManager.spaceTopology
    }

    var borderConfig: BorderConfig {
        BorderConfig.from(settings: controller.settings)
    }

    func entry(for token: WindowToken) -> WindowState? {
        controller.workspaceManager.entry(for: token)
    }

    func isWindowFullscreenInLayout(_ token: WindowToken) -> Bool {
        guard let entry = controller.workspaceManager.entry(for: token) else { return false }
        switch controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) {
        case .dwindle:
            return controller.dwindleEngine?.isWindowFullscreen(token, in: entry.workspaceId) == true
        case .niri:
            return controller.niriEngine?.isWindowFullscreen(token, in: entry.workspaceId) == true
        }
    }

    func isManagedWindowDisplayable(_ token: WindowToken) -> Bool {
        controller.isManagedWindowDisplayable(token)
    }

    func isWorkspaceVisible(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
    }

    func tabRailInfos() -> [TabRailInfo] {
        var infos = controller.niriLayoutHandler.desiredTabRailInfos()
        infos.append(contentsOf: controller.dwindleLayoutHandler.desiredTabRailInfos())
        return infos
    }

    func barSurfaces() -> [DesiredBarSurface] {
        guard controller.hasWorkspaceBarDataConsumers else { return [] }
        let settings = controller.settings
        var bars: [DesiredBarSurface] = []
        for monitor in controller.workspaceManager.monitors {
            let resolved = settings.resolvedBarSettings(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            let projection = controller.workspaceBarProjection(
                for: monitor,
                projection: resolved.projectionOptions
            )
            bars.append(
                DesiredBarSurface(
                    monitor: monitor,
                    visible: controller.isWorkspaceBarVisible(on: monitor, resolved: resolved),
                    snapshot: WorkspaceBarSnapshot(
                        projection: projection,
                        showLabels: resolved.showLabels,
                        showSystemStatsButton: resolved.systemStatsButton,
                        backgroundOpacity: resolved.backgroundOpacity,
                        barHeight: geometry.barHeight,
                        accentColor: resolved.accentColor,
                        textColor: resolved.textColor
                    )
                )
            )
        }
        return bars
    }

    func nativeFullscreenPlaceholders() -> [NativeFullscreenPlaceholderUpdate] {
        let workspaceManager = controller.workspaceManager
        var updates: [NativeFullscreenPlaceholderUpdate] = []
        for record in workspaceManager.nativeFullscreenRecordsByOriginalToken.values {
            let entry = workspaceManager.entry(for: record.currentToken)
            updates.append(
                NativeFullscreenPlaceholderUpdate(
                    originalToken: record.originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    frame: .zero,
                    displayContext: nil,
                    selected: workspaceManager.selectedManagedToken == record.currentToken
                        || workspaceManager.pendingFocusedToken == record.currentToken,
                    visible: record.transition == .suspended
                        && entry?.layoutReason == .nativeFullscreen
                        && entry.map(isPlaceholderDescriptorVisible(entry:)) == true
                )
            )
        }
        updates.sort {
            ($0.originalToken.pid, $0.originalToken.windowId) < ($1.originalToken.pid, $1.originalToken.windowId)
        }
        return updates
    }

    private func isPlaceholderDescriptorVisible(entry: WindowState) -> Bool {
        let workspaceManager = controller.workspaceManager
        guard isWorkspaceVisible(entry.workspaceId),
              !workspaceManager.isAppHidden(pid: entry.pid),
              !workspaceManager.isHiddenInCorner(entry.token)
        else { return false }
        guard spaceTopology.isPopulated,
              let monitor = workspaceManager.monitor(for: entry.workspaceId),
              spaceTopology.isDisplayShowingFullscreenSpace(on: monitor) == false
        else { return false }
        return true
    }

    /// Resolves the frame the focused-window border ring should hug.
    /// The ring follows presentation truth: live WindowServer bounds win whenever
    /// they can be queried (apps apply AX writes late and may constrain themselves,
    /// so layout-intent frames can overlap the presented window). Pending AX writes
    /// and layout caches only backfill when live bounds are unavailable.
    /// - Returns: The frame to draw the border around, or `nil` when the window has
    ///   no usable geometry from any source.
    func borderFrame(for entry: WindowState) -> CGRect? {
        // The ring hugs what is actually presented: live WindowServer bounds are the
        // ground truth for overlay placement, even while an AX write is still pending
        // (apps may apply writes late or constrain themselves — issues #211/#223/#380).
        // Pending writes and layout caches only backfill when live bounds are unavailable.
        if let observed = observedWindowBounds(windowId: entry.windowId) {
            return observed
        }
        if let pending = controller.axManager.pendingFrameWrite(for: entry.windowId) {
            return pending
        }
        return cachedBorderFrame(for: entry) ?? borderFrameResolver?(entry.windowId)
    }

    func cachedBorderFrame(for entry: WindowState) -> CGRect? {
        if let pending = controller.axManager.pendingFrameWrite(for: entry.windowId) {
            return pending
        }
        if entry.mode == .floating {
            if let observed = entry.observedState.frame {
                return observed
            }
            if let desired = entry.desiredState.floatingFrame {
                return desired
            }
            if let lastFloatingFrame = entry.floatingState?.lastFrame {
                return lastFloatingFrame
            }
        } else if let applied = controller.axManager.lastAppliedFrame(for: entry.windowId) {
            return applied
        }
        return nil
    }

    /// Returns the window's live bounds in AppKit screen coordinates, or `nil` when
    /// the window has no positive-size WindowServer bounds.
    func observedWindowBounds(windowId: Int) -> CGRect? {
        if let liveBoundsProvider {
            return liveBoundsProvider(windowId)
        }
        guard windowId > 0,
              let bounds = SkyLight.shared.getWindowBounds(UInt32(windowId)),
              bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: bounds)
    }
}
