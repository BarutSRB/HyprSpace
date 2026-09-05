// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    struct Operations {
        var createLayerPanel: @MainActor (CGRect) -> BorderLayerPanel
        var excludeFromScreencaptureSelection: @MainActor (UInt32) -> Void
        var queryWindowInfoDeferred: @MainActor (UInt32) async throws -> WindowServerInfo?
        var backingScaleForFrame: @MainActor (CGRect) -> (scale: CGFloat, screenFrame: CGRect)
        var orderWindow: @MainActor (UInt32, UInt32, SkyLightWindowOrder) -> Void

        static let live = Self(
            createLayerPanel: { BorderLayerPanel(frame: $0) },
            excludeFromScreencaptureSelection: { SkyLight.shared.excludeFromScreencaptureWindowSelection($0) },
            queryWindowInfoDeferred: {
                try await SkyLight.shared.queryWindowInfoDeferred(windowIds: [$0])?[$0]
            },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return (targetScreen?.backingScaleFactor ?? 2.0, targetScreen?.frame ?? .null)
            },
            orderWindow: { SkyLight.shared.orderWindow($0, relativeTo: $1, order: $2) }
        )
    }

    private var wid: UInt32 = 0
    private var layerPanel: BorderLayerPanel?
    private var config: BorderConfig
    private let operations: Operations

    private struct CachedTargetLevel {
        let token: WindowToken
        let level: Int32
    }

    private var currentSurfaceFrame: CGRect = .zero
    private var appliedTargetFrame: CGRect = .zero
    private var appliedSurfaceFrame: CGRect = .zero
    private var appliedTargetToken: WindowToken?
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetToken: WindowToken?
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadii = WindowCornerRadii(uniform: 9.0)
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null
    private var cachedTargetLevel: CachedTargetLevel?
    private var deferredLevelTarget: WindowToken?
    private var deferredLevelGeneration: UInt64 = 0
    private var deferredLevelTask: Task<Void, Never>?
    private(set) var hasDeferredLevelUpdate = false
    var onWindowLevelResolved: (@MainActor () -> Void)?
    private var pendingTargetLevelRetryToken: WindowToken?
    private(set) var needsWindowLevelRetry = false
    private(set) var appliedTargetLevel: Int32 = 0

    private let defaultCornerRadii = WindowCornerRadii(uniform: 9.0)
    private static let borderColorSpace = CGColorSpaceCreateDeviceRGB()

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    isolated deinit {
        destroy()
    }

    func destroy() {
        invalidateDeferredLevel(target: nil)
        if wid != 0 {
            layerPanel?.close()
            layerPanel = nil
            wid = 0
        }
        isVisible = false
        lastOrderedTargetToken = nil
        appliedTargetToken = nil
        cachedTargetLevel = nil
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
        currentCornerRadii = defaultCornerRadii
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetToken: WindowToken,
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 9.0),
        forceOrdering: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        needsWindowLevelRetry = false
        guard let targetWid = UInt32(exactly: targetToken.windowId), targetWid != 0 else { return false }
        let scale = backingScale(for: targetFrame)
        let resolvedCornerRadii = cornerRadii.nonnegative
        let geometry = config.resolvedGeometry(for: targetFrame, scale: scale)
        let surfaceFrame = geometry.surfaceFrame
        appliedTargetFrame = geometry.targetFrame
        appliedSurfaceFrame = surfaceFrame
        let localSurfaceFrame = CGRect(origin: .zero, size: surfaceFrame.size)
        let localTargetFrame = CGRect(
            origin: CGPoint(x: geometry.width, y: geometry.width),
            size: geometry.targetFrame.size
        )
        let targetChanged = appliedTargetToken != targetToken
        if targetChanged {
            pendingTargetLevelRetryToken = nil
            invalidateDeferredLevel(target: targetToken)
        }

        let createdWindow: Bool
        if wid == 0 {
            createWindow(scale: scale)
            guard wid != 0 else { return false }
            createdWindow = true
        } else {
            createdWindow = false
        }

        if scale != lastConfiguredScale, wid != 0 {
            BorderOpMetricsRecorder.shared.noteScaleReconfiguration()
            lastConfiguredScale = scale
            needsRedraw = true
        }

        if localSurfaceFrame.size != currentSurfaceFrame.size {
            BorderOpMetricsRecorder.shared.noteReshape()
            needsRedraw = true
        }
        if currentCornerRadii != resolvedCornerRadii {
            needsRedraw = true
        }
        currentSurfaceFrame = localSurfaceFrame
        currentCornerRadii = resolvedCornerRadii

        if needsRedraw {
            draw(
                surfaceFrame: localSurfaceFrame,
                targetFrame: localTargetFrame,
                borderWidth: geometry.width
            )
        }

        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        let needsOrdering = forceOrdering || createdWindow || !isVisible
            || lastOrderedTargetToken != targetToken || retryingTargetLevel || hasDeferredLevelUpdate
        move(
            relativeTo: targetToken,
            targetWid: targetWid,
            needsOrdering: needsOrdering,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
        return true
    }

    func invalidateScaleCache() {
        cachedScale = 0
        cachedScaleScreenFrame = .null
        lastConfiguredScale = 0
        needsRedraw = true
    }

    private func backingScale(for targetFrame: CGRect) -> CGFloat {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return cachedScale
        }
        let (scale, screenFrame) = operations.backingScaleForFrame(targetFrame)
        cachedScale = scale
        cachedScaleScreenFrame = screenFrame
        return scale
    }

    private func createWindow(scale: CGFloat) {
        let panel = operations.createLayerPanel(appliedSurfaceFrame)
        guard let windowId = UInt32(exactly: panel.windowNumber), windowId != 0 else {
            panel.close()
            return
        }
        layerPanel = panel
        wid = windowId
        needsRedraw = true
        lastConfiguredScale = scale
        BorderOpMetricsRecorder.shared.noteWindowCreation()
        BorderOpMetricsRecorder.shared.noteScaleReconfiguration()
        operations.excludeFromScreencaptureSelection(wid)
    }

    private func draw(surfaceFrame: CGRect, targetFrame: CGRect, borderWidth: CGFloat) {
        guard let layerPanel else { return }
        layerPanel.updateBorder(
            surfaceFrame: surfaceFrame, targetFrame: targetFrame,
            cornerRadii: currentCornerRadii, width: borderWidth,
            color: Self.cgColor(config.color), scale: lastConfiguredScale
        )
        needsRedraw = false
        BorderOpMetricsRecorder.shared.noteRedraw(rasterizedArea: surfaceFrame.width * surfaceFrame.height)
    }

    private static func cgColor(_ color: SettingsColor) -> CGColor {
        CGColor(
            colorSpace: borderColorSpace,
            components: [
                component(color.red),
                component(color.green),
                component(color.blue),
                component(color.alpha)
            ]
        )!
    }

    private static func component(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }

    static func roundedRectPath(in rect: CGRect, radii: WindowCornerRadii) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull else { return path }
        let radii = radii.normalized(to: rect.size)

        path.move(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radii.bottomRight),
            radius: radii.bottomRight
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.topRight))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - radii.topRight, y: rect.maxY),
            radius: radii.topRight
        )

        path.addLine(to: CGPoint(x: rect.minX + radii.topLeft, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radii.topLeft),
            radius: radii.topLeft
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.bottomLeft))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY),
            radius: radii.bottomLeft
        )

        path.closeSubpath()
        return path
    }

    private func move(
        relativeTo targetToken: WindowToken,
        targetWid: UInt32,
        needsOrdering: Bool,
        retryingTargetLevel: Bool
    ) {
        layerPanel?.applyFrame(appliedSurfaceFrame)
        if needsOrdering {
            BorderOpMetricsRecorder.shared.noteMoveAndOrder()
            let level = resolvedTargetLevel(
                for: targetToken,
                retrying: retryingTargetLevel
            )
            appliedTargetLevel = level
            if let layerPanel {
                layerPanel.level = NSWindow.Level(rawValue: Int(level))
                if !isVisible {
                    layerPanel.orderFront(nil)
                }
                operations.orderWindow(wid, targetWid, .below)
            }
            return
        }

        BorderOpMetricsRecorder.shared.noteMoveOnly()
    }

    private func resolvedTargetLevel(
        for targetToken: WindowToken,
        retrying: Bool
    ) -> Int32 {
        if deferredLevelTarget != targetToken {
            invalidateDeferredLevel(target: targetToken)
        }
        if hasDeferredLevelUpdate {
            hasDeferredLevelUpdate = false
            if retrying {
                startDeferredLevelQuery(for: targetToken, retrying: true)
            }
        } else {
            startDeferredLevelQuery(for: targetToken, retrying: retrying)
        }
        return cachedLevel(for: targetToken)
    }

    private func cachedLevel(for targetToken: WindowToken) -> Int32 {
        guard let cachedTargetLevel, cachedTargetLevel.token == targetToken else { return 0 }
        return cachedTargetLevel.level
    }

    private func acceptTargetLevel(
        _ info: WindowServerInfo?, for targetToken: WindowToken, retrying: Bool
    ) -> Int32 {
        if let info, Int(info.id) == targetToken.windowId, info.pid == targetToken.pid {
            cachedTargetLevel = CachedTargetLevel(token: targetToken, level: info.level)
            pendingTargetLevelRetryToken = nil
            return info.level
        }
        BorderOpMetricsRecorder.shared.noteLevelFallback()
        FallbackFiringRecorder.shared.note(.skylight, "borderTargetLevelDefault")
        if retrying {
            pendingTargetLevelRetryToken = nil
        } else {
            pendingTargetLevelRetryToken = targetToken
            needsWindowLevelRetry = true
        }
        return cachedLevel(for: targetToken)
    }

    private func invalidateDeferredLevel(target: WindowToken?) {
        deferredLevelGeneration &+= 1
        deferredLevelTarget = target
        deferredLevelTask?.cancel()
        hasDeferredLevelUpdate = false
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
    }

    private func startDeferredLevelQuery(for targetToken: WindowToken, retrying: Bool) {
        guard deferredLevelTask == nil,
              let targetWid = UInt32(exactly: targetToken.windowId)
        else { return }
        let generation = deferredLevelGeneration
        let query = operations.queryWindowInfoDeferred
        if retrying {
            pendingTargetLevelRetryToken = nil
            BorderOpMetricsRecorder.shared.noteLevelRetry()
        }
        BorderOpMetricsRecorder.shared.noteLevelQuery()
        deferredLevelTask = Task { @MainActor [weak self] in
            let info = try? await query(targetWid)
            guard let self else { return }
            deferredLevelTask = nil
            guard generation == deferredLevelGeneration,
                  deferredLevelTarget == targetToken, isVisible, wid != 0
            else {
                if isVisible, let deferredLevelTarget {
                    startDeferredLevelQuery(for: deferredLevelTarget, retrying: false)
                }
                return
            }
            _ = acceptTargetLevel(info, for: targetToken, retrying: retrying)
            hasDeferredLevelUpdate = true
            onWindowLevelResolved?()
        }
    }

    func reorder(relativeTo targetToken: WindowToken) {
        needsWindowLevelRetry = false
        guard wid != 0,
              let targetWid = UInt32(exactly: targetToken.windowId),
              targetWid != 0
        else { return }
        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        move(
            relativeTo: targetToken,
            targetWid: targetWid,
            needsOrdering: true,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
    }

    func hide() {
        invalidateDeferredLevel(target: nil)
        guard wid != 0 else { return }
        BorderOpMetricsRecorder.shared.noteHide()
        layerPanel?.orderOut(nil)
        isVisible = false
        lastOrderedTargetToken = nil
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
    }

    func updateConfig(_ newConfig: BorderConfig) {
        guard config != newConfig else { return }
        if config.color != newConfig.color || config.width != newConfig.width {
            needsRedraw = true
        }
        config = newConfig
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }

    var frameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedSurfaceFrame
    }

    var targetFrameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedTargetFrame
    }
}
