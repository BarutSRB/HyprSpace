// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleSettings {
    static let splitRatioPresets: [CGFloat] = [0.6, 1.0, 1.4]

    var defaultSplitRatio: CGFloat = 1.0
    var splitWidthMultiplier: CGFloat = 1.0
    var smartSplit: Bool = true
    var resizeStep: CGFloat = 0.1

    var singleWindowFit: SingleWindowFit = .fullScreen

    var innerGap: CGFloat = 8.0

    func clampedRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.1), 1.9)
    }

    func ratioToFraction(_ ratio: CGFloat) -> CGFloat {
        let clamped = clampedRatio(ratio)
        return min(max(clamped / 2.0, 0.05), 0.95)
    }
}
