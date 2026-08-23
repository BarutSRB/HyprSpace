// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
enum WorkspaceBarDataSource {
    private struct WorkspaceSnapshot {
        let workspace: WorkspaceDescriptor
        let tiledEntries: [WindowState]
        let floatingEntries: [WindowState]
        let hasBarOccupancy: Bool
    }

    private enum AppGroupKey: Hashable {
        case bundleId(String)
        case pid(pid_t)
    }

    static func workspaceBarProjection(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> WorkspaceBarProjection {
        WorkspaceBarProjection(
            items: workspaceItems(
                for: monitor,
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                iconResolver: iconResolver,
                focusedToken: focusedToken,
                settings: settings
            ),
            scratchpad: scratchpadItem(
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                iconResolver: iconResolver,
                focusedToken: focusedToken,
                settings: settings
            )
        )
    }

    private static func workspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
            workspaceSnapshot(
                for: workspace,
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache
            )
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
        let hiddenAppPIDs = workspaceManager.hiddenAppPIDs

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter { $0.hasBarOccupancy || $0.workspace.id == activeWorkspaceId }
        }

        return workspaces.map { snapshot in
            let topology = workspaceManager.layoutTopology(for: snapshot.workspace.id)
            let orderedTiledEntries = visibilityOrderedEntries(
                WorkspaceEntryOrdering.orderedEntries(
                    snapshot.tiledEntries,
                    topology: topology
                ),
                hiddenAppPIDs: hiddenAppPIDs
            )
            let orderedFloatingEntries = visibilityOrderedEntries(
                WorkspaceEntryOrdering.orderedEntries(
                    snapshot.floatingEntries,
                    topology: topology
                ),
                hiddenAppPIDs: hiddenAppPIDs
            )
            let useLayoutOrder = topology.hasColumns
            let tiledWindows = createWindowItems(
                entries: orderedTiledEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                iconResolver: iconResolver,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs,
                workspaceManager: workspaceManager
            )
            let floatingWindows = createWindowItems(
                entries: orderedFloatingEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                iconResolver: iconResolver,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs,
                workspaceManager: workspaceManager
            )

            return WorkspaceBarItem(
                id: snapshot.workspace.id,
                name: settings.displayName(for: snapshot.workspace.name),
                rawName: snapshot.workspace.name,
                isFocused: snapshot.workspace.id == activeWorkspaceId,
                tiledWindows: tiledWindows,
                floatingWindows: floatingWindows
            )
        }
    }

    private static func workspaceSnapshot(
        for workspace: WorkspaceDescriptor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache
    ) -> WorkspaceSnapshot {
        let projectedEntries = workspaceManager.barVisibleEntries(
            in: workspace.id,
            showFloatingWindows: options.showFloatingWindows
        )
        var tiledEntries: [WindowState] = []
        var floatingEntries: [WindowState] = []
        for entry in projectedEntries {
            if isExcluded(entry, options: options, appInfoCache: appInfoCache) {
                continue
            }
            switch entry.mode {
            case .tiling:
                tiledEntries.append(entry)
            case .floating:
                floatingEntries.append(entry)
            }
        }
        return WorkspaceSnapshot(
            workspace: workspace,
            tiledEntries: tiledEntries,
            floatingEntries: floatingEntries,
            hasBarOccupancy: !tiledEntries.isEmpty || !floatingEntries.isEmpty
        )
    }

    private static func scratchpadItem(
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> WorkspaceBarScratchpadItem? {
        guard let scratchpadToken = workspaceManager.scratchpadToken(),
              let entry = workspaceManager.entry(for: scratchpadToken),
              !isExcluded(entry, options: options, appInfoCache: appInfoCache),
              let window = createWindowItems(
                  entries: [entry],
                  deduplicate: false,
                  useLayoutOrder: false,
                  appInfoCache: appInfoCache,
                  iconResolver: iconResolver,
                  focusedToken: focusedToken,
                  hiddenAppPIDs: workspaceManager.hiddenAppPIDs,
                  workspaceManager: workspaceManager
              ).first
        else {
            return nil
        }

        let descriptor = workspaceManager.descriptor(for: entry.workspaceId)
        let rawWorkspaceName = descriptor?.name ?? ""
        return WorkspaceBarScratchpadItem(
            window: window,
            isVisible: workspaceManager.hiddenState(for: scratchpadToken) == nil
                && !workspaceManager.isAppHidden(pid: entry.pid),
            workspaceId: entry.workspaceId,
            workspaceName: settings.displayName(for: rawWorkspaceName),
            rawWorkspaceName: rawWorkspaceName
        )
    }

    private static func isExcluded(
        _ entry: WindowState,
        options: WorkspaceBarProjectionOptions,
        appInfoCache: AppInfoCache
    ) -> Bool {
        if entry.interactionPolicy.isHandsOff { return true }
        guard !options.excludedBundleIDs.isEmpty else { return false }
        return options.excludes(bundleId: bundleId(for: entry, appInfoCache: appInfoCache))
    }

    private static func createWindowItems(
        entries: [WindowState],
        deduplicate: Bool,
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>,
        workspaceManager: WorkspaceManager
    ) -> [WorkspaceBarWindowItem] {
        if deduplicate {
            return createDedupedWindowItems(
                entries: entries,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                iconResolver: iconResolver,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs,
                workspaceManager: workspaceManager
            )
        }

        return createIndividualWindowItems(
            entries: entries,
            appInfoCache: appInfoCache,
            iconResolver: iconResolver,
            focusedToken: focusedToken,
            hiddenAppPIDs: hiddenAppPIDs,
            workspaceManager: workspaceManager
        )
    }

    private static func createDedupedWindowItems(
        entries: [WindowState],
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>,
        workspaceManager: WorkspaceManager
    ) -> [WorkspaceBarWindowItem] {
        var entriesByApp: [AppGroupKey: [WindowState]] = [:]
        var appOrder: [AppGroupKey] = []
        entriesByApp.reserveCapacity(entries.count)
        appOrder.reserveCapacity(entries.count)

        for entry in entries {
            let groupKey = appGroupKey(for: entry, appInfoCache: appInfoCache)
            if entriesByApp[groupKey] == nil {
                entriesByApp[groupKey] = []
                appOrder.append(groupKey)
            }
            entriesByApp[groupKey]?.append(entry)
        }

        let indexedItems = appOrder.enumerated().compactMap { index, groupKey -> (Int, WorkspaceBarWindowItem)? in
            guard let appEntries = entriesByApp[groupKey],
                  let item = createDeduplicatedWindowItem(
                      entries: appEntries,
                      appInfoCache: appInfoCache,
                      iconResolver: iconResolver,
                      focusedToken: focusedToken,
                      hiddenAppPIDs: hiddenAppPIDs,
                      workspaceManager: workspaceManager
                  )
            else {
                return nil
            }
            return (index, item)
        }

        if useLayoutOrder {
            return indexedItems.map(\.1)
        }

        return indexedItems.sorted {
            if $0.1.isAppHidden != $1.1.isAppHidden {
                return !$0.1.isAppHidden
            }
            if $0.1.appName != $1.1.appName {
                return $0.1.appName < $1.1.appName
            }
            return $0.0 < $1.0
        }.map(\.1)
    }

    private static func createDeduplicatedWindowItem(
        entries: [WindowState],
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>,
        workspaceManager: WorkspaceManager
    ) -> WorkspaceBarWindowItem? {
        guard let firstEntry = entries.first,
              let firstHandle = workspaceManager.handle(for: firstEntry.token)
        else {
            return nil
        }
        let appInfo = entries.lazy.compactMap { appInfoCache.info(for: $0.pid) }.first
        let appName = appInfo?.name ?? "Unknown"
        let windowInfos = entries.compactMap { entry -> WorkspaceBarWindowInfo? in
            guard let handle = workspaceManager.handle(for: entry.token) else { return nil }
            return WorkspaceBarWindowInfo(
                id: entry.token,
                handle: handle,
                windowId: entry.windowId,
                title: windowTitle(for: entry) ?? appName,
                isFocused: entry.token == focusedToken,
                isAppHidden: hiddenAppPIDs.contains(entry.pid)
            )
        }

        return WorkspaceBarWindowItem(
            id: firstEntry.token,
            handle: firstHandle,
            windowId: firstEntry.windowId,
            appName: appName,
            icon: icon(
                for: firstEntry,
                appInfo: appInfo,
                iconResolver: iconResolver
            ),
            isFocused: entries.contains { $0.token == focusedToken },
            windowCount: windowInfos.count,
            hiddenWindowCount: windowInfos.count { $0.isAppHidden },
            allWindows: windowInfos
        )
    }

    private static func createIndividualWindowItems(
        entries: [WindowState],
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>,
        workspaceManager: WorkspaceManager
    ) -> [WorkspaceBarWindowItem] {
        entries.compactMap { entry -> WorkspaceBarWindowItem? in
            guard let handle = workspaceManager.handle(for: entry.token) else { return nil }
            let appInfo = appInfoCache.info(for: entry.pid)
            let appName = appInfo?.name ?? "Unknown"
            let title = windowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.token,
                handle: handle,
                windowId: entry.windowId,
                appName: appName,
                icon: icon(
                    for: entry,
                    appInfo: appInfo,
                    iconResolver: iconResolver
                ),
                isFocused: entry.token == focusedToken,
                windowCount: 1,
                hiddenWindowCount: hiddenAppPIDs.contains(entry.pid) ? 1 : 0,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.token,
                        handle: handle,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.token == focusedToken,
                        isAppHidden: hiddenAppPIDs.contains(entry.pid)
                    )
                ]
            )
        }
    }

    private static func icon(
        for entry: WindowState,
        appInfo: AppInfoCache.AppInfo?,
        iconResolver: WorkspaceBarIconResolver
    ) -> NSImage? {
        guard iconResolver.hasOverrides else { return appInfo?.icon }
        if let bundleId = normalizedBundleId(entry.managedReplacementMetadata?.bundleId)
            ?? normalizedBundleId(appInfo?.bundleId),
            let override = iconResolver.image(for: bundleId)
        {
            return override
        }
        return appInfo?.icon
    }

    private static func visibilityOrderedEntries(
        _ entries: [WindowState],
        hiddenAppPIDs: Set<pid_t>
    ) -> [WindowState] {
        var visible: [WindowState] = []
        var hidden: [WindowState] = []
        visible.reserveCapacity(entries.count)
        hidden.reserveCapacity(entries.count)
        for entry in entries {
            if hiddenAppPIDs.contains(entry.pid) {
                hidden.append(entry)
            } else {
                visible.append(entry)
            }
        }
        visible.append(contentsOf: hidden)
        return visible
    }

    private static func appGroupKey(
        for entry: WindowState,
        appInfoCache: AppInfoCache
    ) -> AppGroupKey {
        if let bundleId = bundleId(for: entry, appInfoCache: appInfoCache) {
            return .bundleId(bundleId.lowercased())
        }
        return .pid(entry.pid)
    }

    private static func bundleId(
        for entry: WindowState,
        appInfoCache: AppInfoCache
    ) -> String? {
        normalizedBundleId(entry.managedReplacementMetadata?.bundleId)
            ?? normalizedBundleId(appInfoCache.bundleId(for: entry.pid))
    }

    private static func normalizedBundleId(_ bundleId: String?) -> String? {
        guard let trimmed = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func windowTitle(for entry: WindowState) -> String? {
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
        return title
    }
}
