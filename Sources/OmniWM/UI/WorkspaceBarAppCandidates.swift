// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct WorkspaceBarAppCandidate: Identifiable {
    var bundleID: String
    var name: String?
    var icon: NSImage?
    var isManaged: Bool
    var bundleURL: URL?

    var id: String {
        bundleID.lowercased()
    }

    static func sort(
        _ lhs: WorkspaceBarAppCandidate,
        _ rhs: WorkspaceBarAppCandidate
    ) -> Bool {
        let lhsName = lhs.name ?? lhs.bundleID
        let rhsName = rhs.name ?? rhs.bundleID
        let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        let bundleIDOrder = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
        if bundleIDOrder != .orderedSame {
            return bundleIDOrder == .orderedAscending
        }
        return lhs.bundleID < rhs.bundleID
    }
}

struct WorkspaceBarManagedAppCandidate {
    let bundleID: String?
    let name: String?
    let icon: NSImage?
    let bundleURL: URL?
}

@MainActor
enum WorkspaceBarAppCandidates {
    static func build(
        controller: WMController,
        configuredBundleIDs: [String]
    ) -> [WorkspaceBarAppCandidate] {
        let managedApps = controller.workspaceManager.allEntries().map { entry in
            let appInfo = controller.appInfoCache.info(for: entry.pid)
            let runningApp = NSRunningApplication(processIdentifier: entry.pid)
            return WorkspaceBarManagedAppCandidate(
                bundleID: entry.managedReplacementMetadata?.bundleId ?? appInfo?.bundleId,
                name: appInfo?.name,
                icon: appInfo?.icon,
                bundleURL: runningApp?.bundleURL
            )
        }
        return build(
            managedApps: managedApps,
            configuredBundleIDs: configuredBundleIDs
        )
    }

    static func build(
        managedApps: [WorkspaceBarManagedAppCandidate],
        configuredBundleIDs: [String]
    ) -> [WorkspaceBarAppCandidate] {
        var candidatesByID: [String: WorkspaceBarAppCandidate] = [:]

        for managedApp in managedApps {
            guard let bundleID = normalizedBundleID(managedApp.bundleID) else { continue }
            let key = bundleID.lowercased()
            if var existing = candidatesByID[key] {
                existing.name = existing.name ?? managedApp.name
                existing.icon = existing.icon ?? managedApp.icon
                existing.bundleURL = existing.bundleURL ?? managedApp.bundleURL
                existing.isManaged = true
                candidatesByID[key] = existing
            } else {
                candidatesByID[key] = WorkspaceBarAppCandidate(
                    bundleID: bundleID,
                    name: managedApp.name,
                    icon: managedApp.icon,
                    isManaged: true,
                    bundleURL: managedApp.bundleURL
                )
            }
        }

        for configuredBundleID in configuredBundleIDs {
            guard let bundleID = normalizedBundleID(configuredBundleID) else { continue }
            let key = bundleID.lowercased()
            if var existing = candidatesByID[key] {
                existing.bundleID = bundleID
                candidatesByID[key] = existing
            } else {
                candidatesByID[key] = WorkspaceBarAppCandidate(
                    bundleID: bundleID,
                    name: nil,
                    icon: nil,
                    isManaged: false,
                    bundleURL: nil
                )
            }
        }

        return candidatesByID.values.sorted(by: WorkspaceBarAppCandidate.sort)
    }

    static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
