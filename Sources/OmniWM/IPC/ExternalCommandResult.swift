// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum ExternalCommandResult: Equatable, Sendable, Error {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case ignoredLayoutMismatch
    case staleWindowId
    case workspaceAssignmentConflict
    case workspaceStateConflict
    case notFound
    case noChange
    case invalidArguments
}
