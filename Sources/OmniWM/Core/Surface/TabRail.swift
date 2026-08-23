// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

private enum TabRailMetrics {
    static let barThickness: CGFloat = 10
    static let spacing: CGFloat = 2
    static let totalWidth: CGFloat = barThickness + spacing
    static let hitWidth: CGFloat = 20
    static let cornerRadius: CGFloat = 3
    static let preferredSegmentHeight: CGFloat = 32
    static let minimumSegmentHeight: CGFloat = 2
    static let preferredSegmentGap: CGFloat = 6
    static let minimumSegmentGap: CGFloat = 0
    static let minVisibleIntersection: CGFloat = 10
    static let minimumRailHeight: CGFloat = 8
    static let activeSegmentWidth: CGFloat = 8
    static let inactiveSegmentWidth: CGFloat = 5
    static let hoveredSegmentWidth: CGFloat = 7
    static let segmentVerticalInset: CGFloat = 1
    static let edgeLineWidth: CGFloat = 1

    static var backgroundColor: NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return .windowBackgroundColor
        }
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.44
        return .black.withAlphaComponent(alpha)
    }

    static func selectedColor(hovered: Bool) -> NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.92
        return NSColor.controlAccentColor.withAlphaComponent(min(1.0, alpha + (hovered ? 0.06 : 0)))
    }

    static func unselectedColor(hovered: Bool, railHovered: Bool) -> NSColor {
        let baseAlpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.45
        let hoverAlpha: CGFloat = if hovered {
            0.2
        } else if railHovered {
            0.08
        } else {
            0
        }
        let alpha = min(0.9, baseAlpha + hoverAlpha)
        return NSColor.labelColor.withAlphaComponent(alpha)
    }

    static var hoverColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.22 : 0.14
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }

    static var gutterColor: NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return NSColor.separatorColor.withAlphaComponent(0.55)
        }
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.34 : 0.18
        return NSColor.black.withAlphaComponent(alpha)
    }

    static var edgeColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.86 : 0.42
        return NSColor.separatorColor.withAlphaComponent(alpha)
    }

    static var selectedStrokeColor: NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.9
        return NSColor.keyboardFocusIndicatorColor.withAlphaComponent(alpha)
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
    let activeVisualIndex: Int
    let activeWindowId: Int?
    let tabs: [TabRailTabInfo]

    var tabCount: Int {
        tabs.count
    }

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
        self.activeVisualIndex = activeVisualIndex
        self.activeWindowId = activeWindowId
        self.tabs = tabs ?? Self.defaultTabs(tabCount: tabCount, activeVisualIndex: activeVisualIndex)
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

    static let empty = TabRailLayout(railRect: .zero, items: [])

    let railRect: CGRect
    let items: [Item]

    private init(railRect: CGRect, items: [Item]) {
        self.railRect = railRect
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
                x: visualRailRect.minX,
                y: hitRect.minY + TabRailMetrics.segmentVerticalInset,
                width: visualRailRect.width,
                height: max(0, hitRect.height - TabRailMetrics.segmentVerticalInset * 2)
            )
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            items.append(Item(visualIndex: visualIndex, hitRect: hitRect, pillRect: pillRect))
        }

        self.railRect = railRect
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
        contentView = railView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak railView] _ in
            Task { @MainActor [weak railView] in
                railView?.needsDisplay = true
            }
        }
    }

    override func close() {
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
        railView.update(tabs: info.tabs, activeVisualIndex: clampedActiveVisualIndex)

        let frame = Self.railFrame(for: info.visibleTileFrame, tabCount: info.tabCount)
        guard frame.width > 1, frame.height > 1 else {
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
        if forceOrdering || !wasVisible {
            orderFront(nil)
        }
        syncSurfaceRegistration()

        if let targetWid = info.activeWindowId,
           forceOrdering || lastActiveWindowId != targetWid || !wasVisible
        {
            let wid = UInt32(windowNumber)
            SkyLight.shared.orderWindow(wid, relativeTo: UInt32(targetWid))
        }
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

private final class TabRailView: NSView {
    private var tabs: [TabRailTabInfo] = []

    private var isHovered = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    private var hoveredVisualIndex: Int? {
        didSet {
            if oldValue != hoveredVisualIndex {
                needsDisplay = true
            }
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

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int) {
        let metadataChanged = !Self.hasSameAccessibilityMetadata(self.tabs, tabs)
        let tabsChanged = self.tabs != tabs
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        self.tabs = tabs
        self.activeVisualIndex = activeVisualIndex

        if tabsChanged || activeChanged {
            needsDisplay = true
        }

        if metadataChanged {
            refreshAccessibilityElements()
        } else if activeChanged {
            updateAccessibilitySelection(postNotification: true)
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !suppressAccessibilityGeometryUpdates {
            refreshAccessibilityElements()
        }
    }

    func performWithoutAccessibilityGeometryUpdates(_ body: () -> Void) {
        suppressAccessibilityGeometryUpdates = true
        body()
        suppressAccessibilityGeometryUpdates = false
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

    override func draw(_: NSRect) {
        guard tabCount > 0 else { return }

        let layout = currentLayout()
        guard !layout.items.isEmpty else { return }
        let visualRailRect = TabRailLayout.visualRailRect(in: layout.railRect)

        fillRoundedRect(visualBarRect(in: visualRailRect), color: TabRailMetrics.backgroundColor)
        fillRect(gutterRect(in: visualRailRect), color: TabRailMetrics.gutterColor)
        fillRect(edgeRect(in: visualRailRect), color: TabRailMetrics.edgeColor)

        if isHovered {
            fillRoundedRect(visualRailRect, color: TabRailMetrics.hoverColor)
        }

        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)

        for item in layout.items {
            if item.visualIndex != clampedActiveVisualIndex {
                drawSegment(item, selected: false)
            }
        }

        if let selectedItem = layout.items.first(where: { $0.visualIndex == clampedActiveVisualIndex }) {
            drawSegment(selectedItem, selected: true)
        }
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

    private func visualBarRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX,
            y: railRect.minY,
            width: TabRailMetrics.barThickness,
            height: railRect.height
        )
    }

    private func gutterRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabRailMetrics.barThickness,
            y: railRect.minY,
            width: TabRailMetrics.spacing,
            height: railRect.height
        )
    }

    private func edgeRect(in railRect: CGRect) -> CGRect {
        CGRect(
            x: railRect.minX + TabRailMetrics.barThickness,
            y: railRect.minY + 1,
            width: TabRailMetrics.edgeLineWidth,
            height: max(0, railRect.height - 2)
        )
    }

    private func visualRectForSegment(_ item: TabRailLayout.Item, selected: Bool, hovered: Bool) -> CGRect {
        let segmentRect = item.pillRect
        let width = if selected {
            TabRailMetrics.activeSegmentWidth
        } else if hovered {
            TabRailMetrics.hoveredSegmentWidth
        } else {
            TabRailMetrics.inactiveSegmentWidth
        }
        let x = segmentRect.midX - width / 2
        return CGRect(
            x: x,
            y: segmentRect.origin.y,
            width: width,
            height: segmentRect.height
        )
    }

    private func drawSegment(_ item: TabRailLayout.Item, selected: Bool) {
        let hovered = hoveredVisualIndex == item.visualIndex
        let segmentRect = visualRectForSegment(item, selected: selected, hovered: hovered)
        guard segmentRect.width > 0, segmentRect.height > 0 else { return }
        let path = NSBezierPath(
            roundedRect: segmentRect,
            xRadius: TabRailMetrics.cornerRadius,
            yRadius: TabRailMetrics.cornerRadius
        )
        if selected {
            TabRailMetrics.selectedColor(hovered: hovered).setFill()
        } else {
            TabRailMetrics.unselectedColor(hovered: hovered, railHovered: isHovered).setFill()
        }
        path.fill()

        if selected {
            TabRailMetrics.selectedStrokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func fillRoundedRect(_ rect: CGRect, color: NSColor) {
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: TabRailMetrics.cornerRadius,
            yRadius: TabRailMetrics.cornerRadius
        ).fill()
    }

    private func fillRect(_ rect: CGRect, color: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill()
        NSBezierPath(rect: rect).fill()
    }

    private func updateHoveredVisualIndex(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredVisualIndex = visualIndex(at: point)
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
