// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

private enum TabRailMetrics {
    static let trackWidth: CGFloat = 10
    static let totalWidth: CGFloat = trackWidth
    static let hitWidth: CGFloat = 22
    static let trackCornerRadius: CGFloat = 5
    static let segmentCornerRadius: CGFloat = 2.5
    static let preferredSegmentHeight: CGFloat = 28
    static let minimumSegmentHeight: CGFloat = 2
    static let preferredSegmentGap: CGFloat = 4
    static let minimumSegmentGap: CGFloat = 0
    static let minVisibleIntersection: CGFloat = 10
    static let minimumRailHeight: CGFloat = 8
    static let segmentWidth: CGFloat = 3
    static let segmentVerticalInset: CGFloat = 2
    static let trackEndInset: CGFloat = 6
    static let trackBorderWidth: CGFloat = 0.5
    static let hoverCardSize = CGSize(width: 260, height: 52)
    static let hoverCardGap: CGFloat = 8

    static func selectedColor(hovered: Bool) -> NSColor {
        let baseAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.86
        return NSColor.controlAccentColor.withAlphaComponent(min(1, baseAlpha + (hovered ? 0.1 : 0)))
    }

    static func unselectedColor(hovered: Bool, railHovered: Bool) -> NSColor {
        let baseAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.82 : 0.58
        let hoverAlpha: CGFloat = hovered ? 0.24 : (railHovered ? 0.08 : 0)
        return NSColor.labelColor.withAlphaComponent(min(0.92, baseAlpha + hoverAlpha))
    }

    static var hoverColor: NSColor {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.2 : 0.1
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }

    static var trackBorderColor: NSColor {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.28
        return NSColor.separatorColor.withAlphaComponent(alpha)
    }
}

enum TabRailOrderingPolicy {
    static func shouldOrderFront(
        forceOrdering: Bool,
        wasVisible: Bool,
        lastActiveWindowId: Int?,
        activeWindowId: Int?
    ) -> Bool {
        forceOrdering || !wasVisible || lastActiveWindowId != activeWindowId
    }
}

enum TabRailOwner: Hashable {
    case niriColumn(NodeId)
    case dwindleTile(DwindleTileId)

    fileprivate var surfaceIdentifier: String {
        switch self {
        case let .niriColumn(id):
            "niri-column-\(id.uuid.uuidString)"
        case let .dwindleTile(id):
            "dwindle-tile-\(id.uuidString)"
        }
    }
}

struct TabRailTabInfo: Equatable {
    let visualIndex: Int
    let token: WindowToken?
    let windowId: Int?
    let appName: String?
    let title: String?
    let isActive: Bool

    var accessibilityLabel: String {
        let ordinal = "Tab \(visualIndex + 1)"
        switch (title?.nilIfEmpty, appName?.nilIfEmpty) {
        case let (title?, appName?):
            return "\(ordinal), \(title), \(appName)"
        case let (title?, nil):
            return "\(ordinal), \(title)"
        case let (nil, appName?):
            return "\(ordinal), \(appName)"
        case (nil, nil):
            return ordinal
        }
    }
}

struct TabRailInfo: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let owner: TabRailOwner
    let plannedSeq: UInt64
    let tileFrame: CGRect
    let visibleTileFrame: CGRect
    let tabCount: Int
    let activeVisualIndex: Int
    let activeWindowId: Int?
    let tabs: [TabRailTabInfo]

    var key: TabRailKey {
        TabRailKey(workspaceId: workspaceId, owner: owner)
    }

    init(
        workspaceId: WorkspaceDescriptor.ID,
        owner: TabRailOwner,
        plannedSeq: UInt64,
        tileFrame: CGRect,
        visibleTileFrame: CGRect? = nil,
        tabCount: Int,
        activeVisualIndex: Int,
        activeWindowId: Int?,
        tabs: [TabRailTabInfo]? = nil
    ) {
        self.workspaceId = workspaceId
        self.owner = owner
        self.plannedSeq = plannedSeq
        self.tileFrame = tileFrame
        self.visibleTileFrame = visibleTileFrame ?? tileFrame
        self.tabCount = max(0, tabCount)
        self.activeVisualIndex = activeVisualIndex
        self.activeWindowId = activeWindowId
        self.tabs = tabs ?? Self.defaultTabs(tabCount: tabCount, activeVisualIndex: activeVisualIndex)
    }

    var normalizedTabs: [TabRailTabInfo] {
        let metadataByIndex = Dictionary(
            tabs.map { ($0.visualIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.defaultTabs(
            tabCount: tabCount,
            activeVisualIndex: activeVisualIndex
        ).map { fallback in
            metadataByIndex[fallback.visualIndex] ?? fallback
        }
    }

    private static func defaultTabs(tabCount: Int, activeVisualIndex: Int) -> [TabRailTabInfo] {
        guard tabCount > 0 else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return (0 ..< tabCount).map { visualIndex in
            TabRailTabInfo(
                visualIndex: visualIndex,
                token: nil,
                windowId: nil,
                appName: nil,
                title: nil,
                isActive: visualIndex == clampedActiveVisualIndex
            )
        }
    }
}

struct TabRailKey: Hashable {
    let workspaceId: WorkspaceDescriptor.ID
    let owner: TabRailOwner
}

struct TabRailLayout: Equatable {
    struct Item: Equatable {
        let visualIndex: Int
        let hitRect: CGRect
        let pillRect: CGRect
    }

    static let empty = TabRailLayout(railRect: .zero, barRect: .zero, items: [])

    let railRect: CGRect
    let barRect: CGRect
    let items: [Item]

    private init(railRect: CGRect, barRect: CGRect, items: [Item]) {
        self.railRect = railRect
        self.barRect = barRect
        self.items = items
    }

    init(tabCount: Int, bounds: CGRect) {
        guard tabCount > 0,
              bounds.width > 0,
              bounds.height >= TabRailMetrics.minimumRailHeight
        else {
            self = .empty
            return
        }

        let segmentGap = Self.segmentGap(tabCount: tabCount, availableHeight: bounds.height)
        let segmentHeight = Self.segmentHeight(
            tabCount: tabCount,
            availableHeight: bounds.height,
            segmentGap: segmentGap
        )
        guard segmentHeight > 0 else {
            self = .empty
            return
        }

        let totalHeight = Self.totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        let railY = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        let railRect = CGRect(x: bounds.minX, y: railY, width: bounds.width, height: min(bounds.height, totalHeight))
        let visualRailRect = Self.visualRailRect(in: railRect)
        let barRect = CGRect(
            x: visualRailRect.minX,
            y: visualRailRect.minY,
            width: TabRailMetrics.trackWidth,
            height: visualRailRect.height
        )

        var items: [Item] = []
        items.reserveCapacity(tabCount)

        for visualIndex in 0 ..< tabCount {
            let y = railRect.maxY
                - CGFloat(visualIndex + 1) * segmentHeight
                - CGFloat(visualIndex) * segmentGap
            let hitRect = CGRect(
                x: railRect.minX,
                y: y,
                width: railRect.width,
                height: segmentHeight
            ).intersection(railRect)
            let pillRect = CGRect(
                x: barRect.minX,
                y: hitRect.minY + TabRailMetrics.segmentVerticalInset,
                width: barRect.width,
                height: max(0, hitRect.height - TabRailMetrics.segmentVerticalInset * 2)
            )
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            items.append(Item(visualIndex: visualIndex, hitRect: hitRect, pillRect: pillRect))
        }

        self.railRect = railRect
        self.barRect = barRect
        self.items = items
    }

    static func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 0, availableHeight >= TabRailMetrics.minimumRailHeight else { return 0 }
        let segmentGap = segmentGap(tabCount: tabCount, availableHeight: availableHeight)
        let segmentHeight = segmentHeight(
            tabCount: tabCount,
            availableHeight: availableHeight,
            segmentGap: segmentGap
        )
        guard segmentHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(
            availableHeight,
            totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        )
    }

    static func visualRailRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - TabRailMetrics.totalWidth,
            y: bounds.minY,
            width: TabRailMetrics.totalWidth,
            height: bounds.height
        )
    }

    private static func totalHeight(tabCount: Int, segmentHeight: CGFloat, segmentGap: CGFloat) -> CGFloat {
        CGFloat(tabCount) * segmentHeight + CGFloat(max(0, tabCount - 1)) * segmentGap
    }

    private static func segmentGap(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 1 else { return 0 }
        let preferredHeight = totalHeight(
            tabCount: tabCount,
            segmentHeight: TabRailMetrics.preferredSegmentHeight,
            segmentGap: TabRailMetrics.preferredSegmentGap
        )
        guard preferredHeight > availableHeight else {
            return TabRailMetrics.preferredSegmentGap
        }
        let scale = max(0, availableHeight / preferredHeight)
        return max(
            TabRailMetrics.minimumSegmentGap,
            min(TabRailMetrics.preferredSegmentGap, TabRailMetrics.preferredSegmentGap * scale)
        )
    }

    private static func segmentHeight(
        tabCount: Int,
        availableHeight: CGFloat,
        segmentGap: CGFloat
    ) -> CGFloat {
        let totalGapHeight = CGFloat(max(0, tabCount - 1)) * segmentGap
        let availableForSegments = max(0, availableHeight - totalGapHeight)
        let fitHeight = availableForSegments / CGFloat(tabCount)
        guard fitHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(TabRailMetrics.preferredSegmentHeight, fitHeight)
    }
}

enum TabRailSegmentGeometry {
    static let inactiveHeightRatio: CGFloat = 0.67

    static func rect(
        sourceRect: CGRect,
        trackBounds: CGRect,
        width: CGFloat,
        selected: Bool,
        scale: CGFloat
    ) -> CGRect {
        let height = aligned(
            sourceRect.height * (selected ? 1 : inactiveHeightRatio),
            scale: scale
        )
        let horizontalGeometry = pixelAlignedHorizontalGeometry(
            trackBounds: trackBounds,
            width: width,
            scale: scale
        )
        return CGRect(
            x: horizontalGeometry.x,
            y: aligned(sourceRect.midY - height / 2, scale: scale),
            width: horizontalGeometry.width,
            height: height
        )
    }

    static func packedHeight(
        sourceRects: [Int: CGRect],
        selectedVisualIndex: Int,
        verticalMargin: CGFloat,
        endInset: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let orderedRects = sourceRects.sorted { $0.value.midY < $1.value.midY }
        guard !orderedRects.isEmpty else { return 0 }

        let sourceGaps = zip(orderedRects, orderedRects.dropFirst()).map { lower, upper in
            max(0, upper.value.minY - lower.value.maxY - verticalMargin * 2)
        }
        let slotGap = sourceGaps.min() ?? 0
        let markerHeight = orderedRects.reduce(CGFloat.zero) { result, item in
            result + aligned(
                item.value.height * (item.key == selectedVisualIndex ? 1 : inactiveHeightRatio),
                scale: scale
            )
        }
        return markerHeight
            + CGFloat(max(0, orderedRects.count - 1)) * (verticalMargin * 2 + slotGap)
            + endInset * 2
    }

    static func equallyPaddedRects(
        sourceRects: [Int: CGRect],
        trackBounds: CGRect,
        width: CGFloat,
        selectedVisualIndex: Int,
        verticalMargin: CGFloat,
        scale: CGFloat
    ) -> [Int: CGRect] {
        let orderedRects = sourceRects.sorted { $0.value.midY < $1.value.midY }
        guard !orderedRects.isEmpty else { return [:] }

        let sourceGaps = zip(orderedRects, orderedRects.dropFirst()).map { lower, upper in
            max(0, upper.value.minY - lower.value.maxY - verticalMargin * 2)
        }
        let slotGap = sourceGaps.min() ?? 0
        let markerHeights = orderedRects.map { visualIndex, sourceRect in
            aligned(
                sourceRect.height * (visualIndex == selectedVisualIndex ? 1 : inactiveHeightRatio),
                scale: scale
            )
        }
        let totalHeight = markerHeights.reduce(0, +)
            + CGFloat(orderedRects.count) * verticalMargin * 2
            + CGFloat(max(0, orderedRects.count - 1)) * slotGap
        var cursorY = trackBounds.midY - totalHeight / 2
        let horizontalGeometry = pixelAlignedHorizontalGeometry(
            trackBounds: trackBounds,
            width: width,
            scale: scale
        )
        var result: [Int: CGRect] = [:]
        result.reserveCapacity(orderedRects.count)

        for ((visualIndex, _), markerHeight) in zip(orderedRects, markerHeights) {
            result[visualIndex] = CGRect(
                x: horizontalGeometry.x,
                y: aligned(cursorY + verticalMargin, scale: scale),
                width: horizontalGeometry.width,
                height: markerHeight
            )
            cursorY += markerHeight + verticalMargin * 2 + slotGap
        }
        return result
    }

    private static func pixelAlignedHorizontalGeometry(
        trackBounds: CGRect,
        width: CGFloat,
        scale: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        guard scale > 0 else {
            return (trackBounds.midX - width / 2, width)
        }

        let trackPixelWidth = Int((trackBounds.width * scale).rounded())
        var segmentPixelWidth = max(1, Int((width * scale).rounded()))
        // Matching pixel-width parity keeps both edges crisp without shifting the segment off-center.
        if trackPixelWidth.isMultiple(of: 2) != segmentPixelWidth.isMultiple(of: 2) {
            if segmentPixelWidth < trackPixelWidth {
                segmentPixelWidth += 1
            } else if segmentPixelWidth > 1 {
                segmentPixelWidth -= 1
            }
        }

        let alignedWidth = CGFloat(segmentPixelWidth) / scale
        let alignedX = (trackBounds.midX * scale - CGFloat(segmentPixelWidth) / 2).rounded() / scale
        return (alignedX, alignedWidth)
    }

    private static func aligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}

enum TabRailHoverCardPlacement {
    static func frame(
        railFrame: CGRect,
        itemRect: CGRect,
        cardSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let itemCenterY = railFrame.minY + itemRect.midY
        let leftX = railFrame.minX - gap - cardSize.width
        let rightX = railFrame.maxX + gap
        let x = leftX >= visibleFrame.minX ? leftX : min(rightX, visibleFrame.maxX - cardSize.width)
        let unclampedY = itemCenterY - cardSize.height / 2
        let y = min(
            max(unclampedY, visibleFrame.minY),
            max(visibleFrame.minY, visibleFrame.maxY - cardSize.height)
        )
        return CGRect(
            origin: CGPoint(x: max(visibleFrame.minX, x), y: y),
            size: cardSize
        )
    }
}

@MainActor
final class TabRailManager {
    typealias SelectionHandler = (TabRailInfo, Int, WindowToken?) -> Void

    static let tabIndicatorWidth: CGFloat = TabRailMetrics.totalWidth

    var onSelect: SelectionHandler?

    private var railWindows: [TabRailKey: TabRailWindow] = [:]
    private var railInfos: [TabRailKey: TabRailInfo] = [:]

    func updateRails(_ infos: [TabRailInfo], forceOrdering: Bool = false) {
        var desiredKeys = Set<TabRailKey>()
        desiredKeys.reserveCapacity(infos.count)
        for info in infos where info.tabCount > 0 {
            desiredKeys.insert(info.key)
            railInfos[info.key] = info
            if railWindows[info.key] != nil || Self.isRenderable(visibleTileFrame: info.visibleTileFrame) {
                updateRail(info, forceOrdering: forceOrdering)
            }
        }

        let staleWindowKeys = railWindows.keys.filter { !desiredKeys.contains($0) }
        for key in staleWindowKeys {
            railWindows.removeValue(forKey: key)?.close()
        }
        let staleInfoKeys = railInfos.keys.filter { !desiredKeys.contains($0) }
        for key in staleInfoKeys {
            railInfos.removeValue(forKey: key)
        }
    }

    func applyAnimationGeometry(
        _ commands: [TabRailGeometryCommand],
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) {
        for command in commands {
            if let workspaceId, command.key.workspaceId != workspaceId {
                continue
            }
            if let window = railWindows[command.key] {
                window.updateAnimationGeometry(command)
                continue
            }
            guard Self.isRenderable(visibleTileFrame: command.visibleTileFrame),
                  let info = railInfos[command.key]
            else {
                continue
            }
            let presentedInfo = TabRailInfo(
                workspaceId: info.workspaceId,
                owner: info.owner,
                plannedSeq: info.plannedSeq,
                tileFrame: command.tileFrame,
                visibleTileFrame: command.visibleTileFrame,
                tabCount: info.tabCount,
                activeVisualIndex: info.activeVisualIndex,
                activeWindowId: info.activeWindowId,
                tabs: info.tabs
            )
            railInfos[command.key] = presentedInfo
            updateRail(presentedInfo, forceOrdering: false)
        }
    }

    func existingWindow(for key: TabRailKey) -> NSWindow? {
        railWindows[key]
    }

    private func updateRail(_ info: TabRailInfo, forceOrdering: Bool) {
        let key = info.key
        let window = railWindows[key] ?? {
            let window = TabRailWindow(owner: info.owner, workspaceId: info.workspaceId)
            window.onSelect = { [weak self] info, visualIndex, token in
                self?.onSelect?(info, visualIndex, token)
            }
            railWindows[key] = window
            return window
        }()
        window.update(info: info, forceOrdering: forceOrdering)
    }

    func removeAll() {
        for (_, window) in railWindows {
            window.close()
        }
        railWindows.removeAll()
        railInfos.removeAll()
    }

    fileprivate static func isRenderable(visibleTileFrame: CGRect) -> Bool {
        !visibleTileFrame.isNull
            && visibleTileFrame.width >= TabRailMetrics.minVisibleIntersection
            && visibleTileFrame.height >= TabRailMetrics.minVisibleIntersection
    }
}

@MainActor
private final class TabRailWindow: NSPanel {
    private let railView: TabRailView
    private let hoverCard: TabRailHoverCardWindow
    private let surfaceID: String
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var lastFrame: CGRect?
    private var lastActiveWindowId: Int?
    private var currentInfo: TabRailInfo?
    private var animationGeometryNeedsAccessibilityRefresh = false
    private var registeredSurfaceWindowNumber: Int?
    private var accessibilityDisplayObserver: NSObjectProtocol?

    var onSelect: ((TabRailInfo, Int, WindowToken?) -> Void)?

    init(owner: TabRailOwner, workspaceId: WorkspaceDescriptor.ID) {
        surfaceID = Self.surfaceID(workspaceId: workspaceId, owner: owner)
        railView = TabRailView(frame: .zero)
        hoverCard = TabRailHoverCardWindow()

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        railView.onSelect = { [weak self] visualIndex in
            guard let self, let currentInfo else { return }
            let token = currentInfo.tabs.first(where: { $0.visualIndex == visualIndex })?.token
            self.onSelect?(currentInfo, visualIndex, token)
        }
        railView.onHoverChange = { [weak self] tab, itemRect in
            self?.updateHoverCard(tab: tab, itemRect: itemRect)
        }
        contentView = railView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak railView, weak hoverCard] _ in
            Task { @MainActor [weak railView, weak hoverCard] in
                railView?.refreshAppearance()
                hoverCard?.refreshAppearance()
            }
        }
    }

    override func close() {
        hoverCard.hide()
        if let accessibilityDisplayObserver {
            NotificationCenter.default.removeObserver(accessibilityDisplayObserver)
            self.accessibilityDisplayObserver = nil
        }
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
        super.close()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(info: TabRailInfo, forceOrdering: Bool) {
        currentInfo = info
        let clampedActiveVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        railView.update(tabs: info.normalizedTabs, activeVisualIndex: clampedActiveVisualIndex)

        let frame = Self.railFrame(for: info.visibleTileFrame, tabCount: info.tabCount)
        guard frame.width > 1, frame.height > 1 else {
            hoverCard.hide()
            orderOut(nil)
            lastFrame = nil
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }

        let accessibilityGeometryChanged = animationGeometryNeedsAccessibilityRefresh || self.frame != frame
        if lastFrame != frame || self.frame != frame {
            setFrame(frame, display: false)
            railView.frame = CGRect(origin: .zero, size: frame.size)
            lastFrame = frame
        }

        if accessibilityGeometryChanged {
            railView.refreshAccessibilityFrames()
        }
        animationGeometryNeedsAccessibilityRefresh = false

        let wasVisible = isVisible
        if TabRailOrderingPolicy.shouldOrderFront(
            forceOrdering: forceOrdering,
            wasVisible: wasVisible,
            lastActiveWindowId: lastActiveWindowId,
            activeWindowId: info.activeWindowId
        ) {
            orderFront(nil)
        }
        syncSurfaceRegistration()
        lastActiveWindowId = info.activeWindowId
    }

    func updateAnimationGeometry(_ command: TabRailGeometryCommand) {
        guard let currentInfo, currentInfo.key == command.key else { return }
        let frame = Self.railFrame(for: command.visibleTileFrame, tabCount: currentInfo.tabCount)
        guard frame.width > 1, frame.height > 1 else {
            if isVisible {
                orderOut(nil)
            }
            if registeredSurfaceWindowNumber != nil {
                surfaceCoordinator.unregister(id: surfaceID)
                registeredSurfaceWindowNumber = nil
            }
            lastFrame = nil
            return
        }
        guard frame != lastFrame || frame != self.frame else { return }

        animationGeometryNeedsAccessibilityRefresh = true
        if frame.size == self.frame.size {
            SkyLight.shared.transactionMove(
                UInt32(windowNumber),
                origin: ScreenCoordinateSpace.toWindowServer(rect: frame).origin
            )
        } else {
            railView.performWithoutAccessibilityGeometryUpdates {
                setFrame(frame, display: false)
                railView.frame = CGRect(origin: .zero, size: frame.size)
                railView.needsDisplay = true
            }
        }
        lastFrame = frame

        guard !isVisible else { return }
        orderFront(nil)
        syncSurfaceRegistration()
        if let targetWid = currentInfo.activeWindowId {
            SkyLight.shared.orderWindow(UInt32(windowNumber), relativeTo: UInt32(targetWid))
        }
    }

    private func updateHoverCard(tab: TabRailTabInfo?, itemRect: CGRect?) {
        guard let tab, let itemRect, let currentInfo, isVisible else {
            hoverCard.hide()
            return
        }
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            hoverCard.hide()
            return
        }
        let cardFrame = TabRailHoverCardPlacement.frame(
            railFrame: frame,
            itemRect: itemRect,
            cardSize: TabRailMetrics.hoverCardSize,
            visibleFrame: screenFrame,
            gap: TabRailMetrics.hoverCardGap
        )
        hoverCard.show(tab: tab, tabCount: currentInfo.tabCount, frame: cardFrame)
    }

    private static func railFrame(for visibleTileFrame: CGRect, tabCount: Int) -> CGRect {
        guard tabCount > 0,
              TabRailManager.isRenderable(visibleTileFrame: visibleTileFrame)
        else {
            return .zero
        }
        let width = max(TabRailMetrics.hitWidth, TabRailMetrics.totalWidth)
        let height = TabRailLayout.fittedHeight(tabCount: tabCount, availableHeight: visibleTileFrame.height)
        guard height > 1 else { return .zero }
        let x = visibleTileFrame.minX - (width - TabRailMetrics.totalWidth)
        let y = visibleTileFrame.minY + (visibleTileFrame.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func syncSurfaceRegistration() {
        let currentWindowNumber = windowNumber
        guard currentWindowNumber > 0 else {
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }
        guard registeredSurfaceWindowNumber != currentWindowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: currentWindowNumber,
            frameProvider: { [weak self] in
                self?.lastFrame
            },
            visibilityProvider: { [weak self] in
                self?.isVisible == true && self?.lastFrame != nil
            },
            policy: SurfacePolicy(
                kind: .tabRail,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = currentWindowNumber
    }

    private static func surfaceID(workspaceId: WorkspaceDescriptor.ID, owner: TabRailOwner) -> String {
        "tab-rail-\(workspaceId.uuidString)-\(owner.surfaceIdentifier)"
    }
}

@MainActor
private final class TabRailHoverCardWindow: NSPanel {
    private let effectView = NSVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: TabRailMetrics.hoverCardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(iconView)
        effectView.addSubview(titleLabel)
        effectView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
        refreshAppearance()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(tab: TabRailTabInfo, tabCount: Int, frame: CGRect) {
        let app = tab.token.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        iconView.image = app?.icon ?? NSImage(named: NSImage.applicationIconName)
        titleLabel.stringValue = tab.title?.nilIfEmpty
            ?? tab.appName?.nilIfEmpty
            ?? "Untitled window"
        let appName = tab.appName?.nilIfEmpty ?? app?.localizedName?.nilIfEmpty ?? "Window"
        detailLabel.stringValue = "\(appName) · Tab \(tab.visualIndex + 1) of \(tabCount)"
        setFrame(frame, display: false)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effectView.layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        effectView.layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        effectView.layer?.borderColor = TabRailMetrics.trackBorderColor.cgColor
        titleLabel.textColor = .labelColor
        detailLabel.textColor = .secondaryLabelColor
    }
}

private final class TabRailTrackView: NSVisualEffectView {
    private let overlayView = TabRailTrackOverlayView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = TabRailMetrics.trackCornerRadius
        layer?.masksToBounds = true
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func update(
        layout: TabRailLayout,
        activeVisualIndex: Int,
        hoveredVisualIndex: Int?,
        railHovered: Bool
    ) {
        overlayView.update(
            layout: layout,
            activeVisualIndex: activeVisualIndex,
            hoveredVisualIndex: hoveredVisualIndex,
            railHovered: railHovered
        )
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = reduceTransparency ? .windowBackground : .hudWindow
        blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        overlayView.refreshAppearance()
    }
}

private final class TabRailTrackOverlayView: NSView {
    private static let selectionAnimationDuration: CFTimeInterval = 0.25

    private var railLayout = TabRailLayout.empty
    private var activeVisualIndex = 0
    private var hoveredVisualIndex: Int?
    private var railHovered = false
    private var segmentLayers: [Int: CAShapeLayer] = [:]
    private var hasRenderedSegments = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSegmentLayers(
            animateSelectionChange: false,
            preserveRunningPathAnimation: false,
            preserveRunningColorAnimation: false
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func update(
        layout: TabRailLayout,
        activeVisualIndex: Int,
        hoveredVisualIndex: Int?,
        railHovered: Bool
    ) {
        let activeChanged = hasRenderedSegments && self.activeVisualIndex != activeVisualIndex
        let hoverChanged = self.hoveredVisualIndex != hoveredVisualIndex || self.railHovered != railHovered
        let layoutChanged = railLayout != layout
        let previousIndices = Set(railLayout.items.map(\.visualIndex))
        let nextIndices = Set(layout.items.map(\.visualIndex))

        railLayout = layout
        self.activeVisualIndex = activeVisualIndex
        self.hoveredVisualIndex = hoveredVisualIndex
        self.railHovered = railHovered

        let layersChanged = previousIndices != nextIndices
        if layersChanged {
            rebuildSegmentLayers()
        }
        let geometryStable = !layoutChanged && !layersChanged
        updateSegmentLayers(
            animateSelectionChange: activeChanged
                && geometryStable
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            preserveRunningPathAnimation: !activeChanged && geometryStable,
            preserveRunningColorAnimation: !activeChanged && !hoverChanged && geometryStable
        )
        hasRenderedSegments = !layout.items.isEmpty
        needsDisplay = true
    }

    func refreshAppearance() {
        updateSegmentLayers(
            animateSelectionChange: false,
            preserveRunningPathAnimation: false,
            preserveRunningColorAnimation: false
        )
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let localBounds = bounds.insetBy(
            dx: TabRailMetrics.trackBorderWidth / 2,
            dy: TabRailMetrics.trackBorderWidth / 2
        )
        if railHovered {
            TabRailMetrics.hoverColor.setFill()
            NSBezierPath(
                roundedRect: localBounds,
                xRadius: TabRailMetrics.trackCornerRadius,
                yRadius: TabRailMetrics.trackCornerRadius
            ).fill()
        }

        TabRailMetrics.trackBorderColor.setStroke()
        let border = NSBezierPath(
            roundedRect: localBounds,
            xRadius: TabRailMetrics.trackCornerRadius,
            yRadius: TabRailMetrics.trackCornerRadius
        )
        border.lineWidth = TabRailMetrics.trackBorderWidth
        border.stroke()
    }

    private func rebuildSegmentLayers() {
        for segmentLayer in segmentLayers.values {
            segmentLayer.removeAllAnimations()
            segmentLayer.removeFromSuperlayer()
        }
        segmentLayers.removeAll(keepingCapacity: true)

        for item in railLayout.items {
            let segmentLayer = CAShapeLayer()
            segmentLayer.actions = [
                "path": NSNull(),
                "fillColor": NSNull(),
                "bounds": NSNull(),
                "position": NSNull()
            ]
            layer?.addSublayer(segmentLayer)
            segmentLayers[item.visualIndex] = segmentLayer
        }
    }

    private func updateSegmentLayers(
        animateSelectionChange: Bool,
        preserveRunningPathAnimation: Bool,
        preserveRunningColorAnimation: Bool
    ) {
        guard !railLayout.items.isEmpty else { return }
        let clampedActiveIndex = min(max(0, activeVisualIndex), railLayout.items.count - 1)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let sourceRects = Dictionary(
            uniqueKeysWithValues: railLayout.items.map { item in
                (
                    item.visualIndex,
                    item.pillRect.offsetBy(
                        dx: -railLayout.barRect.minX,
                        dy: -railLayout.barRect.minY
                    )
                )
            }
        )
        let targetRects = TabRailSegmentGeometry.equallyPaddedRects(
            sourceRects: sourceRects,
            trackBounds: bounds,
            width: TabRailMetrics.segmentWidth,
            selectedVisualIndex: clampedActiveIndex,
            verticalMargin: TabRailMetrics.segmentVerticalInset,
            scale: scale
        )
        let startTime = CACurrentMediaTime()

        for item in railLayout.items {
            guard let segmentLayer = segmentLayers[item.visualIndex],
                  let rect = targetRects[item.visualIndex]
            else { continue }
            let selected = item.visualIndex == clampedActiveIndex
            let hovered = hoveredVisualIndex == item.visualIndex
            let targetPath = CGPath(
                roundedRect: rect,
                cornerWidth: TabRailMetrics.segmentCornerRadius,
                cornerHeight: TabRailMetrics.segmentCornerRadius,
                transform: nil
            )
            let color = selected
                ? TabRailMetrics.selectedColor(hovered: hovered)
                : TabRailMetrics.unselectedColor(hovered: hovered, railHovered: railHovered)
            let targetColor = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            let presentation = segmentLayer.presentation()
            let fromPath = presentation?.path ?? segmentLayer.path
            let fromColor = presentation?.fillColor ?? segmentLayer.fillColor

            if !preserveRunningPathAnimation {
                segmentLayer.removeAnimation(forKey: "selection.path")
            }
            if !preserveRunningColorAnimation {
                segmentLayer.removeAnimation(forKey: "selection.color")
            }
            segmentLayer.frame = bounds
            segmentLayer.contentsScale = scale
            segmentLayer.path = targetPath
            segmentLayer.fillColor = targetColor

            guard animateSelectionChange, let fromPath, let fromColor else { continue }
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            let pathAnimation = CABasicAnimation(keyPath: "path")
            pathAnimation.fromValue = fromPath
            pathAnimation.toValue = targetPath
            pathAnimation.duration = Self.selectionAnimationDuration
            pathAnimation.beginTime = segmentLayer.convertTime(startTime, from: nil)
            pathAnimation.timingFunction = timing
            segmentLayer.add(pathAnimation, forKey: "selection.path")

            let colorAnimation = CABasicAnimation(keyPath: "fillColor")
            colorAnimation.fromValue = fromColor
            colorAnimation.toValue = targetColor
            colorAnimation.duration = Self.selectionAnimationDuration
            colorAnimation.beginTime = segmentLayer.convertTime(startTime, from: nil)
            colorAnimation.timingFunction = timing
            segmentLayer.add(colorAnimation, forKey: "selection.color")
        }
    }
}

private final class TabRailView: NSView {
    private var tabs: [TabRailTabInfo] = []
    private let trackView = TabRailTrackView(frame: .zero)

    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateTrackView()
            if !isHovered {
                onHoverChange?(nil, nil)
            }
        }
    }

    private var hoveredVisualIndex: Int? {
        didSet {
            guard oldValue != hoveredVisualIndex else { return }
            updateTrackView()
            notifyHoverChange()
        }
    }

    private var tracking: NSTrackingArea?
    private var accessibilityTabElements: [TabRailAccessibilityElement] = []
    private var suppressAccessibilityGeometryUpdates = false

    private var tabCount: Int {
        tabs.count
    }

    private var activeVisualIndex = 0

    var onSelect: ((Int) -> Void)?
    var onHoverChange: ((TabRailTabInfo?, CGRect?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(trackView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int) {
        let metadataChanged = !Self.hasSameAccessibilityMetadata(self.tabs, tabs)
        let tabsChanged = self.tabs != tabs
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        self.tabs = tabs
        self.activeVisualIndex = activeVisualIndex
        updateTrackView()

        if metadataChanged {
            refreshAccessibilityElements()
        } else if activeChanged {
            updateAccessibilitySelection(postNotification: true)
        }
        if tabsChanged || activeChanged {
            notifyHoverChange()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackView()
        if !suppressAccessibilityGeometryUpdates {
            refreshAccessibilityElements()
        }
    }

    func performWithoutAccessibilityGeometryUpdates(_ body: () -> Void) {
        suppressAccessibilityGeometryUpdates = true
        body()
        suppressAccessibilityGeometryUpdates = false
    }

    func refreshAppearance() {
        trackView.refreshAppearance()
        updateTrackView()
    }

    func refreshAccessibilityFrames() {
        let items = currentLayout().items
        guard items.count == accessibilityTabElements.count,
              zip(accessibilityTabElements, items).allSatisfy({ pair in
                  pair.0.visualIndex == pair.1.visualIndex
              })
        else {
            refreshAccessibilityElements()
            NSAccessibility.post(element: self, notification: .layoutChanged)
            return
        }
        for (element, item) in zip(accessibilityTabElements, items) {
            element.updateScreenFrame(screenFrame(for: item.hitRect))
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = nextTracking
        addTrackingArea(nextTracking)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoveredVisualIndex(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredVisualIndex(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        hoveredVisualIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let visualIndex = visualIndex(at: point) else { return }
        onSelect?(visualIndex)
    }

    private func visualIndex(at point: CGPoint) -> Int? {
        guard tabCount > 0 else { return nil }
        for item in currentLayout().items {
            if item.hitRect.contains(point) {
                return item.visualIndex
            }
        }
        return nil
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityTabElements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityTabElements.filter(\.isSelected)
    }

    override func accessibilityLabel() -> String? {
        "Window tabs"
    }

    override func accessibilityValue() -> Any? {
        guard tabCount > 0 else { return "No tabs" }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return "Tab \(clampedActiveVisualIndex + 1) of \(tabCount) selected"
    }

    override func accessibilityHelp() -> String? {
        "Click a segment to select that tab."
    }

    private func hoverVisualIndex(at point: CGPoint) -> Int? {
        let layout = currentLayout()
        guard tabCount > 0, layout.railRect.contains(point) else { return nil }
        return layout.items.min {
            abs($0.hitRect.midY - point.y) < abs($1.hitRect.midY - point.y)
        }?.visualIndex
    }

    private func updateHoveredVisualIndex(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredVisualIndex = hoverVisualIndex(at: point)
    }

    private func updateTrackView() {
        let layout = currentLayout()
        let sourceRects = Dictionary(
            uniqueKeysWithValues: layout.items.map { ($0.visualIndex, $0.pillRect) }
        )
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let packedHeight = TabRailSegmentGeometry.packedHeight(
            sourceRects: sourceRects,
            selectedVisualIndex: activeVisualIndex,
            verticalMargin: TabRailMetrics.segmentVerticalInset,
            endInset: TabRailMetrics.trackEndInset,
            scale: scale
        )
        let trackHeight = min(layout.barRect.height, packedHeight)
        trackView.frame = CGRect(
            x: layout.barRect.minX,
            y: layout.barRect.midY - trackHeight / 2,
            width: layout.barRect.width,
            height: trackHeight
        )
        trackView.update(
            layout: layout,
            activeVisualIndex: activeVisualIndex,
            hoveredVisualIndex: hoveredVisualIndex,
            railHovered: isHovered
        )
    }

    private func notifyHoverChange() {
        guard isHovered,
              let hoveredVisualIndex,
              let tab = tabs.first(where: { $0.visualIndex == hoveredVisualIndex }),
              let item = currentLayout().items.first(where: { $0.visualIndex == hoveredVisualIndex })
        else {
            onHoverChange?(nil, nil)
            return
        }
        onHoverChange?(tab, item.hitRect)
    }

    private func currentLayout() -> TabRailLayout {
        TabRailLayout(tabCount: tabCount, bounds: bounds)
    }

    private func refreshAccessibilityElements() {
        let layout = currentLayout()
        let tabsByVisualIndex = Dictionary(tabs.map { ($0.visualIndex, $0) }, uniquingKeysWith: { first, _ in first })
        let existingElements = Dictionary(
            accessibilityTabElements.map { ($0.visualIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        accessibilityTabElements = layout.items.compactMap { item in
            guard let tab = tabsByVisualIndex[item.visualIndex] else {
                return nil
            }
            let screenFrame = screenFrame(for: item.hitRect)
            if let element = existingElements[item.visualIndex] {
                element.update(tab: tab, screenFrame: screenFrame)
                return element
            }
            let element = TabRailAccessibilityElement(
                parent: self,
                tab: tab,
                screenFrame: screenFrame,
                pressAction: { [weak self] visualIndex in
                    _ = self?.performAccessibilitySelection(visualIndex)
                }
            )
            return element
        }
        updateAccessibilitySelection(postNotification: false)
    }

    private func updateAccessibilitySelection(postNotification: Bool) {
        for element in accessibilityTabElements {
            element.updateSelected(element.visualIndex == activeVisualIndex, postNotification: postNotification)
        }
    }

    fileprivate func performAccessibilitySelection(_ visualIndex: Int) -> Bool {
        guard tabs.contains(where: { $0.visualIndex == visualIndex }) else { return false }
        onSelect?(visualIndex)
        return true
    }

    private func screenFrame(for rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    private static func hasSameAccessibilityMetadata(
        _ lhs: [TabRailTabInfo],
        _ rhs: [TabRailTabInfo]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.visualIndex == right.visualIndex,
                  left.windowId == right.windowId,
                  left.appName == right.appName,
                  left.title == right.title
            else {
                return false
            }
        }
        return true
    }
}

private final class TabRailAccessibilityElement: NSAccessibilityElement {
    private weak var parentElement: AnyObject?
    private var tab: TabRailTabInfo
    private var screenFrame: CGRect
    private let pressAction: (Int) -> Void
    private(set) var isSelected: Bool

    var visualIndex: Int {
        tab.visualIndex
    }

    init(
        parent: AnyObject,
        tab: TabRailTabInfo,
        screenFrame: CGRect,
        pressAction: @escaping (Int) -> Void
    ) {
        parentElement = parent
        self.tab = tab
        self.screenFrame = screenFrame
        self.pressAction = pressAction
        isSelected = tab.isActive
        super.init()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func accessibilityLabel() -> String? {
        tab.accessibilityLabel
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityParent() -> Any? {
        parentElement
    }

    override func accessibilityFrame() -> NSRect {
        screenFrame
    }

    override func isAccessibilityEnabled() -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        pressAction(tab.visualIndex)
        return true
    }

    func update(tab: TabRailTabInfo, screenFrame: CGRect) {
        self.tab = tab
        self.screenFrame = screenFrame
    }

    func updateScreenFrame(_ screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    func updateSelected(_ selected: Bool, postNotification: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        if postNotification {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
