// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var borderSafeFillFrame: CGRect
    var fullscreenLayoutFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat

    init(
        workingFrame: CGRect,
        borderSafeFillFrame: CGRect? = nil,
        fullscreenLayoutFrame: CGRect? = nil,
        viewFrame: CGRect,
        scale: CGFloat
    ) {
        self.workingFrame = workingFrame
        self.borderSafeFillFrame = borderSafeFillFrame ?? fullscreenLayoutFrame ?? workingFrame
        self.fullscreenLayoutFrame = fullscreenLayoutFrame ?? workingFrame
        self.viewFrame = viewFrame
        self.scale = scale
    }
}

struct Struts {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.bottom

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

func normalizedTopStrut(top: CGFloat, menuBarInset: CGFloat, reservedTopInset: CGFloat) -> CGFloat {
    max(0, top - menuBarInset) + reservedTopInset
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

final class NiriWorkspaceState {
    let root: NiriRoot
    var nodesByToken: [WindowToken: NiriWindow] = [:]
    var attachedMonitorId: Monitor.ID?

    init(workspaceId: WorkspaceDescriptor.ID) {
        root = NiriRoot(workspaceId: workspaceId)
    }

    func index(_ window: NiriWindow) {
        if let existing = nodesByToken[window.token] {
            precondition(existing === window)
            return
        }
        nodesByToken[window.token] = window
    }

    func unindex(_ window: NiriWindow) {
        if nodesByToken[window.token] === window {
            nodesByToken.removeValue(forKey: window.token)
        }
    }
}

final class NiriLayoutEngine {
    enum NewContainerSizingPolicy {
        case workspaceDefault
        case inheritSource
    }

    static let defaultPresetContainerPrimarySpanValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetContainerPrimarySpans: [PresetSize] = defaultPresetContainerPrimarySpanValues
        .map { .proportion($0) }
    static let defaultPresetWindowSecondarySpanValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetWindowSecondarySpans: [PresetSize] = defaultPresetWindowSecondarySpanValues
        .map { .proportion($0) }
    private static let presetMatchTolerance: CGFloat = 0.001

    var monitors: [Monitor.ID: NiriMonitor] = [:]

    var states: [WorkspaceDescriptor.ID: NiriWorkspaceState] = [:]

    var framePool: [WindowToken: CGRect] = [:]
    var hiddenPool: [WindowToken: HideSide] = [:]

    var axisSolveCache: [NiriAxisSolveKey: [NiriAxisSolver.Output]] = [:]
    private(set) var axisSolveConfigurationRevision: UInt64 = 0

    var excludedTokensByWorkspace: [WorkspaceDescriptor.ID: Set<WindowToken>] = [:]

    var visibleContainerCount: Int
    var infiniteLoop: Bool

    var centerFocusedColumn: CenterFocusedColumn = .never

    var alwaysCenterSingleColumn: Bool = false

    var singleWindowFit: SingleWindowFit = .fullScreen

    var renderStyle: NiriRenderStyle = .default

    var interactiveResize: InteractiveResize?
    var interactiveMove: InteractiveMove?

    var resizeConfiguration = ResizeConfiguration.default
    var moveConfiguration = MoveConfiguration.default

    var windowMovementAnimationConfig: SpringConfig = .niriWindowMovement
    var animationClock: AnimationClock?
    var isMutationSanctioned = true

    func assertSanctionedMutation(_ operation: StaticString = #function) {
        assert(
            isMutationSanctioned,
            "\(operation) mutated the Niri layout tree outside a sanctioned WorldStore scope"
        )
    }

    func cancelInteractions(in workspaceId: WorkspaceDescriptor.ID) {
        if interactiveMove?.workspaceId == workspaceId {
            interactiveMoveCancel()
        }
        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
    }

    func cancelInteractions(for windowIds: Set<NodeId>, in workspaceId: WorkspaceDescriptor.ID) {
        if let move = interactiveMove,
           move.workspaceId == workspaceId,
           windowIds.contains(move.windowId)
        {
            interactiveMoveCancel()
        }
        if let resize = interactiveResize,
           resize.workspaceId == workspaceId,
           windowIds.contains(resize.windowId)
        {
            clearInteractiveResize()
        }
    }

    var presetContainerPrimarySpans: [PresetSize] = NiriLayoutEngine.defaultPresetContainerPrimarySpans
    var presetWindowSecondarySpans: [PresetSize] = NiriLayoutEngine.defaultPresetWindowSecondarySpans {
        didSet {
            if oldValue != presetWindowSecondarySpans {
                axisSolveConfigurationRevision &+= 1
            }
        }
    }

    var defaultContainerPrimarySpan: CGFloat? = 0.5

    init(visibleContainerCount: Int = 2, infiniteLoop: Bool = false) {
        self.visibleContainerCount = max(1, min(5, visibleContainerCount))
        self.infiniteLoop = infiniteLoop
    }

    func ensureState(for workspaceId: WorkspaceDescriptor.ID) -> NiriWorkspaceState {
        if let existing = states[workspaceId] {
            return existing
        }
        let state = NiriWorkspaceState(workspaceId: workspaceId)
        states[workspaceId] = state
        return state
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        ensureState(for: workspaceId).root
    }

    func claimEmptyColumnIfWorkspaceEmpty(in root: NiriRoot) -> NiriContainer? {
        guard root.allWindows.isEmpty else { return nil }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        guard let target = emptyColumns.first else { return nil }

        for column in emptyColumns.dropFirst() {
            column.remove()
        }

        return target
    }

    func removeEmptyColumnsIfWorkspaceEmpty(in root: NiriRoot) {
        guard root.allWindows.isEmpty else { return }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        for column in emptyColumns {
            column.remove()
        }
    }

    func resolvedContainerResetPrimarySpan(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> (proportion: CGFloat, presetWidthIdx: Int?) {
        resolvedContainerResetPrimarySpan(for: monitorContaining(workspace: workspaceId))
    }

    func resolvedContainerResetPrimarySpan(
        for monitorId: Monitor.ID?
    ) -> (proportion: CGFloat, presetWidthIdx: Int?) {
        if let defaultContainerPrimarySpan {
            return (defaultContainerPrimarySpan, matchingPresetIndex(for: defaultContainerPrimarySpan))
        }
        let settings = monitorId.map(effectiveSettings(for:)) ?? globalResolvedSettings()
        return (1.0 / CGFloat(settings.visibleContainerCount), nil)
    }

    func initialContainerSizingState(for proportion: CGFloat) -> NiriContainerSizingState {
        precondition(proportion.isFinite && (0.05 ... 1.0).contains(proportion))
        return initialContainerSizingState(
            for: proportion,
            presetWidthIndex: matchingPresetIndex(for: proportion)
        )
    }

    private func initialContainerSizingState(
        for proportion: CGFloat,
        presetWidthIndex: Int?
    ) -> NiriContainerSizingState {
        return NiriContainerSizingState(
            width: .proportion(proportion),
            presetWidthIndex: presetWidthIndex,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false,
            height: .proportion(proportion),
            isFullHeight: false,
            savedHeight: nil,
            hasManualSingleWindowHeightOverride: false
        )
    }

    func containerSizingState(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriContainerSizingState? {
        guard let window = states[workspaceId]?.nodesByToken[token],
              let column = window.parent as? NiriContainer
        else {
            return nil
        }
        return containerSizingState(for: column)
    }

    private func applyContainerSizingState(_ state: NiriContainerSizingState, to column: NiriContainer) {
        column.width = state.width
        column.presetWidthIdx = state.presetWidthIndex
        column.isFullWidth = state.isFullWidth
        column.savedWidth = state.savedWidth
        column.hasManualSingleWindowWidthOverride = state.hasManualSingleWindowWidthOverride
        column.height = state.height
        column.isFullHeight = state.isFullHeight
        column.savedHeight = state.savedHeight
        column.hasManualSingleWindowHeightOverride = state.hasManualSingleWindowHeightOverride
        column.cachedWidth = 0
        column.cachedHeight = 0
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    func initializeNewContainerSizing(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        initialState: NiriContainerSizingState? = nil
    ) {
        if let initialState {
            applyContainerSizingState(initialState, to: column)
            return
        }
        let resolvedWidth = resolvedContainerResetPrimarySpan(in: workspaceId)
        applyContainerSizingState(
            initialContainerSizingState(
                for: resolvedWidth.proportion,
                presetWidthIndex: resolvedWidth.presetWidthIdx
            ),
            to: column
        )
    }

    func copyContainerSizingState(from sourceColumn: NiriContainer, to targetColumn: NiriContainer) {
        applyContainerSizingState(containerSizingState(for: sourceColumn), to: targetColumn)
    }

    private func containerSizingState(for column: NiriContainer) -> NiriContainerSizingState {
        NiriContainerSizingState(
            width: column.width,
            presetWidthIndex: column.presetWidthIdx,
            isFullWidth: column.isFullWidth,
            savedWidth: column.savedWidth,
            hasManualSingleWindowWidthOverride: column.hasManualSingleWindowWidthOverride,
            height: column.height,
            isFullHeight: column.isFullHeight,
            savedHeight: column.savedHeight,
            hasManualSingleWindowHeightOverride: column.hasManualSingleWindowHeightOverride
        )
    }

    private func matchingPresetIndex(for width: CGFloat) -> Int? {
        presetContainerPrimarySpans.firstIndex { preset in
            guard case let .proportion(presetWidth) = preset.kind else { return false }
            return abs(presetWidth - width) <= Self.presetMatchTolerance
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        states[workspaceId]?.root
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        root(for: workspaceId)?.columns ?? []
    }

    struct SingleWindowLayoutContext {
        let container: NiriContainer
        let window: NiriWindow
        let fit: SingleWindowFit
    }

    func singleWindowLayoutContext(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedTokens: Set<WindowToken>? = nil
    ) -> SingleWindowLayoutContext? {
        let fit = effectiveSingleWindowFit(in: workspaceId)
        guard fit.mode != .containerPrimarySpan else {
            return nil
        }

        let effectiveExcludedTokens = excludedTokens ?? projectionExclusions(in: workspaceId)
        let workspaceColumns = columns(in: workspaceId).compactMap { column -> (NiriContainer, [NiriWindow])? in
            let windows = effectiveExcludedTokens.isEmpty
                ? column.windowNodes
                : column.windowNodes.filter { !effectiveExcludedTokens.contains($0.token) }
            return windows.isEmpty ? nil : (column, windows)
        }
        guard workspaceColumns.count == 1,
              let (column, windows) = workspaceColumns.first,
              !column.isTabbed
        else {
            return nil
        }

        guard windows.count == 1,
              let window = windows.first,
              window.sizingMode == .normal
        else {
            return nil
        }

        return SingleWindowLayoutContext(
            container: column,
            window: window,
            fit: fit
        )
    }

    func wrapIndex(_ idx: Int, total: Int, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        guard total > 0 else { return nil }
        if effectiveInfiniteLoop(in: workspaceId) {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }

    func findNode(by id: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriNode? {
        root(for: workspaceId)?.findNode(by: id)
    }

    func findNode(for handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        findNode(for: handle.token, in: workspaceId)
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.nodesByToken[token]?.isFullscreen ?? false
    }

    func column(of node: NiriNode) -> NiriContainer? {
        var current = node
        while let parent = current.parent {
            if parent is NiriRoot {
                return current as? NiriContainer
            }
            current = parent
        }
        return nil
    }

    func columnIndex(of column: NiriNode, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        columns(in: workspaceId).firstIndex { $0 === column }
    }

    func activateWindow(_ nodeId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(by: nodeId, in: workspaceId),
              let col = column(of: node),
              let idx = col.windowNodes.firstIndex(where: { $0.id == nodeId })
        else { return }
        col.setActiveTileIdx(idx)
        updateTabbedColumnVisibility(column: col)
    }

    func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index where i < columns.count {
            x += columns[i].cachedWidth + gaps
        }
        return x
    }

    func findColumn(containing window: NiriWindow, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        guard let col = column(of: window),
              let root = col.parent as? NiriRoot,
              self.root(for: workspaceId)?.id == root.id else { return nil }
        return col
    }

    func updateConfiguration(
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        presetContainerPrimarySpans: [PresetSize]? = nil,
        defaultContainerPrimarySpan: CGFloat?? = nil
    ) {
        assertSanctionedMutation()
        if let max = visibleContainerCount {
            self.visibleContainerCount = max.clamped(to: 1 ... 5)
        }
        if let loop = infiniteLoop {
            self.infiniteLoop = loop
        }
        if let center = centerFocusedColumn {
            self.centerFocusedColumn = center
        }
        if let centerSingle = alwaysCenterSingleColumn {
            self.alwaysCenterSingleColumn = centerSingle
        }
        if let singleWindowFit {
            self.singleWindowFit = singleWindowFit
        }
        // Double optional distinguishes "no config change" from "set Auto/nil".
        if let defaultContainerPrimarySpan {
            self.defaultContainerPrimarySpan = defaultContainerPrimarySpan?.clamped(to: 0.05 ... 1.0)
        }

        if let presets = presetContainerPrimarySpans, !presets.isEmpty {
            self.presetContainerPrimarySpans = presets
            resetAllPresetWidthIndices()
        }
    }

    private func resetAllPresetWidthIndices() {
        for state in states.values {
            for child in state.root.children {
                if let column = child as? NiriContainer {
                    column.presetWidthIdx = nil
                }
            }
        }
    }
}
