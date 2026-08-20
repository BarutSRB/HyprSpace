// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class LockScreenObserver {
    static let lockScreenAppBundleId = "com.apple.loginwindow"

    enum LockState {
        case unlocked
        case locked
        case transitioning
    }

    private enum ObserverEvent: Sendable {
        case appActivated(String?)
        case locked
        case unlocked
    }

    private(set) var state: LockState = .unlocked

    var onLockDetected: (() -> Void)?
    var onUnlockDetected: (() -> Void)?
    var frontmostBundleIdProvider: @MainActor () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var activationObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?
    private var frontmostIsLockScreen = false
    private var observerGeneration = 0
    private var transitionGeneration = 0

    init() {}

    func start() {
        guard activationObserver == nil else { return }
        observerGeneration &+= 1
        setupObservers(generation: observerGeneration)
        guard let frontmostBundleId = frontmostBundleIdProvider() else { return }
        frontmostIsLockScreen = frontmostBundleId == Self.lockScreenAppBundleId
        if frontmostIsLockScreen {
            handleLockEvent()
        } else {
            handleUnlockEvent()
        }
    }

    func stop() {
        cleanup()
    }

    private func setupObservers(generation: Int) {
        let nc = NSWorkspace.shared.notificationCenter

        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundleId = app.bundleIdentifier
            self?.enqueueObserverEvent(.appActivated(bundleId), generation: generation)
        }

        let dnc = DistributedNotificationCenter.default()

        screenLockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.locked, generation: generation)
        }

        screenUnlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.unlocked, generation: generation)
        }
    }

    private nonisolated func enqueueObserverEvent(_ event: ObserverEvent, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, generation == observerGeneration else { return }
            switch event {
            case let .appActivated(bundleId):
                handleAppActivation(bundleId: bundleId)
            case .locked:
                handleLockEvent()
            case .unlocked:
                handleUnlockEvent()
            }
        }
    }

    func enqueueLockEventForTests() {
        enqueueObserverEvent(.locked, generation: observerGeneration)
    }

    func handleAppActivation(bundleId: String?) {
        guard let bundleId else { return }
        frontmostIsLockScreen = bundleId == Self.lockScreenAppBundleId
        if frontmostIsLockScreen {
            handleLockEvent()
        } else if state == .locked || state == .transitioning {
            handleUnlockEvent()
        }
    }

    private func handleLockEvent() {
        frontmostIsLockScreen = true
        guard state != .locked else { return }
        transitionGeneration &+= 1
        state = .locked
        onLockDetected?()
    }

    func handleUnlockEvent() {
        frontmostIsLockScreen = false
        guard state == .locked else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        state = .transitioning
        onUnlockDetected?()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.state == .transitioning, generation == self.transitionGeneration {
                self.state = .unlocked
            }
        }
    }

    func isFrontmostAppLockScreen() -> Bool {
        frontmostIsLockScreen
    }

    func cleanup() {
        observerGeneration &+= 1
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        let dnc = DistributedNotificationCenter.default()
        if let observer = screenLockObserver {
            dnc.removeObserver(observer)
            screenLockObserver = nil
        }
        if let observer = screenUnlockObserver {
            dnc.removeObserver(observer)
            screenUnlockObserver = nil
        }
    }
}
