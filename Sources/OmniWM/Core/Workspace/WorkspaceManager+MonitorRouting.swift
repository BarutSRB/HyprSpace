// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

private enum MonitorSelectionMode {
    case directional
    case wrapped
}

private struct MonitorSelectionRank {
    let primary: CGFloat
    let secondary: CGFloat
    let distance: CGFloat?
}

extension WorkspaceManager {
    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        guard let monitorId = resolvedWorkspaceMonitorId(for: workspaceId) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        monitorForWorkspace(workspaceId)
    }

    func monitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        monitorForWorkspace(workspaceId)?.id
    }

    func adjacentMonitor(from monitorId: Monitor.ID, direction: Direction, wrapAround: Bool = false) -> Monitor? {
        guard let current = monitor(byId: monitorId) else { return nil }

        if settings.monitorRoutingMode == .custom {
            switch MonitorRouting.gridAdjacent(
                from: current,
                direction: direction,
                layout: MonitorRouting.layout(for: monitors, in: settings.monitorArrangements),
                monitors: monitors,
                wrapAround: wrapAround
            ) {
            case let .monitor(target):
                return target
            case .edge:
                return nil
            case .fallBackToMacOS:
                break
            }
        }

        return macOSAdjacentMonitor(from: current, direction: direction, wrapAround: wrapAround)
    }

    func previousMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = sortedMonitors()
        guard let currentIndex = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        let previousIndex = currentIndex > 0 ? currentIndex - 1 : sorted.count - 1
        return sorted[previousIndex]
    }

    func nextMonitor(from monitorId: Monitor.ID) -> Monitor? {
        guard monitors.count > 1 else { return nil }

        let sorted = sortedMonitors()
        guard let currentIndex = sorted.firstIndex(where: { $0.id == monitorId }) else { return nil }

        return sorted[(currentIndex + 1) % sorted.count]
    }

    func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
    }

    func runtimeOverrideReconnectAssignments(
        previousMonitors: [Monitor],
        newMonitors: [Monitor]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        let previous = Monitor.sortedByPosition(previousMonitors)
        let next = Monitor.sortedByPosition(newMonitors)
        let visibleWorkspaceIds = visibleWorkspaceIds()
        var candidatesByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]] = [:]

        for workspace in sortedWorkspaces() {
            guard let runtimeOverride = workspace.runtimeMonitorOverride,
                  runtimeOverride.resolveMonitor(in: previous) == nil,
                  let targetMonitor = runtimeOverride.resolveMonitor(in: next)
            else {
                continue
            }
            candidatesByMonitor[targetMonitor.id, default: []].append(workspace.id)
        }

        var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for (monitorId, candidates) in candidatesByMonitor {
            guard let visibleWorkspaceId = candidates.first(where: visibleWorkspaceIds.contains) else {
                continue
            }
            assignments[monitorId] = visibleWorkspaceId
        }
        return assignments
    }

    func translatedFloatingStates(
        in workspaceId: WorkspaceDescriptor.ID,
        to targetMonitor: Monitor
    ) -> [WindowToken: FloatingState] {
        let entries = entries(in: workspaceId)
        var states: [WindowToken: FloatingState] = [:]
        states.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.mode == .floating,
                  entry.layoutReason == .standard,
                  !isScratchpadToken(entry.token),
                  let existingState = entry.floatingState,
                  let frame = resolvedFloatingFrame(for: entry.token, preferredMonitor: targetMonitor)
            else {
                continue
            }
            states[entry.token] = FloatingState(
                lastFrame: frame,
                normalizedOrigin: existingState.normalizedOrigin,
                referenceMonitorId: targetMonitor.id,
                restoreToFloating: existingState.restoreToFloating
            )
        }
        return states
    }

    private func macOSAdjacentMonitor(from current: Monitor, direction: Direction, wrapAround: Bool) -> Monitor? {
        let others = monitors.filter { $0.id != current.id }
        guard !others.isEmpty else { return nil }

        let directional = others.filter { candidate in
            let delta = monitorDelta(from: current, to: candidate)
            switch direction {
            case .left: return delta.dx < 0 && abs(delta.dx) >= abs(delta.dy)
            case .right: return delta.dx > 0 && abs(delta.dx) >= abs(delta.dy)
            case .up: return delta.dy > 0 && abs(delta.dy) >= abs(delta.dx)
            case .down: return delta.dy < 0 && abs(delta.dy) >= abs(delta.dx)
            }
        }

        if let bestDirectional = bestMonitor(in: directional, from: current, direction: direction) {
            return bestDirectional
        }

        guard wrapAround else { return nil }
        return wrappedMonitor(in: others, from: current, direction: direction)
    }

    private func monitorDelta(from source: Monitor, to target: Monitor) -> (dx: CGFloat, dy: CGFloat) {
        (
            target.frame.center.x - source.frame.center.x,
            target.frame.center.y - source.frame.center.y
        )
    }

    private func bestMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .directional)
        }
    }

    private func wrappedMonitor(in candidates: [Monitor], from current: Monitor, direction: Direction) -> Monitor? {
        candidates.min {
            isBetterMonitorCandidate($0, than: $1, from: current, direction: direction, mode: .wrapped)
        }
    }

    private func isBetterMonitorCandidate(
        _ lhs: Monitor,
        than rhs: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> Bool {
        let lhsRank = monitorSelectionRank(for: lhs, from: current, direction: direction, mode: mode)
        let rhsRank = monitorSelectionRank(for: rhs, from: current, direction: direction, mode: mode)

        if lhsRank.primary != rhsRank.primary {
            return lhsRank.primary < rhsRank.primary
        }
        if lhsRank.secondary != rhsRank.secondary {
            return lhsRank.secondary < rhsRank.secondary
        }
        if let lhsDistance = lhsRank.distance,
           let rhsDistance = rhsRank.distance,
           lhsDistance != rhsDistance
        {
            return lhsDistance < rhsDistance
        }
        return monitorSortKey(lhs) < monitorSortKey(rhs)
    }

    private func monitorSelectionRank(
        for candidate: Monitor,
        from current: Monitor,
        direction: Direction,
        mode: MonitorSelectionMode
    ) -> MonitorSelectionRank {
        let delta = monitorDelta(from: current, to: candidate)

        switch mode {
        case .directional:
            switch direction {
            case .left,
                 .right:
                return MonitorSelectionRank(
                    primary: abs(delta.dx),
                    secondary: abs(delta.dy),
                    distance: monitorDistanceSquared(from: candidate, to: current)
                )
            case .up,
                 .down:
                return MonitorSelectionRank(
                    primary: abs(delta.dy),
                    secondary: abs(delta.dx),
                    distance: monitorDistanceSquared(from: candidate, to: current)
                )
            }
        case .wrapped:
            switch direction {
            case .right:
                return MonitorSelectionRank(primary: candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .left:
                return MonitorSelectionRank(primary: -candidate.frame.center.x, secondary: abs(delta.dy), distance: nil)
            case .up:
                return MonitorSelectionRank(primary: candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            case .down:
                return MonitorSelectionRank(primary: -candidate.frame.center.y, secondary: abs(delta.dx), distance: nil)
            }
        }
    }

    private func monitorDistanceSquared(from source: Monitor, to target: Monitor) -> CGFloat {
        let delta = monitorDelta(from: source, to: target)
        return delta.dx * delta.dx + delta.dy * delta.dy
    }
}
