// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorRestoreKey: Hashable {
    let displayUUID: String?
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayUUID = monitor.displayUUID
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }

    static func == (lhs: MonitorRestoreKey, rhs: MonitorRestoreKey) -> Bool {
        if lhs.displayUUID != nil || rhs.displayUUID != nil {
            return lhs.displayUUID == rhs.displayUUID
        }
        return lhs.displayId == rhs.displayId &&
            lhs.name == rhs.name &&
            lhs.anchorPoint == rhs.anchorPoint &&
            lhs.frameSize == rhs.frameSize
    }

    func hash(into hasher: inout Hasher) {
        if let displayUUID {
            hasher.combine(displayUUID)
        } else {
            hasher.combine(displayId)
            hasher.combine(name)
            hasher.combine(anchorPoint)
            hasher.combine(frameSize)
        }
    }
}

struct WorkspaceRestoreSnapshot: Hashable {
    let monitor: MonitorRestoreKey
    let workspaceId: WorkspaceDescriptor.ID
}

private struct RestoreMatchingResult {
    var assignmentsBySnapshotIndex: [Int: Monitor.ID] = [:]
    var assignedCount = 0
    var totalNamePenalty = 0
    var totalGeometryDelta: CGFloat = 0
}

func resolveWorkspaceRestoreAssignments(
    snapshots: [WorkspaceRestoreSnapshot],
    monitors: [Monitor],
    workspaceExists: (WorkspaceDescriptor.ID) -> Bool
) -> [Monitor.ID: WorkspaceDescriptor.ID] {
    guard !snapshots.isEmpty, !monitors.isEmpty else { return [:] }

    var filteredSnapshots: [WorkspaceRestoreSnapshot] = []
    var seenWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    filteredSnapshots.reserveCapacity(snapshots.count)

    for snapshot in snapshots {
        guard workspaceExists(snapshot.workspaceId) else { continue }
        guard seenWorkspaceIds.insert(snapshot.workspaceId).inserted else { continue }
        filteredSnapshots.append(snapshot)
    }

    filteredSnapshots.sort { lhs, rhs in
        snapshotSortKey(lhs.monitor) < snapshotSortKey(rhs.monitor)
    }

    let sortedMonitors = monitors.sorted { lhs, rhs in
        monitorRestoreSortKey(lhs) < monitorRestoreSortKey(rhs)
    }

    var assignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    var usedMonitorIds: Set<Monitor.ID> = []
    var assignedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

    let snapshotUUIDCounts = filteredSnapshots.reduce(into: [String: Int]()) { counts, snapshot in
        guard let displayUUID = snapshot.monitor.displayUUID else { return }
        counts[displayUUID, default: 0] += 1
    }
    let monitorUUIDCounts = sortedMonitors.reduce(into: [String: Int]()) { counts, monitor in
        guard let displayUUID = monitor.displayUUID else { return }
        counts[displayUUID, default: 0] += 1
    }

    for snapshot in filteredSnapshots {
        guard let displayUUID = snapshot.monitor.displayUUID,
              snapshotUUIDCounts[displayUUID] == 1,
              monitorUUIDCounts[displayUUID] == 1,
              let exactMonitor = sortedMonitors.first(where: { $0.displayUUID == displayUUID })
        else {
            continue
        }
        guard usedMonitorIds.insert(exactMonitor.id).inserted else { continue }
        assignments[exactMonitor.id] = snapshot.workspaceId
        assignedWorkspaceIds.insert(snapshot.workspaceId)
    }

    for snapshot in filteredSnapshots {
        guard snapshot.monitor.displayUUID == nil,
              !assignedWorkspaceIds.contains(snapshot.workspaceId),
              let exactMonitor = sortedMonitors.first(where: {
                  !usedMonitorIds.contains($0.id) &&
                      $0.displayId == snapshot.monitor.displayId &&
                      Monitor.namesMatch($0.name, snapshot.monitor.name)
              })
        else {
            continue
        }
        guard usedMonitorIds.insert(exactMonitor.id).inserted else { continue }
        assignments[exactMonitor.id] = snapshot.workspaceId
        assignedWorkspaceIds.insert(snapshot.workspaceId)
    }

    let remainingSnapshots = filteredSnapshots.filter {
        !assignedWorkspaceIds.contains($0.workspaceId)
    }
    let remainingMonitors = sortedMonitors.filter {
        !usedMonitorIds.contains($0.id)
    }
    let remainingAssignments = resolveBestRestoreMatches(
        snapshots: remainingSnapshots,
        monitors: remainingMonitors
    )
    for (snapshotIndex, monitorId) in remainingAssignments {
        assignments[monitorId] = remainingSnapshots[snapshotIndex].workspaceId
    }

    return assignments
}

private func resolveBestRestoreMatches(
    snapshots: [WorkspaceRestoreSnapshot],
    monitors: [Monitor]
) -> [Int: Monitor.ID] {
    guard !snapshots.isEmpty, !monitors.isEmpty else { return [:] }

    let monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })

    func prefersAssignments(_ lhs: RestoreMatchingResult, over rhs: RestoreMatchingResult) -> Bool {
        if lhs.assignedCount != rhs.assignedCount {
            return lhs.assignedCount > rhs.assignedCount
        }
        if lhs.totalNamePenalty != rhs.totalNamePenalty {
            return lhs.totalNamePenalty < rhs.totalNamePenalty
        }
        if lhs.totalGeometryDelta != rhs.totalGeometryDelta {
            return lhs.totalGeometryDelta < rhs.totalGeometryDelta
        }

        for index in snapshots.indices {
            let lhsMonitorId = lhs.assignmentsBySnapshotIndex[index]
            let rhsMonitorId = rhs.assignmentsBySnapshotIndex[index]

            switch (lhsMonitorId, rhsMonitorId) {
            case (nil, nil):
                continue
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case let (.some(lhsMonitorId), .some(rhsMonitorId)):
                guard lhsMonitorId != rhsMonitorId else { continue }
                guard let lhsMonitor = monitorsById[lhsMonitorId],
                      let rhsMonitor = monitorsById[rhsMonitorId]
                else {
                    return lhsMonitorId.displayId < rhsMonitorId.displayId
                }
                return monitorRestoreSortKey(lhsMonitor) < monitorRestoreSortKey(rhsMonitor)
            }
        }

        return false
    }

    func search(snapshotIndex: Int, availableMonitors: [Monitor]) -> RestoreMatchingResult {
        guard snapshotIndex < snapshots.count, !availableMonitors.isEmpty else {
            return RestoreMatchingResult()
        }

        let currentSnapshot = snapshots[snapshotIndex]
        // Monitor counts are small, so an exact search keeps restore matching
        // stable when a newly inserted display collides with a later exact fit.
        var bestResult = search(
            snapshotIndex: snapshotIndex + 1,
            availableMonitors: availableMonitors
        )

        for (monitorIndex, monitor) in availableMonitors.enumerated() {
            var nextMonitors = availableMonitors
            nextMonitors.remove(at: monitorIndex)

            let score = restoreMatchScore(snapshot: currentSnapshot.monitor, monitor: monitor)
            var candidate = search(
                snapshotIndex: snapshotIndex + 1,
                availableMonitors: nextMonitors
            )
            candidate.assignmentsBySnapshotIndex[snapshotIndex] = monitor.id
            candidate.assignedCount += 1
            candidate.totalNamePenalty += score.namePenalty
            candidate.totalGeometryDelta += score.geometryDelta

            if prefersAssignments(candidate, over: bestResult) {
                bestResult = candidate
            }
        }

        return bestResult
    }

    return search(snapshotIndex: 0, availableMonitors: monitors).assignmentsBySnapshotIndex
}

private func restoreMatchScore(
    snapshot: MonitorRestoreKey,
    monitor: Monitor
) -> (namePenalty: Int, geometryDelta: CGFloat) {
    let namePenalty = snapshot.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
    let anchorDistance = snapshot.anchorPoint.distanceSquared(to: monitor.workspaceAnchorPoint)
    let widthDelta = abs(snapshot.frameSize.width - monitor.frame.width)
    let heightDelta = abs(snapshot.frameSize.height - monitor.frame.height)
    let geometryDelta = anchorDistance + widthDelta + heightDelta
    return (namePenalty, geometryDelta)
}

private func snapshotSortKey(_ snapshot: MonitorRestoreKey) -> (CGFloat, CGFloat, UInt32) {
    (snapshot.anchorPoint.x, -snapshot.anchorPoint.y, snapshot.displayId)
}

private func monitorRestoreSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
    (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
