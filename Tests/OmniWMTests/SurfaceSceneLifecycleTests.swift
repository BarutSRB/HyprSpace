// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SurfaceSceneLifecycleTests: XCTestCase {
    func testReplacingSurfaceIDRemovesPreviousObjectReverseIndex() {
        let scene = SurfaceScene()
        let firstWindow = NSPanel()
        let secondWindow = NSPanel()
        scene.beginRuntimeCapture()

        scene.register(window: firstWindow, node: node(id: "shared", window: firstWindow))
        scene.register(window: secondWindow, node: node(id: "shared", window: secondWindow))

        XCTAssertFalse(scene.contains(window: firstWindow))
        XCTAssertTrue(scene.contains(window: secondWindow))
        scene.unregister(window: firstWindow)
        XCTAssertTrue(scene.contains(window: secondWindow))
        let snapshot = scene.runtimeSnapshot()
        XCTAssertEqual(snapshot.total, 1)
        XCTAssertEqual(snapshot.reverseEntries, secondWindow.windowNumber > 0 ? 2 : 1)
        XCTAssertEqual(snapshot.orphanReverseEntries, 0)
        XCTAssertEqual(snapshot.highWater, 1)

        scene.unregister(id: "shared")
        XCTAssertFalse(scene.contains(window: secondWindow))
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
        firstWindow.close()
        secondWindow.close()
    }

    func testDragSurfaceDestroyUnregistersAllOwnedWindowsIdempotently() {
        let scene = SurfaceScene()
        let coordinator = SurfaceCoordinator(scene: scene)
        let controller = DragGhostController(
            surfaceCoordinator: coordinator,
            captureAccessAllowed: { false }
        )

        controller.beginDrag(
            windowId: 720_001,
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            cursorLocation: CGPoint(x: 400, y: 300)
        )
        controller.showSwapTarget(frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(coordinator.visibleSurfaceIDs(kind: .dragGhost).count, 1)

        controller.destroy()
        controller.destroy()

        XCTAssertTrue(coordinator.visibleSurfaceIDs(kind: .dragGhost).isEmpty)
        XCTAssertEqual(coordinator.runtimeSnapshot().total, 0)
        XCTAssertEqual(coordinator.runtimeSnapshot().orphanReverseEntries, 0)
    }

    func testRepeatedDragControllerLifecyclesReturnAllIndexesToBaseline() {
        let scene = SurfaceScene()
        let coordinator = SurfaceCoordinator(scene: scene)
        scene.beginRuntimeCapture()

        for index in 0 ..< 100 {
            let ghostWindow = DragGhostWindow(surfaceCoordinator: coordinator)
            ghostWindow.destroy()
            let controller = DragGhostController(
                surfaceCoordinator: coordinator,
                captureAccessAllowed: { false }
            )
            controller.beginDrag(
                windowId: 800_000 + index,
                originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                cursorLocation: CGPoint(x: 400, y: 300)
            )
            controller.showSwapTarget(frame: CGRect(x: 10, y: 20, width: 300, height: 200))
            controller.destroy()

            let snapshot = coordinator.runtimeSnapshot()
            XCTAssertEqual(snapshot.total, 0)
            XCTAssertEqual(snapshot.reverseEntries, 0)
            XCTAssertEqual(snapshot.orphanReverseEntries, 0)
        }

        XCTAssertGreaterThanOrEqual(coordinator.runtimeSnapshot().highWater, 1)
    }

    func testNumberBackedSurfacesAreNotReportedAsLiveWindows() {
        let scene = SurfaceScene()
        scene.registerWindowNumber(node: SurfaceScene.SurfaceNode(
            id: "border-1",
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            window: nil,
            windowObjectIdentifier: nil,
            windowNumber: 91,
            frameProvider: { .zero },
            visibilityProvider: { true }
        ))

        let snapshot = scene.runtimeSnapshot()
        XCTAssertEqual(snapshot.total, 1)
        XCTAssertEqual(snapshot.live, 0)
        XCTAssertEqual(snapshot.dead, 0)
        XCTAssertEqual(snapshot.numberBacked, 1)
        XCTAssertEqual(snapshot.byKind[.border], 1)

        scene.unregister(id: "border-1")
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
    }

    func testDeallocatedWindowBackedNodeIsInvisibleAndReapedOnNumberLookup() {
        let scene = SurfaceScene()
        weak var releasedWindow: NSPanel?
        autoreleasepool {
            let window = NSPanel()
            releasedWindow = window
            scene.register(window: window, node: SurfaceScene.SurfaceNode(
                id: "ephemeral",
                policy: SurfacePolicy(
                    kind: .utility,
                    hitTestPolicy: .interactive,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: true
                ),
                window: window,
                windowObjectIdentifier: ObjectIdentifier(window),
                windowNumber: 92,
                frameProvider: nil,
                visibilityProvider: nil
            ))
            window.close()
        }

        XCTAssertNil(releasedWindow)
        XCTAssertTrue(scene.visibleSurfaceIDs().isEmpty)
        XCTAssertTrue(scene.isCaptureEligible(windowNumber: 92))
        XCTAssertFalse(scene.contains(windowNumber: 92))
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
        XCTAssertEqual(scene.runtimeSnapshot().reverseEntries, 0)
    }

    private func node(id: String, window: NSWindow) -> SurfaceScene.SurfaceNode {
        SurfaceScene.SurfaceNode(
            id: id,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            window: window,
            windowObjectIdentifier: ObjectIdentifier(window),
            windowNumber: window.windowNumber > 0 ? window.windowNumber : nil,
            frameProvider: nil,
            visibilityProvider: nil
        )
    }
}
