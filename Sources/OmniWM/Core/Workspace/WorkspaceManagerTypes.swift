// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?
    var runtimeMonitorOverride: OutputId?

    init(name: String, assignedMonitorPoint: CGPoint? = nil) {
        id = UUID()
        self.name = name
        self.assignedMonitorPoint = assignedMonitorPoint
        runtimeMonitorOverride = nil
    }
}

struct WorkspaceFloatingRelocation: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let token: WindowToken
    let frame: CGRect
}

struct WorkspaceMonitorMoveOutcome: Equatable {
    enum Status: Equatable {
        case executed
        case conflict
        case notFound
        case stateConflict
    }

    let status: Status
    let affectedWorkspaces: Set<WorkspaceDescriptor.ID>
    let floatingRelocations: [WorkspaceFloatingRelocation]
}

enum WorkspaceNativeFullscreenTransition: Equatable {
    case enterRequested
    case suspended
    case exitRequested
}

struct WorkspaceNativeFullscreenRecord: Equatable {
    let originalToken: WindowToken
    var currentToken: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var exitRequestedByCommand: Bool
    var transition: WorkspaceNativeFullscreenTransition
}
