// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarNativeFullscreenSettingsTests: XCTestCase {
    private static let builtInUUID = "11111111-1111-4111-8111-111111111111"
    private static let externalUUID = "22222222-2222-4222-8222-222222222222"

    func testDefaultsRoundTrip() throws {
        XCTAssertFalse(SettingsExport.defaults().workspaceBarHideInNativeFullscreen)

        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("hideInNativeFullscreen = false"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertFalse(decoded.workspaceBarHideInNativeFullscreen)
    }

    func testNonDefaultRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.workspaceBarHideInNativeFullscreen = true

        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hideInNativeFullscreen = true"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertTrue(decoded.workspaceBarHideInNativeFullscreen)
    }

    func testMissingKeyRejectsDecode() throws {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let withoutKey = toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("hideInNativeFullscreen") }
            .joined(separator: "\n")

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(withoutKey.utf8))) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "hideInNativeFullscreen")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["workspaceBar"])
        }
    }

    @MainActor
    func testBarHidesOnlyOnTheDisplayShowingNativeFullscreen() {
        let settings = makeSettingsStore()
        settings.workspaceBarEnabled = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_001, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        let external = makeMonitor(displayId: 71_002, uuid: Self.externalUUID, name: "External", originX: 1_440)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn, external])

        commitTopology(on: controller, fullscreenDisplayUUID: Self.builtInUUID)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))

        settings.workspaceBarHideInNativeFullscreen = true
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))

        commitTopology(on: controller, fullscreenDisplayUUID: nil)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))
    }

    @MainActor
    func testAutoHideDoesNotReleaseReservedLayoutSpace() {
        let settings = makeSettingsStore()
        settings.workspaceBarEnabled = true
        settings.workspaceBarReserveLayoutSpace = true
        settings.workspaceBarHeight = 24
        settings.workspaceBarHideInNativeFullscreen = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_003, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

        commitTopology(on: controller, fullscreenDisplayUUID: nil)
        let reservedWorkingBefore = controller.insetWorkingFrame(for: builtIn)
        let reservedFullscreenBefore = controller.fullscreenLayoutFrame(for: builtIn)
        XCTAssertEqual(reservedWorkingBefore, CGRect(x: 5, y: 5, width: 1_430, height: 831))
        XCTAssertEqual(reservedFullscreenBefore, CGRect(x: 0, y: 0, width: 1_440, height: 836))

        commitTopology(on: controller, fullscreenDisplayUUID: Self.builtInUUID)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertEqual(controller.insetWorkingFrame(for: builtIn), reservedWorkingBefore)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: builtIn), reservedFullscreenBefore)
    }

    @MainActor
    func testUnknownTopologyKeepsTheBarVisible() {
        let settings = makeSettingsStore()
        settings.workspaceBarEnabled = true
        settings.workspaceBarHideInNativeFullscreen = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_004, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

        XCTAssertFalse(controller.workspaceManager.spaceTopology.isPopulated)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
    }

    @MainActor
    func testRawSkyLightDisplayIdentifiersStillHideTheBar() {
        for rawIdentifier in ["Main", "71005"] {
            let settings = makeSettingsStore()
            settings.workspaceBarEnabled = true
            settings.workspaceBarHideInNativeFullscreen = true
            let controller = WMController(settings: settings)
            let builtIn = makeMonitor(displayId: 71_005, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
            controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

            controller.workspaceManager.commitSpaceTopology(
                SpaceTopology(
                    displays: [
                        .init(displayIdentifier: rawIdentifier, spaceIds: [1], currentSpaceId: 1)
                    ],
                    activeSpaceId: 1,
                    fullscreenSpaceIds: [1],
                    windowSpace: [:]
                )
            )

            XCTAssertEqual(
                controller.workspaceManager.spaceTopology.isDisplayShowingFullscreenSpace(on: builtIn),
                true,
                "raw identifier \(rawIdentifier) should canonicalize to the monitor UUID"
            )
            XCTAssertFalse(
                controller.isWorkspaceBarVisible(on: builtIn),
                "bar should hide for raw identifier \(rawIdentifier)"
            )
        }
    }

    @MainActor
    private func commitTopology(on controller: WMController, fullscreenDisplayUUID: String?) {
        let spaceIdsByUUID: [String: UInt64] = [Self.builtInUUID: 1, Self.externalUUID: 2]
        let displays = spaceIdsByUUID
            .sorted { $0.key < $1.key }
            .map {
                SpaceTopology.DisplaySpaces(
                    displayIdentifier: $0.key,
                    spaceIds: [$0.value],
                    currentSpaceId: $0.value
                )
            }
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: displays,
                activeSpaceId: 1,
                fullscreenSpaceIds: fullscreenDisplayUUID.flatMap { spaceIdsByUUID[$0] }.map { [$0] } ?? [],
                windowSpace: [:]
            )
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        uuid: String,
        name: String,
        originX: CGFloat
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: originX, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: originX, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarFullscreenTests-\(UUID().uuidString)", isDirectory: true)
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
