// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct OverviewTextLineCache {
    enum Role: Hashable {
        case appName
        case groupBadge
        case searchPlaceholder
        case searchQuery
        case title
        case workspaceActive
        case workspaceInactive
    }

    struct Key: Hashable {
        let role: Role
        let text: String
        let widthBucket: Int
    }

    private static let maximumEntryCount = 512
    private var lines: [Key: CTLine] = [:]
    let appNameFont = CTFontCreateWithName("SF Pro Text" as CFString, 10, nil)
    let groupBadgeFont = CTFontCreateWithName("SF Pro Text" as CFString, 11, nil)
    let searchFont = CTFontCreateWithName("SF Pro Text" as CFString, 16, nil)
    let titleFont = CTFontCreateWithName("SF Pro Text" as CFString, 12, nil)
    let workspaceLabelFont = CTFontCreateWithName("SF Pro Display" as CFString, 16, nil)

    var entryCount: Int {
        lines.count
    }

    mutating func line(for key: Key, make: () -> CTLine) -> CTLine {
        if let line = lines[key] {
            return line
        }
        if lines.count >= Self.maximumEntryCount {
            lines.removeAll(keepingCapacity: true)
        }
        let line = make()
        lines[key] = line
        return line
    }

    mutating func removeAll() {
        lines.removeAll(keepingCapacity: true)
    }
}

struct OverviewRenderPalette {
    private struct Components: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private static let backdropDefault = Components(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
    private static let normalBorderDefault = Components(red: 0.3, green: 0.3, blue: 0.35, alpha: 0.5)
    private static let hoveredBorderDefault = Components(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
    private static let selectedBorderDefault = Components(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)

    static let `default` = OverviewRenderPalette(
        backdrop: cgColor(backdropDefault),
        normalBorder: cgColor(normalBorderDefault),
        hoveredBorder: cgColor(hoveredBorderDefault),
        selectedBorder: cgColor(selectedBorderDefault)
    )

    let backdrop: CGColor
    let normalBorder: CGColor
    let hoveredBorder: CGColor
    let selectedBorder: CGColor

    init(
        backdropColor: SettingsColor,
        normalBorderColor: SettingsColor,
        hoveredBorderColor: SettingsColor,
        selectedBorderColor: SettingsColor
    ) {
        backdrop = Self.cgColor(backdropColor, fallback: Self.backdropDefault)
        normalBorder = Self.cgColor(normalBorderColor, fallback: Self.normalBorderDefault)
        hoveredBorder = Self.cgColor(hoveredBorderColor, fallback: Self.hoveredBorderDefault)
        selectedBorder = Self.cgColor(selectedBorderColor, fallback: Self.selectedBorderDefault)
    }

    private init(
        backdrop: CGColor,
        normalBorder: CGColor,
        hoveredBorder: CGColor,
        selectedBorder: CGColor
    ) {
        self.backdrop = backdrop
        self.normalBorder = normalBorder
        self.hoveredBorder = hoveredBorder
        self.selectedBorder = selectedBorder
    }

    private static func cgColor(_ color: SettingsColor, fallback: Components) -> CGColor {
        CGColor(
            red: component(color.red, fallback: fallback.red),
            green: component(color.green, fallback: fallback.green),
            blue: component(color.blue, fallback: fallback.blue),
            alpha: component(color.alpha, fallback: fallback.alpha)
        )
    }

    private static func cgColor(_ components: Components) -> CGColor {
        CGColor(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: CGFloat(components.alpha)
        )
    }

    private static func component(_ value: Double, fallback: Double) -> CGFloat {
        guard value.isFinite else { return CGFloat(fallback) }
        return CGFloat(min(max(value, 0), 1))
    }
}

enum OverviewRenderer {
    private enum Colors {
        static let windowBackground = CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0)
        static let windowDimmed = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.7)
        static let infoBackground = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.9)
        static let closeButtonBackground = CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        static let closeButtonHover = CGColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
        static let closeButtonX = CGColor(gray: 1.0, alpha: 1.0)
        static let searchBarBackground = CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 0.95)
        static let searchBarBorder = CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
        static let textWhite = CGColor(gray: 1.0, alpha: 1.0)
        static let textGray = CGColor(gray: 0.7, alpha: 1.0)
        static let textDimmed = CGColor(gray: 0.4, alpha: 1.0)
        static let workspaceLabelActive = CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
        static let workspaceLabelInactive = CGColor(gray: 0.6, alpha: 1.0)
        static let dropTarget = CGColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)
        static let dropTargetBackground = CGColor(red: 0.1, green: 0.6, blue: 1.0, alpha: 0.2)
        static let columnBackground = CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 0.6)
        static let columnBorder = CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1.0)
        static let columnDivider = CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 0.8)
        static let textWhiteNS = NSColor(cgColor: textWhite)!
        static let textGrayNS = NSColor(cgColor: textGray)!
        static let textDimmedNS = NSColor(cgColor: textDimmed)!
        static let workspaceLabelActiveNS = NSColor(cgColor: workspaceLabelActive)!
        static let workspaceLabelInactiveNS = NSColor(cgColor: workspaceLabelInactive)!
    }

    private enum Metrics {
        static let windowCornerRadius: CGFloat = 8
        static let windowBorderWidth: CGFloat = 2
        static let selectedBorderWidth: CGFloat = 3
        static let closeButtonSize: CGFloat = 20
        static let closeButtonPadding: CGFloat = 6
        static let thumbnailInset: CGFloat = 1
        static let searchBarCornerRadius: CGFloat = 10
        static let searchBarBorderWidth: CGFloat = 1.5
        static let iconSize: CGFloat = 24
        static let groupBadgeHeight: CGFloat = 22
        static let groupBadgePadding: CGFloat = 8
        static let dropLineHeight: CGFloat = 4
        static let dropOutlineWidth: CGFloat = 3
        static let dropLineWidth: CGFloat = 4
        static let columnCornerRadius: CGFloat = 10
        static let dividerHeight: CGFloat = 2
        static let titleWidthBucket: CGFloat = 4
    }

    static func render(
        context: CGContext,
        layout: OverviewLayout,
        thumbnails: [Int: CGImage],
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        hoveredWindowHandle: WindowHandle?,
        closeButtonHovered: Bool,
        textLineCache: inout OverviewTextLineCache,
        progress: Double,
        bounds: CGRect,
        palette: OverviewRenderPalette = .default
    ) {
        let alpha = CGFloat(progress)

        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(palette.backdrop)
        context.fill(bounds)
        context.restoreGState()

        guard progress > 0 else { return }

        let scrollOffset = layout.scrollOffset
        let visibleContentRect = visibleContentRect(bounds: bounds, scrollOffset: scrollOffset)

        context.saveGState()
        context.translateBy(x: 0, y: -scrollOffset)

        for section in layout.workspaceSections {
            if !shouldRender(
                frame: sectionCullingFrame(section, progress: progress),
                visibleContentRect: visibleContentRect
            ) {
                continue
            }

            renderWorkspaceLabel(
                context: context,
                section: section,
                alpha: alpha,
                textLineCache: &textLineCache
            )

            if let columns = layout.niriColumnsByWorkspace[section.workspaceId] {
                renderNiriColumns(
                    context: context,
                    columns: columns,
                    layout: layout,
                    alpha: alpha,
                    visibleContentRect: visibleContentRect
                )
            }

            for window in section.windows {
                let frame = window.interpolatedFrame(progress: progress)
                if !shouldRender(frame: frame, visibleContentRect: visibleContentRect) {
                    continue
                }

                renderWindow(
                    context: context,
                    window: window,
                    frame: frame,
                    thumbnail: thumbnails[window.windowId],
                    isSelected: window.handle == selectedWindowHandle,
                    isHovered: window.handle == hoveredWindowHandle,
                    isCloseButtonHovered: window.handle == hoveredWindowHandle && closeButtonHovered,
                    textLineCache: &textLineCache,
                    progress: progress,
                    palette: palette
                )
            }
        }

        if let dragTarget = layout.dragTarget {
            renderDragTarget(
                context: context,
                layout: layout,
                dragTarget: dragTarget,
                alpha: alpha
            )
        }

        context.restoreGState()

        renderSearchBar(
            context: context,
            frame: layout.searchBarFrame,
            searchQuery: searchQuery,
            alpha: alpha,
            textLineCache: &textLineCache
        )
    }

    static func visibleContentRect(bounds: CGRect, scrollOffset: CGFloat) -> CGRect {
        return bounds.offsetBy(dx: 0, dy: scrollOffset)
    }

    static func shouldRender(frame: CGRect, visibleContentRect: CGRect) -> Bool {
        frame.intersects(visibleContentRect.insetBy(dx: -8, dy: -8))
    }

    static func sectionCullingFrame(
        _ section: OverviewWorkspaceSection,
        progress: Double
    ) -> CGRect {
        section.windows.reduce(section.sectionFrame.union(section.labelFrame)) { frame, window in
            frame.union(window.interpolatedFrame(progress: progress))
        }
    }

    static func borderColor(
        isSelected: Bool,
        isHovered: Bool,
        palette: OverviewRenderPalette
    ) -> CGColor {
        if isSelected {
            return palette.selectedBorder
        }
        if isHovered {
            return palette.hoveredBorder
        }
        return palette.normalBorder
    }

    private static func renderNiriColumns(
        context: CGContext,
        columns: [OverviewNiriColumn],
        layout: OverviewLayout,
        alpha: CGFloat,
        visibleContentRect: CGRect
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)

        for column in columns {
            let frame = column.frame
            if !shouldRender(frame: frame, visibleContentRect: visibleContentRect) {
                continue
            }

            let path = CGPath(
                roundedRect: frame,
                cornerWidth: Metrics.columnCornerRadius,
                cornerHeight: Metrics.columnCornerRadius,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(Colors.columnBackground)
            context.fillPath()

            context.addPath(path)
            context.setStrokeColor(Colors.columnBorder)
            context.setLineWidth(1.0)
            context.strokePath()

            if column.windowHandles.count > 1 {
                let frames = column.windowHandles.compactMap { layout.window(for: $0)?.overviewFrame }
                let sorted = frames.sorted { $0.maxY > $1.maxY }
                for i in 0 ..< (sorted.count - 1) {
                    let upper = sorted[i]
                    let lower = sorted[i + 1]
                    let y = (upper.minY + lower.maxY) / 2
                    let divider = CGRect(
                        x: frame.minX + 8,
                        y: y - Metrics.dividerHeight / 2,
                        width: frame.width - 16,
                        height: Metrics.dividerHeight
                    )
                    context.setFillColor(Colors.columnDivider)
                    context.fill(divider)
                }
            }
        }
    }

    private static func renderDragTarget(
        context: CGContext,
        layout: OverviewLayout,
        dragTarget: OverviewDragTarget,
        alpha: CGFloat
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)

        switch dragTarget {
        case let .niriWindowInsert(_, targetHandle, position):
            guard let window = layout.window(for: targetHandle) else { return }
            let frame = window.overviewFrame
            let y = position == .before ? frame.maxY - Metrics.dropLineHeight : frame.minY
            let lineFrame = CGRect(
                x: frame.minX,
                y: y,
                width: frame.width,
                height: Metrics.dropLineHeight
            )
            context.setFillColor(Colors.dropTarget)
            context.fill(lineFrame)

        case let .niriColumnInsert(workspaceId, insertIndex):
            guard let zones = layout.niriColumnDropZonesByWorkspace[workspaceId] else { return }
            guard let zone = zones.first(where: { $0.insertIndex == insertIndex }) else { return }
            let x = zone.frame.midX - Metrics.dropLineWidth / 2
            let lineFrame = CGRect(
                x: x,
                y: zone.frame.minY,
                width: Metrics.dropLineWidth,
                height: zone.frame.height
            )
            context.setFillColor(Colors.dropTarget)
            context.fill(lineFrame)

        case let .workspaceMove(workspaceId):
            guard let section = layout.workspaceSections.first(where: { $0.workspaceId == workspaceId }) else { return }
            context.setStrokeColor(Colors.dropTarget)
            context.setLineWidth(Metrics.dropOutlineWidth)
            context.stroke(section.sectionFrame)
        }
    }

    private static func renderWorkspaceLabel(
        context: CGContext,
        section: OverviewWorkspaceSection,
        alpha: CGFloat,
        textLineCache: inout OverviewTextLineCache
    ) {
        let color = section.isActive ? Colors.workspaceLabelActiveNS : Colors.workspaceLabelInactiveNS
        let role: OverviewTextLineCache.Role = section.isActive ? .workspaceActive : .workspaceInactive
        let key = OverviewTextLineCache.Key(role: role, text: section.name, widthBucket: 0)
        let font = textLineCache.workspaceLabelFont
        let line = textLineCache.line(for: key) {
            makeLine(text: section.name, font: font, color: color)
        }

        context.saveGState()
        context.setAlpha(alpha)
        context.textMatrix = .identity
        context.translateBy(x: section.labelFrame.minX, y: section.labelFrame.minY + 8)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func renderWindow(
        context: CGContext,
        window: OverviewWindowItem,
        frame: CGRect,
        thumbnail: CGImage?,
        isSelected: Bool,
        isHovered: Bool,
        isCloseButtonHovered: Bool,
        textLineCache: inout OverviewTextLineCache,
        progress: Double,
        palette: OverviewRenderPalette
    ) {
        let alpha = CGFloat(progress) * (window.matchesSearch ? 1.0 : 0.3)

        context.saveGState()
        context.setAlpha(alpha)

        let path = CGPath(
            roundedRect: frame,
            cornerWidth: Metrics.windowCornerRadius,
            cornerHeight: Metrics.windowCornerRadius,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(Colors.windowBackground)
        context.fillPath()

        if let thumbnail {
            let thumbnailRect = frame.insetBy(dx: Metrics.thumbnailInset, dy: Metrics.thumbnailInset)
            let drawRect = aspectFitRect(
                contentSize: CGSize(width: thumbnail.width, height: thumbnail.height),
                in: thumbnailRect
            )
            context.saveGState()
            let clipPath = CGPath(
                roundedRect: thumbnailRect,
                cornerWidth: Metrics.windowCornerRadius - 1,
                cornerHeight: Metrics.windowCornerRadius - 1,
                transform: nil
            )
            context.addPath(clipPath)
            context.clip()
            context.draw(thumbnail, in: drawRect)
            context.restoreGState()
        }

        if !window.matchesSearch {
            context.addPath(path)
            context.setFillColor(Colors.windowDimmed)
            context.fillPath()
        }

        let borderColor = Self.borderColor(
            isSelected: isSelected,
            isHovered: isHovered,
            palette: palette
        )
        let borderWidth = isSelected ? Metrics.selectedBorderWidth : Metrics.windowBorderWidth

        context.addPath(path)
        context.setStrokeColor(borderColor)
        context.setLineWidth(borderWidth)
        context.strokePath()

        let infoHeight: CGFloat = 36
        let infoRect = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: infoHeight
        )

        context.saveGState()
        let infoPath = CGMutablePath()
        infoPath.move(to: CGPoint(x: infoRect.minX + Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addLine(to: CGPoint(x: infoRect.maxX - Metrics.windowCornerRadius, y: infoRect.minY))
        infoPath.addArc(
            center: CGPoint(
                x: infoRect.maxX - Metrics.windowCornerRadius,
                y: infoRect.minY + Metrics.windowCornerRadius
            ),
            radius: Metrics.windowCornerRadius,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: false
        )
        infoPath.addLine(to: CGPoint(x: infoRect.maxX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.maxY))
        infoPath.addLine(to: CGPoint(x: infoRect.minX, y: infoRect.minY + Metrics.windowCornerRadius))
        infoPath.addArc(
            center: CGPoint(
                x: infoRect.minX + Metrics.windowCornerRadius,
                y: infoRect.minY + Metrics.windowCornerRadius
            ),
            radius: Metrics.windowCornerRadius,
            startAngle: .pi,
            endAngle: -.pi / 2,
            clockwise: false
        )
        infoPath.closeSubpath()

        context.addPath(infoPath)
        context.setFillColor(Colors.infoBackground)
        context.fillPath()
        context.restoreGState()

        if let icon = window.appIcon {
            let iconRect = CGRect(
                x: infoRect.minX + 8,
                y: infoRect.minY + (infoHeight - Metrics.iconSize) / 2,
                width: Metrics.iconSize,
                height: Metrics.iconSize
            )
            context.draw(icon, in: iconRect)
        }

        let textX = infoRect.minX + 8 + Metrics.iconSize + 6
        let maxTextWidth = infoRect.width - (textX - infoRect.minX) - 8

        let titleWidth = bucketedTitleWidth(maxTextWidth)
        let titleKey = OverviewTextLineCache.Key(
            role: .title,
            text: window.title,
            widthBucket: Int(titleWidth)
        )
        let titleFont = textLineCache.titleFont
        let titleLine = textLineCache.line(for: titleKey) {
            makeTruncatedLine(
                text: window.title,
                font: titleFont,
                color: Colors.textWhiteNS,
                maxWidth: titleWidth
            )
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 20)
        CTLineDraw(titleLine, context)
        context.restoreGState()

        let appKey = OverviewTextLineCache.Key(role: .appName, text: window.appName, widthBucket: 0)
        let appNameFont = textLineCache.appNameFont
        let appLine = textLineCache.line(for: appKey) {
            makeLine(text: window.appName, font: appNameFont, color: Colors.textGrayNS)
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: infoRect.minY + 6)
        CTLineDraw(appLine, context)
        context.restoreGState()

        if isHovered {
            renderCloseButton(
                context: context,
                frame: window.closeButtonFrame,
                isHovered: isCloseButtonHovered
            )
        }

        if window.groupCount > 1 {
            renderGroupBadge(
                context: context,
                count: window.groupCount,
                frame: frame,
                textLineCache: &textLineCache
            )
        }

        context.restoreGState()
    }

    private static func renderGroupBadge(
        context: CGContext,
        count: Int,
        frame: CGRect,
        textLineCache: inout OverviewTextLineCache
    ) {
        let text = "\(count)"
        let key = OverviewTextLineCache.Key(role: .groupBadge, text: text, widthBucket: 0)
        let font = textLineCache.groupBadgeFont
        let line = textLineCache.line(for: key) {
            makeLine(text: text, font: font, color: Colors.textWhiteNS)
        }
        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let badgeWidth = max(
            Metrics.groupBadgeHeight,
            ceil(textBounds.width) + Metrics.groupBadgePadding * 2
        )
        let badgeFrame = CGRect(
            x: frame.minX + 8,
            y: frame.maxY - Metrics.groupBadgeHeight - 8,
            width: badgeWidth,
            height: Metrics.groupBadgeHeight
        )
        let badgePath = CGPath(
            roundedRect: badgeFrame,
            cornerWidth: Metrics.groupBadgeHeight / 2,
            cornerHeight: Metrics.groupBadgeHeight / 2,
            transform: nil
        )

        context.saveGState()
        context.addPath(badgePath)
        context.setFillColor(CGColor(gray: 0.05, alpha: 0.82))
        context.fillPath()
        context.textMatrix = .identity
        context.translateBy(
            x: badgeFrame.midX - textBounds.midX,
            y: badgeFrame.midY - textBounds.midY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func renderCloseButton(
        context: CGContext,
        frame: CGRect,
        isHovered: Bool
    ) {
        let bgColor = isHovered ? Colors.closeButtonHover : Colors.closeButtonBackground
        let path = CGPath(ellipseIn: frame, transform: nil)

        context.saveGState()
        context.addPath(path)
        context.setFillColor(bgColor)
        context.fillPath()

        let xInset: CGFloat = 6
        context.setStrokeColor(Colors.closeButtonX)
        context.setLineWidth(2)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: frame.minX + xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.maxX - xInset, y: frame.maxY - xInset))
        context.strokePath()

        context.move(to: CGPoint(x: frame.maxX - xInset, y: frame.minY + xInset))
        context.addLine(to: CGPoint(x: frame.minX + xInset, y: frame.maxY - xInset))
        context.strokePath()
        context.restoreGState()
    }

    private static func renderSearchBar(
        context: CGContext,
        frame: CGRect,
        searchQuery: String,
        alpha: CGFloat,
        textLineCache: inout OverviewTextLineCache
    ) {
        let path = CGPath(
            roundedRect: frame,
            cornerWidth: Metrics.searchBarCornerRadius,
            cornerHeight: Metrics.searchBarCornerRadius,
            transform: nil
        )

        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(path)
        context.setFillColor(Colors.searchBarBackground)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(Colors.searchBarBorder)
        context.setLineWidth(Metrics.searchBarBorderWidth)
        context.strokePath()

        let displayText = searchQuery.isEmpty ? "Type to search..." : searchQuery
        let textColor = searchQuery.isEmpty ? Colors.textDimmedNS : Colors.textWhiteNS

        let role: OverviewTextLineCache.Role = searchQuery.isEmpty ? .searchPlaceholder : .searchQuery
        let key = OverviewTextLineCache.Key(role: role, text: displayText, widthBucket: 0)
        let font = textLineCache.searchFont
        let line = textLineCache.line(for: key) {
            makeLine(text: displayText, font: font, color: textColor)
        }

        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textX = frame.midX - textBounds.width / 2
        let textY = frame.midY - textBounds.height / 2

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
        context.restoreGState()

        if !searchQuery.isEmpty {
            let cursorX = textX + textBounds.width + 2
            let cursorHeight: CGFloat = 18
            let cursorY = frame.midY - cursorHeight / 2

            let time = CACurrentMediaTime()
            let cursorAlpha = (sin(time * 3) + 1) / 2

            context.saveGState()
            context.setAlpha(alpha * CGFloat(cursorAlpha))
            context.setFillColor(Colors.textWhite)
            context.fill(CGRect(x: cursorX, y: cursorY, width: 2, height: cursorHeight))
            context.restoreGState()
        }
    }

    private static func bucketedTitleWidth(_ maxWidth: CGFloat) -> CGFloat {
        max(1, floor(maxWidth / Metrics.titleWidthBucket) * Metrics.titleWidthBucket)
    }

    private static func makeLine(text: String, font: CTFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color
                ]
            )
        )
    }

    private static func makeTruncatedLine(
        text: String,
        font: CTFont,
        color: NSColor,
        maxWidth: CGFloat
    ) -> CTLine {
        let line = makeLine(text: text, font: font, color: color)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) else {
            return line
        }
        let token = makeLine(text: "…", font: font, color: color)
        return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) ?? token
    }

    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - fittedSize.width) / 2,
            y: bounds.minY + (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
