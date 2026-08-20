// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class MouseWarpHandler: NSObject {
    struct State {
        var cooldownTimer: Timer?
        var isWarping = false
        var lastMonitorId: Monitor.ID?
        var lastSampleAt: Date?
    }

    static let cooldownSeconds: TimeInterval = 0.05

    weak var controller: WMController?
    var state = State()
    var activeDisplayBounds: (CGDirectDisplayID) -> CGRect? = { displayId in
        guard CGDisplayIsActive(displayId) == 1 else { return nil }
        let bounds = CGDisplayBounds(displayId)
        guard !bounds.isNull,
              !bounds.isEmpty,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite
        else { return nil }
        return bounds
    }

    var warpCursor: (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) }
    var postMouseMovedEvent: (CGPoint) -> Void = { point in
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func setup() {
        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0.0
        }
    }

    func cleanup() {
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = nil
        state.isWarping = false
        state.lastMonitorId = nil
        state.lastSampleAt = nil
    }

    func resetTransientState() {
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = nil
        state.isWarping = false
        state.lastMonitorId = nil
        state.lastSampleAt = nil
    }

    func handleMouseWarpMoved(at location: CGPoint) {
        guard let controller else { return }
        guard !state.isWarping else { return }
        guard controller.isEnabled else { return }
        guard controller.settings.mouseWarpEnabled else { return }

        let monitors = controller.workspaceManager.monitors
        guard monitors.count > 1 else { return }

        let margin = CGFloat(controller.settings.mouseWarpMargin)

        if attemptContainment(location: location, monitors: monitors, margin: margin) { return }

        if let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) {
            state.lastMonitorId = currentMonitor.id
            state.lastSampleAt = Date()
            _ = attemptWarp(from: currentMonitor, location: location, margin: margin)
            return
        }

        guard let lastMonitorId = state.lastMonitorId,
              let lastMonitor = controller.workspaceManager.monitor(byId: lastMonitorId)
        else { return }
        _ = attemptWarp(from: lastMonitor, location: location, margin: margin)
    }

    private func attemptWarp(from sourceMonitor: Monitor, location: CGPoint, margin: CGFloat) -> Bool {
        guard let controller else { return false }
        guard let crossing = MouseWarpGeometry.crossing(
            location: location,
            frame: sourceMonitor.frame,
            margin: margin
        ) else {
            return false
        }
        guard let target = controller.workspaceManager.adjacentMonitor(
            from: sourceMonitor.id,
            direction: crossing.direction
        ) else {
            return false
        }

        let destination = MouseWarpGeometry.destinationPoint(
            on: target.frame,
            entryEdge: crossing.entryEdge,
            ratio: crossing.ratio,
            margin: margin
        )
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: destination)

        guard let targetBounds = activeDisplayBounds(target.displayId),
              targetBounds.contains(warpPoint)
        else {
            MouseTrace.record(
                "edge-warp suppressed (invalid-target-bounds) from=\(sourceMonitor.id) to=\(target.id) dir=\(crossing.direction) dest=\(TraceFormat.point(destination)) warp=\(TraceFormat.point(warpPoint))"
            )
            return false
        }

        let error = warpCursor(warpPoint)
        guard error == .success else {
            MouseTrace.record(
                "edge-warp failed (cursor-warp raw=\(error.rawValue)) from=\(sourceMonitor.id) to=\(target.id) dir=\(crossing.direction) dest=\(TraceFormat.point(destination)) warp=\(TraceFormat.point(warpPoint))"
            )
            return false
        }

        state.isWarping = true
        state.lastMonitorId = target.id
        _ = controller.workspaceManager.setInteractionMonitor(target.id)
        MouseTrace.record(
            "edge-warp from=\(sourceMonitor.id) to=\(target.id) dir=\(crossing.direction) dest=\(TraceFormat.point(destination)) warp=\(TraceFormat.point(warpPoint))"
        )
        postMouseMovedEvent(warpPoint)
        scheduleWarpCooldownReset()
        return true
    }

    private func attemptContainment(location: CGPoint, monitors: [Monitor], margin: CGFloat) -> Bool {
        guard let controller else { return false }
        guard controller.settings.cursorContainmentEnabled else { return false }
        guard controller.settings.monitorRoutingMode == .custom else { return false }
        guard let sourceMonitorId = state.lastMonitorId,
              let source = controller.workspaceManager.monitor(byId: sourceMonitorId)
        else { return false }
        guard !source.frame.contains(location) else { return false }
        guard let destination = monitors.first(where: { $0.id != source.id && $0.frame.contains(location) }) else {
            return false
        }

        let now = Date()
        guard let lastSampleAt = state.lastSampleAt,
              now.timeIntervalSince(lastSampleAt) <= 1
        else {
            adoptContainmentDestination(destination, sampledAt: now)
            return true
        }

        switch MouseContainment.evaluate(
            location: location,
            source: source,
            destination: destination,
            layout: controller.settings.monitorRoutingSettings,
            monitors: monitors,
            margin: margin
        ) {
        case .allow:
            adoptContainmentDestination(destination, sampledAt: now)
        case let .wall(clamped):
            applyContainmentWall(clamped, source: source, destination: destination, sampledAt: now)
        }
        return true
    }

    private func applyContainmentWall(
        _ clamped: CGPoint,
        source: Monitor,
        destination: Monitor,
        sampledAt: Date
    ) {
        state.lastSampleAt = sampledAt
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: clamped)

        guard let sourceBounds = activeDisplayBounds(source.displayId),
              sourceBounds.contains(warpPoint)
        else {
            MouseTrace.record(
                "containment-wall suppressed (invalid-source-bounds) from=\(source.id) blocked=\(destination.id) dest=\(TraceFormat.point(clamped)) warp=\(TraceFormat.point(warpPoint))"
            )
            return
        }

        let error = warpCursor(warpPoint)
        guard error == .success else {
            MouseTrace.record(
                "containment-wall failed (cursor-warp raw=\(error.rawValue)) from=\(source.id) blocked=\(destination.id) dest=\(TraceFormat.point(clamped)) warp=\(TraceFormat.point(warpPoint))"
            )
            return
        }

        state.isWarping = true
        MouseTrace.record(
            "containment-wall from=\(source.id) blocked=\(destination.id) dest=\(TraceFormat.point(clamped)) warp=\(TraceFormat.point(warpPoint))"
        )
        postMouseMovedEvent(warpPoint)
        scheduleWarpCooldownReset()
    }

    private func adoptContainmentDestination(_ destination: Monitor, sampledAt: Date) {
        state.lastMonitorId = destination.id
        state.lastSampleAt = sampledAt
    }

    func noteProgrammaticCursorMove(to location: CGPoint) {
        guard let controller else { return }
        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.frame.contains(location) }) else {
            return
        }
        state.lastMonitorId = monitor.id
        state.lastSampleAt = Date()
        state.isWarping = true
        scheduleWarpCooldownReset()
    }

    private func scheduleWarpCooldownReset() {
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = Timer(
            fireAt: Date(timeIntervalSinceNow: MouseWarpHandler.cooldownSeconds),
            interval: 0,
            target: self,
            selector: #selector(handleWarpCooldownTimer(_:)),
            userInfo: nil,
            repeats: false
        )

        if let cooldownTimer = state.cooldownTimer {
            RunLoop.main.add(cooldownTimer, forMode: .common)
        }
    }

    @objc private func handleWarpCooldownTimer(_ timer: Timer) {
        timer.invalidate()
        guard state.cooldownTimer === timer else { return }
        handleCooldownExpiry()
    }

    func handleCooldownExpiry() {
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = nil
        state.isWarping = false
        guard let controller else { return }
        guard controller.isEnabled else { return }
        guard controller.settings.mouseWarpEnabled else { return }
        let monitors = controller.workspaceManager.monitors
        guard monitors.count > 1 else { return }
        let margin = CGFloat(controller.settings.mouseWarpMargin)
        _ = attemptContainment(
            location: controller.currentMouseLocation(),
            monitors: monitors,
            margin: margin
        )
    }
}
