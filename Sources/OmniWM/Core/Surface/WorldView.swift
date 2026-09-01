// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct WorldView {
    private let controller: WMController
    private let borderFrameResolver: ((Int) -> CGRect?)?

    init(controller: WMController, borderFrameResolver: ((Int) -> CGRect?)? = nil) {
        self.controller = controller
        self.borderFrameResolver = borderFrameResolver
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

    func borderFrame(for entry: WindowState) -> CGRect? {
        if let borderFrameResolver {
            return borderFrameResolver(entry.windowId)
        }
        if let cached = cachedBorderFrame(for: entry) {
            return cached
        }
        BorderOpMetricsRecorder.shared.noteBoundsQueryFallback()
        return observedWindowBounds(windowId: entry.windowId)
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

    func observedWindowBounds(windowId: Int) -> CGRect? {
        guard windowId > 0,
              let bounds = SkyLight.shared.getWindowBounds(UInt32(windowId)),
              bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: bounds)
    }
}
