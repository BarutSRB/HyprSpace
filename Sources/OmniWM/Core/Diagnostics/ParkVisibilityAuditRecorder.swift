// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum ParkVisibilityAudit {
    struct Record: Sendable {
        let mediaTime: CFTimeInterval
        let displayId: CGDirectDisplayID
        let laggards: [String]
        let strays: [String]
        let visible: [Int]
        let parkedCount: Int
        let appHiddenCount: Int
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Park Visibility Audit",
        capacity: 1024
    ) { record in
        let mediaTime = String(format: "%.3f", record.mediaTime)
        let laggards = record.laggards.isEmpty ? "none" : record.laggards.joined(separator: " ")
        let strays = record.strays.isEmpty ? "none" : record.strays.joined(separator: " ")
        let visible = record.visible.map(String.init).joined(separator: ",")
        return "t=\(mediaTime) disp=\(record.displayId)"
            + " laggards=\(laggards)"
            + " strays=\(strays)"
            + " visible=[\(visible)]"
            + " parked=\(record.parkedCount)"
            + " appHidden=\(record.appHiddenCount)"
    }
}
