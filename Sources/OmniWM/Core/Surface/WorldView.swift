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

    var isNonManagedFocusActive: Bool {
        controller.workspaceManager.isNonManagedFocusActive
    }

    var suppressedFocusToken: WindowToken? {
        controller.workspaceManager.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        controller.workspaceManager.systemModalFocusToken
    }

    var hasPendingNativeFullscreenTransition: Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition
    }

    var isAppFullscreenActive: Bool {
        controller.workspaceManager.isAppFullscreenActive
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

    func isOwnedWindow(windowId: Int) -> Bool {
        controller.isOwnedWindow(windowNumber: windowId)
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
        for monitor in workspaceManager.monitors {
            guard let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            for entry in workspaceManager.entries(in: workspace.id) {
                guard entry.layoutReason == .nativeFullscreen,
                      !workspaceManager.isAppHidden(pid: entry.pid),
                      workspaceManager.showsNativeFullscreenPlaceholder(for: entry.token),
                      !workspaceManager.isHiddenInCorner(entry.token),
                      let frame = placeholderFrame(for: entry.token),
                      frame.width > 1, frame.height > 1
                else { continue }
                let appInfo = controller.appInfoCache.info(for: entry.pid)
                updates.append(
                    NativeFullscreenPlaceholderUpdate(
                        token: entry.token,
                        workspaceId: workspace.id,
                        frame: frame,
                        selected: workspaceManager.focusedToken == entry.token
                            || workspaceManager.pendingFocusedToken == entry.token,
                        appName: appInfo?.name,
                        icon: appInfo?.icon
                    )
                )
            }
        }
        return updates
    }

    private func placeholderFrame(for token: WindowToken) -> CGRect? {
        guard let workspaceId = controller.workspaceManager.entry(for: token)?.workspaceId else { return nil }
        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let node = controller.niriEngine?.findNode(for: token, in: workspaceId) else { return nil }
            return node.renderedFrame ?? node.frame
        case .dwindle:
            return controller.dwindleEngine?.findNode(for: token, in: workspaceId)?.cachedFrame
        }
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
        if entry.mode == .tiling,
           let applied = controller.axManager.lastAppliedFrame(for: entry.windowId)
        {
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
