// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarRevealSettingsTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        XCTAssertEqual(SettingsExport.defaults().workspaceBarRevealModifier, WorkspaceBarRevealModifier.off.rawValue)
        XCTAssertEqual(SettingsExport.defaults().workspaceBarRevealHoldMilliseconds, 200)

        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("revealModifier = \"off\""))
        XCTAssertTrue(toml.contains("revealHoldMilliseconds = 200"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBarRevealModifier, WorkspaceBarRevealModifier.off.rawValue)
        XCTAssertEqual(decoded.workspaceBarRevealHoldMilliseconds, 200)
    }

    func testNonDefaultRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.workspaceBarRevealModifier = WorkspaceBarRevealModifier.controlOptionCommand.rawValue
        export.workspaceBarRevealHoldMilliseconds = 350

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("revealModifier = \"controlOptionCommand\""))
        XCTAssertTrue(toml.contains("revealHoldMilliseconds = 350"))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBarRevealModifier, WorkspaceBarRevealModifier.controlOptionCommand.rawValue)
        XCTAssertEqual(decoded.workspaceBarRevealHoldMilliseconds, 350)
    }

    @MainActor
    func testApplyExportClampsDelayAndRecoversInvalidModifier() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.workspaceBarRevealModifier = WorkspaceBarRevealModifier.option.rawValue
        export.workspaceBarRevealHoldMilliseconds = -50
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarRevealModifier, .option)
        XCTAssertEqual(settings.workspaceBarRevealHoldMilliseconds, 0)

        export.workspaceBarRevealHoldMilliseconds = 5000
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarRevealHoldMilliseconds, 1000)

        export.workspaceBarRevealModifier = "bogus"
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarRevealModifier, .off)
    }

    @MainActor
    func testRevealModeIsOverlayOnlyAndOffModePreservesReservation() {
        let settings = makeSettingsStore()
        settings.workspaceBarEnabled = true
        settings.workspaceBarReserveLayoutSpace = true
        settings.workspaceBarHeight = 24
        settings.workspaceBarRevealModifier = .option
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), monitor.visibleFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)

        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), monitor.visibleFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)

        settings.workspaceBarRevealModifier = .off
        controller.setWorkspaceBarRevealHeld(false)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )
        XCTAssertEqual(
            controller.fullscreenLayoutFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )
    }

    @MainActor
    func testRevealModeKeepsFullscreenOuterGapsButDropsReservation() {
        let settings = makeSettingsStore()
        settings.outerGapLeft = 12
        settings.outerGapRight = 12
        settings.outerGapTop = 46
        settings.outerGapBottom = 14
        settings.fullscreenUsesOuterGaps = true
        settings.workspaceBarEnabled = true
        settings.workspaceBarReserveLayoutSpace = true
        settings.workspaceBarHeight = 24
        settings.workspaceBarRevealModifier = .option
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        let overlayFrame = CGRect(x: 12, y: 14, width: 1416, height: 840)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), overlayFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), overlayFrame)

        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), overlayFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), overlayFrame)

        settings.workspaceBarRevealModifier = .off
        controller.setWorkspaceBarRevealHeld(false)
        let reservedFrame = CGRect(x: 12, y: 14, width: 1416, height: 816)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), reservedFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), reservedFrame)
    }

    private func defaultsDroppingLines(containing fragments: String...) throws -> Data {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !fragments.contains { line.contains($0) }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarRevealTests-\(UUID().uuidString)", isDirectory: true)
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
