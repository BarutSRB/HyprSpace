// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionIdentityLifecycleTests: XCTestCase {
    func testDuplicateCGSCreatePreservesPinnedHiddenScratchpad() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_951
        let pid: pid_t = 467_952
        let element = AXUIElementCreateApplication(pid)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: element, windowId: Int(windowId)),
            pid: pid,
            windowId: Int(windowId),
            to: workspaceId,
            mode: .floating
        )
        XCTAssertTrue(controller.workspaceManager.setScratchpadToken(token))
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .scratchpad
            ),
            for: token
        )
        AXWindowService.pinAXElement(element, for: windowId)
        defer { AXWindowService.unpinAXElement(for: windowId) }

        controller.axEventHandler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))

        XCTAssertTrue(AXWindowService.hasPinnedAXElement(for: windowId))
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: Int(windowId))?.token, token)
    }

    func testCanonicalObservationDoesNotMutateNiriState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_953), windowId: 467_954)
        let oldToken = controller.workspaceManager.addWindow(
            oldAXRef,
            pid: 467_953,
            windowId: oldAXRef.windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.niriEngine?.addWindow(token: oldToken, to: workspaceId, afterSelection: nil)
        }
        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_955),
            windowId: oldToken.windowId
        )

        let observed = controller.axEventHandler.canonicalObservedWindowToken(
            pid: 467_955,
            axRef: replacementAXRef
        )

        XCTAssertEqual(observed, WindowToken(pid: 467_955, windowId: oldToken.windowId))
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.token, oldToken)
        XCTAssertNotNil(controller.niriEngine?.findNode(for: oldToken, in: workspaceId))
    }

    func testCanonicalObservationDoesNotMutateDwindleState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "97",
                layoutType: .dwindle,
                controller: controller
            )
        )
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_956), windowId: 467_957)
        let oldToken = controller.workspaceManager.addWindow(
            oldAXRef,
            pid: 467_956,
            windowId: oldAXRef.windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.dwindleEngine?.addWindow(
                token: oldToken,
                to: workspaceId,
                activeWindowFrame: nil
            )
        }
        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_958),
            windowId: oldToken.windowId
        )

        let observed = controller.axEventHandler.canonicalObservedWindowToken(
            pid: 467_958,
            axRef: replacementAXRef
        )

        XCTAssertEqual(observed, WindowToken(pid: 467_958, windowId: oldToken.windowId))
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.token, oldToken)
        XCTAssertTrue(controller.dwindleEngine?.containsWindow(oldToken, in: workspaceId) == true)
    }

    func testExplicitStaleRetirementRemovesNiriLayoutNode() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(467_959), windowId: 467_960)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 467_959,
            windowId: axRef.windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

        controller.axEventHandler.discardStaleManagedWindowIncarnation(entry)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
    }

    func testExplicitStaleRetirementRemovesDwindleLayoutNode() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "98",
                layoutType: .dwindle,
                controller: controller
            )
        )
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(467_961), windowId: 467_962)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 467_961,
            windowId: axRef.windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.dwindleEngine?.addWindow(
                token: token,
                to: workspaceId,
                activeWindowFrame: nil
            )
        }
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

        controller.axEventHandler.discardStaleManagedWindowIncarnation(entry)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertFalse(controller.dwindleEngine?.containsWindow(token, in: workspaceId) == true)
    }

    func testAuthoritativeRescanRetirementCancelsRebindAndRemovesNiriIdentity() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldPID: pid_t = 467_973
        let newPID: pid_t = 467_974
        let windowId = 467_975
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(oldPID), windowId: windowId)
        let newAXRef = AXWindowRef(element: AXUIElementCreateApplication(newPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            oldAXRef,
            pid: oldPID,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let aliases = FullRescanWindowIdentityAliases(
            pids: [oldPID, newPID],
            axRefs: [oldAXRef, newAXRef]
        )
        controller.axEventHandler.updateIdentityAliases([windowId: aliases])
        _ = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: newAXRef,
            pid: newPID,
            windowId: windowId,
            observedAliases: aliases
        )
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(keys: [], requiredConsecutiveMisses: 2).isEmpty
        )
        let missingEntry = try XCTUnwrap(
            controller.layoutRefreshController.confirmedMissingEntries(keys: [], requiredConsecutiveMisses: 2).first
        )

        controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(missingEntry)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])
        XCTAssertNil(controller.axEventHandler.identityAliasesByWindowId[windowId])
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
    }

    func testAuthoritativeRescanRetirementRemovesDwindleIdentity() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "99",
                layoutType: .dwindle,
                controller: controller
            )
        )
        let token = WindowToken(pid: 467_976, windowId: 467_977)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        }
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(keys: [], requiredConsecutiveMisses: 2).isEmpty
        )
        let missingEntry = try XCTUnwrap(
            controller.layoutRefreshController.confirmedMissingEntries(keys: [], requiredConsecutiveMisses: 2).first
        )

        controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(missingEntry)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertFalse(controller.dwindleEngine?.containsWindow(token, in: workspaceId) == true)
    }

    func testIdentityAliasHistoryRetainsOnlyTwoCommittedGenerations() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId = 467_963
        let first = AXWindowRef(element: AXUIElementCreateApplication(467_964), windowId: windowId)
        let second = AXWindowRef(element: AXUIElementCreateApplication(467_965), windowId: windowId)
        let third = AXWindowRef(element: AXUIElementCreateApplication(467_966), windowId: windowId)

        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [467_964], axRefs: [first])
        ])
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [467_965], axRefs: [second])
        ])
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [467_966], axRefs: [third])
        ])

        XCTAssertFalse(controller.axEventHandler.isKnownAXIdentityAlias(windowId: windowId, axRef: first))
        XCTAssertTrue(controller.axEventHandler.isKnownAXIdentityAlias(windowId: windowId, axRef: second))
        XCTAssertTrue(controller.axEventHandler.isKnownAXIdentityAlias(windowId: windowId, axRef: third))
        XCTAssertEqual(controller.axEventHandler.identityAliasesByWindowId[windowId]?.current?.axRefs.count, 1)
        XCTAssertEqual(controller.axEventHandler.identityAliasesByWindowId[windowId]?.previous?.axRefs.count, 1)
    }

    func testIdentityAliasHistoryPreservesOmittedRetainedWindowAndPrunesUnretainedWindow() {
        let controller = WindowAdmissionTestSupport.controller()
        let retainedWindowId = 467_967
        let removedWindowId = 467_968
        let retained = AXWindowRef(
            element: AXUIElementCreateApplication(467_969),
            windowId: retainedWindowId
        )
        let removed = AXWindowRef(
            element: AXUIElementCreateApplication(467_970),
            windowId: removedWindowId
        )
        controller.axEventHandler.updateIdentityAliases([
            retainedWindowId: .init(pids: [467_969], axRefs: [retained]),
            removedWindowId: .init(pids: [467_970], axRefs: [removed])
        ])

        controller.axEventHandler.updateIdentityAliases([:])
        controller.axEventHandler.pruneIdentityAliases(retainingWindowIds: [retainedWindowId])

        XCTAssertTrue(
            controller.axEventHandler.isKnownAXIdentityAlias(
                windowId: retainedWindowId,
                axRef: retained
            )
        )
        XCTAssertNil(controller.axEventHandler.identityAliasesByWindowId[removedWindowId])
    }

    func testAppTerminationPrunesBothAliasGenerations() {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_971
        let windowId = 467_972
        let first = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let second = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [pid], axRefs: [first])
        ])
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [pid], axRefs: [second])
        ])

        controller.axEventHandler.cleanupAdmissionStateForTerminatedApp(pid: pid)

        XCTAssertNil(controller.axEventHandler.identityAliasesByWindowId[windowId])
    }
}
