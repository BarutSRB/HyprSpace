// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

@MainActor
final class IPCQueryRouter {
    let controller: WMController
    private let appVersion: String?
    private let sessionToken: String
    var windowOrderedInProvider: (UInt32) -> Bool? = { SkyLight.shared.isWindowOrderedIn($0) }

    init(
        controller: WMController,
        appVersion: String? = Bundle.main.appVersion,
        sessionToken: String
    ) {
        self.controller = controller
        self.appVersion = appVersion
        self.sessionToken = sessionToken
    }

    func pingResult() -> IPCPingResult {
        IPCPingResult()
    }

    func versionResult() -> IPCVersionResult {
        IPCVersionResult(protocolVersion: OmniWMIPCProtocol.version, appVersion: appVersion)
    }

    func workspaceBarResult() -> IPCWorkspaceBarQueryResult {
        let monitors = controller.workspaceManager.monitors.map { monitor in
            let resolved = controller.settings.resolvedBarSettings(for: monitor)
            let isVisible = controller.isWorkspaceBarVisible(on: monitor, resolved: resolved)
            let geometry = WorkspaceBarGeometry.resolve(
                monitor: monitor,
                resolved: resolved,
                isVisible: isVisible
            )
            let projection = controller.workspaceBarProjection(
                for: monitor,
                projection: resolved.projectionOptions
            )

            return IPCWorkspaceBarMonitor(
                id: monitorIdentifier(monitor.id),
                name: monitor.name,
                enabled: resolved.enabled,
                isVisible: isVisible,
                showLabels: resolved.showLabels,
                backgroundOpacity: resolved.backgroundOpacity,
                barHeight: Double(geometry.barHeight),
                scratchpads: projection.scratchpads.map(workspaceBarScratchpad(from:)),
                workspaces: projection.items.map(workspaceBarWorkspace(from:))
            )
        }

        return IPCWorkspaceBarQueryResult(
            interactionMonitorId: controller.workspaceManager.interactionMonitorId.map(monitorIdentifier),
            monitors: monitors
        )
    }

    func activeWorkspaceResult() -> IPCActiveWorkspaceQueryResult {
        let (monitor, workspace) = controller.interactionWorkspaceProjection()
        let focusedApp: IPCAppRef?

        if let workspace,
           let focusedToken = controller.workspaceManager.nativeManagedFocusToken,
           let entry = controller.workspaceManager.entry(for: focusedToken),
           entry.workspaceId == workspace.id
        {
            focusedApp = appRef(from: controller.appInfoCache.info(for: entry.pid))
        } else {
            focusedApp = nil
        }

        return IPCActiveWorkspaceQueryResult(
            display: monitor.map(displayRef(from:)),
            workspace: workspace.map(workspaceRef(from:)),
            focusedApp: focusedApp
        )
    }

    func focusedMonitorResult() -> IPCFocusedMonitorQueryResult {
        let (monitor, activeWorkspace) = controller.interactionWorkspaceProjection()

        return IPCFocusedMonitorQueryResult(
            display: monitor.map(displayRef(from:)),
            activeWorkspace: activeWorkspace.map(workspaceRef(from:))
        )
    }

    func appsResult() -> IPCAppsQueryResult {
        IPCAppsQueryResult(
            apps: controller.runningAppsWithWindows().map { app in
                IPCManagedAppSummary(
                    bundleId: app.bundleId ?? "",
                    appName: app.appName,
                    windowSize: IPCSize(
                        width: app.windowSize.width,
                        height: app.windowSize.height
                    )
                )
            }
        )
    }

    func focusedWindowResult() -> IPCFocusedWindowQueryResult {
        guard let focusedToken = controller.workspaceManager.nativeManagedFocusToken,
              let entry = controller.workspaceManager.entry(for: focusedToken)
        else {
            return IPCFocusedWindowQueryResult(window: nil)
        }

        let workspaceDescriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
        let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let appInfo = controller.appInfoCache.info(for: entry.pid)
        let frame = AXWindowService.framePreferFast(entry.axRef)
        let snapshot = IPCFocusedWindowSnapshot(
            id: windowIdentifier(focusedToken),
            pid: entry.pid,
            workspace: workspaceDescriptor.map(workspaceRef(from:)),
            display: monitor.map(displayRef(from:)),
            app: appRef(from: appInfo),
            title: AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
            frame: frame.map(rect(from:))
        )

        return IPCFocusedWindowQueryResult(window: snapshot)
    }

    func windowsResult(_ request: IPCQueryRequest) -> IPCWindowsQueryResult {
        let fieldSet = requestedFieldSet(from: request)
        let focusedToken = controller.workspaceManager.nativeManagedFocusToken
        let visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
        let windows = orderedWorkspaces().flatMap { workspace in
            WorkspaceEntryOrdering.orderedEntries(
                controller.workspaceManager.entries(in: workspace.id),
                topology: controller.workspaceManager.layoutTopology(for: workspace.id)
            )
            .filter { entry in
                matchesWindowQuery(
                    entry,
                    selectors: request.selectors,
                    focusedToken: focusedToken,
                    visibleWorkspaceIds: visibleWorkspaceIds
                )
            }
            .map { entry in
                windowSnapshot(
                    from: entry,
                    focusedToken: focusedToken,
                    visibleWorkspaceIds: visibleWorkspaceIds,
                    fields: fieldSet
                )
            }
        }

        return IPCWindowsQueryResult(windows: windows)
    }

    func workspacesResult(_ request: IPCQueryRequest) -> IPCWorkspacesQueryResult {
        let fieldSet = requestedFieldSet(from: request)
        let focusedWindowToken = controller.workspaceManager.nativeManagedFocusToken
        let focusedWorkspaceId = controller.workspaceManager.nativeManagedFocusToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        let currentWorkspaceId = controller.interactionWorkspaceProjection().workspace?.id
        let visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
        let workspaces = orderedWorkspaces()
            .filter { descriptor in
                matchesWorkspaceQuery(
                    descriptor,
                    selectors: request.selectors,
                    focusedWorkspaceId: focusedWorkspaceId,
                    currentWorkspaceId: currentWorkspaceId,
                    visibleWorkspaceIds: visibleWorkspaceIds
                )
            }
            .map { descriptor in
                workspaceSnapshot(
                    from: descriptor,
                    focusedWindowToken: focusedWindowToken,
                    focusedWorkspaceId: focusedWorkspaceId,
                    currentWorkspaceId: currentWorkspaceId,
                    visibleWorkspaceIds: visibleWorkspaceIds,
                    fields: fieldSet
                )
            }

        return IPCWorkspacesQueryResult(workspaces: workspaces)
    }

    func displaysResult(_ request: IPCQueryRequest) -> IPCDisplaysQueryResult {
        let fieldSet = requestedFieldSet(from: request)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let displays = Monitor.sortedByPosition(controller.workspaceManager.monitors)
            .filter { monitor in
                matchesDisplayQuery(monitor, selectors: request.selectors, currentMonitorId: currentMonitorId)
            }
            .map { monitor in
                displaySnapshot(from: monitor, currentMonitorId: currentMonitorId, fields: fieldSet)
            }

        return IPCDisplaysQueryResult(displays: displays)
    }

    func rulesResult() -> IPCRulesQueryResult {
        IPCRuleProjection.result(
            settings: controller.settings,
            windowRuleEngine: controller.windowRuleEngine
        )
    }

    func ruleActionsResult() -> IPCRuleActionsQueryResult {
        IPCRuleActionsQueryResult(ruleActions: IPCAutomationManifest.ruleActionDescriptors)
    }

    func queriesResult() -> IPCQueriesQueryResult {
        IPCQueriesQueryResult(queries: IPCAutomationManifest.queryDescriptors)
    }

    func commandsResult() -> IPCCommandsQueryResult {
        IPCCommandsQueryResult(
            commands: IPCAutomationManifest.commandDescriptors,
            workspaceActions: IPCAutomationManifest.workspaceActionDescriptors,
            windowActions: IPCAutomationManifest.windowActionDescriptors
        )
    }

    func subscriptionsResult() -> IPCSubscriptionsQueryResult {
        IPCSubscriptionsQueryResult(subscriptions: IPCAutomationManifest.subscriptionDescriptors)
    }

    func capabilitiesResult() -> IPCCapabilitiesQueryResult {
        IPCCapabilitiesQueryResult(
            protocolVersion: OmniWMIPCProtocol.version,
            appVersion: appVersion,
            authorizationRequired: true,
            windowIdScope: "session",
            queries: IPCAutomationManifest.queryDescriptors,
            commands: IPCAutomationManifest.commandDescriptors,
            captureActions: IPCAutomationManifest.captureActionDescriptors,
            ruleActions: IPCAutomationManifest.ruleActionDescriptors,
            workspaceActions: IPCAutomationManifest.workspaceActionDescriptors,
            windowActions: IPCAutomationManifest.windowActionDescriptors,
            subscriptions: IPCAutomationManifest.subscriptionDescriptors
        )
    }

    private func workspaceBarWorkspace(from item: WorkspaceBarItem) -> IPCWorkspaceBarWorkspace {
        IPCWorkspaceBarWorkspace(
            id: workspaceIdentifier(item.id),
            rawName: item.rawName,
            displayName: item.name,
            number: workspaceNumber(from: item.rawName),
            isFocused: item.isFocused,
            windows: item.windows.map(workspaceBarApp(from:))
        )
    }

    private func workspaceBarApp(from item: WorkspaceBarWindowItem) -> IPCWorkspaceBarApp {
        IPCWorkspaceBarApp(
            id: windowIdentifier(item.id),
            appName: item.appName,
            isFocused: item.isFocused,
            windowCount: item.windowCount,
            allWindows: item.allWindows.map { window in
                IPCWorkspaceBarWindow(
                    id: windowIdentifier(window.id),
                    title: window.title,
                    isFocused: window.isFocused
                )
            }
        )
    }

    private func workspaceBarScratchpad(from item: WorkspaceBarScratchpadItem) -> IPCWorkspaceBarScratchpad {
        IPCWorkspaceBarScratchpad(
            index: item.index,
            label: item.label,
            windows: item.windows.map(workspaceBarApp(from:)),
            isVisible: item.isVisible
        )
    }

    private func windowSnapshot(
        from entry: WindowState,
        focusedToken: WindowToken?,
        visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        fields: Set<String>?
    ) -> IPCWindowQuerySnapshot {
        let workspaceDescriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
        let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let appInfo = controller.appInfoCache.info(for: entry.pid)
        let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)
        let isAppHidden = controller.workspaceManager.isAppHidden(pid: entry.pid)
        let scratchpadIndex = controller.workspaceManager.scratchpadIndex(for: entry.token)
        let isVisible = isWindowVisible(
            entry,
            visibleWorkspaceIds: visibleWorkspaceIds,
            hiddenState: hiddenState,
            isAppHidden: isAppHidden
        )

        return IPCWindowQuerySnapshot(
            id: include("id", in: fields) ? windowIdentifier(entry.token) : nil,
            pid: include("pid", in: fields) ? entry.pid : nil,
            workspace: include("workspace", in: fields) ? workspaceDescriptor.map(workspaceRef(from:)) : nil,
            display: include("display", in: fields) ? monitor.map(displayRef(from:)) : nil,
            app: include("app", in: fields) ? appRef(from: appInfo) : nil,
            title: include("title", in: fields) ? AXWindowService
                .titlePreferFast(windowId: UInt32(entry.windowId)) : nil,
            frame: include("frame", in: fields) ? AXWindowService.framePreferFast(entry.axRef).map(rect(from:)) : nil,
            mode: include("mode", in: fields) ? ipcWindowMode(from: entry.mode) : nil,
            layoutReason: include("layout-reason", in: fields) ? ipcLayoutReason(from: entry.layoutReason) : nil,
            manualOverride: include("manual-override", in: fields)
                ? controller.workspaceManager.manualLayoutOverride(for: entry.token).map(ipcManualOverride(from:))
                : nil,
            isFocused: include("is-focused", in: fields) ? (entry.token == focusedToken) : nil,
            isVisible: include("is-visible", in: fields) ? isVisible : nil,
            isAppHidden: include("is-app-hidden", in: fields) ? isAppHidden : nil,
            isScratchpad: include("is-scratchpad", in: fields) ? scratchpadIndex != nil : nil,
            scratchpadIndex: include("scratchpad-index", in: fields) ? scratchpadIndex?.rawValue : nil,
            hiddenReason: include("hidden-reason", in: fields) ? hiddenState.map(ipcHiddenReason(from:)) : nil
        )
    }

    private func workspaceSnapshot(
        from descriptor: WorkspaceDescriptor,
        focusedWindowToken: WindowToken?,
        focusedWorkspaceId: WorkspaceDescriptor.ID?,
        currentWorkspaceId: WorkspaceDescriptor.ID?,
        visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        fields: Set<String>?
    ) -> IPCWorkspaceQuerySnapshot {
        let monitor = controller.workspaceManager.monitor(for: descriptor.id)
        let entries = controller.workspaceManager.entries(in: descriptor.id)
        let floatingCount = entries.filter { $0.mode == .floating }.count
        let scratchpadCount = entries.filter { controller.workspaceManager.isScratchpadToken($0.token) }.count
        let counts = IPCWorkspaceWindowCounts(
            total: entries.count,
            tiled: entries.filter { $0.mode == .tiling }.count,
            floating: floatingCount,
            scratchpad: scratchpadCount
        )
        let focusedWindowId = focusedWindowToken
            .flatMap { controller.workspaceManager.entry(for: $0) }
            .flatMap { entry in
                entry.workspaceId == descriptor.id ? windowIdentifier(entry.token) : nil
            }

        return IPCWorkspaceQuerySnapshot(
            id: include("id", in: fields) ? workspaceIdentifier(descriptor.id) : nil,
            rawName: include("raw-name", in: fields) ? descriptor.name : nil,
            displayName: include("display-name", in: fields) ? controller.settings
                .displayName(for: descriptor.name) : nil,
            number: include("number", in: fields) ? workspaceNumber(from: descriptor) : nil,
            layout: include("layout", in: fields) ?
                ipcWorkspaceLayout(from: controller.settings.layoutType(for: descriptor.name)) : nil,
            display: include("display", in: fields) ? monitor.map(displayRef(from:)) : nil,
            isFocused: include("is-focused", in: fields) ? (focusedWorkspaceId == descriptor.id) : nil,
            isVisible: include("is-visible", in: fields) ? visibleWorkspaceIds.contains(descriptor.id) : nil,
            isCurrent: include("is-current", in: fields) ? (currentWorkspaceId == descriptor.id) : nil,
            counts: include("window-counts", in: fields) ? counts : nil,
            focusedWindowId: include("focused-window-id", in: fields) ? focusedWindowId : nil
        )
    }

    private func displaySnapshot(
        from monitor: Monitor,
        currentMonitorId: Monitor.ID?,
        fields: Set<String>?
    ) -> IPCDisplayQuerySnapshot {
        let activeWorkspace = controller.workspaceManager.activeWorkspace(on: monitor.id)
        let gaps = controller.settings.resolvedGapSettings(for: monitor)
        return IPCDisplayQuerySnapshot(
            id: include("id", in: fields) ? monitorIdentifier(monitor.id) : nil,
            name: include("name", in: fields) ? monitor.name : nil,
            isMain: include("is-main", in: fields) ? monitor.isMain : nil,
            isCurrent: include("is-current", in: fields) ? (currentMonitorId == monitor.id) : nil,
            frame: include("frame", in: fields) ? rect(from: monitor.frame) : nil,
            visibleFrame: include("visible-frame", in: fields) ? rect(from: monitor.visibleFrame) : nil,
            hasNotch: include("has-notch", in: fields) ? monitor.hasNotch : nil,
            orientation: include("orientation", in: fields)
                ? ipcDisplayOrientation(from: controller.settings.effectiveOrientation(for: monitor)) : nil,
            innerGap: include("inner-gap", in: fields) ? Double(gaps.innerGap) : nil,
            outerGapLeft: include("outer-gap-left", in: fields) ? Double(gaps.outerGapLeft) : nil,
            outerGapRight: include("outer-gap-right", in: fields) ? Double(gaps.outerGapRight) : nil,
            outerGapTop: include("outer-gap-top", in: fields) ? Double(gaps.outerGapTop) : nil,
            outerGapBottom: include("outer-gap-bottom", in: fields) ? Double(gaps.outerGapBottom) : nil,
            fullscreenUsesOuterGaps: include("fullscreen-uses-outer-gaps", in: fields)
                ? gaps.fullscreenUsesOuterGaps : nil,
            activeWorkspace: include("active-workspace", in: fields) ? activeWorkspace.map(workspaceRef(from:)) : nil
        )
    }

    private func matchesWindowQuery(
        _ entry: WindowState,
        selectors: IPCQuerySelectors,
        focusedToken: WindowToken?,
        visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Bool {
        if let windowSelector = selectors.window {
            switch IPCWindowOpaqueID.validate(windowSelector, expectingSessionToken: sessionToken) {
            case let .valid(pid, windowId):
                guard entry.pid == pid, entry.windowId == windowId else { return false }
            case .stale,
                 .invalid:
                return false
            }
        }

        if let workspaceSelector = selectors.workspace,
           !matchesWorkspaceSelector(workspaceId: entry.workspaceId, candidate: workspaceSelector)
        {
            return false
        }

        if let displaySelector = selectors.display,
           !matchesDisplaySelector(
               monitor: controller.workspaceManager.monitor(for: entry.workspaceId),
               candidate: displaySelector
           )
        {
            return false
        }

        if selectors.focused == true, entry.token != focusedToken {
            return false
        }

        if selectors.visible == true {
            let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)
            let isAppHidden = controller.workspaceManager.isAppHidden(pid: entry.pid)
            if !isWindowVisible(
                entry,
                visibleWorkspaceIds: visibleWorkspaceIds,
                hiddenState: hiddenState,
                isAppHidden: isAppHidden
            ) {
                return false
            }
        }

        if selectors.floating == true, entry.mode != .floating {
            return false
        }

        if selectors.scratchpad == true, !controller.workspaceManager.isScratchpadToken(entry.token) {
            return false
        }

        if let appSelector = selectors.app {
            let appName = controller.appInfoCache.info(for: entry.pid)?.name
            guard appName?.localizedCaseInsensitiveCompare(appSelector) == .orderedSame else { return false }
        }

        if let bundleIdSelector = selectors.bundleId {
            let bundleId = controller.appInfoCache.info(for: entry.pid)?.bundleId
            guard bundleId?.localizedCaseInsensitiveCompare(bundleIdSelector) == .orderedSame else { return false }
        }

        return true
    }

    private func isWindowVisible(
        _ entry: WindowState,
        visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        hiddenState: HiddenState?,
        isAppHidden: Bool
    ) -> Bool {
        guard visibleWorkspaceIds.contains(entry.workspaceId),
              hiddenState == nil,
              !isAppHidden
        else {
            return false
        }
        return windowOrderedInProvider(UInt32(entry.windowId)) ?? true
    }

    private func matchesWorkspaceQuery(
        _ descriptor: WorkspaceDescriptor,
        selectors: IPCQuerySelectors,
        focusedWorkspaceId: WorkspaceDescriptor.ID?,
        currentWorkspaceId: WorkspaceDescriptor.ID?,
        visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Bool {
        if let workspaceSelector = selectors.workspace,
           !matchesWorkspaceSelector(workspaceId: descriptor.id, candidate: workspaceSelector)
        {
            return false
        }

        if let displaySelector = selectors.display,
           !matchesDisplaySelector(
               monitor: controller.workspaceManager.monitor(for: descriptor.id),
               candidate: displaySelector
           )
        {
            return false
        }

        if selectors.current == true, descriptor.id != currentWorkspaceId {
            return false
        }

        if selectors.visible == true, !visibleWorkspaceIds.contains(descriptor.id) {
            return false
        }

        if selectors.focused == true, descriptor.id != focusedWorkspaceId {
            return false
        }

        return true
    }

    private func matchesDisplayQuery(
        _ monitor: Monitor,
        selectors: IPCQuerySelectors,
        currentMonitorId: Monitor.ID?
    ) -> Bool {
        if let displaySelector = selectors.display,
           !matchesDisplaySelector(monitor: monitor, candidate: displaySelector)
        {
            return false
        }

        if selectors.main == true, !monitor.isMain {
            return false
        }

        if selectors.current == true, monitor.id != currentMonitorId {
            return false
        }

        return true
    }

    private func matchesWorkspaceSelector(workspaceId: WorkspaceDescriptor.ID, candidate: String) -> Bool {
        guard let descriptor = controller.workspaceManager.descriptor(for: workspaceId) else { return false }
        if workspaceIdentifier(descriptor.id) == candidate {
            return true
        }
        if descriptor.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame {
            return true
        }
        let displayName = controller.settings.displayName(for: descriptor.name)
        return displayName.localizedCaseInsensitiveCompare(candidate) == .orderedSame
    }

    private func matchesDisplaySelector(monitor: Monitor?, candidate: String) -> Bool {
        guard let monitor else { return false }
        if monitorIdentifier(monitor.id) == candidate {
            return true
        }
        if String(monitor.id.displayId) == candidate {
            return true
        }
        return monitor.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
    }

    private func requestedFieldSet(from request: IPCQueryRequest) -> Set<String>? {
        guard !request.fields.isEmpty else { return nil }
        return Set(request.fields)
    }

    private func include(_ field: String, in fields: Set<String>?) -> Bool {
        guard let fields else { return true }
        return fields.contains(field)
    }

    private func orderedWorkspaces() -> [WorkspaceDescriptor] {
        let orderedMonitors = Monitor.sortedByPosition(controller.workspaceManager.monitors)
        var orderedWorkspaces: [WorkspaceDescriptor] = []
        var seenWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for monitor in orderedMonitors {
            for workspace in controller.workspaceManager.workspaces(on: monitor.id) {
                guard seenWorkspaceIds.insert(workspace.id).inserted else { continue }
                orderedWorkspaces.append(workspace)
            }
        }

        for workspace in controller.workspaceManager.workspaces where seenWorkspaceIds.insert(workspace.id).inserted {
            orderedWorkspaces.append(workspace)
        }

        return orderedWorkspaces
    }

    private func workspaceNumber(from descriptor: WorkspaceDescriptor) -> Int? {
        workspaceNumber(from: descriptor.name)
    }

    private func workspaceNumber(from rawName: String) -> Int? {
        WorkspaceIDPolicy.workspaceNumber(from: rawName)
    }

    private func rect(from rect: CGRect) -> IPCRect {
        IPCRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func workspaceIdentifier(_ id: WorkspaceDescriptor.ID) -> String {
        id.uuidString
    }

    private func workspaceRef(from descriptor: WorkspaceDescriptor) -> IPCWorkspaceRef {
        IPCWorkspaceRef(
            id: workspaceIdentifier(descriptor.id),
            rawName: descriptor.name,
            displayName: controller.settings.displayName(for: descriptor.name),
            number: workspaceNumber(from: descriptor)
        )
    }

    private func monitorIdentifier(_ id: Monitor.ID) -> String {
        "display:\(id.displayId)"
    }

    private func displayRef(from monitor: Monitor) -> IPCDisplayRef {
        IPCDisplayRef(
            id: monitorIdentifier(monitor.id),
            name: monitor.name,
            isMain: monitor.isMain
        )
    }

    private func windowIdentifier(_ token: WindowToken) -> String {
        IPCWindowOpaqueID.encode(
            pid: token.pid,
            windowId: token.windowId,
            sessionToken: sessionToken
        )
    }

    private func appRef(from appInfo: AppInfoCache.AppInfo?) -> IPCAppRef? {
        guard let appInfo, let name = appInfo.name else { return nil }
        return IPCAppRef(name: name, bundleId: appInfo.bundleId)
    }

    private func appRef(name: String?, bundleId: String?) -> IPCAppRef? {
        guard let name else { return nil }
        return IPCAppRef(name: name, bundleId: bundleId)
    }

    private func ipcWindowMode(from mode: TrackedWindowMode) -> IPCWindowMode {
        switch mode {
        case .tiling:
            .tiling
        case .floating:
            .floating
        }
    }

    private func ipcLayoutReason(from reason: LayoutReason) -> IPCLayoutReason {
        switch reason {
        case .standard:
            .standard
        case .nativeFullscreen:
            .nativeFullscreen
        }
    }

    private func ipcWorkspaceLayout(from layout: LayoutType) -> IPCWorkspaceLayout {
        switch layout {
        case .defaultLayout:
            .defaultLayout
        case .niri:
            .niri
        case .dwindle:
            .dwindle
        }
    }

    private func ipcManualOverride(from override: ManualWindowOverride) -> IPCManualWindowOverride {
        switch override {
        case .forceTile:
            .forceTile
        case .forceFloat:
            .forceFloat
        }
    }

    private func ipcHiddenReason(from hiddenState: HiddenState) -> IPCHiddenReason {
        switch hiddenState.reason {
        case .workspaceInactive:
            .workspaceInactive
        case .layoutTransient:
            .layoutTransient
        case .scratchpad:
            .scratchpad
        }
    }

    private func ipcDisplayOrientation(from orientation: Monitor.Orientation) -> IPCDisplayOrientation {
        switch orientation {
        case .horizontal:
            .horizontal
        case .vertical:
            .vertical
        }
    }
}
