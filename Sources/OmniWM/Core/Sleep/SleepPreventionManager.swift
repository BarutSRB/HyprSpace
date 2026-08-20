// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import IOKit.pwr_mgt

@MainActor
final class SleepPreventionManager {
    struct PerformanceSnapshot: Equatable, Sendable {
        let timerFires: UInt64
        let assertionRefreshes: UInt64
    }

    static let shared = SleepPreventionManager()

    private var sleepAssertionID: IOPMAssertionID?
    private var assertionTimer: Timer?
    private var isUserSessionActive = true
    private var performanceTimerFires: UInt64?
    private var performanceAssertionRefreshes: UInt64?

    private init() {
        setupWorkspaceNotifications()
    }

    func preventSleep() {
        assertionTimer?.invalidate()
        assertionTimer = Timer.scheduledTimer(
            withTimeInterval: 10.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSleepAssertion()
            }
        }
        assertionTimer?.fire()
    }

    func allowSleep() {
        assertionTimer?.invalidate()
        assertionTimer = nil
        releaseSleepAssertion()
    }

    func beginPerformanceCapture() {
        performanceTimerFires = 0
        performanceAssertionRefreshes = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        guard let timerFires = performanceTimerFires,
              let assertionRefreshes = performanceAssertionRefreshes
        else { return nil }
        return PerformanceSnapshot(
            timerFires: timerFires,
            assertionRefreshes: assertionRefreshes
        )
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceTimerFires = nil
        performanceAssertionRefreshes = nil
        return snapshot
    }

    private func refreshSleepAssertion() {
        performanceTimerFires? &+= 1
        guard isUserSessionActive else { return }
        performanceAssertionRefreshes? &+= 1

        if let assertionID = sleepAssertionID {
            if IOPMAssertionRelease(assertionID) != kIOReturnSuccess {
                FallbackFiringRecorder.shared.note(.system, "sleepAssertionReleaseFailed")
            }
        }

        var assertionID: IOPMAssertionID = 0
        let reason = "OmniWM prevents sleep" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            reason,
            nil,
            nil,
            nil,
            8,
            nil,
            &assertionID
        )

        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
        } else {
            FallbackFiringRecorder.shared.note(.system, "sleepAssertionCreateFailed")
        }
    }

    private func releaseSleepAssertion() {
        if let assertionID = sleepAssertionID {
            if IOPMAssertionRelease(assertionID) != kIOReturnSuccess {
                FallbackFiringRecorder.shared.note(.system, "sleepAssertionReleaseFailed")
            }
            sleepAssertionID = nil
        }
    }

    private func setupWorkspaceNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func sessionDidResignActive() {
        isUserSessionActive = false
    }

    @objc private func sessionDidBecomeActive() {
        isUserSessionActive = true
    }
}
