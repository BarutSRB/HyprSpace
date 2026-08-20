// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarLifecyclePolicyTests: XCTestCase {
    func testRefreshRequiresEnabledAvailableAndConfiguredHiddenApp() {
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: false,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: true,
            available: false,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarController.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: []
        ))
        XCTAssertTrue(HiddenBarController.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
    }

    func testTemporaryRevealAndPendingCaptureStayAllowed() {
        XCTAssertEqual(
            HiddenBarController.effectiveHiddenBundleIDs(
                configured: ["revealed", "capturing", "concealed"],
                temporarilyRevealed: ["revealed"],
                pendingCapture: ["capturing"]
            ),
            ["concealed"]
        )
    }

    @MainActor
    func testTopologyRefreshDebouncesScreenChanges() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarTopologyDebounce")
        let hiddenBar = controller.hiddenBarController
        var refreshes = 0
        hiddenBar.topologyRefreshSleeper = { _ in await Task.yield() }
        hiddenBar.onTopologyRefreshForTests = { refreshes += 1 }

        hiddenBar.scheduleTopologyRefresh()
        hiddenBar.scheduleTopologyRefresh()
        let didRefresh = await waitUntil { refreshes == 1 }

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(hiddenBar.hasPendingTopologyRefreshForTests)
        hiddenBar.cleanup()
    }

    @MainActor
    func testCleanupRemovesScreenObserverAndCancelsTopologyRefresh() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarTopologyCleanup")
        let hiddenBar = controller.hiddenBarController
        var refreshes = 0
        hiddenBar.topologyRefreshSleeper = { _ in try await Task.sleep(for: .seconds(60)) }
        hiddenBar.onTopologyRefreshForTests = { refreshes += 1 }
        hiddenBar.setup()
        XCTAssertTrue(hiddenBar.hasScreenParametersObserverForTests)

        hiddenBar.scheduleTopologyRefresh()
        XCTAssertTrue(hiddenBar.hasPendingTopologyRefreshForTests)
        hiddenBar.cleanup()
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        XCTAssertFalse(hiddenBar.hasScreenParametersObserverForTests)
        XCTAssertFalse(hiddenBar.hasPendingTopologyRefreshForTests)
        XCTAssertEqual(refreshes, 0)
    }

    @MainActor
    func testCleanupRejectsQueuedObserverEventFromStoppedGeneration() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarObserverCleanup")
        let hiddenBar = controller.hiddenBarController
        hiddenBar.setup()
        hiddenBar.beginPerformanceCapture()

        hiddenBar.enqueueDidBecomeActiveForTests()
        hiddenBar.cleanup()
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        XCTAssertEqual(hiddenBar.endPerformanceCapture()?.refreshEvents, 0)
    }

    func testLaunchCaptureStaysAllowedDuringAnotherAppsReveal() {
        let effectiveHidden = HiddenBarController.effectiveHiddenBundleIDs(
            configured: ["revealed", "newly-launched", "concealed"],
            temporarilyRevealed: ["revealed"],
            pendingCapture: ["newly-launched"]
        )
        let result = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: effectiveHidden,
            runningBundleIDs: ["revealed", "concealed", "newly-launched"],
            protectedBundleIDs: []
        )
        XCTAssertTrue(result.allowed.contains("revealed"))
        XCTAssertTrue(result.allowed.contains("newly-launched"))
        XCTAssertEqual(result.concealed, ["concealed"])
    }

    func testOpenMenuDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: true
            ),
            .seconds(5)
        )
    }

    func testUnknownMenuStateDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: nil
            ),
            .seconds(5)
        )
    }

    func testClosedIntervalsAccumulateUntilRehideExpires() {
        var remaining = Duration.seconds(5)
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(2),
            previousMenuOpen: false,
            menuOpen: false
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(4),
            previousMenuOpen: false,
            menuOpen: true
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: true,
            menuOpen: false
        )
        remaining = HiddenBarController.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: false,
            menuOpen: false
        )
        XCTAssertEqual(remaining, .zero)
    }

    func testNegativeElapsedTimeDoesNotIncreaseCountdown() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(-2),
                previousMenuOpen: false,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testFirstClosedSampleStartsCountdownWithFullInterval() {
        XCTAssertEqual(
            HiddenBarController.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: nil,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testMenuGuardPollingBacksOffAndCaps() {
        XCTAssertEqual(HiddenBarController.menuGuardRetryDelay(consecutiveDeferrals: 0), .milliseconds(250))
        XCTAssertEqual(HiddenBarController.menuGuardRetryDelay(consecutiveDeferrals: 1), .milliseconds(500))
        XCTAssertEqual(HiddenBarController.menuGuardRetryDelay(consecutiveDeferrals: 2), .seconds(1))
        XCTAssertEqual(HiddenBarController.menuGuardRetryDelay(consecutiveDeferrals: 20), .seconds(2))
    }

    func testMenuGuardUnknownStateHasThreeQueryBound() {
        XCTAssertFalse(HiddenBarController.shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: 2))
        XCTAssertTrue(HiddenBarController.shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: 3))
    }

    func testMenuGuardWatchdogHasSixtySecondBound() {
        XCTAssertFalse(HiddenBarController.menuGuardWatchdogExpired(elapsed: .seconds(59)))
        XCTAssertTrue(HiddenBarController.menuGuardWatchdogExpired(elapsed: .seconds(60)))
    }

    @MainActor
    func testUnknownMenuStateTerminatesAfterThreeInjectedQueries() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarUnknownGuard")
        let hiddenBar = controller.hiddenBarController
        var now = ContinuousClock().now
        hiddenBar.menuGuardNow = { now }
        hiddenBar.menuGuardSleeper = { delay in
            now = now.advanced(by: delay)
            await Task.yield()
        }
        hiddenBar.menuOpenProviderForTests = { _ in nil }
        hiddenBar.beginPerformanceCapture()

        hiddenBar.startReconcealForTests(revealedBundleIDs: ["com.omniwm.unknown"])
        await driveReconcealTask(hiddenBar)

        let snapshot = hiddenBar.endPerformanceCapture()
        XCTAssertEqual(snapshot?.menuGuardQueries, 3)
        XCTAssertEqual(snapshot?.terminalReason, .unknownStateLimit)
        XCTAssertTrue(hiddenBar.temporarilyRevealedBundleIDsForTests.isEmpty)
        hiddenBar.cleanup()
    }

    @MainActor
    func testDefinitelyOpenMenuUsesWatchdogInsteadOfUnknownBound() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarWatchdog")
        let hiddenBar = controller.hiddenBarController
        var now = ContinuousClock().now
        hiddenBar.menuGuardNow = { now }
        hiddenBar.menuGuardSleeper = { delay in
            now = now.advanced(by: delay)
            await Task.yield()
        }
        hiddenBar.menuOpenProviderForTests = { _ in true }
        hiddenBar.beginPerformanceCapture()

        hiddenBar.startReconcealForTests(revealedBundleIDs: ["com.omniwm.open"])
        await driveReconcealTask(hiddenBar)

        let terminalSnapshot = hiddenBar.performanceSnapshot()
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(
            hiddenBar.performanceSnapshot()?.menuGuardQueries,
            terminalSnapshot?.menuGuardQueries
        )
        let snapshot = hiddenBar.endPerformanceCapture()
        XCTAssertGreaterThan(snapshot?.menuGuardQueries ?? 0, 3)
        XCTAssertEqual(snapshot?.terminalReason, .watchdog)
        XCTAssertTrue(hiddenBar.temporarilyRevealedBundleIDsForTests.isEmpty)
        hiddenBar.cleanup()
    }

    func testFailedRevealDoesNotStartCountdownDuringPriorActivation() {
        XCTAssertFalse(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: true
        ))
        XCTAssertTrue(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: false
        ))
        XCTAssertFalse(HiddenBarController.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: false,
            activationInFlight: false
        ))
    }

    func testActivationContextRequiresConfigurationRevealAndExactPID() {
        let candidates = [
            MenuBarAppCandidate(bundleID: "target", pid: 42, name: "Target"),
            MenuBarAppCandidate(bundleID: "target", pid: 43, name: "Replacement")
        ]
        XCTAssertTrue(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: [],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: [],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarController.activationContextIsValid(
            bundleID: "target",
            pid: 44,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
    }

    func testAppliedConfigReportsWhetherTargetRemainsConcealed() {
        let config = HiddenBarAppliedConfig(
            allowed: ["visible"],
            concealed: ["hidden"],
            at: .now
        )
        XCTAssertTrue(AssessmentModeHider.appliedConfig(config, conceals: "hidden"))
        XCTAssertFalse(AssessmentModeHider.appliedConfig(config, conceals: "visible"))
        XCTAssertFalse(AssessmentModeHider.appliedConfig(nil, conceals: "hidden"))
    }

    @MainActor
    private func driveReconcealTask(_ hiddenBar: HiddenBarController) async {
        for _ in 0 ..< 256 {
            if hiddenBar.performanceSnapshot()?.terminalReason != nil {
                return
            }
            await Task.yield()
        }
        XCTFail("Reconceal task did not reach a terminal state")
    }

    @MainActor
    func testDroppingAssertionInvalidatesActivationGeneration() {
        let hider = AssessmentModeHider()
        let generation = hider.activationGeneration

        hider.drop()

        XCTAssertEqual(hider.activationGeneration, generation + 1)
    }

    @MainActor
    func testSynchronousActivationFailureRetriesUntilSuccess() async {
        var attempts = 0
        let handle = UnsafeMutableRawPointer(bitPattern: 1)!
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, _ in
                attempts += 1
                return attempts == 3 ? handle : nil
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertFalse(hider.apply(
            hiddenBundleIDs: ["com.example.hidden"],
            runningBundleIDs: ["com.example.hidden"]
        ))
        let didConceal = await waitUntil { hider.isConcealing }
        XCTAssertTrue(didConceal)
        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(hider.hasPendingRetryForTests)
        hider.drop()
    }

    @MainActor
    func testSynchronousActivationRetriesAreBounded() async {
        var attempts = 0
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, _ in
                attempts += 1
                return nil
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertFalse(hider.apply(
            hiddenBundleIDs: ["com.example.hidden"],
            runningBundleIDs: ["com.example.hidden"]
        ))
        let didExhaustRetries = await waitUntil { !hider.hasPendingRetryForTests }
        XCTAssertTrue(didExhaustRetries)
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(attempts, 4)
        hider.drop()
    }

    @MainActor
    func testIdenticalRefreshesDoNotResetActivationRetryBudget() async {
        var attempts = 0
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, _ in
                attempts += 1
                return nil
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertFalse(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
        for _ in 0 ..< 16 {
            XCTAssertFalse(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
            await Task.yield()
        }
        let didExhaustRetries = await waitUntil { !hider.hasPendingRetryForTests }
        XCTAssertTrue(didExhaustRetries)

        for _ in 0 ..< 8 {
            XCTAssertFalse(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
            await Task.yield()
        }

        XCTAssertEqual(attempts, 4)
        hider.drop()
    }

    @MainActor
    func testAsynchronousActivationFailureRetriesCurrentDesiredConfig() async {
        var attempts = 0
        var failures: [() -> Void] = []
        var invalidated: [Int] = []
        let firstHandle = UnsafeMutableRawPointer(bitPattern: 1)!
        let secondHandle = UnsafeMutableRawPointer(bitPattern: 2)!
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, onFailure in
                attempts += 1
                failures.append(onFailure)
                return attempts == 1 ? firstHandle : secondHandle
            },
            invalidationHandler: { invalidated.append(Int(bitPattern: $0)) }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertTrue(hider.apply(
            hiddenBundleIDs: ["com.example.hidden"],
            runningBundleIDs: ["com.example.hidden"]
        ))
        failures[0]()
        let didRetry = await waitUntil { attempts == 2 && hider.isConcealing }
        XCTAssertTrue(didRetry)
        XCTAssertEqual(invalidated, [1])
        XCTAssertFalse(hider.hasPendingRetryForTests)
        hider.drop()
    }

    @MainActor
    func testFailedReplacementCallbackCannotInvalidateNewerHandle() async {
        var attempts = 0
        var failures: [() -> Void] = []
        var invalidated: [Int] = []
        let firstHandle = UnsafeMutableRawPointer(bitPattern: 1)!
        let newestHandle = UnsafeMutableRawPointer(bitPattern: 3)!
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, onFailure in
                attempts += 1
                failures.append(onFailure)
                switch attempts {
                case 1:
                    return firstHandle
                case 2:
                    return nil
                default:
                    return newestHandle
                }
            },
            invalidationHandler: { invalidated.append(Int(bitPattern: $0)) }
        )
        hider.retrySleeper = { _ in try await Task.sleep(for: .seconds(60)) }

        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["b"], runningBundleIDs: ["b"]))
        XCTAssertTrue(hider.isConcealing)

        failures[0]()
        let didHonorOldHandleFailure = await waitUntil { !hider.isConcealing }
        XCTAssertTrue(didHonorOldHandleFailure)
        XCTAssertEqual(invalidated, [1])

        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["c"], runningBundleIDs: ["c"]))
        XCTAssertTrue(hider.conceals("c"))
        failures[1]()
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        XCTAssertTrue(hider.isConcealing)
        XCTAssertTrue(hider.conceals("c"))
        XCTAssertEqual(invalidated, [1])
        hider.drop()
    }

    @MainActor
    func testOldHandleFailureCannotRestartExhaustedReplacementRetries() async {
        var attemptsByBundleID: [String: Int] = [:]
        var oldHandleFailure: (() -> Void)?
        let oldHandle = UnsafeMutableRawPointer(bitPattern: 1)!
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, onFailure in
                let bundleID = attemptsByBundleID["a"] == nil ? "a" : "b"
                attemptsByBundleID[bundleID, default: 0] += 1
                if bundleID == "a" {
                    oldHandleFailure = onFailure
                    return oldHandle
                }
                return nil
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["b"], runningBundleIDs: ["b"]))
        let didExhaustReplacementRetries = await waitUntil {
            attemptsByBundleID["b"] == 4 && !hider.hasPendingRetryForTests
        }
        XCTAssertTrue(didExhaustReplacementRetries)
        XCTAssertTrue(hider.isConcealing)

        oldHandleFailure?()
        let didRemoveOldHandle = await waitUntil { !hider.isConcealing }
        XCTAssertTrue(didRemoveOldHandle)
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(attemptsByBundleID["b"], 4)
        XCTAssertFalse(hider.hasPendingRetryForTests)

        XCTAssertFalse(hider.apply(hiddenBundleIDs: ["b"], runningBundleIDs: ["b"]))
        XCTAssertEqual(attemptsByBundleID["b"], 4)
        hider.drop()
    }

    @MainActor
    func testAntiFlapDeferralEventuallyAppliesDesiredConfig() async {
        var attempts = 0
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, _ in
                attempts += 1
                return UnsafeMutableRawPointer(bitPattern: attempts)!
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in await Task.yield() }

        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["b"], runningBundleIDs: ["b"]))
        XCTAssertTrue(hider.apply(hiddenBundleIDs: ["a"], runningBundleIDs: ["a"]))
        XCTAssertTrue(hider.hasPendingRetryForTests)
        let didApplyDeferredConfig = await waitUntil { hider.conceals("a") }
        XCTAssertTrue(didApplyDeferredConfig)
        XCTAssertEqual(attempts, 3)
        hider.drop()
    }

    @MainActor
    func testDropCancelsPendingActivationRetry() async {
        var attempts = 0
        let hider = AssessmentModeHider(
            availabilityProvider: { true },
            activationHandler: { _, _, _ in
                attempts += 1
                return nil
            },
            invalidationHandler: { _ in }
        )
        hider.retrySleeper = { _ in try await Task.sleep(for: .seconds(60)) }

        XCTAssertFalse(hider.apply(
            hiddenBundleIDs: ["com.example.hidden"],
            runningBundleIDs: ["com.example.hidden"]
        ))
        XCTAssertTrue(hider.hasPendingRetryForTests)
        hider.drop()
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(hider.hasPendingRetryForTests)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0 ..< 128 {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
