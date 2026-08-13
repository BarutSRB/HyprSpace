// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct FocusedWindowFact: Sendable {
    let axRef: AXWindowRef
    let isFullscreen: Bool
    let isSystemModalSurface: Bool
}

struct SameAppFocusCausality: Equatable, Sendable {
    let focusedToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
}

struct ActivationFacts: Sendable {
    let pid: pid_t
    let source: ActivationEventSource
    let origin: ActivationCallOrigin
    let observationGeneration: UInt64
    let requestedAtSeq: UInt64
    let focusedWindow: FocusedWindowFact?
    let sameAppFocusCausality: SameAppFocusCausality?
    let callbackGeneration: UInt64?
    let appVisibilityGeneration: UInt64
    let focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution?

    init(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64,
        requestedAtSeq: UInt64,
        focusedWindow: FocusedWindowFact?,
        sameAppFocusCausality: SameAppFocusCausality? = nil,
        callbackGeneration: UInt64? = nil,
        appVisibilityGeneration: UInt64 = 0,
        focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution? = nil
    ) {
        self.pid = pid
        self.source = source
        self.origin = origin
        self.observationGeneration = observationGeneration
        self.requestedAtSeq = requestedAtSeq
        self.focusedWindow = focusedWindow
        self.sameAppFocusCausality = sameAppFocusCausality
        self.callbackGeneration = callbackGeneration
        self.appVisibilityGeneration = appVisibilityGeneration
        self.focusedAdmissionRetryExecution = focusedAdmissionRetryExecution
    }
}

struct WindowConstraintsFact: Sendable {
    let token: WindowToken
    let constraints: WindowSizeConstraints
}

@MainActor
final class FactResolver {
    private struct ActivationFactRequest {
        let pid: pid_t
        let source: ActivationEventSource
        let origin: ActivationCallOrigin
        let observationGeneration: UInt64
        let requestedAtSeq: UInt64
        let sameAppFocusCausality: SameAppFocusCausality?
        let callbackGeneration: UInt64?
        let appVisibilityGeneration: UInt64
        let resolverGeneration: UInt64
        let focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution?
    }

    var factProvider: ((pid_t) -> FocusedWindowFact?)?
    var deferredFactProvider: ((pid_t) async -> FocusedWindowFact?)?

    private var resolverThread: Thread?
    private var inFlightActivationPids: Set<pid_t> = []
    private var pendingActivationRequestsByPid: [pid_t: ActivationFactRequest] = [:]
    private var inFlightConstraintTokens: Set<WindowToken> = []
    private var resolverGeneration: UInt64 = 0

    @discardableResult
    func resolveActivationFacts(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64,
        sameAppFocusCausality: SameAppFocusCausality? = nil,
        callbackGeneration: UInt64? = nil,
        appVisibilityGeneration: UInt64 = 0,
        focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution? = nil
    ) -> Bool {
        let request = ActivationFactRequest(
            pid: pid,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration,
            requestedAtSeq: EventIntake.currentSeq(),
            sameAppFocusCausality: sameAppFocusCausality,
            callbackGeneration: callbackGeneration,
            appVisibilityGeneration: appVisibilityGeneration,
            resolverGeneration: resolverGeneration,
            focusedAdmissionRetryExecution: focusedAdmissionRetryExecution
        )
        return resolveActivationFacts(request)
    }

    @discardableResult
    private func resolveActivationFacts(_ request: ActivationFactRequest) -> Bool {
        if let factProvider {
            return EventIntake.post(
                .activationFactsResolved(
                    ActivationFacts(
                        pid: request.pid,
                        source: request.source,
                        origin: request.origin,
                        observationGeneration: request.observationGeneration,
                        requestedAtSeq: request.requestedAtSeq,
                        focusedWindow: factProvider(request.pid),
                        sameAppFocusCausality: request.sameAppFocusCausality,
                        callbackGeneration: request.callbackGeneration,
                        appVisibilityGeneration: request.appVisibilityGeneration,
                        focusedAdmissionRetryExecution: request.focusedAdmissionRetryExecution
                    )
                )
            )
        }
        if inFlightActivationPids.contains(request.pid) {
            if let superseded = pendingActivationRequestsByPid[request.pid]?.focusedAdmissionRetryExecution,
               superseded != request.focusedAdmissionRetryExecution
            {
                EventIntake.post(.focusedAdmissionRetryFactRequestSuperseded(superseded))
            }
            pendingActivationRequestsByPid[request.pid] = request
            return true
        }
        inFlightActivationPids.insert(request.pid)
        if let deferredFactProvider {
            Task { @MainActor in
                let focusedWindow = await deferredFactProvider(request.pid)
                completeActivationFactRequest(request, focusedWindow: focusedWindow)
            }
            return true
        }
        nonisolated(unsafe) let thread = AppAXContext.contexts[request.pid]?.axThread ?? sharedResolverThread()
        Task { @MainActor in
            let focusedWindow = (try? await thread.runInLoop { _ in
                Self.readFocusedWindowFact(pid: request.pid)
            }) ?? nil
            completeActivationFactRequest(request, focusedWindow: focusedWindow)
        }
        return true
    }

    private func completeActivationFactRequest(
        _ request: ActivationFactRequest,
        focusedWindow: FocusedWindowFact?
    ) {
        guard request.resolverGeneration == resolverGeneration else { return }
        inFlightActivationPids.remove(request.pid)
        EventIntake.post(
            .activationFactsResolved(
                ActivationFacts(
                    pid: request.pid,
                    source: request.source,
                    origin: request.origin,
                    observationGeneration: request.observationGeneration,
                    requestedAtSeq: request.requestedAtSeq,
                    focusedWindow: focusedWindow,
                    sameAppFocusCausality: request.sameAppFocusCausality,
                    callbackGeneration: request.callbackGeneration,
                    appVisibilityGeneration: request.appVisibilityGeneration,
                    focusedAdmissionRetryExecution: request.focusedAdmissionRetryExecution
                )
            )
        )
        if let pendingRequest = pendingActivationRequestsByPid.removeValue(forKey: request.pid) {
            _ = resolveActivationFacts(pendingRequest)
        }
    }

    func resolveWindowConstraints(token: WindowToken, axRef: AXWindowRef) {
        guard inFlightConstraintTokens.insert(token).inserted else { return }
        let generation = resolverGeneration
        nonisolated(unsafe) let thread = AppAXContext.contexts[token.pid]?.axThread ?? sharedResolverThread()
        Task { @MainActor in
            let constraints = try? await thread.runInLoop { _ in
                AXWindowService.sizeConstraints(axRef)
            }
            guard generation == resolverGeneration else { return }
            inFlightConstraintTokens.remove(token)
            guard let constraints else { return }
            EventIntake.post(
                .windowConstraintsResolved(WindowConstraintsFact(token: token, constraints: constraints))
            )
        }
    }

    func stop() {
        resolverGeneration &+= 1
        inFlightActivationPids.removeAll()
        pendingActivationRequestsByPid.removeAll()
        inFlightConstraintTokens.removeAll()
        guard let thread = resolverThread else { return }
        resolverThread = nil
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func sharedResolverThread() -> Thread {
        if let resolverThread {
            return resolverThread
        }
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "OmniWM-FactResolver"
        thread.start()
        resolverThread = thread
        return thread
    }

    private nonisolated static func readFocusedWindowFact(pid: pid_t) -> FocusedWindowFact? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard result == .success, let focusedWindow else { return nil }
        guard CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return nil }
        let axElement = unsafeDowncast(focusedWindow, to: AXUIElement.self)
        guard let axRef = try? AXWindowRef(element: axElement) else { return nil }
        if let elementPid = AXWindowService.processIdentifier(axRef), elementPid != pid {
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "focusedAX.pidMismatch.expected=\(pid)",
                pid: elementPid,
                windowId: UInt32(exactly: axRef.windowId)
            )
        }
        let attributes = AXWindowService.roleAndSubrole(axRef)
        return FocusedWindowFact(
            axRef: axRef,
            isFullscreen: AXWindowService.isFullscreen(axRef, subrole: attributes.subrole),
            isSystemModalSurface: AXWindowService.isSystemModalSurface(
                role: attributes.role,
                subrole: attributes.subrole
            )
        )
    }
}
