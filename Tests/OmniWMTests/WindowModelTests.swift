// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

final class WindowModelTests: XCTestCase {
    func testUpsertInstallsAndUpdatesLifetimeAuthorityAtomically() throws {
        let model = WindowModel()
        let workspaceId = WorkspaceDescriptor(name: "workspace").id
        let token = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_000), windowId: 467_000),
            pid: 467_000,
            windowId: 467_000,
            workspace: workspaceId,
            lifetimeAuthority: .directLifecycle
        )

        XCTAssertEqual(model.entry(for: token)?.lifetimeAuthority, .directLifecycle)

        _ = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_000), windowId: 467_000),
            pid: 467_000,
            windowId: 467_000,
            workspace: workspaceId,
            lifetimeAuthority: .axTopLevelInventory
        )

        XCTAssertEqual(model.entry(for: token)?.lifetimeAuthority, .axTopLevelInventory)
    }

    func testNestedIndexesRemainCoherentAcrossRemovalMoveModeAndRekey() throws {
        let model = WindowModel()
        let firstWorkspace = WorkspaceDescriptor(name: "first").id
        let secondWorkspace = WorkspaceDescriptor(name: "second").id
        let pid: pid_t = 467_050
        let tokens = (1 ... 3).map { windowId in
            model.upsert(
                window: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                workspace: firstWorkspace
            )
        }

        XCTAssertEqual(model.windowCount(in: firstWorkspace), 3)
        XCTAssertEqual(model.removeWindow(key: tokens[1])?.token, tokens[1])
        XCTAssertEqual(model.windows(in: firstWorkspace).map(\.token), [tokens[0], tokens[2]])

        model.updateWorkspace(for: tokens[2], workspace: secondWorkspace)
        model.setMode(.floating, for: tokens[2])
        XCTAssertEqual(model.windowCount(in: firstWorkspace), 1)
        XCTAssertEqual(model.windowCount(in: secondWorkspace), 1)
        XCTAssertEqual(model.windows(in: secondWorkspace, mode: .floating).map(\.token), [tokens[2]])
        XCTAssertTrue(model.windows(in: secondWorkspace, mode: .tiling).isEmpty)

        let rekeyedToken = WindowToken(pid: pid + 1, windowId: 4)
        let handle = try XCTUnwrap(model.handle(for: tokens[2]))
        XCTAssertNotNil(
            model.rekeyWindow(
                from: tokens[2],
                to: rekeyedToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(rekeyedToken.pid),
                    windowId: rekeyedToken.windowId
                )
            )
        )

        XCTAssertEqual(model.windows(in: secondWorkspace).map(\.token), [rekeyedToken])
        XCTAssertEqual(model.entries(forPid: pid + 1).map(\.token), [rekeyedToken])
        XCTAssertFalse(model.entries(forPid: pid).contains { $0.token == tokens[2] })
        XCTAssertTrue(model.handle(for: rekeyedToken) === handle)
    }

    func testUpsertPreservesExistingEntryWhenPidConflictsForSameWindowId() throws {
        let model = WindowModel()
        let existingWorkspaceId = WorkspaceDescriptor(name: "existing").id
        let proposedWorkspaceId = WorkspaceDescriptor(name: "proposed").id
        let windowId = 467_001
        let existingPid: pid_t = 467_101
        let proposedPid: pid_t = 467_102
        let existingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(existingPid),
            windowId: windowId
        )
        let existingRuleEffects = ManagedWindowRuleEffects(
            minWidth: 640,
            minHeight: 480,
            matchedRuleId: nil
        )
        let existingAdmissionHints = ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.5)
        let existingToken = model.upsert(
            window: existingAXRef,
            pid: existingPid,
            windowId: windowId,
            workspace: existingWorkspaceId,
            mode: .floating,
            ruleEffects: existingRuleEffects,
            admissionHints: existingAdmissionHints
        )
        let existingHandle = try XCTUnwrap(model.handle(for: existingToken))
        let existingConstraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: .zero,
            isFixed: false
        )
        model.setCachedConstraints(existingConstraints, for: existingToken)

        let returnedToken = model.upsert(
            window: AXWindowRef(
                element: AXUIElementCreateApplication(proposedPid),
                windowId: windowId
            ),
            pid: proposedPid,
            windowId: windowId,
            workspace: proposedWorkspaceId,
            mode: .tiling
        )

        XCTAssertEqual(returnedToken, existingToken)
        XCTAssertEqual(model.allEntries().count, 1)
        XCTAssertEqual(model.entry(forWindowId: windowId)?.token, existingToken)
        XCTAssertNil(model.entry(for: WindowToken(pid: proposedPid, windowId: windowId)))
        XCTAssertEqual(model.entries(forPid: existingPid).map(\.token), [existingToken])
        XCTAssertTrue(model.entries(forPid: proposedPid).isEmpty)
        XCTAssertEqual(model.windows(in: existingWorkspaceId).map(\.token), [existingToken])
        XCTAssertTrue(model.windows(in: proposedWorkspaceId).isEmpty)
        XCTAssertEqual(model.mode(for: existingToken), .floating)
        XCTAssertEqual(model.entry(for: existingToken)?.ruleEffects, existingRuleEffects)
        XCTAssertEqual(model.admissionHints(for: existingToken), existingAdmissionHints)
        XCTAssertEqual(model.cachedConstraints(for: existingToken), existingConstraints.normalized())
        XCTAssertTrue(model.handle(for: existingToken) === existingHandle)

        var retainedAXPid: pid_t = 0
        let retainedAXRef = try XCTUnwrap(model.entry(for: existingToken)?.axRef)
        XCTAssertEqual(AXUIElementGetPid(retainedAXRef.element, &retainedAXPid), .success)
        XCTAssertEqual(retainedAXPid, existingPid)

        XCTAssertEqual(model.removeWindow(key: existingToken)?.token, existingToken)
        XCTAssertNil(model.entry(forWindowId: windowId))
        XCTAssertTrue(model.entries(forPid: existingPid).isEmpty)
        XCTAssertTrue(model.windows(in: existingWorkspaceId).isEmpty)
    }

    func testRekeyRejectsWindowIdOwnedByAnotherToken() throws {
        let model = WindowModel()
        let workspaceId = WorkspaceDescriptor(name: "workspace").id
        let sourceToken = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_201), windowId: 467_011),
            pid: 467_201,
            windowId: 467_011,
            workspace: workspaceId
        )
        let existingToken = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_202), windowId: 467_012),
            pid: 467_202,
            windowId: 467_012,
            workspace: workspaceId
        )
        let sourceHandle = try XCTUnwrap(model.handle(for: sourceToken))
        let existingHandle = try XCTUnwrap(model.handle(for: existingToken))
        let proposedToken = WindowToken(pid: 467_203, windowId: existingToken.windowId)

        let result = model.rekeyWindow(
            from: sourceToken,
            to: proposedToken,
            newAXRef: AXWindowRef(
                element: AXUIElementCreateApplication(proposedToken.pid),
                windowId: proposedToken.windowId
            )
        )

        XCTAssertNil(result)
        XCTAssertEqual(Set(model.allEntries().map(\.token)), [sourceToken, existingToken])
        XCTAssertEqual(model.entry(forWindowId: sourceToken.windowId)?.token, sourceToken)
        XCTAssertEqual(model.entry(forWindowId: existingToken.windowId)?.token, existingToken)
        XCTAssertNil(model.entry(for: proposedToken))
        XCTAssertTrue(model.handle(for: sourceToken) === sourceHandle)
        XCTAssertTrue(model.handle(for: existingToken) === existingHandle)
        XCTAssertEqual(Set(model.windows(in: workspaceId).map(\.token)), [sourceToken, existingToken])
    }
}
