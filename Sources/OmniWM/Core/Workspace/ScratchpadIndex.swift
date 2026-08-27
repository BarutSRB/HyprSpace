// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

struct ScratchpadIndex: Hashable, Comparable, Sendable {
    static let range = IPCScratchpadSlots.range

    let rawValue: Int

    init?(_ rawValue: Int) {
        guard Self.range.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension ScratchpadIndex: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        guard let index = ScratchpadIndex(value) else {
            preconditionFailure("scratchpad slot \(value) is outside \(Self.range)")
        }
        self = index
    }
}

extension ScratchpadIndex: CustomStringConvertible {
    var description: String {
        String(rawValue)
    }
}
