// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class LockScreenObserverTests: XCTestCase {
    func testStartReportsFrontmostLoginWindowAsLocked() {
        let observer = LockScreenObserver()
        observer.frontmostBundleIdProvider = { LockScreenObserver.lockScreenAppBundleId }
        var lockDetections = 0
        observer.onLockDetected = { lockDetections += 1 }

        observer.start()
        defer { observer.stop() }
        observer.start()

        XCTAssertEqual(lockDetections, 1)
        guard case .locked = observer.state else {
            return XCTFail("expected locked state")
        }
        XCTAssertTrue(observer.isFrontmostAppLockScreen())
    }

    func testServiceRestartReconcilesUnlockMissedWhileObserverWasStopped() {
        let controller = WindowAdmissionTestSupport.controller()
        let observer = controller.lockScreenObserver
        observer.frontmostBundleIdProvider = { LockScreenObserver.lockScreenAppBundleId }
        defer {
            observer.stop()
            controller.layoutRefreshController.resetState()
            controller.isLockScreenActive = false
        }

        controller.serviceLifecycleManager.startLockScreenObserver()
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.pendingRefresh)

        observer.stop()
        observer.frontmostBundleIdProvider = { "com.example.unlocked" }
        controller.serviceLifecycleManager.startLockScreenObserver()

        XCTAssertFalse(controller.isLockScreenActive)
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isAwaitingPostUnlockTopologySample)
    }

    func testServiceRestartWhileStillLockedRestoresRefreshSuspension() {
        let controller = WindowAdmissionTestSupport.controller()
        let observer = controller.lockScreenObserver
        observer.frontmostBundleIdProvider = { LockScreenObserver.lockScreenAppBundleId }
        defer {
            observer.stop()
            controller.layoutRefreshController.resetState()
            controller.isLockScreenActive = false
        }

        controller.serviceLifecycleManager.startLockScreenObserver()
        observer.stop()
        controller.layoutRefreshController.resetState()

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertFalse(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)

        controller.serviceLifecycleManager.startLockScreenObserver()

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)
    }

    func testAuthoritativeUnlockClearsCachedLoginWindowBeforeAppActivation() {
        let observer = LockScreenObserver()
        observer.frontmostBundleIdProvider = { LockScreenObserver.lockScreenAppBundleId }
        var unlockDetections = 0
        observer.onUnlockDetected = { unlockDetections += 1 }
        observer.start()
        defer { observer.stop() }

        observer.handleUnlockEvent()
        observer.handleUnlockEvent()

        XCTAssertEqual(unlockDetections, 1)
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
        guard case .transitioning = observer.state else {
            return XCTFail("expected transitioning state")
        }
    }

    func testQueuedLockFromStoppedGenerationCannotOverrideRestartSample() async {
        let observer = LockScreenObserver()
        observer.frontmostBundleIdProvider = { "com.example.unlocked" }
        var lockDetections = 0
        observer.onLockDetected = { lockDetections += 1 }
        observer.start()

        observer.enqueueLockEventForTests()
        observer.stop()
        observer.start()
        defer { observer.stop() }
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        XCTAssertEqual(lockDetections, 0)
        guard case .unlocked = observer.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
    }

    func testUnknownFrontmostIdentityPreservesLockedStateOnRestart() {
        let observer = LockScreenObserver()
        observer.frontmostBundleIdProvider = { LockScreenObserver.lockScreenAppBundleId }
        observer.start()
        observer.stop()
        observer.frontmostBundleIdProvider = { nil }

        observer.start()
        defer { observer.stop() }
        observer.handleAppActivation(bundleId: nil)

        guard case .locked = observer.state else {
            return XCTFail("expected locked state")
        }
        XCTAssertTrue(observer.isFrontmostAppLockScreen())
    }
}
