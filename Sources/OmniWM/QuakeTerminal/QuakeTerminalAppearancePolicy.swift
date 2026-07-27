// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum QuakeTerminalBackgroundEffect: String, CaseIterable, Codable, Sendable {
    case standardBlur
    case glassRegular
    case glassClear

    var displayName: String {
        switch self {
        case .standardBlur:
            "Standard Blur"
        case .glassRegular:
            "Regular Glass"
        case .glassClear:
            "Clear Glass"
        }
    }

    var ghosttyBackgroundBlurValue: String {
        switch self {
        case .standardBlur:
            "false"
        case .glassRegular:
            "macos-glass-regular"
        case .glassClear:
            "macos-glass-clear"
        }
    }
}

enum QuakeTerminalAppearancePolicy {
    static let minimumBackgroundBlurRadius = 0
    static let maximumBackgroundBlurRadius = 100
    static let disabledBackgroundBlurRadius = 0

    static func normalizedBackgroundBlurRadius(_ value: Int) -> Int {
        min(max(value, minimumBackgroundBlurRadius), maximumBackgroundBlurRadius)
    }

    static func effectiveBackgroundBlurRadius(_ value: Int, glassEffectActive: Bool) -> Int {
        glassEffectActive ? disabledBackgroundBlurRadius : normalizedBackgroundBlurRadius(value)
    }

    static func backgroundBlurIsHiddenByOpaqueBackground(radius: Int, opacity: Double) -> Bool {
        normalizedBackgroundBlurRadius(radius) > disabledBackgroundBlurRadius && opacity >= 1.0
    }
}
