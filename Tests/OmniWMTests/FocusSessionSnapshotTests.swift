// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class FocusSessionSnapshotTests: XCTestCase {
    func testRecordTiledFocusReportsOnlyHistoryChangesAndMaintainsBound() {
        let newest = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 1, windowId: 2)
        var focus = FocusSessionSnapshot(
            lastTiledFocusedToken: newest,
            tiledFocusHistory: [newest, second]
        )

        XCTAssertFalse(focus.recordTiledFocus(newest))
        XCTAssertEqual(focus.tiledFocusHistory, [newest, second])
        XCTAssertTrue(focus.recordTiledFocus(second))
        XCTAssertEqual(focus.tiledFocusHistory, [second, newest])

        focus.tiledFocusHistory = (1 ... 33).map { WindowToken(pid: 2, windowId: $0) }
        let promoted = WindowToken(pid: 2, windowId: 33)
        XCTAssertTrue(focus.recordTiledFocus(promoted))
        XCTAssertEqual(focus.tiledFocusHistory.count, 32)
        XCTAssertEqual(focus.tiledFocusHistory.first, promoted)
        XCTAssertEqual(focus.tiledFocusHistory.last?.windowId, 31)
    }

    func testClearRememberedFocusRemovesEveryMatchingWorkspaceEntry() {
        let removed = WindowToken(pid: 3, windowId: 1)
        let retained = WindowToken(pid: 3, windowId: 2)
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let retainedWorkspace = UUID()
        var focus = FocusSessionSnapshot(
            lastTiledFocusedByWorkspace: [
                firstWorkspace: removed,
                secondWorkspace: removed,
                retainedWorkspace: retained
            ],
            lastFloatingFocusedByWorkspace: [firstWorkspace: removed],
            lastFocusedByWorkspace: [secondWorkspace: removed, retainedWorkspace: retained],
            lastTiledFocusedToken: removed,
            tiledFocusHistory: [retained, removed]
        )

        XCTAssertTrue(focus.clearRememberedFocus(removed, workspaceId: nil))
        XCTAssertEqual(focus.lastTiledFocusedByWorkspace, [retainedWorkspace: retained])
        XCTAssertTrue(focus.lastFloatingFocusedByWorkspace.isEmpty)
        XCTAssertEqual(focus.lastFocusedByWorkspace, [retainedWorkspace: retained])
        XCTAssertEqual(focus.tiledFocusHistory, [retained])
        XCTAssertNil(focus.lastTiledFocusedToken)
        XCTAssertFalse(focus.clearRememberedFocus(removed, workspaceId: nil))
    }

    func testReplaceRememberedFocusMutatesAllStorageInPlaceAndRejectsIdentityReplacement() {
        let oldToken = WindowToken(pid: 4, windowId: 1)
        let newToken = WindowToken(pid: 4, windowId: 2)
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        var focus = FocusSessionSnapshot(
            lastTiledFocusedByWorkspace: [firstWorkspace: oldToken],
            lastFloatingFocusedByWorkspace: [secondWorkspace: oldToken],
            lastFocusedByWorkspace: [firstWorkspace: oldToken, secondWorkspace: oldToken],
            lastTiledFocusedToken: oldToken,
            tiledFocusHistory: [oldToken, newToken, oldToken]
        )

        XCTAssertFalse(focus.replaceRememberedFocus(from: oldToken, to: oldToken))
        XCTAssertTrue(focus.replaceRememberedFocus(from: oldToken, to: newToken))
        XCTAssertEqual(focus.lastTiledFocusedToken, newToken)
        XCTAssertEqual(focus.tiledFocusHistory, [newToken, newToken, newToken])
        XCTAssertEqual(focus.lastTiledFocusedByWorkspace, [firstWorkspace: newToken])
        XCTAssertEqual(focus.lastFloatingFocusedByWorkspace, [secondWorkspace: newToken])
        XCTAssertEqual(
            focus.lastFocusedByWorkspace,
            [firstWorkspace: newToken, secondWorkspace: newToken]
        )
        XCTAssertFalse(focus.replaceRememberedFocus(from: oldToken, to: newToken))
    }
}
