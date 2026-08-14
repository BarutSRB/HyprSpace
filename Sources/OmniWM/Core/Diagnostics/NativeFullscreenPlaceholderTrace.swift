// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import QuartzCore

enum NativeFullscreenPlaceholderTrace {
    enum Operation: String, Sendable {
        case recordUpsert = "record_upsert"
        case recordRemoved = "record_removed"
        case deadlineScheduled = "deadline_scheduled"
        case deadlineCancelled = "deadline_cancelled"
        case deadlineFired = "deadline_fired"
        case projectionAccepted = "projection_accepted"
        case projectionDiscarded = "projection_discarded"
        case surfaceApplied = "surface_applied"
        case panelCreated = "panel_created"
        case panelDestroyed = "panel_destroyed"
        case panelMoved = "panel_moved"
        case panelResized = "panel_resized"
        case panelModeChanged = "panel_mode_changed"
        case panelShown = "panel_shown"
        case panelHidden = "panel_hidden"
        case panelOrdered = "panel_ordered"
        case captureAttempt = "capture_attempt"
        case captureExcluded = "capture_excluded"
        case captureRetryScheduled = "capture_retry_scheduled"
        case captureRetryCancelled = "capture_retry_cancelled"
        case captureRetryExhausted = "capture_retry_exhausted"
        case activationRequested = "activation_requested"
        case activationResolved = "activation_resolved"
        case activationRejected = "activation_rejected"
    }

    enum Transition: String, Sendable {
        case enterRequested = "enter_requested"
        case suspended
        case exitRequested = "exit_requested"

        init(_ transition: WorkspaceNativeFullscreenTransition) {
            switch transition {
            case .enterRequested:
                self = .enterRequested
            case .suspended:
                self = .suspended
            case .exitRequested:
                self = .exitRequested
            }
        }
    }

    enum Mode: String, Sendable {
        case regular
        case compact

        init(_ mode: NativeFullscreenCardMode) {
            switch mode {
            case .regular:
                self = .regular
            case .compact:
                self = .compact
            }
        }
    }

    enum Reason: String, Sendable {
        case accepted
        case controllerUnavailable = "controller_unavailable"
        case servicesStopped = "services_stopped"
        case workspaceMissing = "workspace_missing"
        case displayMismatch = "display_mismatch"
        case recordMissing = "record_missing"
        case recordWorkspaceMismatch = "record_workspace_mismatch"
        case transitionPending = "transition_pending"
        case layoutNotNativeFullscreen = "layout_not_native_fullscreen"
        case descriptorHidden = "descriptor_hidden"
        case descriptorStale = "descriptor_stale"
        case projectionMissingRetained = "projection_missing_retained"
        case projectionMissingHidden = "projection_missing_hidden"
        case slotMissing = "slot_missing"
        case slotTokenMismatchRetained = "slot_token_mismatch_retained"
        case slotTokenMismatchHidden = "slot_token_mismatch_hidden"
        case slotHidden = "slot_hidden"
        case geometryRejected = "geometry_rejected"
        case orderingFailed = "ordering_failed"
        case recordLookupFailed = "record_lookup_failed"
        case entryMissing = "entry_missing"
        case appHidden = "app_hidden"
        case lockScreen = "lock_screen"
        case placeholderUnavailable = "placeholder_unavailable"
        case captureFailed = "capture_failed"
    }

    struct Record: Sendable {
        let mediaTime: CFTimeInterval
        let operation: Operation
        let originalToken: WindowToken?
        let currentToken: WindowToken?
        let workspaceId: WorkspaceDescriptor.ID?
        let displayId: CGDirectDisplayID?
        let transition: Transition?
        let generation: Int?
        let slotFrame: CGRect?
        let cardFrame: CGRect?
        let workingFrame: CGRect?
        let scale: CGFloat?
        let visible: Bool?
        let selected: Bool?
        let mode: Mode?
        let windowNumber: Int?
        let reason: Reason?
        let retryIndex: Int?
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Native Fullscreen Placeholder Trace",
        capacity: 4096
    ) { record in
        var fields = [
            String(format: "t=%.3f", record.mediaTime),
            "op=\(record.operation.rawValue)"
        ]
        if let token = record.originalToken {
            fields.append("original=\(token.pid):\(token.windowId)")
        }
        if let token = record.currentToken {
            fields.append("current=\(token.pid):\(token.windowId)")
        }
        if let workspaceId = record.workspaceId {
            fields.append("workspace=\(workspaceId.uuidString)")
        }
        if let displayId = record.displayId {
            fields.append("display=\(displayId)")
        }
        if let transition = record.transition {
            fields.append("transition=\(transition.rawValue)")
        }
        if let generation = record.generation {
            fields.append("generation=\(generation)")
        }
        if let slotFrame = record.slotFrame {
            fields.append("slot=\(TraceFormat.rect(slotFrame))")
        }
        if let cardFrame = record.cardFrame {
            fields.append("card=\(TraceFormat.rect(cardFrame))")
        }
        if let workingFrame = record.workingFrame {
            fields.append("working=\(TraceFormat.rect(workingFrame))")
        }
        if let scale = record.scale {
            fields.append(String(format: "scale=%.2f", scale))
        }
        if let visible = record.visible {
            fields.append("visible=\(visible)")
        }
        if let selected = record.selected {
            fields.append("selected=\(selected)")
        }
        if let mode = record.mode {
            fields.append("mode=\(mode.rawValue)")
        }
        if let windowNumber = record.windowNumber {
            fields.append("window=\(windowNumber)")
        }
        if let reason = record.reason {
            fields.append("reason=\(reason.rawValue)")
        }
        if let retryIndex = record.retryIndex {
            fields.append("retry=\(retryIndex)")
        }
        return fields.joined(separator: " ")
    }

    static var isActive: Bool {
        shared.isActive
    }

    static func record(_ record: @autoclosure () -> Record) {
        guard shared.isActive else { return }
        shared.record(record())
    }

    static func makeRecord(
        _ operation: Operation,
        originalToken: WindowToken? = nil,
        currentToken: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        displayId: CGDirectDisplayID? = nil,
        transition: Transition? = nil,
        generation: Int? = nil,
        slotFrame: CGRect? = nil,
        cardFrame: CGRect? = nil,
        workingFrame: CGRect? = nil,
        scale: CGFloat? = nil,
        visible: Bool? = nil,
        selected: Bool? = nil,
        mode: Mode? = nil,
        windowNumber: Int? = nil,
        reason: Reason? = nil,
        retryIndex: Int? = nil
    ) -> Record {
        Record(
            mediaTime: CACurrentMediaTime(),
            operation: operation,
            originalToken: originalToken,
            currentToken: currentToken,
            workspaceId: workspaceId,
            displayId: displayId,
            transition: transition,
            generation: generation,
            slotFrame: slotFrame,
            cardFrame: cardFrame,
            workingFrame: workingFrame,
            scale: scale,
            visible: visible,
            selected: selected,
            mode: mode,
            windowNumber: windowNumber,
            reason: reason,
            retryIndex: retryIndex
        )
    }
}
