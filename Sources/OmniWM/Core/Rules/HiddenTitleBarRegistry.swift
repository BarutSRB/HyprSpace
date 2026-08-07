// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum HiddenTitleBarRegistry {
    static let fullscreenButtonOptionalBundleIds: Set<String> = [
        "com.microsoft.vscode",
        "com.vscodium"
    ]

    static let nonStandardSubroleBundleIds: Set<String> = [
        "org.qutebrowser.qutebrowser"
    ]

    static func decision(
        for facts: AXWindowFacts,
        windowServer: WindowServerInfo?,
        fullscreenButtonOptionalBundleIds: Set<String>,
        nonStandardSubroleBundleIds: Set<String>
    ) -> Bool {
        guard facts.attributeFetchSucceeded,
              facts.role == (kAXWindowRole as String),
              let windowServer,
              windowServer.level == 0,
              !windowServer.hasParentWindow
        else {
            return false
        }

        let hasAnyButton = facts.hasCloseButton
            || facts.hasFullscreenButton
            || facts.hasZoomButton
            || facts.hasMinimizeButton
        let isStandardSubrole = facts.subrole == (kAXStandardWindowSubrole as String)

        if !hasAnyButton, isStandardSubrole, facts.appPolicy == .regular {
            return true
        }

        guard let bundleId = facts.bundleId?.lowercased() else { return false }

        if !facts.hasFullscreenButton, fullscreenButtonOptionalBundleIds.contains(bundleId) {
            return true
        }

        return !hasAnyButton
            && facts.subrole == (kAXDialogSubrole as String)
            && nonStandardSubroleBundleIds.contains(bundleId)
    }
}
