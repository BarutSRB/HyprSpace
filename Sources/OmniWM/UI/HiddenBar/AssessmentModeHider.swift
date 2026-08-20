// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMMenuBarAssertion

@MainActor
final class AssessmentModeHider {
    typealias ActivationHandler = @MainActor ([String], [NSNumber], @escaping () -> Void)
        -> UnsafeMutableRawPointer?

    private static let systemItemNumbers: [NSNumber] =
        HiddenBarAllowlistResolver.allowedSystemItemIdentifiers.map { NSNumber(value: $0) }

    static var isAvailable: Bool {
        omniwm_assessment_available()
    }

    private(set) var available: Bool

    var onConcealingChanged: ((Bool) -> Void)?
    var retrySleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    private static let retryBackoff: Duration = .seconds(3)
    private static let retryLimit = 3

    private let availabilityProvider: @MainActor () -> Bool
    private let activationHandler: ActivationHandler
    private let invalidationHandler: @MainActor (UnsafeMutableRawPointer) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var currentConfig: HiddenBarAppliedConfig?
    private var previousConfig: HiddenBarAppliedConfig?
    private var lastFailed: (desired: HiddenBarDesiredConfig, at: ContinuousClock.Instant)?
    private var desiredConfig: HiddenBarDesiredConfig?
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = 0
    private(set) var activationGeneration = 0
    private var activeHandleGeneration: Int?
    private var learnedNames: [String: String] = [:]
    private let clock = ContinuousClock()

    init(
        availabilityProvider: @escaping @MainActor () -> Bool = { AssessmentModeHider.isAvailable },
        activationHandler: @escaping ActivationHandler = { allowed, systemItems, onFailure in
            omniwm_assessment_activate(allowed, systemItems, onFailure)
        },
        invalidationHandler: @escaping @MainActor (UnsafeMutableRawPointer) -> Void = {
            omniwm_assessment_invalidate($0)
        }
    ) {
        self.availabilityProvider = availabilityProvider
        self.activationHandler = activationHandler
        self.invalidationHandler = invalidationHandler
        available = availabilityProvider()
    }

    var isConcealing: Bool {
        handle != nil
    }

    func conceals(_ bundleID: String) -> Bool {
        Self.appliedConfig(currentConfig, conceals: bundleID)
    }

    nonisolated static func appliedConfig(_ config: HiddenBarAppliedConfig?, conceals bundleID: String) -> Bool {
        config?.concealed.contains(bundleID) == true
    }

    private var protectedBundleIDs: Set<String> {
        [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
    }

    @discardableResult
    func refreshAvailability() -> Bool {
        available = availabilityProvider()
        if !available {
            drop()
        }
        return available
    }

    @discardableResult
    func apply(
        hiddenBundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) -> Bool {
        guard available else {
            cancelRetry()
            return false
        }

        let resolved = HiddenBarAllowlistResolver.resolve(
            hiddenBundleIDs: hiddenBundleIDs,
            runningBundleIDs: runningBundleIDs,
            protectedBundleIDs: protectedBundleIDs
        )

        guard !resolved.concealed.isEmpty else {
            drop()
            return false
        }

        let now = clock.now
        let desired = HiddenBarDesiredConfig(allowed: resolved.allowed, concealed: resolved.concealed)
        if bypassHysteresis || desiredConfig != desired {
            desiredConfig = desired
            cancelRetry()
        } else if retryTask != nil || lastFailed?.desired == desired {
            return handle != nil
        }

        if !bypassHysteresis {
            if let delay = retryDelay(desired: desired, now: now) {
                scheduleRetry(desired: desired, delay: delay, remainingRetries: Self.retryLimit)
                return handle != nil
            }
            guard HiddenBarAntiFlap.shouldReactivate(
                desired: desired,
                current: currentConfig,
                previousConfig: previousConfig,
                now: now
            ) else {
                return handle != nil
            }
        }

        return activate(desired: desired, now: now, remainingRetries: Self.retryLimit)
    }

    private func retryDelay(
        desired: HiddenBarDesiredConfig,
        now: ContinuousClock.Instant
    ) -> Duration? {
        if let lastFailed, desired == lastFailed.desired {
            let elapsed = lastFailed.at.duration(to: now)
            if elapsed < Self.retryBackoff {
                return Self.retryBackoff - elapsed
            }
        }
        return HiddenBarAntiFlap.reactivationDelay(
            desired: desired,
            current: currentConfig,
            previousConfig: previousConfig,
            now: now
        )
    }

    private func activate(
        desired: HiddenBarDesiredConfig,
        now: ContinuousClock.Instant,
        remainingRetries: Int
    ) -> Bool {
        activationGeneration += 1
        let generation = activationGeneration

        let newHandle = activationHandler(
            desired.allowed.sorted(),
            Self.systemItemNumbers,
            { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleActivationFailure(
                        generation: generation,
                        attempted: desired,
                        remainingRetries: remainingRetries
                    )
                }
            }
        )

        guard let newHandle else {
            recordActivationFailure(
                attempted: desired,
                remainingRetries: remainingRetries,
                now: now
            )
            return handle != nil
        }

        let oldHandle = handle
        if let currentConfig {
            previousConfig = currentConfig
        }
        activeHandleGeneration = generation
        handle = newHandle
        if let oldHandle {
            invalidationHandler(oldHandle)
        }
        currentConfig = HiddenBarAppliedConfig(allowed: desired.allowed, concealed: desired.concealed, at: now)
        lastFailed = nil
        onConcealingChanged?(true)
        return true
    }

    func drop() {
        cancelRetry()
        activationGeneration += 1
        activeHandleGeneration = nil
        let wasConcealing = handle != nil
        if let handle {
            invalidationHandler(handle)
        }
        handle = nil
        currentConfig = nil
        previousConfig = nil
        lastFailed = nil
        desiredConfig = nil
        if wasConcealing {
            onConcealingChanged?(false)
        }
    }

    func learn(_ apps: [DetectedMenuBarApp]) {
        for app in apps {
            learnedNames[app.bundleID] = app.name
        }
    }

    func displayName(for bundleID: String) -> String? {
        learnedNames[bundleID]
    }

    private func handleActivationFailure(
        generation: Int,
        attempted: HiddenBarDesiredConfig,
        remainingRetries: Int
    ) {
        guard generation == activeHandleGeneration else { return }
        activeHandleGeneration = nil
        let wasConcealing = handle != nil
        if let handle {
            invalidationHandler(handle)
        }
        handle = nil
        currentConfig = nil
        if desiredConfig == nil || desiredConfig == attempted {
            recordActivationFailure(
                attempted: attempted,
                remainingRetries: remainingRetries,
                now: clock.now
            )
        }
        if wasConcealing {
            onConcealingChanged?(false)
        }
    }

    private func recordActivationFailure(
        attempted: HiddenBarDesiredConfig,
        remainingRetries: Int,
        now: ContinuousClock.Instant
    ) {
        lastFailed = (attempted, now)
        guard remainingRetries > 0 else { return }
        scheduleRetry(
            desired: attempted,
            delay: Self.retryBackoff,
            remainingRetries: remainingRetries - 1
        )
    }

    private func scheduleRetry(
        desired: HiddenBarDesiredConfig,
        delay: Duration,
        remainingRetries: Int
    ) {
        retryTask?.cancel()
        retryGeneration += 1
        let generation = retryGeneration
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await retrySleeper(delay)
            guard !Task.isCancelled,
                  generation == retryGeneration,
                  available,
                  desiredConfig == desired
            else { return }
            retryTask = nil
            _ = activate(
                desired: desired,
                now: clock.now,
                remainingRetries: remainingRetries
            )
        }
    }

    private func cancelRetry() {
        retryGeneration += 1
        retryTask?.cancel()
        retryTask = nil
    }

    var hasPendingRetryForTests: Bool {
        retryTask != nil
    }

    isolated deinit {
        retryTask?.cancel()
        if let handle {
            invalidationHandler(handle)
        }
    }
}
