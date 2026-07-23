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

    static func workspaceBarItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        workspaceItems(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            focusedToken: focusedToken,
            settings: settings
        )
    }

    static func workspaceBarProjection(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> WorkspaceBarProjection {
        WorkspaceBarProjection(
            items: workspaceItems(
                for: monitor,
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken,
                settings: settings
            ),
            scratchpad: scratchpadItem(
                options: options,
                workspaceManager: workspaceManager,
                appInfoCache: appInfoCache,
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

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter { $0.hasBarOccupancy || $0.workspace.id == activeWorkspaceId }
        }

        return workspaces.map { snapshot in
            let topology = workspaceManager.layoutTopology(for: snapshot.workspace.id)
            let orderedTiledEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.tiledEntries,
                topology: topology
            )
            let orderedFloatingEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.floatingEntries,
                topology: topology
            )
            let useLayoutOrder = topology.hasColumns
            let tiledWindows = createWindowItems(
                entries: orderedTiledEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
            )
            let floatingWindows = createWindowItems(
                entries: orderedFloatingEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
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
                  focusedToken: focusedToken
              ).first
        else {
            return nil
        }

        let descriptor = workspaceManager.descriptor(for: entry.workspaceId)
        let rawWorkspaceName = descriptor?.name ?? ""
        return WorkspaceBarScratchpadItem(
            window: window,
            isVisible: workspaceManager.hiddenState(for: scratchpadToken) == nil,
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
        guard !options.excludedBundleIDs.isEmpty else { return false }
        let bundleId = entry.managedReplacementMetadata?.bundleId ?? appInfoCache.bundleId(for: entry.pid)
        return options.excludes(bundleId: bundleId)
    }

    private static func createWindowItems(
        entries: [WindowState],
        deduplicate: Bool,
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        if deduplicate {
            return createDedupedWindowItems(
                entries: entries,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
            )
        }

        return createIndividualWindowItems(
            entries: entries,
            appInfoCache: appInfoCache,
            focusedToken: focusedToken
        )
    }

    private static func createDedupedWindowItems(
        entries: [WindowState],
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        if useLayoutOrder {
            var groupedByApp: [String: [WindowState]] = [:]
            var orderedAppNames: [String] = []

            for entry in entries {
                let appName = appInfoCache.name(for: entry.pid) ?? "Unknown"

                if groupedByApp[appName] == nil {
                    groupedByApp[appName] = []
                    orderedAppNames.append(appName)
                }

                groupedByApp[appName]?.append(entry)
            }

            return orderedAppNames.compactMap { appName -> WorkspaceBarWindowItem? in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let appInfo = appInfoCache.info(for: firstEntry.pid)
                let anyFocused = appEntries.contains { $0.token == focusedToken }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.token,
                        windowId: entry.windowId,
                        title: windowTitle(for: entry) ?? appName,
                        isFocused: entry.token == focusedToken
                    )
                }

                return WorkspaceBarWindowItem(
                    id: firstEntry.token,
                    windowId: firstEntry.windowId,
                    appName: appName,
                    icon: appInfo?.icon,
                    isFocused: anyFocused,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            appInfoCache.name(for: entry.pid) ?? "Unknown"
        }

        return groupedByApp.map { appName, appEntries -> WorkspaceBarWindowItem in
            let firstEntry = appEntries.first!
            let appInfo = appInfoCache.info(for: firstEntry.pid)
            let anyFocused = appEntries.contains { $0.token == focusedToken }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.token,
                    windowId: entry.windowId,
                    title: windowTitle(for: entry) ?? appName,
                    isFocused: entry.token == focusedToken
                )
            }

            return WorkspaceBarWindowItem(
                id: firstEntry.token,
                windowId: firstEntry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: anyFocused,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private static func createIndividualWindowItems(
        entries: [WindowState],
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let appInfo = appInfoCache.info(for: entry.pid)
            let appName = appInfo?.name ?? "Unknown"
            let title = windowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.token,
                windowId: entry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: entry.token == focusedToken,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.token,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.token == focusedToken
                    )
                ]
            )
        }
    }

    private static func windowTitle(for entry: WindowState) -> String? {
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
        return title
    }
}
