// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct StatusMenuControlPreviewView: View {
    let preview: StatusMenuControlPreview
    let animationsEnabled: Bool

    var body: some View {
        if animationsEnabled, isAnimated {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                StatusMenuControlPreviewCanvas(
                    preview: preview,
                    phase: StatusMenuControlPreviewPhase(
                        timeInterval: context.date.timeIntervalSinceReferenceDate
                    )
                )
            }
        } else {
            StatusMenuControlPreviewCanvas(preview: preview, phase: .staticEnd)
        }
    }

    private var isAnimated: Bool {
        switch preview {
        case .focusMouse,
             .focusEdge,
             .mouseToFocused,
             .followMonitor,
             .moveEdge,
             .mouseWarp:
            true
        case .focusedWindow,
             .workspaceBar,
             .keepAwake,
             .hiddenMenuIcons:
            false
        }
    }
}

private struct StatusMenuControlPreviewCanvas: View {
    let preview: StatusMenuControlPreview
    let phase: StatusMenuControlPreviewPhase

    private let accent = Color(nsColor: .controlAccentColor)
    private let label = Color(nsColor: .labelColor)
    private let secondary = Color(nsColor: .secondaryLabelColor)
    private let tertiary = Color(nsColor: .tertiaryLabelColor)
    private let window = Color(nsColor: .windowBackgroundColor)

    private var progress: CGFloat {
        phase.progress
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 72, y: size.height / 72)
            switch preview {
            case .focusedWindow:
                drawFocusedWindow(in: &context)
            case .workspaceBar:
                drawWorkspaceBar(in: &context)
            case .keepAwake:
                drawKeepAwake(in: &context)
            case .focusMouse:
                drawFocusMouse(in: &context)
            case .focusEdge:
                drawFocusEdge(in: &context)
            case .mouseToFocused:
                drawMouseToFocused(in: &context)
            case .followMonitor:
                drawFollowMonitor(in: &context)
            case .moveEdge:
                drawMoveEdge(in: &context)
            case .mouseWarp:
                drawMouseWarp(in: &context)
            case .hiddenMenuIcons:
                drawHiddenMenuIcons(in: &context)
            }
        }
    }
}

extension StatusMenuControlPreviewCanvas {
    private func drawFocusedWindow(in context: inout GraphicsContext) {
        let rect = CGRect(x: 8, y: 11, width: 56, height: 47)
        drawWindow(rect, focused: true, in: &context)
        drawContent(in: rect.insetBy(dx: 8, dy: 13), in: &context)
    }

    private func drawWorkspaceBar(in context: inout GraphicsContext) {
        let rect = CGRect(x: 6, y: 10, width: 60, height: 51)
        drawWindow(rect, focused: false, in: &context)
        let bar = CGRect(x: 10, y: 44, width: 52, height: 12)
        context.fill(
            Path(roundedRect: bar, cornerRadius: 3),
            with: .color(secondary.opacity(0.16))
        )
        for index in 0 ..< 3 {
            let item = CGRect(x: 13 + CGFloat(index) * 16, y: 47, width: 12, height: 6)
            context.fill(
                Path(roundedRect: item, cornerRadius: 2),
                with: .color(index == 1 ? accent : tertiary.opacity(0.45))
            )
        }
    }

    private func drawKeepAwake(in context: inout GraphicsContext) {
        let display = CGRect(x: 7, y: 14, width: 50, height: 37)
        drawDisplay(display, active: true, in: &context)
        let symbol = context.resolve(Image(systemName: "moon.stars.fill"))
        context.draw(symbol, at: CGPoint(x: 53, y: 19))
        var baseline = Path()
        baseline.move(to: CGPoint(x: 23, y: 58))
        baseline.addLine(to: CGPoint(x: 42, y: 58))
        context.stroke(baseline, with: .color(secondary.opacity(0.6)), lineWidth: 2)
    }

    private func drawFocusMouse(in context: inout GraphicsContext) {
        let left = CGRect(x: 4, y: 14, width: 29, height: 39)
        let right = CGRect(x: 39, y: 14, width: 29, height: 39)
        drawWindow(left, focused: progress < 0.5, in: &context)
        drawWindow(right, focused: progress >= 0.5, in: &context)
        drawCursor(
            at: CGPoint(x: 20 + 33 * progress, y: 34),
            in: &context
        )
    }

    private func drawFocusEdge(in context: inout GraphicsContext) {
        let geometry = StatusMenuControlRoutedGeometry(direction: phase.direction)
        drawRoutedDisplays(geometry, in: &context)
        for rect in geometry.sourceWindows {
            drawRoutedWindow(rect, in: &context)
        }
        for rect in geometry.destinationWindows {
            drawRoutedWindow(rect, in: &context)
        }
        drawFocusRing(routedFocusRect(in: geometry), in: &context)
        drawArrow(from: geometry.arrowStart, to: geometry.arrowEnd, in: &context)
    }

    private func drawMouseToFocused(in context: inout GraphicsContext) {
        let left = CGRect(x: 4, y: 14, width: 29, height: 39)
        let right = CGRect(x: 39, y: 14, width: 29, height: 39)
        drawWindow(left, focused: progress < 0.12, in: &context)
        drawWindow(right, focused: progress >= 0.12, in: &context)
        let cursorProgress = min(max((progress - 0.25) / 0.75, 0), 1)
        drawCursor(
            at: CGPoint(x: 20 + 33 * cursorProgress, y: 36),
            in: &context
        )
    }

    private func drawFollowMonitor(in context: inout GraphicsContext) {
        let leftDisplay = CGRect(x: 2, y: 12, width: 31, height: 46)
        let rightDisplay = CGRect(x: 39, y: 12, width: 31, height: 46)
        drawDisplay(leftDisplay, active: progress < 0.55, in: &context)
        drawDisplay(rightDisplay, active: progress >= 0.55, in: &context)
        drawWindow(
            CGRect(x: 7 + 37 * progress, y: 21, width: 21, height: 23),
            focused: true,
            in: &context
        )
        for index in 0 ..< 2 {
            context.fill(
                Path(ellipseIn: CGRect(x: 12 + CGFloat(index) * 9, y: 49, width: 4, height: 4)),
                with: .color(index == (progress < 0.55 ? 0 : 1) ? accent : tertiary.opacity(0.45))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: 49 + CGFloat(index) * 9, y: 49, width: 4, height: 4)),
                with: .color(index == 1 && progress >= 0.55 ? accent : tertiary.opacity(0.45))
            )
        }
    }

    private func drawMoveEdge(in context: inout GraphicsContext) {
        let geometry = StatusMenuControlRoutedGeometry(direction: phase.direction)
        drawRoutedDisplays(geometry, in: &context)
        for (index, rect) in geometry.sourceWindows.enumerated() where index != 1 {
            drawRoutedWindow(rect, in: &context)
        }
        for (index, rect) in geometry.destinationWindows.enumerated() where index != 0 {
            drawRoutedWindow(rect, in: &context)
        }
        let movingWindow = interpolatedRect(
            from: geometry.sourceWindows[1],
            to: geometry.destinationWindows[0],
            progress: progress
        )
        drawRoutedWindow(movingWindow, in: &context)
        drawFocusRing(movingWindow, in: &context)
        drawArrow(from: geometry.arrowStart, to: geometry.arrowEnd, in: &context)
    }

    private func drawMouseWarp(in context: inout GraphicsContext) {
        let leftDisplay = CGRect(x: 2, y: 13, width: 31, height: 43)
        let rightDisplay = CGRect(x: 39, y: 13, width: 31, height: 43)
        drawDisplay(leftDisplay, active: false, in: &context)
        drawDisplay(rightDisplay, active: false, in: &context)
        let cursorX = progress < 0.5
            ? 20 + 12 * (progress / 0.5)
            : 41 + 12 * ((progress - 0.5) / 0.5)
        drawCursor(at: CGPoint(x: cursorX, y: 34), in: &context)
        drawArrow(from: CGPoint(x: 31, y: 47), to: CGPoint(x: 42, y: 47), in: &context)
    }

    private func drawHiddenMenuIcons(in context: inout GraphicsContext) {
        let bar = CGRect(x: 5, y: 13, width: 62, height: 17)
        context.fill(
            Path(roundedRect: bar, cornerRadius: 4),
            with: .color(secondary.opacity(0.16))
        )
        for index in 0 ..< 5 {
            context.fill(
                Path(ellipseIn: CGRect(x: 11 + CGFloat(index) * 10, y: 19, width: 5, height: 5)),
                with: .color(index < 2 ? secondary.opacity(0.65) : tertiary.opacity(0.22))
            )
        }
        let symbol = context.resolve(Image(systemName: "eye.slash.fill"))
        context.draw(symbol, at: CGPoint(x: 36, y: 48))
    }

    private func drawRoutedDisplays(
        _ geometry: StatusMenuControlRoutedGeometry,
        in context: inout GraphicsContext
    ) {
        drawDisplay(geometry.sourceDisplay, active: false, in: &context)
        drawDisplay(geometry.destinationDisplay, active: false, in: &context)
    }

    private func drawRoutedWindow(_ rect: CGRect, in context: inout GraphicsContext) {
        let path = Path(roundedRect: rect, cornerRadius: 2)
        context.fill(path, with: .color(window.opacity(0.92)))
        context.stroke(path, with: .color(tertiary.opacity(0.58)), lineWidth: 0.7)
        var titleBar = Path()
        titleBar.move(to: CGPoint(x: rect.minX, y: rect.minY + min(4.5, rect.height * 0.45)))
        titleBar.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + min(4.5, rect.height * 0.45)))
        context.stroke(titleBar, with: .color(tertiary.opacity(0.32)), lineWidth: 0.7)
    }

    private func drawFocusRing(_ rect: CGRect, in context: inout GraphicsContext) {
        let path = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3)
        context.fill(path, with: .color(accent.opacity(0.14)))
        context.stroke(path, with: .color(accent), lineWidth: 2)
    }

    private func routedFocusRect(in geometry: StatusMenuControlRoutedGeometry) -> CGRect {
        if progress < 0.32 {
            return interpolatedRect(
                from: geometry.sourceWindows[0],
                to: geometry.sourceWindows[1],
                progress: smoothed(progress / 0.32)
            )
        }
        if progress < 0.48 {
            return geometry.sourceWindows[1]
        }
        if progress < 0.84 {
            return interpolatedRect(
                from: geometry.sourceWindows[1],
                to: geometry.destinationWindows[0],
                progress: smoothed((progress - 0.48) / 0.36)
            )
        }
        return geometry.destinationWindows[0]
    }

    private func interpolatedRect(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private func smoothed(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }

    private func drawWindow(
        _ rect: CGRect,
        focused: Bool,
        in context: inout GraphicsContext
    ) {
        let path = Path(roundedRect: rect, cornerRadius: 4)
        context.fill(path, with: .color(window.opacity(0.9)))
        context.stroke(
            path,
            with: .color(focused ? accent : tertiary.opacity(0.55)),
            lineWidth: focused ? 2.4 : 1
        )
        var titleBar = Path()
        titleBar.move(to: CGPoint(x: rect.minX, y: rect.minY + 8))
        titleBar.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 8))
        context.stroke(titleBar, with: .color(tertiary.opacity(0.35)), lineWidth: 1)
    }

    private func drawDisplay(
        _ rect: CGRect,
        active: Bool,
        in context: inout GraphicsContext
    ) {
        let path = Path(roundedRect: rect, cornerRadius: 4)
        context.fill(path, with: .color(window.opacity(0.72)))
        context.stroke(
            path,
            with: .color(active ? accent : tertiary.opacity(0.6)),
            lineWidth: active ? 2.2 : 1
        )
    }

    private func drawContent(in rect: CGRect, in context: inout GraphicsContext) {
        for index in 0 ..< 3 {
            let line = CGRect(
                x: rect.minX,
                y: rect.minY + CGFloat(index) * 7,
                width: rect.width * (index == 2 ? 0.58 : 1),
                height: 3
            )
            context.fill(
                Path(roundedRect: line, cornerRadius: 1.5),
                with: .color(secondary.opacity(0.3))
            )
        }
    }

    private func drawCursor(at point: CGPoint, in context: inout GraphicsContext) {
        var cursor = Path()
        cursor.move(to: CGPoint(x: point.x - 4, y: point.y - 7))
        cursor.addLine(to: CGPoint(x: point.x + 5, y: point.y + 1))
        cursor.addLine(to: CGPoint(x: point.x, y: point.y + 2))
        cursor.addLine(to: CGPoint(x: point.x + 3, y: point.y + 8))
        cursor.addLine(to: CGPoint(x: point.x, y: point.y + 9))
        cursor.addLine(to: CGPoint(x: point.x - 3, y: point.y + 3))
        cursor.addLine(to: CGPoint(x: point.x - 6, y: point.y + 6))
        cursor.closeSubpath()
        context.fill(cursor, with: .color(label))
        context.stroke(cursor, with: .color(window), lineWidth: 1)
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: inout GraphicsContext
    ) {
        var arrow = Path()
        arrow.move(to: start)
        arrow.addLine(to: end)
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = max((deltaX * deltaX + deltaY * deltaY).squareRoot(), 1)
        let unitX = deltaX / length
        let unitY = deltaY / length
        let base = CGPoint(x: end.x - unitX * 4, y: end.y - unitY * 4)
        let perpendicular = CGPoint(x: -unitY * 3, y: unitX * 3)
        arrow.move(
            to: CGPoint(
                x: base.x + perpendicular.x,
                y: base.y + perpendicular.y
            )
        )
        arrow.addLine(to: end)
        arrow.addLine(
            to: CGPoint(
                x: base.x - perpendicular.x,
                y: base.y - perpendicular.y
            )
        )
        context.stroke(
            arrow,
            with: .color(accent.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}
