// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct InteractiveMove {
    let windowId: NodeId
    var windowToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let originalColumnIndex: Int
    let originalFrame: CGRect
    let isInsertMode: Bool
    let orientation: Monitor.Orientation
    let gaps: CGFloat

    var currentHoverTarget: MoveHoverTarget?
}

enum MoveHoverTarget: Equatable {
    case window(nodeId: NodeId, token: WindowToken, insertPosition: InsertPosition)
    case columnGap(columnIndex: Int, insertPosition: InsertPosition)
    case workspaceEdge(side: HorizontalSide)
}

enum InsertPosition: Equatable {
    case before
    case after
    case swap
}

enum HorizontalSide: Equatable {
    case left
    case right
}

struct MoveConfiguration {
    var dragThreshold: CGFloat = 10.0

    static let `default` = MoveConfiguration()
}
