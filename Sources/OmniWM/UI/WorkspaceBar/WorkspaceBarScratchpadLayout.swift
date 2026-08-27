// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum WorkspaceBarScratchpadLayout {
    static let maximumVisibleAppIcons = 3
    static let compactLabelMaximumWidth: CGFloat = 20
    private static let itemWidthSafetyMargin: CGFloat = 1

    static func compactedItems(
        _ items: [WorkspaceBarScratchpadItem],
        availableWidth: CGFloat,
        baseWidth: CGFloat,
        barHeight: CGFloat,
        hasAdjacentContent: Bool
    ) -> [WorkspaceBarScratchpadItem] {
        let expanded = items.map { $0.presented(as: .expanded) }
        let requiredWidth = baseWidth
            + (hasAdjacentContent && !expanded.isEmpty ? 8 : 0)
            + estimatedWidth(of: expanded, barHeight: barHeight)
        guard requiredWidth > availableWidth else { return expanded }
        let compacted = expanded.map { item in
            item.presented(as: item.isRevealed ? .expanded : .compact)
        }
        let compactedRequiredWidth = baseWidth
            + (hasAdjacentContent && !compacted.isEmpty ? 8 : 0)
            + estimatedWidth(of: compacted, barHeight: barHeight)
        guard compactedRequiredWidth > availableWidth else { return compacted }
        return compacted.map { $0.presented(as: .compact) }
    }

    static func estimatedWidth(
        of items: [WorkspaceBarScratchpadItem],
        barHeight: CGFloat
    ) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let itemHeight = max(16, barHeight - 4)
        let iconSize = max(12, itemHeight - 6)
        return items.reduce(0) { width, item in
            width + estimatedWidth(of: item, iconSize: iconSize)
        } + CGFloat(items.count - 1) * 8
    }

    private static func estimatedWidth(
        of item: WorkspaceBarScratchpadItem,
        iconSize: CGFloat
    ) -> CGFloat {
        let fontSize = max(9, iconSize * 0.6)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let labelWidth = (item.name as NSString).size(withAttributes: [.font: font]).width
        switch item.presentation {
        case .expanded:
            let iconCount = min(maximumVisibleAppIcons, item.windows.count)
            let overflowCount = max(0, item.windows.count - iconCount)
            var widths = [max(14, iconSize), labelWidth]
            widths.append(contentsOf: repeatElement(iconSize, count: iconCount))
            if overflowCount > 0 {
                widths.append(badgeWidth(for: "+\(overflowCount)", iconSize: iconSize))
            }
            return 16
                + widths.reduce(0, +)
                + CGFloat(max(0, widths.count - 1)) * 5
                + itemWidthSafetyMargin
        case .compact:
            return 10
                + min(labelWidth, compactLabelMaximumWidth)
                + 3
                + badgeWidth(for: "\(item.windowCount)", iconSize: iconSize)
                + itemWidthSafetyMargin
        }
    }

    private static func badgeWidth(for text: String, iconSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return max(
            max(12, iconSize * 0.55),
            (text as NSString).size(withAttributes: [.font: font]).width + 6
        )
    }
}
