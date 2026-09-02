// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum OverviewScrollInput {
    static let axisEpsilon: CGFloat = 0.0001

    static func dominantDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        let dominant = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        return abs(dominant) <= axisEpsilon ? 0 : dominant
    }
}
