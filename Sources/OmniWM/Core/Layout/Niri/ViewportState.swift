// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct OffsetTransition: Equatable {
    enum Kind: Equatable {
        case jump
        case spring(SpringConfig)
        case deceleration
    }

    var rebaseDelta: CGFloat = 0
    var kind: Kind?
}

struct ViewportState: Equatable {
    var activeColumnIndex: Int = 0

    var viewOffset: CGFloat = 0.0

    var offsetTransition = OffsetTransition()

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var activatePrevColumnOnRemoval: CGFloat?

    var displayRefreshRate: Double = 60.0
}

extension ViewportState {
    var hasPendingOffsetAnimation: Bool {
        switch offsetTransition.kind {
        case .spring,
             .deceleration: true
        default: false
        }
    }

    mutating func rebaseOffset(by delta: CGFloat) {
        viewOffset += delta
        offsetTransition.rebaseDelta += delta
    }

    mutating func jumpOffset(to offset: CGFloat) {
        offsetTransition.rebaseDelta += offset - viewOffset
        viewOffset = offset
        offsetTransition.kind = .jump
    }

    mutating func springOffset(to offset: CGFloat, config: SpringConfig? = nil) {
        viewOffset = offset
        offsetTransition.kind = .spring(config ?? .niriHorizontalViewMovement)
    }

    mutating func decelerateOffset(to offset: CGFloat) {
        viewOffset = offset
        offsetTransition.kind = .deceleration
    }

    mutating func clearOffsetTransition() {
        offsetTransition = OffsetTransition()
    }
}
