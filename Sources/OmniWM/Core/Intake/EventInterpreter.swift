// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
final class EventInterpreter: EventIntakeSink {
    weak var controller: WMController?
    private let callbackGenerationProvider: @MainActor (pid_t) -> UInt64?

    init(
        controller: WMController,
        callbackGenerationProvider: @escaping @MainActor (pid_t) -> UInt64? = {
            AppAXContext.contexts[$0]?.callbackGeneration
        }
    ) {
        self.controller = controller
        self.callbackGenerationProvider = callbackGenerationProvider
    }

    func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
        guard let controller else { return }

        switch stamped.event {
        case let .activationFactsResolved(facts):
            controller.axEventHandler.handleActivationFactsResolved(facts)

        case let .focusedAdmissionRetryFactRequestSuperseded(execution):
            controller.axEventHandler.finishFocusedAdmissionRetryExecution(execution)

        case .activeSpaceChanged:
            controller.serviceLifecycleManager.handleActiveSpaceDidChange()

        case let .appActivated(pid):
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .workspaceDidActivateApplication
            )

        case let .appDeactivated(pid):
            controller.axEventHandler.handleAppDeactivated(pid: pid)

        case let .appHidden(pid):
            AppVisibilityTrace.record(
                .intake,
                pid: pid,
                visibility: .hidden,
                outcome: .dispatched,
                intakeSequence: stamped.seq,
                source: .service
            )
            controller.axEventHandler.handleAppHidden(pid: pid, source: .service)

        case let .appLaunched(pid):
            controller.serviceLifecycleManager.handleAppLaunched(pid: pid)

        case let .appTerminated(pid):
            controller.serviceLifecycleManager.handleAppTerminated(pid: pid)

        case let .appUnhidden(pid):
            AppVisibilityTrace.record(
                .intake,
                pid: pid,
                visibility: .visible,
                outcome: .dispatched,
                intakeSequence: stamped.seq,
                source: .service
            )
            controller.axEventHandler.handleAppUnhidden(pid: pid, source: .service)

        case let .axFocusedWindowChanged(pid, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged,
                callbackGeneration: callbackGeneration
            )

        case let .axWindowDestroyed(pid, axRef, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleRemoved(
                pid: pid,
                winId: axRef.windowId,
                axRef: axRef,
                callbackGeneration: callbackGeneration
            )

        case let .axWindowMiniaturized(pid, windowId, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleWindowMiniaturized(pid: pid, windowId: windowId)

        case let .cgs(event):
            controller.axEventHandler.handleCGSEvent(event)

        case let .display(event):
            controller.serviceLifecycleManager.handleDisplayEvent(event)

        case let .hotkeyInvocation(invocation):
            _ = controller.commandHandler.handleHotkeyInvocation(invocation)

        case let .intentExpired(intentId):
            controller.axEventHandler.handleIntentExpired(intentId)

        case let .ipcCommand(intake):
            intake.completion(intake.perform(controller))

        case let .mouseDragged(button, location):
            controller.mouseEventHandler.dispatchQueuedMouseDragged(at: location, button: button)

        case let .mouseMoved(location, modifiersRawValue, windowIdUnderPointer):
            controller.mouseEventHandler.dispatchMouseMoved(
                at: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )

        case let .mouseScroll(payload):
            controller.mouseEventHandler.dispatchScrollWheel(
                at: payload.location,
                deltaX: payload.deltaX,
                deltaY: payload.deltaY,
                momentumPhase: payload.momentumPhase,
                phase: payload.phase,
                modifiers: payload.modifiers
            )

        case let .nativeFullscreenTransitionExpired(originalToken, generation):
            _ = controller.workspaceManager.expireNativeFullscreenTransition(
                originalToken: originalToken,
                generation: generation
            )

        case .systemSleep:
            _ = controller.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            controller.mouseEventHandler.suspendMultitouchForSleep()

        case .systemWake:
            controller.serviceLifecycleManager.handleSystemWake()

        case let .windowConstraintsResolved(fact):
            controller.layoutRefreshController.applyResolvedConstraints(fact)
        }
    }

    private func acceptsCallbackGeneration(_ callbackGeneration: UInt64?, pid: pid_t) -> Bool {
        guard let callbackGeneration else { return true }
        return callbackGenerationProvider(pid) == callbackGeneration
    }
}
