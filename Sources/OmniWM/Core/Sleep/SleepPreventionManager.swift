// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import IOKit.pwr_mgt

@MainActor
final class SleepPreventionManager {
    struct PerformanceSnapshot: Equatable, Sendable {
        let assertionAcquisitions: UInt64
    }

    static let shared = SleepPreventionManager()

    private var sleepAssertionID: IOPMAssertionID?
    private var wantsSleepPrevention = false
    private var isUserSessionActive = true
    private var performanceAssertionAcquisitions: UInt64?

    private init() {
        setupWorkspaceNotifications()
    }

    func preventSleep() {
        wantsSleepPrevention = true
        reconcileSleepAssertion()
    }

    func allowSleep() {
        wantsSleepPrevention = false
        reconcileSleepAssertion()
    }

    func beginPerformanceCapture() {
        performanceAssertionAcquisitions = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceAssertionAcquisitions.map {
            PerformanceSnapshot(assertionAcquisitions: $0)
        }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceAssertionAcquisitions = nil
        return snapshot
    }

    private func reconcileSleepAssertion() {
        guard wantsSleepPrevention, isUserSessionActive else {
            releaseSleepAssertion()
            return
        }
        guard sleepAssertionID == nil else { return }
        performanceAssertionAcquisitions? &+= 1

        var assertionID: IOPMAssertionID = 0
        let reason = "OmniWM prevents sleep" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            reason,
            nil,
            nil,
            nil,
            0,
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
        reconcileSleepAssertion()
    }

    @objc private func sessionDidBecomeActive() {
        isUserSessionActive = true
        reconcileSleepAssertion()
    }
}
