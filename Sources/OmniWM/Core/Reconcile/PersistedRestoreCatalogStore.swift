// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct PersistedWindowRestoreCatalogBuildSnapshot: Sendable {
    let entries: [PersistedWindowRestoreCatalogBuildEntry]
}

struct PersistedWindowRestoreCatalogBuildEntry: Sendable {
    let token: WindowToken
    let metadata: ManagedReplacementMetadata
    let workspaceName: String
    let topologyProfile: TopologyProfile
    let preferredMonitor: DisplayFingerprint?
    let floatingFrame: CGRect?
    let normalizedFloatingOrigin: CGPoint?
    let restoreToFloating: Bool
    let rescueEligible: Bool
    let niriPlacement: PersistedNiriPlacement?
    let detachedNiriContainerSizingState: NiriContainerSizingState?
    let dwindlePlacement: PersistedDwindlePlacement?
}

enum PersistedWindowRestoreCatalogBuilder {
    private struct Candidate {
        let key: PersistedWindowRestoreKey
        let entry: PersistedWindowRestoreEntry
    }

    static func build(from snapshot: PersistedWindowRestoreCatalogBuildSnapshot) -> PersistedWindowRestoreCatalog {
        var candidatesByBaseKey: [PersistedWindowRestoreBaseKey: [Candidate]] = [:]

        for snapshotEntry in snapshot.entries {
            guard let key = PersistedWindowRestoreKey(metadata: snapshotEntry.metadata) else { continue }
            let persistedEntry = PersistedWindowRestoreEntry(
                key: key,
                identity: PersistedWindowRestoreIdentity(
                    token: snapshotEntry.token,
                    metadata: snapshotEntry.metadata
                ),
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: snapshotEntry.workspaceName,
                    topologyProfile: snapshotEntry.topologyProfile,
                    preferredMonitor: snapshotEntry.preferredMonitor,
                    floatingFrame: snapshotEntry.floatingFrame,
                    normalizedFloatingOrigin: snapshotEntry.normalizedFloatingOrigin,
                    restoreToFloating: snapshotEntry.restoreToFloating,
                    rescueEligible: snapshotEntry.rescueEligible,
                    niriPlacement: snapshotEntry.niriPlacement,
                    detachedNiriContainerSizingState: snapshotEntry.detachedNiriContainerSizingState,
                    dwindlePlacement: snapshotEntry.dwindlePlacement
                )
            )
            candidatesByBaseKey[key.baseKey, default: []].append(
                Candidate(key: key, entry: persistedEntry)
            )
        }

        var persistedEntries: [PersistedWindowRestoreEntry] = []
        persistedEntries.reserveCapacity(candidatesByBaseKey.count)

        for candidates in candidatesByBaseKey.values {
            if candidates.count == 1, let candidate = candidates.first {
                persistedEntries.append(candidate.entry)
                continue
            }

            let identityCandidates = candidates.filter { $0.entry.identity != nil }
            persistedEntries.append(contentsOf: identityCandidates.map(\.entry))

            let semanticCandidates = candidates.filter { $0.entry.identity == nil }
            let candidatesByTitle = Dictionary(grouping: semanticCandidates, by: { $0.key.title })
            for (title, titledCandidates) in candidatesByTitle where title != nil && titledCandidates.count == 1 {
                if let candidate = titledCandidates.first {
                    persistedEntries.append(candidate.entry)
                }
            }
        }

        persistedEntries.sort { lhs, rhs in
            let lhsWorkspace = lhs.restoreIntent.workspaceName
            let rhsWorkspace = rhs.restoreIntent.workspaceName
            if lhsWorkspace != rhsWorkspace {
                return lhsWorkspace < rhsWorkspace
            }
            if lhs.key.baseKey.bundleId != rhs.key.baseKey.bundleId {
                return lhs.key.baseKey.bundleId < rhs.key.baseKey.bundleId
            }
            if (lhs.key.title ?? "") != (rhs.key.title ?? "") {
                return (lhs.key.title ?? "") < (rhs.key.title ?? "")
            }
            if lhs.identity?.pid != rhs.identity?.pid {
                return (lhs.identity?.pid ?? Int32.min) < (rhs.identity?.pid ?? Int32.min)
            }
            return (lhs.identity?.windowId ?? Int.min) < (rhs.identity?.windowId ?? Int.min)
        }

        return PersistedWindowRestoreCatalog(entries: persistedEntries)
    }
}

@MainActor
final class PersistedRestoreCatalogStore {
    let bootCatalog: PersistedWindowRestoreCatalog
    private(set) var consumedBootEntries: Set<PersistedWindowRestoreConsumptionKey> = []

    private var dirty = false
    private var saveScheduled = false
    private var buildInFlight = false
    private var revision: UInt64 = 0
    private let buildSnapshot: @MainActor () -> PersistedWindowRestoreCatalogBuildSnapshot
    private let save: @MainActor (PersistedWindowRestoreCatalog) -> Void

    init(
        bootCatalog: PersistedWindowRestoreCatalog,
        buildSnapshot: @escaping @MainActor () -> PersistedWindowRestoreCatalogBuildSnapshot,
        save: @escaping @MainActor (PersistedWindowRestoreCatalog) -> Void
    ) {
        self.bootCatalog = bootCatalog
        self.buildSnapshot = buildSnapshot
        self.save = save
    }

    func noteConsumed(_ key: PersistedWindowRestoreConsumptionKey) {
        consumedBootEntries.insert(key)
    }

    func scheduleSave() {
        markDirty()
        enqueueSave()
    }

    func flushNow() {
        markDirty()
        dirty = false
        save(PersistedWindowRestoreCatalogBuilder.build(from: buildSnapshot()))
    }

    private func markDirty() {
        dirty = true
        revision &+= 1
    }

    private func enqueueSave() {
        guard !saveScheduled, !buildInFlight else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.saveScheduled = false
            self.startBuildIfNeeded()
        }
    }

    private func startBuildIfNeeded() {
        guard dirty else { return }
        dirty = false
        buildInFlight = true
        let revision = revision
        let snapshot = buildSnapshot()

        Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) {
                PersistedWindowRestoreCatalogBuilder.build(from: snapshot)
            }.value
            self?.completeBuild(catalog, revision: revision)
        }
    }

    private func completeBuild(_ catalog: PersistedWindowRestoreCatalog, revision: UInt64) {
        buildInFlight = false
        if revision == self.revision, !dirty {
            save(catalog)
            return
        }
        if dirty {
            enqueueSave()
        }
    }
}
