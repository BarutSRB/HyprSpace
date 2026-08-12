// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import wchar_h
import xlocale

private final class TerminalWidthLocale: @unchecked Sendable {
    let value: locale_t

    init() {
        guard let value = newlocale(LC_CTYPE_MASK, "UTF-8", nil) else {
            fatalError("UTF-8 locale is unavailable")
        }
        self.value = value
    }

    deinit {
        freelocale(value)
    }
}

enum TerminalCellWidth {
    private static let locale = TerminalWidthLocale()

    static func measure(_ string: some StringProtocol) -> Int {
        string.reduce(into: 0) { width, character in
            width += measure(character)
        }
    }

    private static func measure(_ character: Character) -> Int {
        var width = 0
        var regionalIndicatorCount = 0
        var hasDefaultEmojiPresentation = false
        var hasEmojiPresentationSelector = false
        var hasKeycap = false
        var hasJoiner = false
        var emojiCount = 0

        for scalar in character.unicodeScalars {
            let properties = scalar.properties

            if (0x1F1E6 ... 0x1F1FF).contains(scalar.value) {
                regionalIndicatorCount += 1
            } else if properties.isEmojiPresentation {
                hasDefaultEmojiPresentation = true
            }

            hasEmojiPresentationSelector = hasEmojiPresentationSelector || scalar.value == 0xFE0F
            hasKeycap = hasKeycap || scalar.value == 0x20E3
            hasJoiner = hasJoiner || scalar.value == 0x200D
            if properties.isEmoji {
                emojiCount += 1
            }

            let scalarWidth = wcwidth_l(Int32(scalar.value), locale.value)
            if scalarWidth >= 0 {
                width += Int(scalarWidth)
            } else if properties.generalCategory != .control,
                      !properties.isDefaultIgnorableCodePoint
            {
                width += 1
            }
        }

        if regionalIndicatorCount == 2 ||
            hasDefaultEmojiPresentation ||
            (hasEmojiPresentationSelector && emojiCount > 0) ||
            (hasKeycap && emojiCount > 0) ||
            (hasJoiner && emojiCount >= 2)
        {
            return 2
        }

        return width
    }
}
