// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension ViewportState {
    func viewPosPixels(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        columnX(at: activeColumnIndex, columns: columns, gap: gap) + viewOffset
    }

    mutating func animateToOffset(
        _ offset: CGFloat,
        motion: MotionSnapshot,
        config: SpringConfig? = nil,
        scale: CGFloat = 2.0
    ) {
        guard motion.animationsEnabled else {
            jumpOffset(to: offset)
            return
        }

        let pixel: CGFloat = 1.0 / scale
        let toDiff = offset - viewOffset
        if abs(toDiff) < pixel {
            rebaseOffset(by: toDiff)
            return
        }

        springOffset(to: offset, config: config)
    }

    mutating func cancelAnimation() {
        jumpOffset(to: viewOffset)
    }

    mutating func reset() {
        activeColumnIndex = 0
        jumpOffset(to: 0.0)
        selectedNodeId = nil
    }

    mutating func offsetViewport(by delta: CGFloat) {
        jumpOffset(to: viewOffset + delta)
    }

    mutating func saveViewOffsetForFullscreen() {
        viewOffsetToRestore = viewOffset
    }

    mutating func animateViewOffsetRestore(_ offset: CGFloat, motion: MotionSnapshot) {
        if motion.animationsEnabled {
            springOffset(to: offset)
        } else {
            jumpOffset(to: offset)
        }
        viewOffsetToRestore = nil
    }
}
