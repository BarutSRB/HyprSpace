// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation

private func secureInputMonitorEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let disabledByUserInput = type == .tapDisabledByUserInput
    let disabledByTimeout = type == .tapDisabledByTimeout
    MainActor.assumeIsolated {
        SecureInputMonitor.handleEventTap(
            disabledByUserInput: disabledByUserInput,
            disabledByTimeout: disabledByTimeout
        )
    }
    return Unmanaged.passUnretained(event)
}

@MainActor @Observable
final class SecureInputMonitor {
    struct PerformanceSnapshot: Equatable, Sendable {
        let recoveryTimerFires: UInt64
    }

    private(set) var isSecureInputActive: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recoveryTimer: Timer?
    private var onStateChange: ((Bool) -> Void)?
    private var performanceRecoveryTimerFires: UInt64?
    var secureInputStateProviderForTests: (() -> Bool)?
    var eventTapInstallerForTests: (() -> (tap: CFMachPort, runLoopSource: CFRunLoopSource))?

    private static var sharedMonitor: SecureInputMonitor?

    func start(onStateChange: @escaping (Bool) -> Void) {
        tearDownEventTap()
        stopRecoveryTimer()
        self.onStateChange = onStateChange
        SecureInputMonitor.sharedMonitor = self
        setupEventTap()
        checkSecureInput()
    }

    func stop() {
        tearDownEventTap()
        stopRecoveryTimer()
        SecureInputMonitor.sharedMonitor = nil
        onStateChange = nil
    }

    func beginPerformanceCapture() {
        performanceRecoveryTimerFires = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceRecoveryTimerFires.map { PerformanceSnapshot(recoveryTimerFires: $0) }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceRecoveryTimerFires = nil
        return snapshot
    }

    private func setupEventTap() {
        if let installation = eventTapInstallerForTests?() {
            eventTap = installation.tap
            runLoopSource = installation.runLoopSource
            return
        }
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: secureInputMonitorEventTapCallback,
            userInfo: nil
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            } else {
                tearDownEventTap()
                FallbackFiringRecorder.shared.note(.input, "secureInputTapRunLoopSourceFailed")
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            FallbackFiringRecorder.shared.note(.input, "secureInputTapCreateFailed")
        }
    }

    fileprivate static func handleEventTap(
        disabledByUserInput: Bool,
        disabledByTimeout: Bool
    ) {
        if disabledByUserInput {
            Task { @MainActor in
                sharedMonitor?.handleSecureInputDetected()
            }
            if let tap = sharedMonitor?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if disabledByTimeout {
            if let tap = sharedMonitor?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if sharedMonitor?.isSecureInputActive ?? false {
            Task { @MainActor in
                sharedMonitor?.checkSecureInputEnded()
            }
        }
    }

    private func handleSecureInputDetected() {
        guard !isSecureInputActive else { return }
        if secureInputState() {
            isSecureInputActive = true
            onStateChange?(true)
            startRecoveryTimer()
        }
    }

    private func checkSecureInputEnded() {
        if !secureInputState() {
            isSecureInputActive = false
            onStateChange?(false)
            stopRecoveryTimer()
        }
    }

    private func startRecoveryTimer() {
        stopRecoveryTimer()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performanceRecoveryTimerFires? &+= 1
                self?.checkSecureInputEnded()
            }
        }
        if let timer = recoveryTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func checkSecureInput() {
        let newState = secureInputState()
        if newState != isSecureInputActive {
            isSecureInputActive = newState
            onStateChange?(newState)
            if newState {
                startRecoveryTimer()
            }
        }
    }

    private func secureInputState() -> Bool {
        secureInputStateProviderForTests?() ?? IsSecureEventInputEnabled()
    }

    private func tearDownEventTap() {
        EventTapTeardown.tearDown(tap: &eventTap, runLoopSource: &runLoopSource)
    }
}
