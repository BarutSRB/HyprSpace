// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct BorderSurfaceApplyResult: Equatable {
    let didApply: Bool
    let needsCornerRadiiRetry: Bool
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

    private struct CornerResolution {
        let radii: WindowCornerRadii
        let needsRetry: Bool
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
    private let borderWindowOperations: BorderWindow.Operations
    private let cornerSampleProvider: @MainActor (Int) -> WindowCornerSample?
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var registeredSurfaceWindowNumber: Int?
    private let defaultCornerRadii = WindowCornerRadii(uniform: 9.0)
    private let surfaceID = "border-surface"
    private var screenParametersObserver: NSObjectProtocol?

    init(
        borderWindowOperations: BorderWindow.Operations = .live,
        cornerSampleProvider: @escaping @MainActor (Int) -> WindowCornerSample? = {
            SkyLight.shared.cornerSample(forWindowId: $0)
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
                self?.borderWindow?.invalidateScaleCache()
                self?.clearCornerState()
            }
        }
    }

    @discardableResult
    func apply(
        _ desired: DesiredBorderSurface?,
        forceOrdering: Bool,
        refreshCornerRadii: Bool = true
    ) -> BorderSurfaceApplyResult {
        guard let desired else {
            hide()
            return BorderSurfaceApplyResult(didApply: true, needsCornerRadiiRetry: false)
        }

        installScreenParametersObserverIfNeeded()
        BorderOpMetricsRecorder.shared.noteApply()
        updateCornerTarget(desired.token)

        if borderWindow == nil {
            borderWindow = BorderWindow(config: desired.config, operations: borderWindowOperations)
        } else {
            borderWindow?.updateConfig(desired.config)
        }

        let cornerResolution = resolvedCornerRadii(
            for: desired.token,
            desiredSize: desired.frame.size,
            refresh: refreshCornerRadii
        )
        if let applied,
           applied.token == desired.token,
           applied.config == desired.config,
           appliedCornerRadii == cornerResolution.radii,
           desired.frame.approximatelyEqual(to: applied.frame, tolerance: FrameTolerance.frameWrite)
        {
            BorderOpMetricsRecorder.shared.noteShortCircuit()
            if forceOrdering {
                borderWindow?.reorder(relativeTo: UInt32(desired.windowId))
            }
            return BorderSurfaceApplyResult(
                didApply: true,
                needsCornerRadiiRetry: cornerResolution.needsRetry
            )
        }

        guard borderWindow?.update(
            frame: desired.frame,
            targetWid: UInt32(desired.windowId),
            cornerRadii: cornerResolution.radii,
            forceOrdering: forceOrdering
        ) == true else {
            applied = nil
            appliedCornerRadii = nil
            clearCornerState()
            unregisterSurface()
            return BorderSurfaceApplyResult(didApply: false, needsCornerRadiiRetry: false)
        }
        applied = desired
        appliedCornerRadii = cornerResolution.radii
        syncSurfaceRegistration()
        return BorderSurfaceApplyResult(
            didApply: true,
            needsCornerRadiiRetry: cornerResolution.needsRetry
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
        clearCornerState()
    }

    private func resolvedCornerRadii(
        for token: WindowToken,
        desiredSize: CGSize,
        refresh: Bool
    ) -> CornerResolution {
        if let cachedCornerSample, cachedCornerSample.token == token {
            if !refresh || sizesMatch(cachedCornerSample.sample.observedSize, desiredSize) {
                BorderOpMetricsRecorder.shared.noteCornerRadiusHit()
                if refresh {
                    cornerRetryState = nil
                }
                return CornerResolution(radii: cachedCornerSample.sample.radii, needsRetry: false)
            }
        }

        guard refresh else {
            return CornerResolution(radii: fallbackCornerRadii(for: token), needsRetry: false)
        }

        if retryIsExhausted(for: token, desiredSize: desiredSize) {
            return CornerResolution(radii: fallbackCornerRadii(for: token), needsRetry: false)
        }

        BorderOpMetricsRecorder.shared.noteCornerRadiusQuery()
        if let providedSample = cornerSampleProvider(token.windowId), validSize(providedSample.observedSize) {
            let sample = WindowCornerSample(
                radii: providedSample.radii.nonnegative,
                observedSize: providedSample.observedSize,
                source: providedSample.source
            )
            if sizesMatch(sample.observedSize, desiredSize) {
                cachedCornerSample = CachedCornerSample(token: token, sample: sample)
                cornerRetryState = nil
                return CornerResolution(radii: sample.radii, needsRetry: false)
            }
            return failedCornerResolution(for: token, desiredSize: desiredSize)
        }

        return failedCornerResolution(for: token, desiredSize: desiredSize)
    }

    private func failedCornerResolution(for token: WindowToken, desiredSize: CGSize) -> CornerResolution {
        let fallback = fallbackCornerRadii(for: token)
        if cachedCornerSample?.token != token {
            FallbackFiringRecorder.shared.note(.skylight, "cornerRadiusDefault")
        }
        return CornerResolution(
            radii: fallback,
            needsRetry: needsAutomaticRetry(for: token, desiredSize: desiredSize)
        )
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
                self?.borderWindow?.frameOnScreen ?? self?.applied?.frame
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
