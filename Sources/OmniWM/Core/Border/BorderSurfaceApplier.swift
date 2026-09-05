// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct BorderSurfaceApplyResult: Equatable {
    let didApply: Bool
    let needsWindowLevelRetry: Bool
}

@MainActor
final class BorderSurfaceApplier {
    private enum CornerRetryPhase: Equatable {
        case scheduled
        case exhausted
    }

    private struct CornerRetryState {
        let token: WindowToken
        let desiredSize: CGSize
        let phase: CornerRetryPhase
    }

    private struct CachedCornerSample {
        let token: WindowToken
        let sample: WindowCornerSample
    }

    private var borderWindow: BorderWindow?
    private var applied: DesiredBorderSurface?
    private var appliedCornerRadii: WindowCornerRadii?
    private var cornerTargetToken: WindowToken?
    private var cachedCornerSample: CachedCornerSample?
    private var cornerRetryState: CornerRetryState?
    private var cornerDesiredSize: CGSize?
    private var cornerQueryGeneration: UInt64 = 0
    private var cornerQueryTask: Task<Void, Never>?
    private var wantsCornerQuery = false
    private let borderWindowOperations: BorderWindow.Operations
    private let cornerSampleProvider: @MainActor (WindowToken) async throws -> WindowCornerSample?
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var registeredSurfaceWindowNumber: Int?
    private let defaultCornerRadii = WindowCornerRadii(uniform: 9.0)
    private let surfaceID = "border-surface"
    private var screenParametersObserver: NSObjectProtocol?
    private var scaleInvalidated = false
    var onWindowLevelResolved: (@MainActor () -> Void)?
    var onDisplayScaleInvalidated: (@MainActor () -> Void)?
    var onCornerSampleResolved: (@MainActor () -> Void)?

    init(
        borderWindowOperations: BorderWindow.Operations = .live,
        cornerSampleProvider: @escaping @MainActor (WindowToken) async throws -> WindowCornerSample? = {
            try await SkyLight.shared.cornerSampleDeferred(for: $0)
        }
    ) {
        self.borderWindowOperations = borderWindowOperations
        self.cornerSampleProvider = cornerSampleProvider
        installScreenParametersObserverIfNeeded()
    }

    private func installScreenParametersObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateDisplayScale()
                self?.onDisplayScaleInvalidated?()
            }
        }
    }

    func invalidateDisplayScale() {
        borderWindow?.invalidateScaleCache()
        clearCornerState()
        scaleInvalidated = true
    }

    @discardableResult
    func apply(
        _ desired: DesiredBorderSurface?,
        forceOrdering: Bool,
        refreshCornerRadii: Bool = true
    ) -> BorderSurfaceApplyResult {
        guard let desired else {
            hide()
            return BorderSurfaceApplyResult(
                didApply: true,
                needsWindowLevelRetry: false
            )
        }

        installScreenParametersObserverIfNeeded()
        BorderOpMetricsRecorder.shared.noteApply()
        updateCornerTarget(desired.token)

        if borderWindow == nil {
            borderWindow = BorderWindow(config: desired.config, operations: borderWindowOperations)
            borderWindow?.onWindowLevelResolved = { [weak self] in
                self?.onWindowLevelResolved?()
            }
        } else {
            borderWindow?.updateConfig(desired.config)
        }

        let cornerRadii = resolvedCornerRadii(
            for: desired.token,
            desiredSize: desired.frame.size,
            refresh: refreshCornerRadii
        )
        if let applied,
           !scaleInvalidated,
           borderWindow?.needsWindowLevelRetry != true,
           borderWindow?.hasDeferredLevelUpdate != true,
           applied.token == desired.token,
           applied.config == desired.config,
           appliedCornerRadii == cornerRadii,
           desired.frame.approximatelyEqual(to: applied.frame, tolerance: FrameTolerance.frameWrite)
        {
            BorderOpMetricsRecorder.shared.noteShortCircuit()
            if forceOrdering {
                borderWindow?.reorder(relativeTo: desired.token)
            }
            return BorderSurfaceApplyResult(
                didApply: true,
                needsWindowLevelRetry: borderWindow?.needsWindowLevelRetry == true
            )
        }

        guard borderWindow?.update(
            frame: desired.frame,
            targetToken: desired.token,
            cornerRadii: cornerRadii,
            forceOrdering: forceOrdering
        ) == true else {
            applied = nil
            appliedCornerRadii = nil
            clearCornerState()
            unregisterSurface()
            return BorderSurfaceApplyResult(
                didApply: false,
                needsWindowLevelRetry: false
            )
        }
        scaleInvalidated = false
        applied = desired
        appliedCornerRadii = cornerRadii
        syncSurfaceRegistration()
        return BorderSurfaceApplyResult(
            didApply: true,
            needsWindowLevelRetry: borderWindow?.needsWindowLevelRetry == true
        )
    }

    func cleanup() {
        hide()
        borderWindow?.destroy()
        borderWindow = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    private func hide() {
        if applied != nil || registeredSurfaceWindowNumber != nil {
            borderWindow?.hide()
            unregisterSurface()
        }
        applied = nil
        appliedCornerRadii = nil
        scaleInvalidated = false
        clearCornerState()
    }

    private func resolvedCornerRadii(
        for token: WindowToken,
        desiredSize: CGSize,
        refresh: Bool
    ) -> WindowCornerRadii {
        if cornerDesiredSize.map({ sizesMatch($0, desiredSize) }) != true {
            cornerQueryGeneration &+= 1
            cornerQueryTask?.cancel()
            cornerDesiredSize = desiredSize
        }
        wantsCornerQuery = false
        if let cachedCornerSample, cachedCornerSample.token == token {
            if !refresh || sizesMatch(cachedCornerSample.sample.observedSize, desiredSize) {
                BorderOpMetricsRecorder.shared.noteCornerRadiusHit()
                if refresh {
                    cornerRetryState = nil
                }
                return cachedCornerSample.sample.radii
            }
        }
        guard refresh, !retryIsExhausted(for: token, desiredSize: desiredSize) else {
            return fallbackCornerRadii(for: token)
        }
        wantsCornerQuery = true
        startCornerQueryIfNeeded()
        return fallbackCornerRadii(for: token)
    }

    private func startCornerQueryIfNeeded() {
        guard wantsCornerQuery, cornerQueryTask == nil,
              let token = cornerTargetToken,
              let desiredSize = cornerDesiredSize
        else { return }
        wantsCornerQuery = false
        let generation = cornerQueryGeneration
        let provider = cornerSampleProvider
        BorderOpMetricsRecorder.shared.noteCornerRadiusQuery()
        cornerQueryTask = Task { [weak self] in
            let sample = try? await provider(token)
            guard let self else { return }
            cornerQueryTask = nil
            guard generation == cornerQueryGeneration, cornerTargetToken == token,
                  cornerDesiredSize.map({ sizesMatch($0, desiredSize) }) == true
            else {
                startCornerQueryIfNeeded()
                return
            }
            wantsCornerQuery = false
            if let sample, validSize(sample.observedSize), sizesMatch(sample.observedSize, desiredSize) {
                cachedCornerSample = CachedCornerSample(token: token, sample: WindowCornerSample(
                    radii: sample.radii.nonnegative,
                    observedSize: sample.observedSize,
                    source: sample.source
                ))
                cornerRetryState = nil
                onCornerSampleResolved?()
            } else if recordCornerFailure(for: token, desiredSize: desiredSize) {
                onCornerSampleResolved?()
            }
        }
    }

    private func recordCornerFailure(for token: WindowToken, desiredSize: CGSize) -> Bool {
        if cachedCornerSample?.token != token {
            FallbackFiringRecorder.shared.note(.skylight, "cornerRadiusDefault")
        }
        return needsAutomaticRetry(for: token, desiredSize: desiredSize)
    }

    private func updateCornerTarget(_ token: WindowToken) {
        guard cornerTargetToken != token else { return }
        clearCornerState()
        cornerTargetToken = token
    }

    private func fallbackCornerRadii(for token: WindowToken) -> WindowCornerRadii {
        guard let cachedCornerSample, cachedCornerSample.token == token else { return defaultCornerRadii }
        return cachedCornerSample.sample.radii
    }

    private func needsAutomaticRetry(for token: WindowToken, desiredSize: CGSize) -> Bool {
        if let cornerRetryState,
           cornerRetryState.token == token,
           sizesMatch(cornerRetryState.desiredSize, desiredSize)
        {
            switch cornerRetryState.phase {
            case .scheduled:
                self.cornerRetryState = CornerRetryState(
                    token: token,
                    desiredSize: desiredSize,
                    phase: .exhausted
                )
            case .exhausted:
                break
            }
            return false
        }
        cornerRetryState = CornerRetryState(token: token, desiredSize: desiredSize, phase: .scheduled)
        return true
    }

    private func retryIsExhausted(for token: WindowToken, desiredSize: CGSize) -> Bool {
        guard let cornerRetryState,
              cornerRetryState.token == token,
              sizesMatch(cornerRetryState.desiredSize, desiredSize)
        else {
            return false
        }
        return cornerRetryState.phase == .exhausted
    }

    private func clearCornerState() {
        cornerQueryGeneration &+= 1
        cornerQueryTask?.cancel()
        cornerDesiredSize = nil
        wantsCornerQuery = false
        cornerTargetToken = nil
        cachedCornerSample = nil
        cornerRetryState = nil
    }

    private func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= FrameTolerance.frameWrite
            && abs(lhs.height - rhs.height) <= FrameTolerance.frameWrite
    }

    private func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func syncSurfaceRegistration() {
        guard let borderWindow, let windowNumber = borderWindow.windowId.map(Int.init) else {
            unregisterSurface()
            return
        }
        guard registeredSurfaceWindowNumber != windowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: windowNumber,
            frameProvider: { [weak self] in
                self?.borderWindow?.frameOnScreen
            },
            visibilityProvider: { [weak self] in
                self?.applied != nil
            },
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = windowNumber
    }

    private func unregisterSurface() {
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
    }
}
