// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct AppHiddenStatusBadge: View {
    private let systemRed = Color(nsColor: .systemRed)

    var body: some View {
        Label("App hidden", systemImage: "eye.slash.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background {
                Capsule(style: .continuous)
                    .fill(systemRed.opacity(0.18))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(systemRed.opacity(0.65), lineWidth: 1)
                    }
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}
