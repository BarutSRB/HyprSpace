// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WorkspaceBarDataSourceTests: XCTestCase {
    private struct Fixture {
        let settings: SettingsStore
        let workspaceManager: WorkspaceManager
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let appInfoCache: AppInfoCache
        let iconResolver: WorkspaceBarIconResolver
    }

    private struct WindowSpec {
        let token: WindowToken
        let bundleId: String?
        let mode: TrackedWindowMode
    }

    private struct FilteringWindows {
        let excludedTiledOne = WindowToken(pid: 42_001, windowId: 42_101)
        let excludedTiledTwo = WindowToken(pid: 42_002, windowId: 42_102)
        let retainedTiledOne = WindowToken(pid: 42_003, windowId: 42_103)
        let retainedTiledTwo = WindowToken(pid: 42_004, windowId: 42_104)
        let excludedFloating = WindowToken(pid: 42_005, windowId: 42_105)
        let retainedFloating = WindowToken(pid: 42_006, windowId: 42_106)

        var specs: [WindowSpec] {
            [
                WindowSpec(token: excludedTiledOne, bundleId: "com.example.excluded", mode: .tiling),
                WindowSpec(token: excludedTiledTwo, bundleId: "com.example.excluded", mode: .tiling),
                WindowSpec(token: retainedTiledOne, bundleId: "com.example.retained.one", mode: .tiling),
                WindowSpec(token: retainedTiledTwo, bundleId: "com.example.retained.two", mode: .tiling),
                WindowSpec(token: excludedFloating, bundleId: "com.example.excluded", mode: .floating),
                WindowSpec(token: retainedFloating, bundleId: "com.example.retained.floating", mode: .floating)
            ]
        }
    }

    func testFiltersTiledAndFloatingEntriesBeforeDeduplication() throws {
        let fixture = try makeFixture()
        let windows = FilteringWindows()
        addWindows(windows.specs, to: fixture)

        let projection = project(
            fixture,
            deduplicate: true,
            showFloatingWindows: true,
            excludedBundleIDs: ["COM.EXAMPLE.EXCLUDED"]
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertEqual(item.tiledWindows.count, 2)
        XCTAssertTrue(item.tiledWindows.allSatisfy { $0.windowCount == 1 })
        XCTAssertEqual(
            Set(item.tiledWindows.flatMap(\.allWindows).map(\.id)),
            Set([windows.retainedTiledOne, windows.retainedTiledTwo])
        )
        XCTAssertEqual(item.floatingWindows.map(\.id), [windows.retainedFloating])
        XCTAssertEqual(item.floatingWindows[0].windowCount, 1)
        XCTAssertFalse(item.windows.flatMap(\.allWindows).contains { $0.id == windows.excludedTiledOne })
        XCTAssertFalse(item.windows.flatMap(\.allWindows).contains { $0.id == windows.excludedTiledTwo })
        XCTAssertFalse(item.windows.flatMap(\.allWindows).contains { $0.id == windows.excludedFloating })

        XCTAssertEqual(fixture.workspaceManager.entries(in: fixture.workspaceId).count, 6)
        XCTAssertEqual(fixture.workspaceManager.entry(for: windows.excludedTiledOne)?.workspaceId, fixture.workspaceId)
        XCTAssertEqual(fixture.workspaceManager.entry(for: windows.excludedTiledOne)?.mode, .tiling)
        XCTAssertEqual(
            fixture.workspaceManager.entry(for: windows.excludedTiledOne)?.managedReplacementMetadata?.bundleId,
            "com.example.excluded"
        )
        XCTAssertEqual(fixture.workspaceManager.entry(for: windows.excludedFloating)?.mode, .floating)
    }

    func testBundlelessManagedEntryFailsOpen() throws {
        let fixture = try makeFixture()
        let token = addWindow(
            pid: 43_001,
            windowId: 43_101,
            bundleId: nil,
            mode: .tiling,
            to: fixture
        )

        let projection = project(
            fixture,
            excludedBundleIDs: ["com.example.excluded"]
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertEqual(item.tiledWindows.map(\.id), [token])
        XCTAssertNotNil(fixture.workspaceManager.entry(for: token))
    }

    func testExcludedOnlyWorkspaceUsesPostFilterEmptyPolicy() throws {
        let fixture = try makeFixture()
        let token = addWindow(
            pid: 44_001,
            windowId: 44_101,
            bundleId: "com.example.excluded",
            mode: .tiling,
            to: fixture
        )
        _ = try XCTUnwrap(fixture.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = fixture.workspaceManager.focusWorkspace(named: "2")

        let visibleEmptyProjection = project(
            fixture,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: ["com.example.excluded"]
        )
        let visibleEmptyItem = try XCTUnwrap(
            visibleEmptyProjection.items.first { $0.id == fixture.workspaceId }
        )
        XCTAssertTrue(visibleEmptyItem.tiledWindows.isEmpty)
        XCTAssertTrue(visibleEmptyItem.floatingWindows.isEmpty)

        let hiddenEmptyProjection = project(
            fixture,
            hideEmptyWorkspaces: true,
            excludedBundleIDs: ["com.example.excluded"]
        )
        XCTAssertFalse(hiddenEmptyProjection.items.contains { $0.id == fixture.workspaceId })
        XCTAssertEqual(fixture.workspaceManager.entry(for: token)?.workspaceId, fixture.workspaceId)
    }

    func testHandsOffSurfacesNeverReachTheBar() throws {
        let fixture = try makeFixture()
        let handsOff = addWindow(
            pid: 46_001,
            windowId: 46_101,
            bundleId: "com.example.overlay",
            mode: .floating,
            to: fixture
        )
        let ordinary = addWindow(
            pid: 46_002,
            windowId: 46_102,
            bundleId: "com.example.ordinary",
            mode: .floating,
            to: fixture
        )
        fixture.workspaceManager.setInteractionPolicy(.handsOffSurface, for: handsOff)
        fixture.workspaceManager.setInteractionPolicy(.full, for: ordinary)

        let projection = project(fixture, showFloatingWindows: true, excludedBundleIDs: [])
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertEqual(
            item.floatingWindows.count,
            1,
            "a surface OmniWM may not focus, raise or frame must not be offered as a clickable bar pill"
        )
        XCTAssertFalse(item.floatingWindows.contains { $0.id == handsOff })
        XCTAssertTrue(item.floatingWindows.contains { $0.id == ordinary })
    }

    func testHandsOffExclusionDoesNotDisturbConfiguredBundleExclusions() throws {
        let fixture = try makeFixture()
        let excluded = addWindow(
            pid: 46_003,
            windowId: 46_103,
            bundleId: "com.example.excluded",
            mode: .floating,
            to: fixture
        )
        fixture.workspaceManager.setInteractionPolicy(.full, for: excluded)

        let projection = project(
            fixture,
            showFloatingWindows: true,
            excludedBundleIDs: ["com.example.excluded"]
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertTrue(item.floatingWindows.isEmpty)
    }

    func testActiveWorkspaceStaysOnBarWhileEmptyWorkspacesAreHidden() throws {
        let fixture = try makeFixture()
        let occupiedId = try XCTUnwrap(
            fixture.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = addWindow(
            token: WindowToken(pid: 47_001, windowId: 47_101),
            bundleId: "com.example.retained",
            mode: .tiling,
            workspaceId: occupiedId,
            workspaceManager: fixture.workspaceManager
        )
        let idleId = try XCTUnwrap(
            fixture.workspaceManager.workspaceId(for: "3", createIfMissing: true)
        )
        XCTAssertEqual(fixture.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id, fixture.workspaceId)

        let projection = project(
            fixture,
            hideEmptyWorkspaces: true,
            excludedBundleIDs: []
        )

        let activeItem = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })
        XCTAssertTrue(activeItem.isFocused)
        XCTAssertTrue(activeItem.windows.isEmpty)
        XCTAssertTrue(projection.items.contains { $0.id == occupiedId })
        XCTAssertFalse(projection.items.contains { $0.id == idleId })
    }

    func testExcludedScratchpadSuppressesOnlyItsBarPill() throws {
        let fixture = try makeFixture()
        let token = addWindow(
            pid: 45_001,
            windowId: 45_101,
            bundleId: "com.example.scratchpad",
            mode: .floating,
            to: fixture
        )
        XCTAssertTrue(fixture.workspaceManager.setScratchpadToken(token))

        let unfiltered = project(
            fixture,
            showFloatingWindows: true,
            excludedBundleIDs: []
        )
        XCTAssertEqual(unfiltered.scratchpad?.id, token)

        let filtered = project(
            fixture,
            showFloatingWindows: true,
            excludedBundleIDs: ["COM.EXAMPLE.SCRATCHPAD"]
        )
        XCTAssertNil(filtered.scratchpad)
        XCTAssertEqual(fixture.workspaceManager.scratchpadToken(), token)
        XCTAssertEqual(fixture.workspaceManager.entry(for: token)?.mode, .floating)
    }

    func testWorkspaceBarIPCUsesFilteredProjectionWhileWindowsQueryRetainsEntry() throws {
        let settings = makeSettingsStore()
        XCTAssertTrue(settings.addWorkspaceBarExcludedBundleID("com.example.ipc"))
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let monitor = makeMonitor(displayId: 46_001)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(
            token: WindowToken(pid: 46_101, windowId: 46_201),
            bundleId: "com.example.ipc",
            mode: .tiling,
            workspaceId: workspaceId,
            workspaceManager: controller.workspaceManager
        )
        let router = IPCQueryRouter(
            controller: controller,
            appVersion: nil,
            sessionToken: "workspace-bar-exclusion-tests"
        )

        let workspaceBar = router.workspaceBarResult()
        let ipcMonitor = try XCTUnwrap(workspaceBar.monitors.first { $0.name == monitor.name })
        let ipcWorkspace = try XCTUnwrap(ipcMonitor.workspaces.first { $0.rawName == "1" })
        XCTAssertTrue(ipcWorkspace.windows.isEmpty)

        let windows = router.windowsResult(
            IPCQueryRequest(name: .windows, fields: ["id", "mode"])
        )
        XCTAssertEqual(windows.windows.count, 1)
        XCTAssertNotNil(windows.windows[0].id)
        XCTAssertEqual(windows.windows[0].mode, .tiling)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testWorkspaceBarFocusUsesIdentityForDuplicateDisplayNames() throws {
        let settings = makeSettingsStore()
        let displayName = "🚀"
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", displayName: displayName),
            WorkspaceConfiguration(name: "2", displayName: displayName)
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let monitor = makeMonitor(displayId: 47_001)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let projection = WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                showFloatingWindows: false,
                excludedBundleIDs: []
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            iconResolver: controller.workspaceBarIconResolver,
            focusedToken: nil,
            settings: settings
        )
        let sourceItem = try XCTUnwrap(projection.items.first { $0.rawName == "1" })
        let targetItem = try XCTUnwrap(projection.items.first { $0.rawName == "2" })

        XCTAssertEqual(sourceItem.name, displayName)
        XCTAssertEqual(targetItem.name, displayName)
        XCTAssertEqual(sourceItem.rawName, "1")
        XCTAssertEqual(targetItem.rawName, "2")
        XCTAssertNotEqual(sourceItem.rawName, targetItem.rawName)
        XCTAssertEqual(sourceItem.id, sourceWorkspaceId)
        XCTAssertEqual(targetItem.id, targetWorkspaceId)
        XCTAssertNotEqual(sourceItem.id, targetItem.id)
        controller.focusWorkspaceFromBar(id: targetItem.id)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, targetWorkspaceId)

        let unknownWorkspaceId = UUID()
        XCTAssertNil(controller.workspaceManager.descriptor(for: unknownWorkspaceId))
        XCTAssertFalse(controller.windowActionHandler.focusWorkspaceFromBar(id: unknownWorkspaceId))
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, targetWorkspaceId)
    }

    func testDeduplicationUsesCaseNormalizedBundleIdentity() throws {
        let overrideImage = NSImage(size: NSSize(width: 24, height: 24))
        let fixture = try makeFixture { _ in overrideImage }
        let first = addWindow(
            pid: 48_001,
            windowId: 48_101,
            bundleId: "Com.Example.Shared",
            mode: .tiling,
            to: fixture
        )
        let second = addWindow(
            pid: 48_002,
            windowId: 48_102,
            bundleId: "com.example.shared",
            mode: .tiling,
            to: fixture
        )
        fixture.iconResolver.synchronize(
            overrides: ["COM.EXAMPLE.SHARED": "icons/shared.icns"]
        )

        let projection = project(
            fixture,
            deduplicate: true,
            excludedBundleIDs: []
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })
        let window = try XCTUnwrap(item.tiledWindows.first)

        XCTAssertEqual(item.tiledWindows.count, 1)
        XCTAssertEqual(window.windowCount, 2)
        XCTAssertEqual(Set(window.allWindows.map(\.id)), Set([first, second]))
        XCTAssertTrue(window.icon === overrideImage)
    }

    func testSameDisplayNameWithDifferentBundleIdsStaysSeparate() throws {
        let fixture = try makeFixture()
        let first = addWindow(
            pid: 49_001,
            windowId: 49_101,
            bundleId: "com.example.first",
            mode: .tiling,
            to: fixture
        )
        let second = addWindow(
            pid: 49_002,
            windowId: 49_102,
            bundleId: "com.example.second",
            mode: .tiling,
            to: fixture
        )

        let projection = project(
            fixture,
            deduplicate: true,
            excludedBundleIDs: []
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertEqual(item.tiledWindows.map(\.appName), ["Unknown", "Unknown"])
        XCTAssertEqual(Set(item.tiledWindows.map(\.id)), Set([first, second]))
        XCTAssertTrue(item.tiledWindows.allSatisfy { $0.windowCount == 1 })
    }

    func testMacOSHiddenWindowsRemainVisibleAndSortAfterVisibleWindows() throws {
        let fixture = try makeFixture()
        let hiddenFirst = addWindow(
            pid: 49_101,
            windowId: 49_201,
            bundleId: "com.example.hidden.first",
            mode: .tiling,
            to: fixture
        )
        let visibleFirst = addWindow(
            pid: 49_102,
            windowId: 49_202,
            bundleId: "com.example.visible.first",
            mode: .tiling,
            to: fixture
        )
        let hiddenSecond = addWindow(
            pid: 49_103,
            windowId: 49_203,
            bundleId: "com.example.hidden.second",
            mode: .tiling,
            to: fixture
        )
        let visibleSecond = addWindow(
            pid: 49_104,
            windowId: 49_204,
            bundleId: "com.example.visible.second",
            mode: .tiling,
            to: fixture
        )
        fixture.workspaceManager.setAppHidden(true, pid: hiddenFirst.pid, source: .service)
        fixture.workspaceManager.setAppHidden(true, pid: hiddenSecond.pid, source: .service)

        let projection = project(fixture, excludedBundleIDs: [])
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })

        XCTAssertEqual(
            item.tiledWindows.map(\.id),
            [visibleFirst, visibleSecond, hiddenFirst, hiddenSecond]
        )
        XCTAssertEqual(item.tiledWindows.map(\.isAppHidden), [false, false, true, true])
        XCTAssertEqual(item.tiledWindows.map(\.hiddenWindowCount), [0, 0, 1, 1])
        for window in item.tiledWindows {
            XCTAssertTrue(window.handle === fixture.workspaceManager.handle(for: window.id))
        }
    }

    func testDeduplicatedMixedVisibilityKeepsExactPIDRowsVisibleFirst() throws {
        let fixture = try makeFixture()
        let hidden = addWindow(
            pid: 49_201,
            windowId: 49_301,
            bundleId: "com.example.mixed",
            mode: .tiling,
            to: fixture
        )
        let visible = addWindow(
            pid: 49_202,
            windowId: 49_302,
            bundleId: "COM.EXAMPLE.MIXED",
            mode: .tiling,
            to: fixture
        )
        fixture.workspaceManager.setAppHidden(true, pid: hidden.pid, source: .service)

        let projection = project(fixture, deduplicate: true, excludedBundleIDs: [])
        let workspace = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })
        let item = try XCTUnwrap(workspace.tiledWindows.first)

        XCTAssertEqual(workspace.tiledWindows.count, 1)
        XCTAssertEqual(item.windowCount, 2)
        XCTAssertEqual(item.hiddenWindowCount, 1)
        XCTAssertFalse(item.isAppHidden)
        XCTAssertTrue(item.hasHiddenWindows)
        XCTAssertEqual(item.allWindows.map(\.id), [visible, hidden])
        XCTAssertEqual(item.allWindows.map(\.isAppHidden), [false, true])
        XCTAssertEqual(item.allWindows.map(\.id.pid), [visible.pid, hidden.pid])
        XCTAssertTrue(item.allWindows[0].handle === fixture.workspaceManager.handle(for: visible))
        XCTAssertTrue(item.allWindows[1].handle === fixture.workspaceManager.handle(for: hidden))
    }

    func testOverrideAppliesToTiledFloatingAndScratchpadItems() throws {
        let overrideImage = NSImage(size: NSSize(width: 32, height: 32))
        let fixture = try makeFixture { _ in overrideImage }
        let tiled = addWindow(
            pid: 50_001,
            windowId: 50_101,
            bundleId: "com.example.override",
            mode: .tiling,
            to: fixture
        )
        let floating = addWindow(
            pid: 50_002,
            windowId: 50_102,
            bundleId: "com.example.override",
            mode: .floating,
            to: fixture
        )
        let scratchpad = addWindow(
            pid: 50_003,
            windowId: 50_103,
            bundleId: "com.example.override",
            mode: .floating,
            to: fixture
        )
        XCTAssertTrue(fixture.workspaceManager.setScratchpadToken(scratchpad))
        fixture.iconResolver.synchronize(
            overrides: ["com.example.override": "icons/custom.png"]
        )

        let projection = project(
            fixture,
            showFloatingWindows: true,
            excludedBundleIDs: []
        )
        let item = try XCTUnwrap(projection.items.first { $0.id == fixture.workspaceId })
        let tiledItem = try XCTUnwrap(item.tiledWindows.first { $0.id == tiled })
        let floatingItem = try XCTUnwrap(item.floatingWindows.first { $0.id == floating })
        let scratchpadItem = try XCTUnwrap(projection.scratchpad)

        XCTAssertTrue(tiledItem.icon === overrideImage)
        XCTAssertTrue(floatingItem.icon === overrideImage)
        XCTAssertTrue(scratchpadItem.window.icon === overrideImage)
    }

    private func project(
        _ fixture: Fixture,
        deduplicate: Bool = false,
        hideEmptyWorkspaces: Bool = false,
        showFloatingWindows: Bool = false,
        excludedBundleIDs: Set<String>
    ) -> WorkspaceBarProjection {
        WorkspaceBarDataSource.workspaceBarProjection(
            for: fixture.monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: deduplicate,
                hideEmptyWorkspaces: hideEmptyWorkspaces,
                showFloatingWindows: showFloatingWindows,
                excludedBundleIDs: excludedBundleIDs
            ),
            workspaceManager: fixture.workspaceManager,
            appInfoCache: fixture.appInfoCache,
            iconResolver: fixture.iconResolver,
            focusedToken: nil,
            settings: fixture.settings
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        bundleId: String?,
        mode: TrackedWindowMode,
        to fixture: Fixture
    ) -> WindowToken {
        addWindow(
            token: WindowToken(pid: pid, windowId: windowId),
            bundleId: bundleId,
            mode: mode,
            workspaceId: fixture.workspaceId,
            workspaceManager: fixture.workspaceManager
        )
    }

    private func addWindows(_ specs: [WindowSpec], to fixture: Fixture) {
        for spec in specs {
            _ = addWindow(
                token: spec.token,
                bundleId: spec.bundleId,
                mode: spec.mode,
                workspaceId: fixture.workspaceId,
                workspaceManager: fixture.workspaceManager
            )
        }
    }

    private func addWindow(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        workspaceId: WorkspaceDescriptor.ID,
        workspaceManager: WorkspaceManager
    ) -> WindowToken {
        workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(token.pid),
                windowId: token.windowId
            ),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: mode,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                mode: mode,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Window \(token.windowId)",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 40, y: 50, width: 600, height: 400)
            )
        )
    }

    private func makeFixture(
        imageLoader: @escaping WorkspaceBarIconResolver.ImageLoader = { _ in nil }
    ) throws -> Fixture {
        let settings = makeSettingsStore()
        let workspaceManager = WorkspaceManager(settings: settings)
        let monitor = makeMonitor(displayId: 40_001)
        workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = workspaceManager.focusWorkspace(named: "1")
        return Fixture(
            settings: settings,
            workspaceManager: workspaceManager,
            monitor: monitor,
            workspaceId: workspaceId,
            appInfoCache: AppInfoCache(),
            iconResolver: WorkspaceBarIconResolver(
                settingsFileURL: settings.settingsFileURL,
                imageLoader: imageLoader,
                unavailableLogger: { _ in }
            )
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Workspace Bar Exclusion Test"
        )
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarDataSourceTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
