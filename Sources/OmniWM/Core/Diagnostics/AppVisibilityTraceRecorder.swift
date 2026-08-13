// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Synchronization

enum AppVisibilityTrace {
    enum Event: String, Sendable {
        case notification
        case intake
        case stateTransition = "state_transition"
        case axFence = "ax_fence"
        case refresh
        case reveal
    }

    enum Visibility: String, Sendable {
        case hidden
        case visible
    }

    enum Outcome: String, Sendable {
        case observed
        case enqueued
        case dropped
        case dispatched
        case duplicate
        case applied
        case invalidated
        case enabled
        case disabled
        case requested
        case queued
        case started
        case completed
        case coalesced
        case skipped
        case issued
        case rekeyed
        case succeeded
        case indeterminate
        case failed
        case confirmed
        case rejected
        case expired
        case cancelled
    }

    enum Destination: String, Sendable {
        case window
        case scratchpad
    }

    enum Reason: String, Sendable {
        case controllerUnavailable = "controller_unavailable"
        case intakeClosed = "intake_closed"
        case noActiveWorkspace = "no_active_workspace"
        case lockScreen = "lock_screen"
        case generationInvalidated = "generation_invalidated"
        case applicationUnavailable = "application_unavailable"
        case unhideRequestReportedNotSent = "unhide_request_reported_not_sent"
        case superseded
        case intentMissing = "intent_missing"
        case intentKindMismatch = "intent_kind_mismatch"
        case newerFocusIntent = "newer_focus_intent"
        case focusStateChanged = "focus_state_changed"
        case stillHidden = "still_hidden"
        case visibilityGenerationChanged = "visibility_generation_changed"
        case handleMissing = "handle_missing"
        case handleIdentityChanged = "handle_identity_changed"
        case entryMissing = "entry_missing"
        case pidChanged = "pid_changed"
        case workspaceChanged = "workspace_changed"
        case ineligibleLayout = "ineligible_layout"
        case focusDisallowed = "focus_disallowed"
        case intentNotPending = "intent_not_pending"
        case navigationFailed = "navigation_failed"
    }

    enum Source: String, Sendable {
        case ax
        case workspaceManager = "workspace_manager"
        case service
        case command
        case mouse
        case focusPolicy = "focus_policy"
        case layoutRefresh = "layout_refresh"

        init(_ source: WMEventSource) {
            switch source {
            case .ax:
                self = .ax
            case .workspaceManager:
                self = .workspaceManager
            case .service:
                self = .service
            case .command:
                self = .command
            case .mouse:
                self = .mouse
            case .focusPolicy:
                self = .focusPolicy
            case .layoutRefresh:
                self = .layoutRefresh
            }
        }
    }

    struct Record: Sendable {
        let ordinal: UInt64
        let timestamp: Date
        let event: Event
        let pid: pid_t?
        let visibility: Visibility?
        let outcome: Outcome?
        let intakeSequence: UInt64?
        let worldSequence: UInt64?
        let intentId: IntentID?
        let windowId: Int?
        let workspaceId: WorkspaceDescriptor.ID?
        let generation: UInt64?
        let intentGeneration: UInt64?
        let managedWindowCount: Int?
        let affectedWorkspaceCount: Int?
        let activeWorkspaceCount: Int?
        let destination: Destination?
        let reason: Reason?
        let source: Source?
    }

    private static let nextOrdinal = Atomic<UInt64>(0)

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "macOS App Visibility Trace",
        capacity: 512
    ) { record in
        var fields = [
            record.timestamp.ISO8601Format(),
            "ord=\(record.ordinal)",
            "event=\(record.event.rawValue)"
        ]
        if let pid = record.pid {
            fields.append("pid=\(pid)")
        }
        if let visibility = record.visibility {
            fields.append("visibility=\(visibility.rawValue)")
        }
        if let outcome = record.outcome {
            fields.append("outcome=\(outcome.rawValue)")
        }
        if let intakeSequence = record.intakeSequence {
            fields.append("intake_seq=\(intakeSequence)")
        }
        if let worldSequence = record.worldSequence {
            fields.append("world_seq=\(worldSequence)")
        }
        if let intentId = record.intentId {
            fields.append("intent=\(intentId)")
        }
        if let windowId = record.windowId {
            fields.append("win=\(windowId)")
        }
        if let workspaceId = record.workspaceId {
            fields.append("workspace=\(workspaceId.uuidString)")
        }
        if let generation = record.generation {
            fields.append("generation=\(generation)")
        }
        if let intentGeneration = record.intentGeneration {
            fields.append("intent_generation=\(intentGeneration)")
        }
        if let managedWindowCount = record.managedWindowCount {
            fields.append("managed_windows=\(managedWindowCount)")
        }
        if let affectedWorkspaceCount = record.affectedWorkspaceCount {
            fields.append("affected_workspaces=\(affectedWorkspaceCount)")
        }
        if let activeWorkspaceCount = record.activeWorkspaceCount {
            fields.append("active_workspaces=\(activeWorkspaceCount)")
        }
        if let destination = record.destination {
            fields.append("destination=\(destination.rawValue)")
        }
        if let reason = record.reason {
            fields.append("reason=\(reason.rawValue)")
        }
        if let source = record.source {
            fields.append("source=\(source.rawValue)")
        }
        return fields.joined(separator: " ")
    }

    static var isActive: Bool {
        shared.isActive
    }

    static func record(
        _ event: Event,
        pid: pid_t? = nil,
        visibility: Visibility? = nil,
        outcome: Outcome? = nil,
        intakeSequence: UInt64? = nil,
        worldSequence: UInt64? = nil,
        intentId: IntentID? = nil,
        windowId: Int? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        generation: UInt64? = nil,
        intentGeneration: UInt64? = nil,
        managedWindowCount: Int? = nil,
        affectedWorkspaceCount: Int? = nil,
        activeWorkspaceCount: Int? = nil,
        destination: Destination? = nil,
        reason: Reason? = nil,
        source: WMEventSource? = nil
    ) {
        shared.record(
            Record(
                ordinal: nextOrdinal.wrappingAdd(1, ordering: .relaxed).newValue,
                timestamp: Date(),
                event: event,
                pid: pid,
                visibility: visibility,
                outcome: outcome,
                intakeSequence: intakeSequence,
                worldSequence: worldSequence,
                intentId: intentId,
                windowId: windowId,
                workspaceId: workspaceId,
                generation: generation,
                intentGeneration: intentGeneration,
                managedWindowCount: managedWindowCount,
                affectedWorkspaceCount: affectedWorkspaceCount,
                activeWorkspaceCount: activeWorkspaceCount,
                destination: destination,
                reason: reason,
                source: source.map(Source.init)
            )
        )
    }
}
