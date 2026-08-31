// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class Issue626WindowOwnershipTests: XCTestCase {
    private let wordPID: pid_t = 20_789
    private let rootWindowId = 2_033
    private let searchWindowId = 2_040
    private let wordBundleId = "com.microsoft.Word"

    func testFocusedWordSearchToolbarIsStructurallyExternalBeforeLayoutRules() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [AppRule(bundleId: wordBundleId, layout: .float)])

        let decision = engine.decision(
            for: facts(
                role: kAXToolbarRole as String,
                subrole: kAXSystemDialogSubrole as String,
                parentId: UInt32(rootWindowId),
                windowId: searchWindowId
            ),
            token: searchToken,
            appFullscreen: false
        )

        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.admissionOutcome, .ignored)
        XCTAssertNil(decision.trackedMode)
    }

    func testRootWordDialogRemainsAManagedFloatingControl() {
        let engine = WindowRuleEngine()

        let decision = engine.decision(
            for: facts(
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                parentId: 0,
                windowId: searchWindowId,
                isModal: true
            ),
            token: searchToken,
            appFullscreen: false
        )

        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.admissionOutcome, .trackedFloating)
        XCTAssertEqual(decision.trackedMode, .floating)
    }

    func testFocusedWordSearchToolbarCannotEnterInventoryRetirementOrFocusRecovery() throws {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMIssue626WindowOwnershipTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in recorder.operations.append("raise") },
                orderWindow: { recorder.operations.append("order:\($0)") }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let notifications = FocusNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .omniwmFocusChanged,
            object: controller,
            queue: nil
        ) { notification in
            notifications.tokens.append(
                notification.userInfo?[OmniWMFocusNotificationKey.newWindowToken] as? WindowToken
            )
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: rootToken),
            pid: rootToken.pid,
            windowId: rootToken.windowId,
            to: workspaceId,
            lifetimeAuthority: .axTopLevelInventory
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                rootToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertEqual(notifications.tokens, [rootToken])

        let searchDecision = controller.windowRuleEngine.decision(
            for: facts(
                role: kAXToolbarRole as String,
                subrole: kAXSystemDialogSubrole as String,
                parentId: UInt32(rootWindowId),
                windowId: searchWindowId
            ),
            token: searchToken,
            appFullscreen: false
        )
        if let mode = controller.trackedModeForLifecycle(
            decision: searchDecision,
            existingEntry: nil
        ) {
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: searchToken),
                pid: searchToken.pid,
                windowId: searchToken.windowId,
                to: workspaceId,
                mode: mode,
                lifetimeAuthority: .directLifecycle
            )
        }

        XCTAssertNil(controller.workspaceManager.entry(for: searchToken))
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [rootToken])
        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: wordPID, windowId: searchWindowId))
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, rootToken)
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(pid: wordPID, windowId: searchWindowId)
        )
        XCTAssertEqual(notifications.tokens, [rootToken, nil])

        let queryRouter = IPCQueryRouter(
            controller: controller,
            appVersion: nil,
            sessionToken: "issue-626"
        )
        XCTAssertNil(queryRouter.focusedWindowResult().window)
        XCTAssertTrue(
            queryRouter.windowsResult(
                IPCQueryRequest(
                    name: .windows,
                    selectors: IPCQuerySelectors(focused: true)
                )
            ).windows.isEmpty
        )

        for _ in 0 ..< 2 {
            let missingEntries = controller.layoutRefreshController
                .confirmedMissingEntriesDuringFullRescan(
                    seenKeys: [rootToken],
                    eligibleKeys: Set(controller.workspaceManager.allEntries().map(\.token)),
                    permitsMissingRetirement: true
                )
            XCTAssertTrue(missingEntries.isEmpty)
        }

        controller.ensureFocusedTokenValid(in: workspaceId)

        XCTAssertNotNil(controller.workspaceManager.entry(for: rootToken))
        XCTAssertNil(controller.workspaceManager.entry(for: searchToken))
        XCTAssertTrue(recorder.operations.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
    }

    func testTopLevelInventoryAbsenceCannotRetireDirectLifecycleWindow() throws {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMIssue626LifetimeAuthorityTests"
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: rootToken),
            pid: rootToken.pid,
            windowId: rootToken.windowId,
            to: workspaceId,
            lifetimeAuthority: .axTopLevelInventory
        )
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: searchToken),
            pid: searchToken.pid,
            windowId: searchToken.windowId,
            to: workspaceId,
            mode: .floating,
            lifetimeAuthority: .directLifecycle
        )
        let eligibleKeys: Set<WindowToken> = [rootToken, searchToken]

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: eligibleKeys,
                permitsMissingRetirement: true
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: eligibleKeys,
                permitsMissingRetirement: true
            ).map(\.token),
            [rootToken]
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: searchToken))
    }

    private var rootToken: WindowToken {
        WindowToken(pid: wordPID, windowId: rootWindowId)
    }

    private var searchToken: WindowToken {
        WindowToken(pid: wordPID, windowId: searchWindowId)
    }

    private func facts(
        role: String,
        subrole: String,
        parentId: UInt32,
        windowId: Int,
        isMain: Bool = false,
        isModal: Bool = false
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Microsoft Word",
            ax: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: nil,
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: false,
                hasZoomButton: false,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: wordBundleId,
                attributeFetchSucceeded: true,
                isMain: isMain,
                isModal: isModal
            ),
            sizeConstraints: nil,
            windowServer: WindowServerInfo(
                id: UInt32(windowId),
                pid: wordPID,
                level: 0,
                frame: CGRect(x: 320, y: 160, width: 640, height: 480),
                parentId: parentId
            )
        )
    }

    private final class FocusRecorder: @unchecked Sendable {
        var operations: [String] = []
    }

    private final class FocusNotificationRecorder: @unchecked Sendable {
        var tokens: [WindowToken?] = []
    }
}
