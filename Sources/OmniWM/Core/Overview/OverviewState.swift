// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum OverviewState {
    case closed
    case opening(progress: Double)
    case open
    case closing(targetWindow: WindowHandle?, progress: Double)

    var isOpen: Bool {
        switch self {
        case .open,
             .opening,
             .closing:
            return true
        case .closed:
            return false
        }
    }

    var isAnimating: Bool {
        switch self {
        case .opening,
             .closing:
            return true
        case .open,
             .closed:
            return false
        }
    }
}

struct OverviewWorkspaceSection {
    let workspaceId: WorkspaceDescriptor.ID
    let name: String
    var windows: [OverviewWindowItem]
    var sectionFrame: CGRect
    var labelFrame: CGRect
    var gridFrame: CGRect
    var isActive: Bool
}

struct OverviewWindowItem {
    let handle: WindowHandle
    let windowId: Int
    let workspaceId: WorkspaceDescriptor.ID
    let title: String
    let appName: String
    let appIcon: CGImage?
    let originalFrame: CGRect
    let overviewFrame: CGRect
    let matchesSearch: Bool
    var groupCount = 1

    var closeButtonFrame: CGRect {
        let size: CGFloat = 20
        let padding: CGFloat = 6
        return CGRect(
            x: overviewFrame.maxX - size - padding,
            y: overviewFrame.maxY - size - padding,
            width: size,
            height: size
        )
    }

    func interpolatedFrame(progress: Double) -> CGRect {
        let t = CGFloat(progress)
        return CGRect(
            x: originalFrame.origin.x + (overviewFrame.origin.x - originalFrame.origin.x) * t,
            y: originalFrame.origin.y + (overviewFrame.origin.y - originalFrame.origin.y) * t,
            width: originalFrame.width + (overviewFrame.width - originalFrame.width) * t,
            height: originalFrame.height + (overviewFrame.height - originalFrame.height) * t
        )
    }
}

struct OverviewLayout {
    struct WindowHit {
        let window: OverviewWindowItem
        let isCloseButton: Bool
    }

    private struct WindowPosition {
        let sectionIndex: Int
        let windowIndex: Int
    }

    private(set) var workspaceSections: [OverviewWorkspaceSection]

    var searchBarFrame: CGRect
    var totalContentHeight: CGFloat
    var scrollOffset: CGFloat
    var scale: CGFloat
    var niriColumnDropZonesByWorkspace: [WorkspaceDescriptor.ID: [OverviewColumnDropZone]]
    var dragTarget: OverviewDragTarget?
    var niriColumnsByWorkspace: [WorkspaceDescriptor.ID: [OverviewNiriColumn]]
    private var windowPositionByHandle: [WindowHandle: WindowPosition]

    init() {
        workspaceSections = []
        searchBarFrame = .zero
        totalContentHeight = 0
        scrollOffset = 0
        scale = 1.0
        niriColumnDropZonesByWorkspace = [:]
        dragTarget = nil
        niriColumnsByWorkspace = [:]
        windowPositionByHandle = [:]
    }

    var allWindows: [OverviewWindowItem] {
        workspaceSections.flatMap(\.windows)
    }

    mutating func replaceWorkspaceSections(_ sections: [OverviewWorkspaceSection]) {
        workspaceSections = sections
        rebuildWindowIndex()
    }

    mutating func updateGroupCounts(_ groupCountByHandle: [WindowHandle: Int]) {
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                let handle = workspaceSections[sectionIndex].windows[windowIndex].handle
                workspaceSections[sectionIndex].windows[windowIndex].groupCount = groupCountByHandle[handle] ?? 1
            }
        }
    }

    private mutating func rebuildWindowIndex() {
        windowPositionByHandle.removeAll(keepingCapacity: true)
        for sectionIndex in workspaceSections.indices {
            for windowIndex in workspaceSections[sectionIndex].windows.indices {
                let handle = workspaceSections[sectionIndex].windows[windowIndex].handle
                windowPositionByHandle[handle] = WindowPosition(sectionIndex: sectionIndex, windowIndex: windowIndex)
            }
        }
    }

    func windowAt(point: CGPoint) -> OverviewWindowItem? {
        windowHit(at: point)?.window
    }

    func windowHit(at point: CGPoint) -> WindowHit? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for section in workspaceSections {
            for window in section.windows where window.matchesSearch {
                if window.overviewFrame.contains(adjustedPoint) {
                    return WindowHit(
                        window: window,
                        isCloseButton: window.closeButtonFrame.contains(adjustedPoint)
                    )
                }
            }
        }
        return nil
    }

    func workspaceSection(at point: CGPoint) -> OverviewWorkspaceSection? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for section in workspaceSections {
            if section.sectionFrame.contains(adjustedPoint) {
                return section
            }
        }
        return nil
    }

    func columnDropZone(at point: CGPoint) -> OverviewColumnDropZone? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for (_, zones) in niriColumnDropZonesByWorkspace {
            for zone in zones where zone.frame.contains(adjustedPoint) {
                return zone
            }
        }
        return nil
    }

    func insertPosition(for window: OverviewWindowItem, at point: CGPoint) -> InsertPosition {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        return adjustedPoint.y > window.overviewFrame.midY ? .before : .after
    }

    func resolveDragTarget(at point: CGPoint, draggedHandle: WindowHandle?) -> OverviewDragTarget? {
        if let zone = columnDropZone(at: point) {
            return .niriColumnInsert(
                workspaceId: zone.workspaceId,
                insertIndex: zone.insertIndex
            )
        }

        if let window = windowAt(point: point) {
            guard window.handle != draggedHandle else { return nil }
            if niriColumnsByWorkspace[window.workspaceId] != nil {
                return .niriWindowInsert(
                    workspaceId: window.workspaceId,
                    targetHandle: window.handle,
                    position: insertPosition(for: window, at: point)
                )
            }
            return .workspaceMove(workspaceId: window.workspaceId)
        }

        if let section = workspaceSection(at: point) {
            return .workspaceMove(workspaceId: section.workspaceId)
        }

        return nil
    }

    func window(for handle: WindowHandle) -> OverviewWindowItem? {
        guard let position = windowPositionByHandle[handle],
              workspaceSections.indices.contains(position.sectionIndex),
              workspaceSections[position.sectionIndex].windows.indices.contains(position.windowIndex)
        else {
            return nil
        }
        return workspaceSections[position.sectionIndex].windows[position.windowIndex]
    }
}

struct OverviewNiriColumn: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let columnIndex: Int
    let frame: CGRect
    let windowHandles: [WindowHandle]
}

enum OverviewDragTarget: Equatable {
    case niriWindowInsert(
        workspaceId: WorkspaceDescriptor.ID,
        targetHandle: WindowHandle,
        position: InsertPosition
    )
    case niriColumnInsert(
        workspaceId: WorkspaceDescriptor.ID,
        insertIndex: Int
    )
    case workspaceMove(
        workspaceId: WorkspaceDescriptor.ID
    )
}

struct OverviewColumnDropZone: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let insertIndex: Int
    let frame: CGRect
}
