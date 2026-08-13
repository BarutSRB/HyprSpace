// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension LayoutRefreshController.ScheduledRefresh {
    var visibilityTraceVisibility: AppVisibilityTrace.Visibility? {
        let resolvedReason = kind == .visibilityRefresh ? reason : visibilityReason
        let visibility: AppVisibilityTrace.Visibility? = switch resolvedReason {
        case .appHidden:
            .hidden
        case .appUnhidden:
            .visible
        default:
            nil
        }
        return visibility
    }
}

extension LayoutRefreshController {
    func recordVisibilityRefresh(
        _ refresh: ScheduledRefresh,
        outcome: AppVisibilityTrace.Outcome,
        reason: AppVisibilityTrace.Reason? = nil
    ) {
        guard let visibility = refresh.visibilityTraceVisibility,
              AppVisibilityTrace.isActive
        else {
            return
        }
        AppVisibilityTrace.record(
            .refresh,
            visibility: visibility,
            outcome: outcome,
            affectedWorkspaceCount: refresh.affectedWorkspaceIds.count,
            reason: reason,
            source: .layoutRefresh
        )
    }

    func auditParkVisibility(displayId: CGDirectDisplayID) {
        guard ParkVisibilityAudit.shared.isActive, let controller else { return }
        let now = CACurrentMediaTime()
        guard now - layoutState.lastParkAuditTime >= 0.1 else { return }
        layoutState.lastParkAuditTime = now

        let monitorFrames = controller.workspaceManager.monitors.map(\.frame)
        var laggards: [String] = []
        var strays: [String] = []
        var visible: [Int] = []
        var parkedCount = 0
        var appHiddenCount = 0
        for entry in controller.workspaceManager.allEntries() {
            if controller.workspaceManager.isAppHidden(pid: entry.pid)
                || controller.axManager.macOSHiddenAppPIDs.contains(entry.pid)
            {
                appHiddenCount += 1
                continue
            }
            guard let windowId = UInt32(exactly: entry.windowId) else { continue }
            guard controller.workspaceManager.hiddenState(for: entry.token) != nil else {
                visible.append(entry.windowId)
                if entry.mode == .tiling,
                   let bounds = SkyLight.shared.getWindowBounds(windowId)
                {
                    let frame = ScreenCoordinateSpace.toAppKit(rect: bounds)
                    let expectations = [
                        controller.axManager.lastAppliedFrame(for: entry.windowId)?.origin,
                        controller.axManager.pendingFrameWrite(for: entry.windowId)?.origin,
                        controller.axManager.skyLightLivePosition(for: entry.windowId)
                    ].compactMap(\.self)
                    let strayEpsilon: CGFloat = 32
                    let matchesExpectation = expectations.contains {
                        abs($0.x - frame.origin.x) <= strayEpsilon
                            && abs($0.y - frame.origin.y) <= strayEpsilon
                    }
                    if !matchesExpectation {
                        let expected = expectations.first.map { TraceFormat.point($0) } ?? "none"
                        strays.append(
                            "\(entry.windowId):\(TraceFormat.point(frame.origin))→\(expected)"
                        )
                    }
                }
                continue
            }
            guard let bounds = SkyLight.shared.getWindowBounds(windowId) else { continue }
            let frame = ScreenCoordinateSpace.toAppKit(rect: bounds)
            let overlap = monitorFrames
                .map { $0.intersection(frame) }
                .filter { !$0.isNull && !$0.isEmpty }
                .max { $0.width * $0.height < $1.width * $1.height }
            if let overlap, overlap.width > 16, overlap.height > 16 {
                laggards.append(
                    "\(entry.windowId):\(Int(overlap.width))x\(Int(overlap.height))"
                        + "@\(TraceFormat.point(frame.origin))"
                )
            } else {
                parkedCount += 1
            }
        }
        ParkVisibilityAudit.shared.record(
            ParkVisibilityAudit.Record(
                mediaTime: now,
                displayId: displayId,
                laggards: laggards,
                strays: strays,
                visible: visible.sorted(),
                parkedCount: parkedCount,
                appHiddenCount: appHiddenCount
            )
        )
    }
}
