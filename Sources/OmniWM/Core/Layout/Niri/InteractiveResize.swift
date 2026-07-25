// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct ResizeEdge: OptionSet, Hashable {
    let rawValue: UInt32

    static let top = ResizeEdge(rawValue: 0b0001)
    static let bottom = ResizeEdge(rawValue: 0b0010)
    static let left = ResizeEdge(rawValue: 0b0100)
    static let right = ResizeEdge(rawValue: 0b1000)
    static let all: ResizeEdge = [.top, .bottom, .left, .right]

    var hasHorizontal: Bool {
        !intersection([.left, .right]).isEmpty
    }

    var hasVertical: Bool {
        !intersection([.top, .bottom]).isEmpty
    }

    @MainActor
    var cursor: NSCursor {
        let hasLeft = contains(.left)
        let hasRight = contains(.right)
        let hasTop = contains(.top)
        let hasBottom = contains(.bottom)

        if (hasTop && hasLeft) || (hasBottom && hasRight) {
            return Self.makeDiagonalNWSECursor()
        }
        if (hasTop && hasRight) || (hasBottom && hasLeft) {
            return Self.makeDiagonalNESWCursor()
        }

        if hasLeft || hasRight {
            return NSCursor.resizeLeftRight
        }
        if hasTop || hasBottom {
            return NSCursor.resizeUpDown
        }

        return NSCursor.arrow
    }

    @MainActor
    private static func makeDiagonalNWSECursor() -> NSCursor {
        if let image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Resize diagonally"
        ) {
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }
        return NSCursor.crosshair
    }

    @MainActor
    private static func makeDiagonalNESWCursor() -> NSCursor {
        if let image = NSImage(
            systemSymbolName: "arrow.up.right.and.arrow.down.left",
            accessibilityDescription: "Resize diagonally"
        ) {
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }
        return NSCursor.crosshair
    }
}

struct InteractiveResize {
    enum WindowBaseline {
        case fixedPixels(CGFloat)
        case weight(CGFloat)
    }

    let windowId: NodeId

    let workspaceId: WorkspaceDescriptor.ID

    let originalContainerSpan: CGFloat?

    let originalWindowBaseline: WindowBaseline?

    let edges: ResizeEdge

    let startMouseLocation: CGPoint

    let columnIndex: Int

    let orientation: Monitor.Orientation

    let originalViewOffset: CGFloat?
}

struct ResizeHitTestResult {
    let windowHandle: WindowHandle

    let nodeId: NodeId

    let edges: ResizeEdge

    let columnIndex: Int

    let windowFrame: CGRect
}

struct ResizeConfiguration {
    var edgeThreshold: CGFloat = 8.0
    var minWindowWeight: CGFloat = 0.3
    var maxWindowWeight: CGFloat = 3.0

    static let `default` = ResizeConfiguration()
}

struct LayoutGaps {
    var horizontal: CGFloat
    var vertical: CGFloat
    var outer: OuterGaps

    struct OuterGaps {
        var left: CGFloat
        var right: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        static let zero = OuterGaps(left: 0, right: 0, top: 0, bottom: 0)

        init(left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }
    }

    init(horizontal: CGFloat = 8.0, vertical: CGFloat = 8.0, outer: OuterGaps = .zero) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.outer = outer
    }

    var asTuple: (horizontal: CGFloat, vertical: CGFloat) {
        (horizontal: horizontal, vertical: vertical)
    }
}
