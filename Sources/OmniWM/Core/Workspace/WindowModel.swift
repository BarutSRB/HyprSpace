// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum TrackedWindowMode: Equatable, Hashable, Sendable {
    case tiling
    case floating
}

struct ManagedReplacementMetadata: Equatable, Sendable {
    var bundleId: String?
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var role: String?
    var subrole: String?
    var title: String?
    var windowLevel: Int32?
    var parentWindowId: UInt32?
    var frame: CGRect?
    var transientWindowServerEvidence = false
    var degradedWindowServerChildEvidence = false

    func mergingNonNilValues(from overlay: ManagedReplacementMetadata) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: overlay.bundleId ?? bundleId,
            workspaceId: overlay.workspaceId,
            mode: overlay.mode,
            role: overlay.role ?? role,
            subrole: overlay.subrole ?? subrole,
            title: overlay.title ?? title,
            windowLevel: overlay.windowLevel ?? windowLevel,
            parentWindowId: overlay.parentWindowId ?? parentWindowId,
            frame: overlay.frame ?? frame,
            transientWindowServerEvidence: transientWindowServerEvidence || overlay.transientWindowServerEvidence,
            degradedWindowServerChildEvidence: degradedWindowServerChildEvidence
                || overlay.degradedWindowServerChildEvidence
        )
    }
}

final class WindowModel {
    typealias WindowKey = WindowToken

    private struct WorkspaceModeKey: Hashable {
        let workspaceId: WorkspaceDescriptor.ID
        let mode: TrackedWindowMode
    }

    private struct ConstraintsCacheRecord {
        let constraints: WindowSizeConstraints
        let cachedAt: Date
    }

    private(set) var entries: [WindowToken: WindowState] = [:]
    private var windowIdToToken: [Int: WindowToken] = [:]
    private var handleByToken: [WindowToken: WindowHandle] = [:]
    private var constraintsCacheByToken: [WindowToken: ConstraintsCacheRecord] = [:]
    private var observedMinSizeByToken: [WindowToken: CGSize] = [:]
    private var tokensByWorkspace: [WorkspaceDescriptor.ID: [WindowToken]] = [:]
    private var tokenIndexByWorkspace: [WorkspaceDescriptor.ID: [WindowToken: Int]] = [:]
    private var tokensByWorkspaceMode: [WorkspaceModeKey: [WindowToken]] = [:]
    private var tokenIndexByWorkspaceMode: [WorkspaceModeKey: [WindowToken: Int]] = [:]
    private var tokensByPid: [pid_t: [WindowToken]] = [:]
    private var tokenIndexByPid: [pid_t: [WindowToken: Int]] = [:]

    private func appendToken<Key: Hashable>(
        _ token: WindowToken,
        to key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        guard tokenIndexByKey[key]?[token] == nil else { return }
        let index = tokensByKey[key]?.count ?? 0
        tokensByKey[key, default: []].append(token)
        tokenIndexByKey[key, default: [:]][token] = index
    }

    private func removeTokenFromBucket(
        _ token: WindowToken,
        tokens: inout [WindowToken],
        indexByToken: inout [WindowToken: Int]
    ) -> Bool {
        guard let index = indexByToken.removeValue(forKey: token) else { return tokens.isEmpty }
        tokens.remove(at: index)
        for position in index ..< tokens.count {
            indexByToken[tokens[position]] = position
        }
        return tokens.isEmpty
    }

    private func removeToken<Key: Hashable>(
        _ token: WindowToken,
        from key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        guard tokensByKey[key] != nil,
              tokenIndexByKey[key]?[token] != nil
        else {
            return
        }

        let bucketIsEmpty = removeTokenFromBucket(
            token,
            tokens: &tokensByKey[key]!,
            indexByToken: &tokenIndexByKey[key]!
        )
        if bucketIsEmpty {
            tokensByKey.removeValue(forKey: key)
            tokenIndexByKey.removeValue(forKey: key)
        }
    }

    private func replaceTokenInBucket(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        tokens: inout [WindowToken],
        indexByToken: inout [WindowToken: Int]
    ) {
        guard let index = indexByToken.removeValue(forKey: oldToken) else { return }
        tokens[index] = newToken
        indexByToken[newToken] = index
    }

    private func replaceToken<Key: Hashable>(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in key: Key,
        tokensByKey: inout [Key: [WindowToken]],
        tokenIndexByKey: inout [Key: [WindowToken: Int]]
    ) {
        guard tokensByKey[key] != nil,
              tokenIndexByKey[key]?[oldToken] != nil
        else {
            return
        }
        replaceTokenInBucket(
            from: oldToken,
            to: newToken,
            tokens: &tokensByKey[key]!,
            indexByToken: &tokenIndexByKey[key]!
        )
    }

    private func appendIndexes(for entry: WindowState) {
        let token = entry.token
        windowIdToToken[entry.windowId] = token
        appendToken(
            token,
            to: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        appendToken(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        appendToken(token, to: entry.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
    }

    private func removeIndexes(for entry: WindowState, token: WindowToken? = nil, windowId: Int? = nil) {
        let token = token ?? entry.token
        let windowId = windowId ?? entry.windowId

        windowIdToToken.removeValue(forKey: windowId)
        removeToken(
            token,
            from: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        removeToken(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        removeToken(token, from: token.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
    }

    private func rekeyIndexes(for entry: WindowState, from oldToken: WindowToken, to newToken: WindowToken) {
        windowIdToToken.removeValue(forKey: oldToken.windowId)
        windowIdToToken[newToken.windowId] = newToken

        replaceToken(
            from: oldToken,
            to: newToken,
            in: entry.workspaceId,
            tokensByKey: &tokensByWorkspace,
            tokenIndexByKey: &tokenIndexByWorkspace
        )
        replaceToken(
            from: oldToken,
            to: newToken,
            in: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )

        if oldToken.pid == newToken.pid {
            replaceToken(
                from: oldToken,
                to: newToken,
                in: oldToken.pid,
                tokensByKey: &tokensByPid,
                tokenIndexByKey: &tokenIndexByPid
            )
        } else {
            removeToken(oldToken, from: oldToken.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
            appendToken(newToken, to: newToken.pid, tokensByKey: &tokensByPid, tokenIndexByKey: &tokenIndexByPid)
        }
    }

    @discardableResult
    func upsert(
        window: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let existingToken = windowIdToToken[windowId], existingToken != token {
            Log.reconcile.fault(
                "WindowModel rejected duplicate windowId=\(windowId) existing=\(existingToken.pid):\(existingToken.windowId) proposed=\(token.pid):\(token.windowId)"
            )
            return existingToken
        }
        if entries[token] != nil {
            entries[token]?.axRef = window
            updateWorkspace(for: token, workspace: workspace)
            setMode(mode, for: token)
            if let managedReplacementMetadata {
                entries[token]?.managedReplacementMetadata = managedReplacementMetadata
            }
            if entries[token]?.ruleEffects != ruleEffects {
                entries[token]?.ruleEffects = ruleEffects
                constraintsCacheByToken.removeValue(forKey: token)
            }
            entries[token]?.admissionHints = admissionHints
            entries[token]?.lifetimeAuthority = lifetimeAuthority
            return token
        }

        let entry = WindowState(
            token: token,
            axRef: window,
            workspaceId: workspace,
            mode: mode,
            managedReplacementMetadata: managedReplacementMetadata,
            ruleEffects: ruleEffects,
            admissionHints: admissionHints,
            lifetimeAuthority: lifetimeAuthority
        )
        entries[token] = entry
        handleByToken[token] = WindowHandle(id: token)
        appendIndexes(for: entry)
        return token
    }

    func setLifetimeAuthority(
        _ authority: ManagedWindowLifetimeAuthority,
        for token: WindowToken
    ) {
        entries[token]?.lifetimeAuthority = authority
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        if oldToken == newToken {
            guard entries[oldToken] != nil else { return nil }
            entries[oldToken]?.axRef = newAXRef
            constraintsCacheByToken.removeValue(forKey: oldToken)
            if let managedReplacementMetadata {
                entries[oldToken]?.managedReplacementMetadata = managedReplacementMetadata
            }
            return entries[oldToken]
        }

        if let existingToken = windowIdToToken[newToken.windowId], existingToken != oldToken {
            Log.reconcile.fault(
                "WindowModel rejected rekey windowId=\(newToken.windowId) existing=\(existingToken.pid):\(existingToken.windowId) proposed=\(newToken.pid):\(newToken.windowId)"
            )
            return nil
        }

        guard entries[newToken] == nil,
              var entry = entries.removeValue(forKey: oldToken)
        else {
            return nil
        }

        entry.token = newToken
        entry.axRef = newAXRef
        constraintsCacheByToken.removeValue(forKey: oldToken)
        let preservesAXIncarnation = CFEqual(entry.axRef.element, newAXRef.element)
        if let minSize = observedMinSizeByToken.removeValue(forKey: oldToken), preservesAXIncarnation {
            observedMinSizeByToken[newToken] = minSize
        }
        if let handle = handleByToken.removeValue(forKey: oldToken) {
            handle.id = newToken
            handleByToken[newToken] = handle
        }
        if let managedReplacementMetadata {
            entry.managedReplacementMetadata = managedReplacementMetadata
        }
        entries[newToken] = entry
        rekeyIndexes(for: entry, from: oldToken, to: newToken)

        return entry
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        handleByToken[token]
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        guard let entry = entries[token] else { return }
        let oldWorkspace = entry.workspaceId
        if oldWorkspace != workspace {
            removeToken(
                token,
                from: oldWorkspace,
                tokensByKey: &tokensByWorkspace,
                tokenIndexByKey: &tokenIndexByWorkspace
            )
            removeToken(
                token,
                from: WorkspaceModeKey(workspaceId: oldWorkspace, mode: entry.mode),
                tokensByKey: &tokensByWorkspaceMode,
                tokenIndexByKey: &tokenIndexByWorkspaceMode
            )
            appendToken(token, to: workspace, tokensByKey: &tokensByWorkspace, tokenIndexByKey: &tokenIndexByWorkspace)
            appendToken(
                token,
                to: WorkspaceModeKey(workspaceId: workspace, mode: entry.mode),
                tokensByKey: &tokensByWorkspaceMode,
                tokenIndexByKey: &tokenIndexByWorkspaceMode
            )
        }
        entries[token]?.workspaceId = workspace
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        guard let tokens = tokensByWorkspace[workspace] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func windowCount(in workspace: WorkspaceDescriptor.ID) -> Int {
        tokensByWorkspace[workspace]?.count ?? 0
    }

    func windows(
        in workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> [WindowState] {
        let key = WorkspaceModeKey(workspaceId: workspace, mode: mode)
        guard let tokens = tokensByWorkspaceMode[key] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        entries[token]?.workspaceId
    }

    func entry(for token: WindowToken) -> WindowState? {
        entries[token]
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        entry(for: handle.id)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        entry(for: WindowToken(pid: pid, windowId: windowId))
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        guard let tokens = tokensByPid[pid] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        tokensByPid[pid]?.isEmpty == false
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        windowIdToToken[windowId].flatMap { entries[$0] }
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowState? {
        guard let entry = entry(forWindowId: windowId),
              visibleIds.contains(entry.workspaceId) else { return nil }
        return entry
    }

    func allEntries() -> [WindowState] {
        Array(entries.values)
    }

    func allEntries(mode: TrackedWindowMode) -> [WindowState] {
        tokensByWorkspaceMode
            .filter { $0.key.mode == mode }
            .values
            .flatMap { $0.compactMap { entries[$0] } }
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        entries[token]?.mode
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        guard let entry = entries[token], entry.mode != mode else { return }
        removeToken(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
        entries[token]?.mode = mode
        appendToken(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: mode),
            tokensByKey: &tokensByWorkspaceMode,
            tokenIndexByKey: &tokenIndexByWorkspaceMode
        )
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        entries[token]?.floatingState
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        entries[token]?.floatingState = state
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        entries[token]?.manualLayoutOverride
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        entries[token]?.manualLayoutOverride = override
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        entries[token]?.admissionHints
    }

    func setAdmissionHints(_ hints: ManagedWindowAdmissionHints, for token: WindowToken) {
        entries[token]?.admissionHints = hints
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        entries[token]?.lifecyclePhase
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        entries[token]?.lifecyclePhase = phase
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        entries[token]?.observedState
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        entries[token]?.observedState = state
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        entries[token]?.desiredState
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        entries[token]?.desiredState = state
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        entries[token]?.restoreIntent
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        entries[token]?.restoreIntent = intent
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        entries[token]?.managedReplacementMetadata
    }

    func setManagedReplacementMetadata(_ metadata: ManagedReplacementMetadata?, for token: WindowToken) {
        entries[token]?.managedReplacementMetadata = metadata
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        entries[token]?.hiddenState = state
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        entries[token]?.hiddenState
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        entries[token]?.hiddenState != nil
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        entries[token]?.layoutReason ?? .standard
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        entries[token]?.layoutReason == .nativeFullscreen
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        entries[token]?.layoutReason = reason
    }

    @discardableResult
    func restoreFromNativeState(for token: WindowToken) -> Bool {
        guard let entry = entries[token],
              entry.layoutReason != .standard
        else { return false }
        entries[token]?.layoutReason = .standard
        return true
    }

    @discardableResult
    func removeWindow(key: WindowKey) -> WindowState? {
        handleByToken.removeValue(forKey: key)
        constraintsCacheByToken.removeValue(forKey: key)
        observedMinSizeByToken.removeValue(forKey: key)
        guard let entry = entries[key] else { return nil }
        removeIndexes(for: entry, token: key, windowId: key.windowId)
        entries.removeValue(forKey: key)
        return entry
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        guard let record = constraintsCacheByToken[token],
              Date().timeIntervalSince(record.cachedAt) < maxAge
        else {
            return nil
        }
        return record.constraints
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard entries[token] != nil else { return }
        constraintsCacheByToken[token] = ConstraintsCacheRecord(
            constraints: constraints.normalized(),
            cachedAt: Date()
        )
    }

    func observedMinSize(for token: WindowToken) -> CGSize? {
        observedMinSizeByToken[token]
    }

    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        guard entries[token] != nil else { return false }
        if let existing = observedMinSizeByToken[token],
           abs(existing.width - size.width) <= FrameTolerance.frameWrite,
           abs(existing.height - size.height) <= FrameTolerance.frameWrite
        {
            return false
        }
        observedMinSizeByToken[token] = size
        return true
    }
}
