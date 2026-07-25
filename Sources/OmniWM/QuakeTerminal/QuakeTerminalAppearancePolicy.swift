// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum QuakeTerminalAppearancePolicy {
    static let minimumBackgroundBlurRadius = 0
    static let maximumBackgroundBlurRadius = 100
    static let disabledBackgroundBlurRadius = 0

    /// Radius Ghostty uses for `background-blur = true`; the value the UI offers as "on".
    static let defaultEnabledBackgroundBlurRadius = 20

    static func normalizedBackgroundBlurRadius(_ value: Int) -> Int {
        min(max(value, minimumBackgroundBlurRadius), maximumBackgroundBlurRadius)
    }

    /// Blur only shows through translucent pixels, so a fully opaque terminal renders
    /// identically with the blur on or off.
    static func backgroundBlurIsHiddenByOpaqueBackground(radius: Int, opacity: Double) -> Bool {
        normalizedBackgroundBlurRadius(radius) > disabledBackgroundBlurRadius && opacity >= 1.0
    }
}
