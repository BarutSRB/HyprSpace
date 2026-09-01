// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SurfaceReconcileScopeTests: XCTestCase {
    private enum AuxiliaryApply: Equatable {
        case tabRails(count: Int, forceOrdering: Bool)
        case nativeFullscreenPlaceholders(count: Int, forceOrdering: Bool)
    }

    func testFullSceneWinsWhenCoalescedWithBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler

        reconciler.noteBorderChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        reconciler.noteWorldChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.noteBorderChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)

        reconciler.reconcileNow()

        XCTAssertNil(reconciler.pendingReconcileScope)
        XCTAssertFalse(reconciler.reconcileScheduled)
    }

    func testRestackSchedulesOnlyBorderAndForcesItsOrdering() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler

        reconciler.noteRestackOccurred()

        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        XCTAssertTrue(reconciler.forceOrderingOnNextReconcile)
    }

    func testForcedBorderRestackReordersAppliedAuxiliarySurfaces() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        var applies: [AuxiliaryApply] = []
        let reconciler = SurfaceReconciler(
            controller: controller,
            applyTabRails: { _, infos, forceOrdering in
                applies.append(.tabRails(count: infos.count, forceOrdering: forceOrdering))
            },
            applyNativeFullscreenPlaceholders: { _, placeholders, forceOrdering in
                applies.append(
                    .nativeFullscreenPlaceholders(
                        count: placeholders.count,
                        forceOrdering: forceOrdering
                    )
                )
            }
        )

        reconciler.noteBorderChanged()
        reconciler.reconcileNow()

        XCTAssertTrue(applies.isEmpty)

        reconciler.noteRestackOccurred()
        reconciler.reconcileNow()

        XCTAssertEqual(
            applies,
            [
                .tabRails(count: 0, forceOrdering: true),
                .nativeFullscreenPlaceholders(count: 0, forceOrdering: true)
            ]
        )
    }

    func testCoalescedFullSceneRestackPreservesAuxiliaryForceOrdering() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        var applies: [AuxiliaryApply] = []
        let reconciler = SurfaceReconciler(
            controller: controller,
            applyTabRails: { _, infos, forceOrdering in
                applies.append(.tabRails(count: infos.count, forceOrdering: forceOrdering))
            },
            applyNativeFullscreenPlaceholders: { _, placeholders, forceOrdering in
                applies.append(
                    .nativeFullscreenPlaceholders(
                        count: placeholders.count,
                        forceOrdering: forceOrdering
                    )
                )
            }
        )

        reconciler.noteRestackOccurred()
        reconciler.noteWorldChanged()
        reconciler.reconcileNow()

        XCTAssertEqual(
            applies,
            [
                .tabRails(count: 0, forceOrdering: true),
                .nativeFullscreenPlaceholders(count: 0, forceOrdering: true)
            ]
        )
    }

    func testDisplayScaleInvalidationSchedulesBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
    }

    func testAnimationTickDoesNotConsumePendingFullScenePass() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler
        reconciler.noteWorldChanged()

        reconciler.reconcileAnimationTick()

        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        XCTAssertTrue(reconciler.reconcileScheduled)
    }

    func testExternalFocusProductionPathSchedulesBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")

        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: 812_001, windowId: 812_002))

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    func testSuppressionAndSystemModalProductionPathsRemainBorderOnly() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 812_051, windowId: 812_052)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.suppressFocusBorder(for: token)

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.setSystemModalFocus(token)

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    func testFloatingGeometryProductionPathSchedulesBorderOnly() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 812_101, windowId: 812_102)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 100, y: 120, width: 800, height: 600),
            for: token
        )

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    func testBorderColorChangeSchedulesOnlyOneBorderPass() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        controller.surfaceReconciler.reconcileNow()
        controller.settings.borderColor = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)

        controller.borderSettingsChanged()

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testClearanceChangingBorderWidthSchedulesFullSceneAndLayout() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        controller.settings.bordersEnabled = true
        controller.settings.borderWidth = 5
        controller.borderSettingsChanged()
        controller.surfaceReconciler.reconcileNow()
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
        controller.settings.borderWidth = 6

        controller.borderSettingsChanged()

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .fullScene)
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.reason
                ?? controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutConfigChanged
        )
    }
}
