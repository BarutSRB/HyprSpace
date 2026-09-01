// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct BorderConfig: Equatable {
    struct ResolvedGeometry {
        let targetFrame: CGRect
        let surfaceFrame: CGRect
        let width: CGFloat
    }

    var enabled: Bool
    var width: CGFloat
    var color: SettingsColor

    init(
        enabled: Bool = false,
        width: CGFloat = 4.0,
        color: SettingsColor = SettingsColor(red: 0, green: 0.478_431_372_5, blue: 1, alpha: 1)
    ) {
        self.enabled = enabled
        self.width = width
        self.color = color
    }

    @MainActor static func from(settings: SettingsStore) -> BorderConfig {
        return BorderConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            color: settings.borderColor
        )
    }

    static func layoutClearance(enabled: Bool, width: CGFloat, scale: CGFloat) -> CGFloat {
        guard enabled else { return 0 }
        let effectiveScale = max(scale, 1)
        return ceil(max(0, width) * effectiveScale) / effectiveScale
    }

    func resolvedGeometry(
        for targetFrame: CGRect,
        scale: CGFloat
    ) -> ResolvedGeometry {
        let targetFrame = targetFrame.roundedToPhysicalPixels(scale: scale)
        let width = Self.layoutClearance(enabled: enabled, width: width, scale: scale)
        return ResolvedGeometry(
            targetFrame: targetFrame,
            surfaceFrame: targetFrame.insetBy(dx: -width, dy: -width),
            width: width
        )
    }
}
