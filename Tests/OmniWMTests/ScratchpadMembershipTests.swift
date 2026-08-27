// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ScratchpadMembershipTests: XCTestCase {
    func testSlotHoldsSeveralWindowsInAssignmentOrder() throws {
        let fixture = makeFixture()
        let first = addWindow(pid: 970_001, windowId: 970_101, to: fixture)
        let second = addWindow(pid: 970_002, windowId: 970_102, to: fixture)
        let third = addWindow(pid: 970_003, windowId: 970_103, to: fixture)

        for token in [first, second, third] {
            XCTAssertTrue(fixture.manager.setScratchpadMembership(token, to: 2))
        }

        XCTAssertEqual(fixture.manager.scratchpadMembers(in: 2), [first, second, third])
        XCTAssertEqual(fixture.manager.occupiedScratchpadIndices(), [2])
        XCTAssertTrue(fixture.manager.isScratchpadToken(second))
        XCTAssertEqual(fixture.manager.scratchpadIndex(for: second), 2)
    }

    func testReassignmentMovesTokenBetweenSlots() throws {
        let fixture = makeFixture()
        let token = addWindow(pid: 970_011, windowId: 970_111, to: fixture)

        XCTAssertTrue(fixture.manager.setScratchpadMembership(token, to: 1))
        XCTAssertTrue(fixture.manager.setScratchpadMembership(token, to: 5))

        XCTAssertTrue(fixture.manager.scratchpadMembers(in: 1).isEmpty)
        XCTAssertEqual(fixture.manager.scratchpadMembers(in: 5), [token])
        XCTAssertEqual(fixture.manager.occupiedScratchpadIndices(), [5])
        XCTAssertFalse(fixture.manager.setScratchpadMembership(token, to: 5))
    }

    func testMembershipRequiresLiveEntry() {
        let fixture = makeFixture()
        let missing = WindowToken(pid: 970_021, windowId: 970_121)
        let initialSeq = fixture.manager.worldSeq

        XCTAssertFalse(fixture.manager.setScratchpadMembership(missing, to: 1))

        XCTAssertNil(fixture.manager.scratchpadIndex(for: missing))
        XCTAssertEqual(fixture.manager.worldSeq, initialSeq)
    }

    func testRevealRequiresAnOccupiedSlotAndClearsWhenItEmpties() throws {
        let fixture = makeFixture()
        let token = addWindow(pid: 970_031, windowId: 970_131, to: fixture)

        XCTAssertFalse(fixture.manager.setRevealedScratchpad(3))
        XCTAssertTrue(fixture.manager.setScratchpadMembership(token, to: 3))
        XCTAssertTrue(fixture.manager.setRevealedScratchpad(3))
        XCTAssertEqual(fixture.manager.revealedScratchpadIndex(), 3)

        XCTAssertTrue(fixture.manager.clearScratchpadIfMatches(token))

        XCTAssertNil(fixture.manager.revealedScratchpadIndex())
        XCTAssertTrue(fixture.manager.occupiedScratchpadIndices().isEmpty)
    }

    func testRemovingOneOfSeveralMembersKeepsTheSlotRevealed() throws {
        let fixture = makeFixture()
        let first = addWindow(pid: 970_041, windowId: 970_141, to: fixture)
        let second = addWindow(pid: 970_042, windowId: 970_142, to: fixture)
        XCTAssertTrue(fixture.manager.setScratchpadMembership(first, to: 4))
        XCTAssertTrue(fixture.manager.setScratchpadMembership(second, to: 4))
        XCTAssertTrue(fixture.manager.setRevealedScratchpad(4))

        XCTAssertNotNil(fixture.manager.removeWindow(pid: first.pid, windowId: first.windowId))

        XCTAssertEqual(fixture.manager.scratchpadMembers(in: 4), [second])
        XCTAssertEqual(fixture.manager.revealedScratchpadIndex(), 4)
    }

    func testRekeyPreservesMembershipAndOrder() throws {
        let fixture = makeFixture()
        let first = addWindow(pid: 970_051, windowId: 970_151, to: fixture)
        let second = addWindow(pid: 970_052, windowId: 970_152, to: fixture)
        XCTAssertTrue(fixture.manager.setScratchpadMembership(first, to: 6))
        XCTAssertTrue(fixture.manager.setScratchpadMembership(second, to: 6))

        let rekeyed = WindowToken(pid: first.pid, windowId: 970_153)
        XCTAssertNotNil(
            fixture.manager.rekeyWindow(
                from: first,
                to: rekeyed,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(rekeyed.pid),
                    windowId: rekeyed.windowId
                )
            )
        )

        XCTAssertEqual(fixture.manager.scratchpadMembers(in: 6), [rekeyed, second])
        XCTAssertNil(fixture.manager.scratchpadIndex(for: first))
    }

    func testVisibleMemberBlocksWorkspaceMonitorMove() throws {
        let fixture = makeFixture()
        let token = addWindow(pid: 970_061, windowId: 970_161, to: fixture)
        XCTAssertTrue(fixture.manager.setScratchpadMembership(token, to: 7))
        let initialSeq = fixture.manager.worldSeq

        let blocked = fixture.manager.moveWorkspaceToMonitor(
            fixture.workspaceId,
            to: fixture.right.id,
            force: true
        )

        XCTAssertEqual(blocked.status, .stateConflict)
        XCTAssertEqual(fixture.manager.worldSeq, initialSeq)

        fixture.manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.left.id,
                reason: .scratchpad
            ),
            for: token
        )

        XCTAssertEqual(
            fixture.manager.moveWorkspaceToMonitor(
                fixture.workspaceId,
                to: fixture.right.id,
                force: true
            ).status,
            .executed
        )
    }

    private struct Fixture {
        let manager: WorkspaceManager
        let workspaceId: WorkspaceDescriptor.ID
        let left: Monitor
        let right: Monitor
    }

    private func makeFixture() -> Fixture {
        let left = makeMonitor(
            displayId: 970_901,
            name: "Left",
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        let right = makeMonitor(
            displayId: 970_902,
            name: "Right",
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMScratchpadMembershipTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
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
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: left)),
                layoutType: .niri
            )
        ]
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([left, right])
        manager.applySettings()
        return Fixture(
            manager: manager,
            workspaceId: manager.workspaceId(for: "1", createIfMissing: true) ?? UUID(),
            left: left,
            right: right
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    @discardableResult
    private func addWindow(pid: pid_t, windowId: Int, to fixture: Fixture) -> WindowToken {
        fixture.manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: fixture.workspaceId,
            mode: .floating
        )
    }
}
