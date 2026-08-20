// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum ColumnDisplay: Codable, Equatable, Sendable {
    case normal

    case tabbed
}

enum SizingMode: Codable, Equatable, Sendable {
    case normal

    case maximized

    case fullscreen
}

enum ProportionalSize: Codable, Equatable, Sendable {
    case proportion(CGFloat)

    case fixed(CGFloat)

    var value: CGFloat {
        switch self {
        case let .proportion(p): p
        case let .fixed(f): f
        }
    }

    var isProportion: Bool {
        if case .proportion = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    static let `default` = ProportionalSize.proportion(1.0)
}

enum WeightedSize: Codable, Equatable, Sendable {
    case auto(weight: CGFloat)

    case fixed(CGFloat)

    case preset(Int)

    var weight: CGFloat {
        switch self {
        case let .auto(w): w
        case .fixed,
             .preset: 0
        }
    }

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    var presetIndex: Int? {
        if case let .preset(index) = self { return index }
        return nil
    }

    static let `default` = WeightedSize.auto(weight: 1.0)
}

struct WindowSizeConstraints: Equatable, Sendable {
    var minSize: CGSize

    var maxSize: CGSize

    var isFixed: Bool

    init(minSize: CGSize, maxSize: CGSize, isFixed: Bool) {
        let normalizedMinWidth = Self.normalizedMinDimension(minSize.width)
        let normalizedMinHeight = Self.normalizedMinDimension(minSize.height)
        let normalizedMaxWidth = Self.normalizedMaxDimension(
            maxSize.width,
            minimum: normalizedMinWidth
        )
        let normalizedMaxHeight = Self.normalizedMaxDimension(
            maxSize.height,
            minimum: normalizedMinHeight
        )

        if isFixed {
            let fixedWidth = normalizedMaxWidth > 0 ? normalizedMaxWidth : normalizedMinWidth
            let fixedHeight = normalizedMaxHeight > 0 ? normalizedMaxHeight : normalizedMinHeight
            self.minSize = CGSize(width: fixedWidth, height: fixedHeight)
            self.maxSize = CGSize(width: fixedWidth, height: fixedHeight)
        } else {
            self.minSize = CGSize(width: normalizedMinWidth, height: normalizedMinHeight)
            self.maxSize = CGSize(width: normalizedMaxWidth, height: normalizedMaxHeight)
        }

        self.isFixed = isFixed
    }

    static let unconstrained = WindowSizeConstraints(
        minSize: CGSize(width: 1, height: 1),
        maxSize: .zero,
        isFixed: false
    )

    static func fixed(size: CGSize) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: size,
            maxSize: size,
            isFixed: true
        )
    }

    func normalized() -> WindowSizeConstraints {
        WindowSizeConstraints(minSize: minSize, maxSize: maxSize, isFixed: isFixed)
    }

    var hasMinWidth: Bool {
        minSize.width > 1
    }

    var hasMinHeight: Bool {
        minSize.height > 1
    }

    var hasMaxWidth: Bool {
        maxSize.width > 0
    }

    var hasMaxHeight: Bool {
        maxSize.height > 0
    }

    func clampHeight(_ height: CGFloat) -> CGFloat {
        var result = height
        if hasMinHeight {
            result = max(result, minSize.height)
        }
        if hasMaxHeight {
            result = min(result, maxSize.height)
        }
        return result
    }

    func clampWidth(_ width: CGFloat) -> CGFloat {
        var result = width
        if hasMinWidth {
            result = max(result, minSize.width)
        }
        if hasMaxWidth {
            result = min(result, maxSize.width)
        }
        return result
    }

    private static func normalizedMinDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return max(1, value)
    }

    private static func normalizedMaxDimension(_ value: CGFloat, minimum: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return max(value, minimum)
    }
}

struct PresetSize: Equatable {
    enum Kind: Equatable {
        case proportion(CGFloat)
        case fixed(CGFloat)

        var value: CGFloat {
            switch self {
            case let .proportion(p): p
            case let .fixed(f): f
            }
        }
    }

    let kind: Kind

    static func proportion(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .proportion(value))
    }

    static func fixed(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .fixed(value))
    }

    var asProportionalSize: ProportionalSize {
        switch kind {
        case let .proportion(p): .proportion(p)
        case let .fixed(f): .fixed(f)
        }
    }
}

struct NodeId: Hashable, Equatable {
    let uuid: UUID

    init() {
        uuid = UUID()
    }
}

class NiriNode {
    let id: NodeId
    weak var parent: NiriNode?
    private(set) var children: [NiriNode] = [] {
        didSet { invalidateChildrenCache() }
    }

    var size: CGFloat = 1.0

    var frame: CGRect?
    var renderedFrame: CGRect?

    init() {
        id = NodeId()
    }

    func invalidateChildrenCache() {
        parent?.invalidateChildrenCache()
    }

    func invalidateAxisSolveInputs() {
        parent?.invalidateAxisSolveInputs()
    }

    func findRoot() -> NiriRoot? {
        var current: NiriNode? = self
        while let node = current {
            if let root = node as? NiriRoot {
                return root
            }
            current = node.parent
        }
        return nil
    }

    func firstChild() -> NiriNode? {
        children.first
    }

    func lastChild() -> NiriNode? {
        children.last
    }

    func nextSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < parent.children.count else { return nil }
        return parent.children[nextIndex]
    }

    func prevSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        guard index > 0 else { return nil }
        return parent.children[index - 1]
    }

    func appendChild(_ child: NiriNode) {
        child.detach()
        child.parent = self
        children.append(child)
        findRoot()?.registerNode(child)
    }

    func insertBefore(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index)
        findRoot()?.registerNode(child)
    }

    func insertAfter(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index + 1)
        findRoot()?.registerNode(child)
    }

    func detach() {
        guard let parent else { return }
        let root = findRoot()
        parent.children.removeAll { $0 === self }
        self.parent = nil
        root?.unregisterNode(self)
    }

    func remove() {
        detach()
        children.removeAll()
    }

    func swapWith(_ sibling: NiriNode) {
        guard let parent,
              parent === sibling.parent,
              let myIndex = parent.children.firstIndex(where: { $0 === self }),
              let sibIndex = parent.children.firstIndex(where: { $0 === sibling })
        else {
            return
        }
        parent.children.swapAt(myIndex, sibIndex)
    }

    func swapChildren(_ child1: NiriNode, _ child2: NiriNode) {
        guard let idx1 = children.firstIndex(where: { $0 === child1 }),
              let idx2 = children.firstIndex(where: { $0 === child2 })
        else {
            return
        }
        children.swapAt(idx1, idx2)
    }

    func insertChild(_ child: NiriNode, at index: Int) {
        child.detach()
        child.parent = self
        let clampedIndex = max(0, min(index, children.count))
        children.insert(child, at: clampedIndex)
        findRoot()?.registerNode(child)
    }

    func findNode(by id: NodeId) -> NiriNode? {
        if self.id == id {
            return self
        }
        for child in children {
            if let found = child.findNode(by: id) {
                return found
            }
        }
        return nil
    }
}

class NiriContainer: NiriNode {
    var displayMode: ColumnDisplay = .normal

    private(set) var activeTileIdx: Int = 0

    var width: ProportionalSize = .default

    var cachedWidth: CGFloat = 0

    var presetWidthIdx: Int?

    var isFullWidth: Bool = false

    var savedWidth: ProportionalSize?

    var hasManualSingleWindowWidthOverride: Bool = false

    var height: ProportionalSize = .default

    var cachedHeight: CGFloat = 0

    var isFullHeight: Bool = false

    var savedHeight: ProportionalSize?

    var hasManualSingleWindowHeightOverride: Bool = false

    var moveAnimation: MoveAnimation?
    private var moveAnimationOrientation: Monitor.Orientation?

    var widthAnimation: SpringAnimation?
    var targetWidth: CGFloat?

    var settledWidth: CGFloat {
        targetWidth ?? cachedWidth
    }

    private var _cachedWindowNodes: [NiriWindow]?

    private(set) var axisSolveRevision: UInt64 = 0

    override init() {
        super.init()
    }

    override func invalidateChildrenCache() {
        axisSolveRevision &+= 1
        _cachedWindowNodes = nil
        super.invalidateChildrenCache()
    }

    override func invalidateAxisSolveInputs() {
        axisSolveRevision &+= 1
    }

    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return
        }

        let orientation: Monitor.Orientation
        let displacementValue: CGFloat
        if displacement.x != 0 {
            orientation = .horizontal
            displacementValue = displacement.x
        } else if displacement.y != 0 {
            orientation = .vertical
            displacementValue = displacement.y
        } else {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentValue = switch orientation {
        case .horizontal: currentOffset.x
        case .vertical: currentOffset.y
        }
        let currentVelocity = moveAnimationOrientation == orientation
            ? moveAnimation?.currentVelocity(at: now) ?? 0
            : 0
        let animation = SpringAnimation(
            from: 1,
            to: 0,
            initialVelocity: currentVelocity,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        moveAnimation = MoveAnimation(
            animation: animation,
            fromOffset: displacementValue + currentValue
        )
        moveAnimationOrientation = orientation
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        guard let animation = moveAnimation,
              let orientation = moveAnimationOrientation
        else {
            return .zero
        }
        let value = animation.currentOffset(at: time)
        return switch orientation {
        case .horizontal: CGPoint(x: value, y: 0)
        case .vertical: CGPoint(x: 0, y: value)
        }
    }

    func tickMoveAnimation(at time: TimeInterval) -> Bool {
        guard let anim = moveAnimation else { return false }
        if anim.isComplete(at: time) {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return false
        }
        return true
    }

    var hasMoveAnimationRunning: Bool {
        moveAnimation != nil
    }

    @discardableResult
    func offsetMoveAnimCurrent(
        _ offset: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard let anim = moveAnimation,
              moveAnimationOrientation == orientation
        else {
            return false
        }
        let now = CACurrentMediaTime()
        let value = anim.animation.value(at: now)
        if value > 0.001 {
            moveAnimation = MoveAnimation(
                animation: anim.animation,
                fromOffset: anim.fromOffset + offset / CGFloat(value)
            )
        }
        return true
    }

    @discardableResult
    func animateWidthTo(
        newWidth: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) -> Bool {
        guard animated else {
            cachedWidth = newWidth
            widthAnimation = nil
            targetWidth = nil
            return false
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentWidth = cachedWidth > 0 ? cachedWidth : newWidth
        let currentVel = widthAnimation?.velocity(at: now) ?? 0

        widthAnimation = SpringAnimation(
            from: Double(currentWidth),
            to: Double(newWidth),
            initialVelocity: currentVel,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        targetWidth = newWidth
        return true
    }

    func tickWidthAnimation(at time: TimeInterval) -> Bool {
        guard let anim = widthAnimation else { return false }

        let lowerEndpoint = min(CGFloat(anim.from), targetWidth ?? CGFloat(anim.from))
        cachedWidth = max(CGFloat(anim.value(at: time)), lowerEndpoint)

        if anim.isComplete(at: time) {
            if let target = targetWidth {
                cachedWidth = target
            }
            widthAnimation = nil
            targetWidth = nil
            return false
        }
        return true
    }

    var hasWidthAnimationRunning: Bool {
        widthAnimation != nil
    }

    func stopAnimations() {
        moveAnimation = nil
        moveAnimationOrientation = nil
        if let targetWidth {
            cachedWidth = targetWidth
        }
        widthAnimation = nil
        targetWidth = nil
    }

    private func resolveSpan(
        spec: ProportionalSize,
        isFull: Bool,
        availableSpace: CGFloat,
        gaps: CGFloat,
        minConstraint: CGFloat,
        maxConstraint: CGFloat?
    ) -> CGFloat {
        var result: CGFloat
        let effectiveSpec = isFull ? ProportionalSize.proportion(1.0) : spec
        switch effectiveSpec {
        case let .proportion(p):
            result = (availableSpace - gaps) * p - gaps
        case let .fixed(f):
            result = f
        }
        let effectiveMaxConstraint = maxConstraint.map { max($0, minConstraint) }
        if result < minConstraint { result = minConstraint }
        if let effectiveMaxConstraint, result > effectiveMaxConstraint { result = effectiveMaxConstraint }
        return result
    }

    func widthBounds(contentInset: CGFloat = 0) -> (min: CGFloat, max: CGFloat?) {
        var minWidth: CGFloat = 1
        var maxWidth: CGFloat?

        for window in windowNodes {
            let constraints = window.constraints.normalized()
            minWidth = max(minWidth, constraints.minSize.width)
            if constraints.hasMaxWidth {
                let candidateMax = constraints.maxSize.width
                maxWidth = min(maxWidth ?? candidateMax, candidateMax)
            }
        }

        return (
            minWidth + contentInset,
            maxWidth.map { max($0, minWidth) + contentInset }
        )
    }

    func heightBounds() -> (min: CGFloat, max: CGFloat?) {
        var minHeight: CGFloat = 1
        var maxHeight: CGFloat?

        for window in windowNodes {
            let constraints = window.constraints.normalized()
            minHeight = max(minHeight, constraints.minSize.height)
            if constraints.hasMaxHeight {
                let candidateMax = constraints.maxSize.height
                maxHeight = min(maxHeight ?? candidateMax, candidateMax)
            }
        }

        return (minHeight, maxHeight.map { max($0, minHeight) })
    }

    func clampedToWidthBounds(_ width: CGFloat, contentInset: CGFloat = 0) -> CGFloat {
        let bounds = widthBounds(contentInset: contentInset)
        let clamped = max(width, bounds.min)
        guard let maxWidth = bounds.max else { return clamped }
        return min(clamped, maxWidth)
    }

    func clampedToHeightBounds(_ height: CGFloat) -> CGFloat {
        let bounds = heightBounds()
        let clamped = max(height, bounds.min)
        guard let maxHeight = bounds.max else { return clamped }
        return min(clamped, maxHeight)
    }

    func resolveAndCacheWidth(
        workingAreaWidth: CGFloat,
        gaps: CGFloat,
        contentInset: CGFloat = 0
    ) {
        let bounds = widthBounds(contentInset: contentInset)
        cachedWidth = resolveSpan(
            spec: width,
            isFull: isFullWidth,
            availableSpace: workingAreaWidth,
            gaps: gaps,
            minConstraint: bounds.min,
            maxConstraint: bounds.max
        )
    }

    func resolveAndCacheHeight(workingAreaHeight: CGFloat, gaps: CGFloat) {
        let bounds = heightBounds()
        cachedHeight = resolveSpan(
            spec: height,
            isFull: isFullHeight,
            availableSpace: workingAreaHeight,
            gaps: gaps,
            minConstraint: bounds.min,
            maxConstraint: bounds.max
        )
    }

    func invalidateCachedPrimarySpan(orientation: Monitor.Orientation) {
        switch orientation {
        case .horizontal:
            cachedWidth = 0
            widthAnimation = nil
            targetWidth = nil
        case .vertical:
            cachedHeight = 0
        }
    }

    override var size: CGFloat {
        get { width.value }
        set {
            width = .proportion(newValue)
        }
    }

    var windowNodes: [NiriWindow] {
        if let cached = _cachedWindowNodes { return cached }
        let result = children.compactMap { $0 as? NiriWindow }
        _cachedWindowNodes = result
        return result
    }

    var isTabbed: Bool {
        displayMode == .tabbed
    }

    var activeWindow: NiriWindow? {
        let windows = windowNodes
        guard !windows.isEmpty else { return nil }
        let idx = activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        return windows[idx]
    }

    // Storage index 0 is the visual bottom of a column; overlay index 0 is the visual top.
    func visualTileIndex(forStorageTileIndex storageIndex: Int) -> Int? {
        let count = windowNodes.count
        guard storageIndex >= 0, storageIndex < count else { return nil }
        return count - 1 - storageIndex
    }

    func storageTileIndex(forVisualTileIndex visualIndex: Int) -> Int? {
        let count = windowNodes.count
        guard visualIndex >= 0, visualIndex < count else { return nil }
        return count - 1 - visualIndex
    }

    var activeVisualTileIdx: Int {
        visualTileIndex(forStorageTileIndex: activeTileIdx) ?? 0
    }

    func clampActiveTileIdx() {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = activeTileIdx.clamped(to: 0 ... (count - 1))
        }
    }

    func setActiveTileIdx(_ idx: Int) {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = idx.clamped(to: 0 ... (count - 1))
        }
    }

    func adjustActiveTileIdxForRemoval(of node: NiriNode) {
        let windows = windowNodes
        guard let idx = windows.firstIndex(where: { $0 === node }) else { return }
        if idx == activeTileIdx {
            if windows.count > 1, idx >= windows.count - 1 {
                activeTileIdx = max(0, idx - 1)
            }
        } else if idx < activeTileIdx {
            activeTileIdx = max(0, activeTileIdx - 1)
        }
    }
}

class NiriWindow: NiriNode {
    var token: WindowToken

    var sizingMode: SizingMode = .normal

    var height: WeightedSize = .default {
        didSet {
            if oldValue != height {
                invalidateAxisSolveInputs()
            }
        }
    }

    var savedHeight: WeightedSize?

    var windowWidth: WeightedSize = .default {
        didSet {
            if oldValue != windowWidth {
                invalidateAxisSolveInputs()
            }
        }
    }

    var constraints: WindowSizeConstraints = .unconstrained {
        didSet {
            if oldValue != constraints {
                invalidateAxisSolveInputs()
            }
        }
    }

    var resolvedHeight: CGFloat?

    var resolvedWidth: CGFloat?

    var heightFixedByConstraint: Bool = false

    var widthFixedByConstraint: Bool = false

    var lastFocusedTime: Date?

    var isHiddenInTabbedMode: Bool = false

    var moveXAnimation: MoveAnimation?
    var moveYAnimation: MoveAnimation?
    private(set) var moveYContainmentFrame: CGRect?

    init(token: WindowToken) {
        self.token = token
        super.init()
    }

    override var size: CGFloat {
        get {
            switch height {
            case let .auto(weight): weight
            case .fixed,
                 .preset: 1.0
            }
        }
        set {
            height = .auto(weight: newValue)
        }
    }

    var heightWeight: CGFloat {
        switch height {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    var widthWeight: CGFloat {
        switch windowWidth {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    var isFullscreen: Bool {
        sizingMode == .fullscreen
    }

    var isMaximized: Bool {
        sizingMode == .maximized
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        var offset = CGPoint.zero
        if let moveX = moveXAnimation {
            offset.x = moveX.currentOffset(at: time)
        }
        if let moveY = moveYAnimation {
            offset.y = moveY.currentOffset(at: time)
        }
        return offset
    }

    func animateMoveFrom(
        displacement: CGPoint,
        yContainmentFrame: CGRect? = nil,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            stopMoveAnimations()
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentVelX = moveXAnimation?.currentVelocity(at: now) ?? 0
        let currentVelY = moveYAnimation?.currentVelocity(at: now) ?? 0

        if displacement.x != 0 {
            let totalOffsetX = displacement.x + currentOffset.x
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelX,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveXAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetX)
        }
        if displacement.y != 0 {
            let totalOffsetY = displacement.y + currentOffset.y
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelY,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveYAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetY)
            moveYContainmentFrame = yContainmentFrame
        }
    }

    func tickMoveAnimations(at time: TimeInterval) -> Bool {
        var running = false
        if let moveX = moveXAnimation {
            if moveX.isComplete(at: time) {
                moveXAnimation = nil
            } else {
                running = true
            }
        }
        if let moveY = moveYAnimation {
            if moveY.isComplete(at: time) {
                moveYAnimation = nil
                moveYContainmentFrame = nil
            } else {
                running = true
            }
        }
        return running
    }

    func stopMoveAnimations() {
        moveXAnimation = nil
        moveYAnimation = nil
        moveYContainmentFrame = nil
    }

    var hasMoveAnimationsRunning: Bool {
        moveXAnimation != nil || moveYAnimation != nil
    }

    var hasAnyAnimationRunning: Bool {
        hasMoveAnimationsRunning
    }
}

class NiriRoot: NiriContainer {
    let workspaceId: WorkspaceDescriptor.ID

    private var nodeIndex: [NodeId: NiriNode]?
    private var _cachedColumns: [NiriContainer]?
    private var _cachedAllWindows: [NiriWindow]?
    private var _cachedWindowIdSet: Set<WindowToken>?

    init(workspaceId: WorkspaceDescriptor.ID) {
        self.workspaceId = workspaceId
        super.init()
    }

    override func invalidateChildrenCache() {
        _cachedColumns = nil
        _cachedAllWindows = nil
        _cachedWindowIdSet = nil
        super.invalidateChildrenCache()
    }

    var columns: [NiriContainer] {
        if let cached = _cachedColumns { return cached }
        let result = children.compactMap { $0 as? NiriContainer }
        _cachedColumns = result
        return result
    }

    var allWindows: [NiriWindow] {
        if let cached = _cachedAllWindows { return cached }
        let result = columns.flatMap(\.windowNodes)
        _cachedAllWindows = result
        return result
    }

    var windowIdSet: Set<WindowToken> {
        if let cached = _cachedWindowIdSet { return cached }
        let result = Set(allWindows.map(\.token))
        _cachedWindowIdSet = result
        return result
    }

    func containsWindowId(_ id: WindowToken) -> Bool {
        windowIdSet.contains(id)
    }

    private func buildNodeIndex() -> [NodeId: NiriNode] {
        var index: [NodeId: NiriNode] = [:]
        func addToIndex(_ node: NiriNode) {
            index[node.id] = node
            for child in node.children {
                addToIndex(child)
            }
        }
        addToIndex(self)
        return index
    }

    override func findNode(by id: NodeId) -> NiriNode? {
        if nodeIndex == nil {
            nodeIndex = buildNodeIndex()
        }
        return nodeIndex?[id]
    }

    func registerNode(_ node: NiriNode) {
        nodeIndex?[node.id] = node
        for child in node.children {
            registerNode(child)
        }
    }

    func unregisterNode(_ node: NiriNode) {
        nodeIndex?.removeValue(forKey: node.id)
        for child in node.children {
            unregisterNode(child)
        }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
