// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum StatusMenuControlPreviewDirection: Int, CaseIterable {
    case right
    case down
    case left
    case up
}

struct StatusMenuControlPreviewPhase: Equatable {
    static let cycleDuration: TimeInterval = 2.4
    static let staticEnd = StatusMenuControlPreviewPhase(direction: .right, progress: 1)
    private static let directionCycle: [StatusMenuControlPreviewDirection] = [.right, .down, .left, .up]

    let direction: StatusMenuControlPreviewDirection
    let progress: CGFloat

    init(direction: StatusMenuControlPreviewDirection, progress: CGFloat) {
        self.direction = direction
        self.progress = min(max(progress, 0), 1)
    }

    init(timeInterval: TimeInterval) {
        let cyclePosition = timeInterval / Self.cycleDuration
        let completedCycles = floor(cyclePosition)
        let directionCount = Self.directionCycle.count
        let rawDirectionIndex = Int(completedCycles) % directionCount
        let directionIndex = rawDirectionIndex >= 0
            ? rawDirectionIndex
            : rawDirectionIndex + directionCount
        let cycle = cyclePosition - completedCycles
        let rawProgress = min(max((cycle - 0.14) / 0.58, 0), 1)
        let easedProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)

        direction = Self.directionCycle[directionIndex]
        progress = CGFloat(easedProgress)
    }
}

struct StatusMenuControlRoutedGeometry: Equatable {
    let sourceDisplay: CGRect
    let destinationDisplay: CGRect
    let sourceWindows: [CGRect]
    let destinationWindows: [CGRect]
    let arrowStart: CGPoint
    let arrowEnd: CGPoint

    init(direction: StatusMenuControlPreviewDirection) {
        switch direction {
        case .right:
            self = Self.right
        case .down:
            self = Self.down
        case .left:
            self = Self.left
        case .up:
            self = Self.up
        }
    }

    private static let right = Self(
        sourceDisplay: CGRect(x: 1, y: 10, width: 32, height: 50),
        destinationDisplay: CGRect(x: 39, y: 10, width: 32, height: 50),
        sourceWindows: [
            CGRect(x: 5, y: 17, width: 10, height: 15),
            CGRect(x: 19, y: 17, width: 10, height: 15),
            CGRect(x: 5, y: 39, width: 10, height: 13),
            CGRect(x: 19, y: 39, width: 10, height: 13)
        ],
        destinationWindows: [
            CGRect(x: 43, y: 17, width: 10, height: 15),
            CGRect(x: 57, y: 17, width: 10, height: 15),
            CGRect(x: 43, y: 39, width: 10, height: 13),
            CGRect(x: 57, y: 39, width: 10, height: 13)
        ],
        arrowStart: CGPoint(x: 31, y: 35),
        arrowEnd: CGPoint(x: 41, y: 35)
    )

    private static let down = Self(
        sourceDisplay: CGRect(x: 10, y: 1, width: 52, height: 32),
        destinationDisplay: CGRect(x: 10, y: 39, width: 52, height: 32),
        sourceWindows: [
            CGRect(x: 17, y: 5, width: 16, height: 10),
            CGRect(x: 17, y: 19, width: 16, height: 10),
            CGRect(x: 40, y: 5, width: 15, height: 10),
            CGRect(x: 40, y: 19, width: 15, height: 10)
        ],
        destinationWindows: [
            CGRect(x: 17, y: 43, width: 16, height: 10),
            CGRect(x: 17, y: 57, width: 16, height: 10),
            CGRect(x: 40, y: 43, width: 15, height: 10),
            CGRect(x: 40, y: 57, width: 15, height: 10)
        ],
        arrowStart: CGPoint(x: 36, y: 31),
        arrowEnd: CGPoint(x: 36, y: 41)
    )

    private static let left = right.mirroredHorizontally()
    private static let up = down.mirroredVertically()

    private init(
        sourceDisplay: CGRect,
        destinationDisplay: CGRect,
        sourceWindows: [CGRect],
        destinationWindows: [CGRect],
        arrowStart: CGPoint,
        arrowEnd: CGPoint
    ) {
        self.sourceDisplay = sourceDisplay
        self.destinationDisplay = destinationDisplay
        self.sourceWindows = sourceWindows
        self.destinationWindows = destinationWindows
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
    }

    private func mirroredHorizontally() -> Self {
        Self(
            sourceDisplay: mirrorHorizontally(sourceDisplay),
            destinationDisplay: mirrorHorizontally(destinationDisplay),
            sourceWindows: sourceWindows.map(mirrorHorizontally),
            destinationWindows: destinationWindows.map(mirrorHorizontally),
            arrowStart: CGPoint(x: 72 - arrowStart.x, y: arrowStart.y),
            arrowEnd: CGPoint(x: 72 - arrowEnd.x, y: arrowEnd.y)
        )
    }

    private func mirroredVertically() -> Self {
        Self(
            sourceDisplay: mirrorVertically(sourceDisplay),
            destinationDisplay: mirrorVertically(destinationDisplay),
            sourceWindows: sourceWindows.map(mirrorVertically),
            destinationWindows: destinationWindows.map(mirrorVertically),
            arrowStart: CGPoint(x: arrowStart.x, y: 72 - arrowStart.y),
            arrowEnd: CGPoint(x: arrowEnd.x, y: 72 - arrowEnd.y)
        )
    }

    private func mirrorHorizontally(_ rect: CGRect) -> CGRect {
        CGRect(x: 72 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func mirrorVertically(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 72 - rect.maxY, width: rect.width, height: rect.height)
    }
}
