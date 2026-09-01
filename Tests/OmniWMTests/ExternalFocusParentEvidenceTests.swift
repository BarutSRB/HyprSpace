// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class ExternalFocusParentEvidenceTests: XCTestCase {
    func testFirefoxTraceShapeVerifiesOnlyTheExactlySelectedManagedParent() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ExternalFocusParentEvidenceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let parent = WindowToken(pid: 10_763, windowId: 3_128)
        let child = WindowToken(pid: 10_763, windowId: 3_260)
        _ = WindowAdmissionTestSupport.track(parent, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parent,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let handler = controller.axEventHandler
        handler.windowInfoProvider = { windowId in
            guard windowId == UInt32(parent.windowId) else { return nil }
            return WindowServerInfo(
                id: windowId,
                pid: parent.pid,
                level: 0,
                frame: CGRect(x: 1_280, y: 70, width: 1_200, height: 1_350)
            )
        }
        let childInfo = WindowServerInfo(
            id: UInt32(child.windowId),
            pid: child.pid,
            level: 0,
            frame: CGRect(x: 2_128, y: 126, width: 280, height: 40),
            parentId: UInt32(parent.windowId)
        )

        XCTAssertEqual(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: childInfo
            ),
            parent
        )
    }

    func testChildAndParentPIDWIDMismatchesRejectContinuity() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ExternalFocusParentEvidenceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let parent = WindowToken(pid: 811_001, windowId: 811_002)
        let child = WindowToken(pid: 811_001, windowId: 811_003)
        _ = WindowAdmissionTestSupport.track(parent, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parent,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let handler = controller.axEventHandler
        var parentInfo = WindowServerInfo(
            id: UInt32(parent.windowId),
            pid: parent.pid + 1,
            level: 0,
            frame: .zero
        )
        handler.windowInfoProvider = { _ in parentInfo }
        let exactChildInfo = WindowServerInfo(
            id: UInt32(child.windowId),
            pid: child.pid,
            level: 0,
            frame: .zero,
            parentId: UInt32(parent.windowId)
        )

        XCTAssertNil(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: exactChildInfo
            )
        )

        parentInfo = WindowServerInfo(
            id: UInt32(parent.windowId),
            pid: parent.pid,
            level: 0,
            frame: .zero
        )
        let mismatchedChildInfo = WindowServerInfo(
            id: UInt32(child.windowId) + 1,
            pid: child.pid,
            level: 0,
            frame: .zero,
            parentId: UInt32(parent.windowId)
        )
        XCTAssertNil(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: mismatchedChildInfo
            )
        )
    }

    func testMissingSelfAndUnselectedParentsRejectContinuity() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ExternalFocusParentEvidenceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let selected = WindowToken(pid: 811_101, windowId: 811_102)
        let other = WindowToken(pid: 811_103, windowId: 811_104)
        let child = WindowToken(pid: 811_103, windowId: 811_105)
        _ = WindowAdmissionTestSupport.track(selected, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(other, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                selected,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let handler = controller.axEventHandler
        handler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: other.pid, level: 0, frame: .zero)
        }

        XCTAssertNil(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: WindowServerInfo(
                    id: UInt32(child.windowId),
                    pid: child.pid,
                    level: 0,
                    frame: .zero,
                    parentId: UInt32(other.windowId)
                )
            )
        )
        XCTAssertNil(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: WindowServerInfo(
                    id: UInt32(child.windowId),
                    pid: child.pid,
                    level: 0,
                    frame: .zero,
                    parentId: UInt32(child.windowId)
                )
            )
        )
        XCTAssertNil(
            handler.verifiedSelectedManagedParentToken(
                for: child,
                childWindowInfo: WindowServerInfo(
                    id: UInt32(child.windowId),
                    pid: child.pid,
                    level: 0,
                    frame: .zero,
                    parentId: 0
                )
            )
        )
    }
}
