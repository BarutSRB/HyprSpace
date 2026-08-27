// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct WorkspaceBarSplitLayout: Equatable {
    let activeFrame: CGRect
    let secondaryFrame: CGRect?
}

struct WorkspaceBarSplitAvailableWidths: Equatable {
    let active: CGFloat
    let secondary: CGFloat
}

private struct WorkspaceBarSplitMetrics {
    let frame: CGRect
    let activeAnchor: CGFloat
    let secondaryAnchor: CGFloat
    let availableActive: CGFloat
    let availableSecondary: CGFloat
    let inverted: Bool
}

struct WorkspaceBarGeometry: Equatable {
    static let notchGap: CGFloat = 8
    static let minimumSplitSideSpace: CGFloat = 60
    static let minimumIslandWidth: CGFloat = 40
    static func statsButtonAnchor(buttonFrame: CGRect) -> CGPoint {
        CGPoint(x: buttonFrame.midX, y: buttonFrame.minY)
    }

    let effectivePosition: WorkspaceBarPosition
    let menuBarHeight: CGFloat
    let barHeight: CGFloat
    let reservedTopInset: CGFloat

    static func resolve(
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        isVisible: Bool,
        menuBarHeight: CGFloat? = nil
    ) -> WorkspaceBarGeometry {
        let resolvedMenuBarHeight = menuBarHeight ?? self.menuBarHeight(for: monitor)
        let effectivePosition = effectivePosition(for: monitor, resolved: resolved)
        let barHeight = max(0, CGFloat(resolved.height))
        let reservedTopInset = isVisible && resolved.reserveLayoutSpace ? barHeight : 0

        return WorkspaceBarGeometry(
            effectivePosition: effectivePosition,
            menuBarHeight: resolvedMenuBarHeight,
            barHeight: barHeight,
            reservedTopInset: reservedTopInset
        )
    }

    func frame(
        fittingWidth: CGFloat,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> CGRect {
        let width = max(fittingWidth, Self.minimumIslandWidth)
        var x = monitor.frame.midX - width / 2
        var y = originY(for: monitor)

        x += CGFloat(resolved.xOffset)
        y += CGFloat(resolved.yOffset)

        return CGRect(x: x, y: y, width: width, height: barHeight)
    }

    func splitFrame(
        activeWidth: CGFloat,
        secondaryWidth: CGFloat?,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSplitLayout? {
        guard let metrics = splitMetrics(monitor: monitor, resolved: resolved) else { return nil }

        let zoneWidth = min(
            max(CGFloat(resolved.notchActiveZoneWidth), Self.minimumSplitSideSpace),
            metrics.availableActive
        )
        let y = originY(for: monitor)
        let activeSize = max(activeWidth, Self.minimumIslandWidth)
        var active = if activeSize <= zoneWidth {
            CGRect(
                x: metrics.activeAnchor - zoneWidth / 2 - activeSize / 2,
                y: y,
                width: activeSize,
                height: barHeight
            )
        } else {
            CGRect(
                x: metrics.activeAnchor - min(activeSize, metrics.availableActive),
                y: y,
                width: min(activeSize, metrics.availableActive),
                height: barHeight
            )
        }
        var secondary = secondaryWidth.map {
            CGRect(
                x: metrics.secondaryAnchor,
                y: y,
                width: min($0, metrics.availableSecondary),
                height: barHeight
            )
        }

        if metrics.inverted {
            active = Self.mirrored(active, in: metrics.frame)
            secondary = secondary.map { Self.mirrored($0, in: metrics.frame) }
        }

        let dx = CGFloat(resolved.xOffset)
        let dy = CGFloat(resolved.yOffset)
        return WorkspaceBarSplitLayout(
            activeFrame: active.offsetBy(dx: dx, dy: dy),
            secondaryFrame: secondary?.offsetBy(dx: dx, dy: dy)
        )
    }

    func splitAvailableWidths(
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSplitAvailableWidths? {
        guard let metrics = splitMetrics(monitor: monitor, resolved: resolved) else { return nil }
        return WorkspaceBarSplitAvailableWidths(
            active: metrics.availableActive,
            secondary: metrics.availableSecondary
        )
    }

    func originY(for monitor: Monitor) -> CGFloat {
        effectivePosition == .belowMenuBar ? monitor.visibleFrame.maxY - barHeight : monitor.visibleFrame.maxY
    }

    static func effectivePosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarPosition {
        if monitor.hasNotch,
           resolved.notchMode == .moveBelowMenuBar,
           resolved.position == .overlappingMenuBar
        {
            return .belowMenuBar
        }
        return resolved.position
    }

    static func menuBarHeight(for monitor: Monitor) -> CGFloat {
        let height = monitor.frame.maxY - monitor.visibleFrame.maxY
        return height > 0 ? height : 28
    }

    private func splitMetrics(
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSplitMetrics? {
        guard resolved.notchMode.isSplit else { return nil }

        let frame = monitor.frame
        let virtualNotch = frame.midX ... frame.midX
        let notch = monitor.hasNotch ? (monitor.notchRange ?? virtualNotch) : virtualNotch
        let inverted = resolved.notchMode == .splitActiveRight
        let oriented = inverted ? Self.mirrored(notch, in: frame) : notch
        let activeAnchor = oriented.lowerBound - Self.notchGap
        let secondaryAnchor = oriented.upperBound + Self.notchGap
        let availableActive = activeAnchor - frame.minX
        let availableSecondary = frame.maxX - secondaryAnchor
        guard availableActive >= Self.minimumSplitSideSpace,
              availableSecondary >= Self.minimumSplitSideSpace
        else {
            return nil
        }
        return WorkspaceBarSplitMetrics(
            frame: frame,
            activeAnchor: activeAnchor,
            secondaryAnchor: secondaryAnchor,
            availableActive: availableActive,
            availableSecondary: availableSecondary,
            inverted: inverted
        )
    }

    private static func mirroredX(_ x: CGFloat, in frame: CGRect) -> CGFloat {
        frame.minX + frame.maxX - x
    }

    private static func mirrored(_ range: ClosedRange<CGFloat>, in frame: CGRect) -> ClosedRange<CGFloat> {
        mirroredX(range.upperBound, in: frame) ... mirroredX(range.lowerBound, in: frame)
    }

    private static func mirrored(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: mirroredX(rect.maxX, in: frame), y: rect.minY, width: rect.width, height: rect.height)
    }
}
