// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let perAppTimeout: TimeInterval = 0.5
private let maxConcurrentFullRescanEnumerations = 4

private struct IndexedAsyncValue<Value: Sendable>: Sendable {
    let index: Int
    let value: Value
}

struct AXFrameApplicationTarget: Sendable {
    let pid: pid_t
    let expectedWindow: AXWindowRef
    let frame: CGRect

    var windowId: Int {
        expectedWindow.windowId
    }

    init(pid: pid_t, window: AXWindowRef, frame: CGRect) {
        self.pid = pid
        expectedWindow = window
        self.frame = frame
    }
}

func boundedFullRescanMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    maxConcurrent: Int,
    priority: @Sendable @escaping (Input) -> TaskPriority? = { _ in nil },
    operation: @Sendable @escaping (Input) async throws -> Output
) async throws -> [Output] {
    guard !inputs.isEmpty else { return [] }
    precondition(maxConcurrent > 0)
    return try await withThrowingTaskGroup(of: IndexedAsyncValue<Output>.self) { group in
        var nextIndex = 0
        let initialCount = min(maxConcurrent, inputs.count)
        for index in 0 ..< initialCount {
            try Task.checkCancellation()
            let input = inputs[index]
            guard group.addTaskUnlessCancelled(priority: priority(input), operation: {
                IndexedAsyncValue(index: index, value: try await operation(input))
            }) else { throw CancellationError() }
            nextIndex += 1
        }

        var completed: [IndexedAsyncValue<Output>] = []
        completed.reserveCapacity(inputs.count)
        while let result = try await group.next() {
            completed.append(result)
            try Task.checkCancellation()
            if nextIndex < inputs.count {
                let index = nextIndex
                let input = inputs[index]
                guard group.addTaskUnlessCancelled(priority: priority(input), operation: {
                    IndexedAsyncValue(index: index, value: try await operation(input))
                }) else { throw CancellationError() }
                nextIndex += 1
            }
        }
        completed.sort { $0.index < $1.index }
        return completed.map(\.value)
    }
}

private struct FullRescanAppEnumerationResult: Sendable {
    let pid: pid_t
    let route: FullRescanEnumerationRoute
    let windows: [AXEnumeratedWindow]
    let failed: Bool
    let callbackGeneration: UInt64?
}

private struct FullRescanAppTarget: @unchecked Sendable {
    let app: NSRunningApplication
    let route: FullRescanEnumerationRoute
    let inspectionContext: AXWindowInspectionContext
    let includedWindowIds: Set<Int>?
}

private struct FullRescanDiscoveryEvidence {
    var pidsWithWindows: Set<pid_t>
    var windowServerInfoByWindowId: [Int: WindowServerInfo]
    var ownerPIDByWindowId: [Int: pid_t]
}

private struct FullRescanCandidateCollection {
    var candidatesByWindowId: [Int: [FullRescanWindowCandidate]]
    var identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
    var failedPIDs: Set<pid_t>
}

struct FullRescanTargetResolution: Equatable {
    let explicitAppPIDs: Set<pid_t>
    let resolvedTargetPIDs: Set<pid_t>
    let resolvedTargetWindowIds: Set<Int>
    let targetPIDs: Set<pid_t>
    let nativeSpaceIds: Set<UInt64>
    let nativeSpaceWindowIdsByPID: [pid_t: Set<Int>]
    var relevantWindowIds: Set<Int>
    var targetPIDsByWindowId: [Int: Set<pid_t>]
    var dependencyPIDs: Set<pid_t>
    var targetPIDsByDependencyPID: [pid_t: Set<pid_t>]

    var effectiveScope: RescanScope {
        .targeted(
            appPIDs: targetPIDs.union(dependencyPIDs),
            nativeSpaceIds: nativeSpaceIds,
            nativeSpaceWindowIdsByPID: nativeSpaceWindowIdsByPID
        )
    }
}

private struct FullRescanEnumerationCoverage {
    let targetPIDs: Set<pid_t>
    let dependencyPIDs: Set<pid_t>
    let targetPIDsByDependencyPID: [pid_t: Set<pid_t>]
    let unavailableTargetPIDs: Set<pid_t>
    let unavailableDependencyPIDs: Set<pid_t>
    let exactWindowIds: Set<Int>?
}

struct AXManagedWindowRebindAcknowledgement {
    let oldPID: pid_t
    let oldContext: AppAXContext?
    let oldCallbackGeneration: UInt64?
    let destinationContext: AppAXContext
    let destinationCallbackGeneration: UInt64
    let destinationBinding: AppAXWindowRebindBinding
}

enum FullRescanCandidatePreferenceReason: String, Equatable, Sendable {
    case manageability = "manageability"
    case preservedLogicalPID = "preserved_logical_pid"
    case regularActivationPolicy = "regular_activation_policy"
    case axHostPID = "ax_host_pid"
    case windowServerOwnerPID = "window_server_owner_pid"
    case lowerPID = "lower_pid"
    case stableFirstCandidate = "stable_first_candidate"
}

struct FullRescanCandidatePreference: Equatable, Sendable {
    let prefersCandidate: Bool
    let reason: FullRescanCandidatePreferenceReason
}

struct FullRescanWindowIdentityAliases {
    var pids: Set<pid_t> = []
    var axRefs: [AXWindowRef] = []
}

@MainActor
final class AXManager {
    typealias FrameApplicationTerminalObserver = AXFrameApplicationTerminalObserver

    struct FullRescanEnumerationSnapshot {
        let windows: [FullRescanWindowCandidate]
        let successfullyEnumeratedPIDs: Set<pid_t>
        let failedPIDs: Set<pid_t>
        let authoritativeTargetPIDs: Set<pid_t>
        let exactWindowIds: Set<Int>?
        let identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
        let windowServerInfoByWindowId: [Int: WindowServerInfo]
    }

    private static let systemUIBundleIds: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight"
    ]

    private var appTerminationObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    var onAppLaunched: ((NSRunningApplication) -> Void)?
    var onAppTerminated: ((pid_t) -> Void)?
    var isWindowParked: ((Int) -> Bool)?
    var onTerminalFrameRefusal: ((AXFrameTerminalRefusal) -> Void)?
    var onFrameApplySucceeded: ((AXFrameApplyResult) -> Void)?
    var onManagedWindowBindingFailed: ((pid_t) -> Void)?
    var managedWindowBindingRetryDelayProvider: (Int) -> Duration? = {
        AXManager.managedWindowBindingRetryDelay(afterFailure: $0)
    }

    private let frameLedger = AXFrameApplicationLedger()
    private var framesByPidBuffer: [pid_t: [AXFrameApplicationRequest]] = [:]
    private var frameApplicationBufferInUse = false
    private var pendingFrameRetryTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var pendingFrameRetryGenerationByWindowId: [Int: UInt64] = [:]
    private var nextFrameRetryGeneration: UInt64 = 1
    private struct ManagedWindowBindingRetryState {
        let generation: UInt64
        var failures: Int
        var task: Task<Void, Never>?
    }

    private var nextManagedWindowBindingGeneration: UInt64 = 1
    private var managedWindowBindingRetryStateByPID: [pid_t: ManagedWindowBindingRetryState] = [:]

    /// Window IDs belonging to inactive workspaces — checked LIVE in applyFramesParallel.
    private(set) var inactiveWorkspaceWindowIds: Set<Int> = []
    private(set) var macOSHiddenAppPIDs: Set<pid_t> = []

    private var skyLightLivePositionByWindowId: [Int: CGPoint] = [:]

    private struct PendingParkFrameRequest {
        let request: AXFrameApplicationRequest
        let retriesRemaining: Int
    }

    private struct ParkFrameTargetState {
        let target: AXFrameApplicationTarget
        var isVerified: Bool
    }

    private(set) var pendingParkWindowIds: Set<Int> = []
    private var pendingParkFrameRequestsByWindowId: [Int: PendingParkFrameRequest] = [:]
    private var parkFrameTargetStatesByWindowId: [Int: ParkFrameTargetState] = [:]
    private var parkPIDByWindowId: [Int: pid_t] = [:]
    private var nextParkFrameRequestId: AXFrameRequestId = 1

    var interactionPolicyForWindowId: ((Int) -> WindowInteractionPolicy)?

    init() {
        installWorkspaceObservers()
    }

    func installWorkspaceObservers() {
        if appTerminationObserver == nil {
            setupTerminationObserver()
        }
        if appLaunchObserver == nil {
            setupLaunchObserver()
        }
    }

    private func setupTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            if WindowAdmissionTrace.shared.isActive, pid != getpid() {
                WindowAdmissionTrace.record(
                    .init(
                        action: .processTerminated,
                        pid: pid,
                        bundleId: app.bundleIdentifier
                    )
                )
            }
            Task { @MainActor in
                self?.clearManagedWindowBindingRetry(for: pid)
                self?.clearParkFrameState(for: pid, reason: "context-teardown")
                self?.onAppTerminated?(pid)
                if let context = AppAXContext.contexts[pid] {
                    context.destroy()
                }
            }
        }
    }

    private func setupLaunchObserver() {
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if WindowAdmissionTrace.shared.isActive, app.processIdentifier != getpid() {
                WindowAdmissionTrace.record(
                    .init(
                        action: .processLaunched,
                        pid: app.processIdentifier,
                        bundleId: app.bundleIdentifier
                    )
                )
            }
            Task { @MainActor in
                self?.onAppLaunched?(app)
            }
        }
    }

    func updateInactiveWorkspaceWindows(
        allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        nativeInactiveWindowIds: Set<Int> = []
    ) {
        inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
        for (wsId, windowId) in allEntries {
            if !activeWorkspaceIds.contains(wsId) {
                inactiveWorkspaceWindowIds.insert(windowId)
            }
        }
        inactiveWorkspaceWindowIds.formUnion(nativeInactiveWindowIds)
    }

    func markWindowActive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.remove(windowId)
    }

    func markWindowInactive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.insert(windowId)
    }

    func forceApplyNextFrame(for windowId: Int) {
        frameLedger.forceApplyNextFrame(for: windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        frameLedger.lastAppliedFrame(for: windowId)
    }

    func recordSkyLightMove(windowId: Int, origin: CGPoint) {
        skyLightLivePositionByWindowId[windowId] = origin
    }

    func skyLightLivePosition(for windowId: Int) -> CGPoint? {
        skyLightLivePositionByWindowId[windowId]
    }

    func clearSkyLightLivePositions() {
        skyLightLivePositionByWindowId.removeAll(keepingCapacity: true)
    }

    func markParkPending(_ target: AXFrameApplicationTarget) {
        markParkPending(
            for: target.windowId,
            pid: target.pid,
            target: target,
            cancellationReason: "animation"
        )
    }

    func markParkPending(for windowId: Int, pid: pid_t) {
        markParkPending(
            for: windowId,
            pid: pid,
            target: nil,
            cancellationReason: nil
        )
    }

    private func markParkPending(
        for windowId: Int,
        pid: pid_t,
        target: AXFrameApplicationTarget?,
        cancellationReason: String?
    ) {
        let pending = pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
        let targetState = parkFrameTargetStatesByWindowId[windowId]
        if let pending {
            AppAXContext.contexts[pending.request.pid]?.cancelParkFrameJob(for: windowId)
        }
        let retainedTarget = target
            ?? pending.map {
                AXFrameApplicationTarget(
                    pid: $0.request.pid,
                    window: $0.request.expectedWindow,
                    frame: $0.request.frame
                )
            }
            ?? targetState?.target
        if let retainedTarget {
            parkFrameTargetStatesByWindowId[windowId] = ParkFrameTargetState(
                target: retainedTarget,
                isVerified: false
            )
        } else {
            parkFrameTargetStatesByWindowId.removeValue(forKey: windowId)
        }
        pendingParkWindowIds.insert(windowId)
        parkPIDByWindowId[windowId] = pid
        let cancelledTarget = pending?.request.frame
            ?? (targetState?.isVerified == true ? targetState?.target.frame : nil)
        if let cancellationReason, let cancelledTarget {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "outcome=ax-park-cancelled/\(cancellationReason)",
                target: cancelledTarget
            )
        }
    }

    func clearParkPending(for windowId: Int, pid: pid_t, reason: String = "revealed") {
        cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: reason)
    }

    private func clearSkyLightLivePosition(for windowId: Int) {
        skyLightLivePositionByWindowId.removeValue(forKey: windowId)
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        frameLedger.recentFrameWriteFailure(for: windowId)
    }

    func hasContext(for pid: pid_t) -> Bool {
        AppAXContext.contexts[pid] != nil
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        frameLedger.hasPendingFrameWrite(for: windowId)
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        frameLedger.pendingFrameWrite(for: windowId)
    }

    func frameStateDump() -> String {
        var sections = ["Ledger:\n\(frameLedger.stateDump())"]
        let inactive = inactiveWorkspaceWindowIds.sorted()
        let inactiveText = inactive.isEmpty ? "none" : inactive.map(String.init).joined(separator: ",")
        sections.append("inactiveWorkspaceWindows=\(inactiveText)")
        let retryTasks = pendingFrameRetryTasksByWindowId.keys.sorted()
        if !retryTasks.isEmpty {
            sections.append("pendingRetryTasks=" + retryTasks.map(String.init).joined(separator: ","))
        }
        if !pendingFrameRetryGenerationByWindowId.isEmpty {
            let generations = pendingFrameRetryGenerationByWindowId.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            sections.append("retryGenerations=" + generations)
        }
        return sections.joined(separator: "\n")
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        frameLedger.shouldSuppressFrameChangeRelayout(for: windowId, observedFrame: observedFrame)
    }

    func clearInactiveWorkspaceWindows() {
        inactiveWorkspaceWindowIds.removeAll()
    }

    func rebindWindowAsync(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        timeoutSeconds: TimeInterval = 0.5
    ) async -> AXManagedWindowRebindAcknowledgement? {
        let destinationContext: AppAXContext
        if let existing = AppAXContext.contexts[newWindow.token.pid] {
            destinationContext = existing
        } else {
            guard let app = NSRunningApplication(processIdentifier: newWindow.token.pid),
                  !app.isTerminated,
                  let created = try? await AppAXContext.getOrCreate(app)
            else {
                return nil
            }
            destinationContext = created
        }

        guard AppAXContext.contexts[newWindow.token.pid] === destinationContext else {
            return nil
        }
        let oldContext = AppAXContext.contexts[oldWindow.token.pid]
        let oldCallbackGeneration = oldContext?.callbackGeneration
        let binding: AppAXWindowRebindBinding?
        do {
            binding = try await destinationContext.rebindWindowAsync(
                oldWindowId: oldWindow.token.windowId,
                newWindow: newWindow.axRef,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return nil
        }
        guard let binding else { return nil }
        return AXManagedWindowRebindAcknowledgement(
            oldPID: oldWindow.token.pid,
            oldContext: oldContext,
            oldCallbackGeneration: oldCallbackGeneration,
            destinationContext: destinationContext,
            destinationCallbackGeneration: destinationContext.callbackGeneration,
            destinationBinding: binding
        )
    }

    func rollbackWindowRebind(
        _ acknowledgement: AXManagedWindowRebindAcknowledgement,
        newWindow: AXManagedWindowIdentity
    ) {
        acknowledgement.destinationContext.rollbackWindowRebind(
            acknowledgement.destinationBinding,
            newWindow: newWindow.axRef
        )
    }

    func isCurrentWindowRebindAcknowledgement(
        _ acknowledgement: AXManagedWindowRebindAcknowledgement,
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) -> Bool {
        guard acknowledgement.oldPID == oldWindow.token.pid,
              acknowledgement.destinationContext.pid == newWindow.token.pid,
              AppAXContext.contexts[newWindow.token.pid] === acknowledgement.destinationContext,
              acknowledgement.destinationContext.callbackGeneration
              == acknowledgement.destinationCallbackGeneration
        else {
            return false
        }
        guard oldWindow.token.pid != newWindow.token.pid else {
            return true
        }
        guard let oldContext = acknowledgement.oldContext else {
            return AppAXContext.contexts[oldWindow.token.pid] == nil
        }
        return AppAXContext.contexts[oldWindow.token.pid] === oldContext
            && oldContext.callbackGeneration == acknowledgement.oldCallbackGeneration
    }

    func finalizeWindowRebindContextState(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) async -> Bool {
        if let acknowledgement {
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
            guard (try? await acknowledgement.destinationContext.commitWindowRebindAsync(
                oldWindow: oldWindow.axRef,
                newWindow: newWindow.axRef,
                binding: acknowledgement.destinationBinding,
                retireOldWindowState: acknowledgement.oldContext === acknowledgement.destinationContext
            )) == true else {
                return false
            }
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
            if acknowledgement.oldContext !== acknowledgement.destinationContext {
                if let oldContext = acknowledgement.oldContext,
                   (try? await oldContext.removeWindowStateAsync(
                       expectedWindow: oldWindow.axRef
                   )) == nil
                {
                    return false
                }
            }
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
        }
        return true
    }

    @discardableResult
    func commitFrameApplicationStateForRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        acknowledgement: AXManagedWindowRebindAcknowledgement? = nil
    ) -> AXFrameApplicationTarget? {
        let oldWindowId = oldWindow.token.windowId
        let newWindowId = newWindow.token.windowId
        let parkFrame = pendingParkFrameRequestsByWindowId[oldWindowId]?.request.frame
            ?? parkFrameTargetStatesByWindowId[oldWindowId]?.target.frame
            ?? pendingParkFrameRequestsByWindowId[newWindowId]?.request.frame
            ?? parkFrameTargetStatesByWindowId[newWindowId]?.target.frame
        let shouldReissuePark = pendingParkWindowIds.contains(oldWindowId)
            || pendingParkWindowIds.contains(newWindowId)
            || pendingParkFrameRequestsByWindowId[oldWindowId] != nil
            || pendingParkFrameRequestsByWindowId[newWindowId] != nil
            || parkFrameTargetStatesByWindowId[oldWindowId] != nil
            || parkFrameTargetStatesByWindowId[newWindowId] != nil
            || isWindowParked?(oldWindowId) == true
            || isWindowParked?(newWindowId) == true
        cancelParkFrameJobs(
            [
                (pid: oldWindow.token.pid, windowId: oldWindowId),
                (pid: newWindow.token.pid, windowId: newWindowId)
            ],
            reason: "rekey"
        )
        if let acknowledgement {
            if acknowledgement.oldContext === acknowledgement.destinationContext {
                acknowledgement.destinationContext.prepareWindowRebind(
                    from: oldWindowId,
                    to: newWindowId
                )
            } else {
                acknowledgement.oldContext?.prepareWindowRemoval(for: oldWindowId)
                acknowledgement.oldContext?.invalidateWindowIdentity()
                acknowledgement.destinationContext.prepareWindowRemoval(for: newWindowId)
                acknowledgement.destinationContext.invalidateWindowIdentity()
            }
        }
        let isIncarnationReplacement = oldWindow.token.pid != newWindow.token.pid
            || oldWindowId == newWindowId
        let deliveries = resetFrameApplicationStateForRebind(
            oldWindowId: oldWindowId,
            newWindowId: newWindowId,
            isIncarnationReplacement: isIncarnationReplacement
        )
        for delivery in deliveries {
            delivery.deliver()
        }
        var retainedParkTarget: AXFrameApplicationTarget?
        if shouldReissuePark {
            markParkPending(for: newWindowId, pid: newWindow.token.pid)
            if let parkFrame {
                retainedParkTarget = AXFrameApplicationTarget(
                    pid: newWindow.token.pid,
                    window: newWindow.axRef,
                    frame: parkFrame
                )
            }
        }
        FrameApplyTrace.recordEvent(
            pid: newWindow.token.pid,
            windowId: oldWindowId,
            outcome: "outcome=rebind→\(newWindowId)"
        )
        return retainedParkTarget
    }

    private func resetFrameApplicationStateForRebind(
        oldWindowId: Int,
        newWindowId: Int,
        isIncarnationReplacement: Bool
    ) -> [AXFrameTerminalDelivery] {
        var deliveries = isIncarnationReplacement
            ? frameLedger.removeWindowState(windowId: oldWindowId)
            : frameLedger.cancelFrameJob(windowId: oldWindowId)
        cancelPendingFrameRetry(for: oldWindowId)
        if oldWindowId != newWindowId {
            cancelPendingFrameRetry(for: newWindowId)
            if isIncarnationReplacement {
                deliveries.append(contentsOf: frameLedger.removeWindowState(windowId: newWindowId))
            } else {
                frameLedger.rekeyWindowState(oldWindowId: oldWindowId, newWindowId: newWindowId)
            }
            rekeyAuxiliaryWindowState(from: oldWindowId, to: newWindowId)
        }
        if isIncarnationReplacement {
            resetIncarnationAuxiliaryState(oldWindowId: oldWindowId, newWindowId: newWindowId)
        }
        frameLedger.forceApplyNextFrame(for: newWindowId)
        clearSkyLightLivePosition(for: oldWindowId)
        clearSkyLightLivePosition(for: newWindowId)
        return deliveries
    }

    private func rekeyAuxiliaryWindowState(from oldWindowId: Int, to newWindowId: Int) {
        if inactiveWorkspaceWindowIds.remove(oldWindowId) != nil {
            inactiveWorkspaceWindowIds.insert(newWindowId)
        }
    }

    private func resetIncarnationAuxiliaryState(oldWindowId: Int, newWindowId: Int) {
        pendingParkWindowIds.remove(oldWindowId)
        pendingParkWindowIds.remove(newWindowId)
        pendingParkFrameRequestsByWindowId.removeValue(forKey: oldWindowId)
        pendingParkFrameRequestsByWindowId.removeValue(forKey: newWindowId)
        parkFrameTargetStatesByWindowId.removeValue(forKey: oldWindowId)
        parkFrameTargetStatesByWindowId.removeValue(forKey: newWindowId)
        parkPIDByWindowId.removeValue(forKey: oldWindowId)
        parkPIDByWindowId.removeValue(forKey: newWindowId)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        frameLedger.confirmFrameWrite(for: windowId, frame: frame)
        clearSkyLightLivePosition(for: windowId)
    }

    func removeWindowState(pid: pid_t, expectedWindow: AXWindowRef) {
        let windowId = expectedWindow.windowId
        cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "removed")
        AppAXContext.contexts[pid]?.prepareWindowRemoval(for: windowId)
        let deliveries = takeRemovedWindowLedgerState(windowId: windowId)
        AppAXContext.contexts[pid]?.removeWindowState(expectedWindow: expectedWindow)
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func removeWindowLedgerState(pid: pid_t, windowId: Int) {
        cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "removed")
        if let context = AppAXContext.contexts[pid] {
            context.prepareWindowRemoval(for: windowId)
            context.invalidateWindowIdentity()
        }
        let deliveries = takeRemovedWindowLedgerState(windowId: windowId)
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    private func takeRemovedWindowLedgerState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = frameLedger.removeWindowState(windowId: windowId)
        cancelPendingFrameRetry(for: windowId)
        inactiveWorkspaceWindowIds.remove(windowId)
        clearSkyLightLivePosition(for: windowId)

        return deliveries
    }

    private func clearParkFrameState(for pid: pid_t, reason: String) {
        var windowIds = Set(
            parkPIDByWindowId.compactMap { windowId, statePID in
                statePID == pid ? windowId : nil
            }
        )
        for (windowId, pending) in pendingParkFrameRequestsByWindowId
            where pending.request.pid == pid
        {
            windowIds.insert(windowId)
        }
        for (windowId, targetState) in parkFrameTargetStatesByWindowId
            where targetState.target.pid == pid
        {
            windowIds.insert(windowId)
        }
        cancelParkFrameJobs(
            windowIds.map { (pid: pid, windowId: $0) },
            reason: reason
        )
    }

    private func destroyContextIfPresent(for pid: pid_t, reason: String) {
        guard let context = AppAXContext.contexts[pid] else { return }
        clearParkFrameState(for: pid, reason: reason)
        context.destroy()
    }

    private func garbageCollectContexts() {
        for (pid, context) in Array(AppAXContext.contexts) where context.nsApp.isTerminated {
            clearParkFrameState(for: pid, reason: "context-garbage-collected")
            context.destroy()
        }
    }

    func cleanup() {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
        if let observer = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appLaunchObserver = nil
        }

        cancelAllPendingFrameState()
        for state in managedWindowBindingRetryStateByPID.values {
            state.task?.cancel()
        }
        managedWindowBindingRetryStateByPID.removeAll()

        AppAXContext.shutdownAll()
    }

    func windowsForApp(_ app: NSRunningApplication) async -> [(AXWindowRef, pid_t, Int)] {
        guard shouldTrack(app) else { return [] }
        var callbackGeneration: UInt64?
        do {
            guard let context = try await AppAXContext.getOrCreate(app) else {
                WindowAdmissionTrace.record(
                    .init(
                        action: .enumerationFailed,
                        pid: app.processIdentifier,
                        bundleId: app.bundleIdentifier,
                        reason: "context_unavailable"
                    )
                )
                return []
            }
            callbackGeneration = context.callbackGeneration
            let windows = try await context.getWindowsAsync(timeoutSeconds: perAppTimeout)
            return windows.map { ($0.axRef, app.processIdentifier, $0.axRef.windowId) }
        } catch {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationFailed,
                    pid: app.processIdentifier,
                    bundleId: app.bundleIdentifier,
                    reason: String(describing: error),
                    callbackGeneration: callbackGeneration
                )
            )
        }
        return []
    }

    func ensureContext(for app: NSRunningApplication) async -> Bool {
        guard shouldTrack(app) else { return false }
        return (try? await AppAXContext.getOrCreate(app)) != nil
    }

    func bindManagedWindows(_ entries: [WindowState]) {
        let windowsByPID = managedWindowsByPID(entries)
        for (pid, windows) in windowsByPID {
            submitManagedWindowBindings(
                pid: pid,
                windows: windows,
                authoritative: false,
                resetsRetryBudget: true
            )
        }
    }

    func reconcileManagedWindowBindings(
        _ entries: [WindowState],
        scopedPIDs: Set<pid_t>? = nil
    ) {
        let windowsByPID = managedWindowsByPID(entries, includedPIDs: scopedPIDs)
        let contextPIDs = Set(AppAXContext.contexts.keys)
        if scopedPIDs == nil {
            for pid in Set(managedWindowBindingRetryStateByPID.keys)
                where !contextPIDs.contains(pid) && windowsByPID[pid] == nil
            {
                clearManagedWindowBindingRetry(for: pid)
            }
        }
        let bindingPIDs = Self.managedWindowBindingPIDs(
            contextPIDs: contextPIDs,
            windowPIDs: Set(windowsByPID.keys),
            scopedPIDs: scopedPIDs
        )
        for pid in bindingPIDs {
            let windows = windowsByPID[pid] ?? [:]
            AppAXContext.contexts[pid]?.retainFrameState(only: Set(windows.keys))
            submitManagedWindowBindings(
                pid: pid,
                windows: windows,
                authoritative: true,
                resetsRetryBudget: false
            )
        }
    }

    nonisolated static func managedWindowBindingRetryDelay(afterFailure failure: Int) -> Duration? {
        switch failure {
        case 1: .milliseconds(100)
        case 2: .milliseconds(250)
        case 3: .milliseconds(500)
        default: nil
        }
    }

    static func managedWindowBindingPIDs(
        contextPIDs: Set<pid_t>,
        windowPIDs: Set<pid_t>,
        scopedPIDs: Set<pid_t>?
    ) -> Set<pid_t> {
        scopedPIDs ?? contextPIDs.union(windowPIDs)
    }

    func pendingManagedWindowBindingRetryPIDs(
        intersecting pids: Set<pid_t>
    ) -> Set<pid_t> {
        Set(managedWindowBindingRetryStateByPID.keys).intersection(pids)
    }

    private func managedWindowsByPID(
        _ entries: [WindowState],
        includedPIDs: Set<pid_t>? = nil
    ) -> [pid_t: [Int: AXWindowRef]] {
        var windowsByPID: [pid_t: [Int: AXWindowRef]] = [:]
        windowsByPID.reserveCapacity(min(entries.count, 8))
        for entry in entries where includedPIDs?.contains(entry.pid) ?? true {
            windowsByPID[entry.pid, default: [:]][entry.windowId] = entry.axRef
        }
        return windowsByPID
    }

    private func submitManagedWindowBindings(
        pid: pid_t,
        windows: [Int: AXWindowRef],
        authoritative: Bool,
        resetsRetryBudget: Bool
    ) {
        let previousState = managedWindowBindingRetryStateByPID[pid]
        previousState?.task?.cancel()
        let generation = nextManagedWindowBindingGeneration
        nextManagedWindowBindingGeneration &+= 1
        managedWindowBindingRetryStateByPID[pid] = .init(
            generation: generation,
            failures: resetsRetryBudget ? 0 : previousState?.failures ?? 0,
            task: nil
        )
        guard let context = AppAXContext.contexts[pid] else {
            handleManagedWindowBindingResult(.retryRequired, pid: pid, generation: generation)
            return
        }
        let completion: @MainActor @Sendable (AppAXWindowBindingResult) -> Void = { [weak self] in
            self?.handleManagedWindowBindingResult($0, pid: pid, generation: generation)
        }
        if authoritative {
            context.reconcileWindowBindings(windows, timeoutSeconds: perAppTimeout, completion: completion)
        } else {
            context.bindWindows(windows, timeoutSeconds: perAppTimeout, completion: completion)
        }
    }

    private func handleManagedWindowBindingResult(
        _ result: AppAXWindowBindingResult,
        pid: pid_t,
        generation: UInt64
    ) {
        guard var state = managedWindowBindingRetryStateByPID[pid],
              state.generation == generation
        else { return }
        guard case .retryRequired = result else {
            clearManagedWindowBindingRetry(for: pid)
            return
        }
        state.failures += 1
        guard let delay = managedWindowBindingRetryDelayProvider(state.failures) else {
            managedWindowBindingRetryStateByPID[pid] = state
            return
        }
        state.task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  var state = self.managedWindowBindingRetryStateByPID[pid],
                  state.generation == generation
            else { return }
            state.task = nil
            self.managedWindowBindingRetryStateByPID[pid] = state
            self.onManagedWindowBindingFailed?(pid)
        }
        managedWindowBindingRetryStateByPID[pid] = state
    }

    private func clearManagedWindowBindingRetry(for pid: pid_t) {
        managedWindowBindingRetryStateByPID.removeValue(forKey: pid)?.task?.cancel()
    }

    func requestPermission() -> Bool {
        if AccessibilityPermissionMonitor.shared.isGranted { return true }

        let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)

        return AccessibilityPermissionMonitor.shared.isGranted
    }

    func fullRescanEnumerationSnapshot(
        scope: RescanScope = .all,
        resolvedTargetPIDs: Set<pid_t> = [],
        resolvedTargetWindowIds: Set<Int> = [],
        supplementalWindowServerInfoByWindowId: [Int: WindowServerInfo] = [:],
        preservingPIDsByWindowId: [Int: pid_t] = [:],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>] = [:],
        requiresTitleForApp: (String?, String?) -> Bool = { _, _ in false }
    ) async throws -> FullRescanEnumerationSnapshot {
        try Task.checkCancellation()
        garbageCollectContexts()
        var discoveryEvidence: FullRescanDiscoveryEvidence
        let appTargets: [FullRescanAppTarget]
        let enumerationResults: [FullRescanAppEnumerationResult]
        let coverage: FullRescanEnumerationCoverage
        switch scope {
        case .all:
            discoveryEvidence = fullRescanDiscoveryEvidence()
            let runningApplications = NSWorkspace.shared.runningApplications
            appTargets = fullRescanAppTargets(
                runningApplications,
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                persistentEvidencePIDs: [],
                includedPIDs: nil,
                allowsEvidenceFreeOneShot: false,
                requiresTitleForApp: requiresTitleForApp
            )
            enumerationResults = try await enumerateFullRescanApps(appTargets)
            coverage = FullRescanEnumerationCoverage(
                targetPIDs: Set(appTargets.map { $0.app.processIdentifier }),
                dependencyPIDs: [],
                targetPIDsByDependencyPID: [:],
                unavailableTargetPIDs: [],
                unavailableDependencyPIDs: [],
                exactWindowIds: nil
            )
        case .targeted:
            discoveryEvidence = targetedFullRescanDiscoveryEvidence(
                supplementalWindowServerInfoByWindowId
            )
            let targeted = try await targetedFullRescanEnumeration(
                scope: scope,
                resolvedTargetPIDs: resolvedTargetPIDs,
                resolvedTargetWindowIds: resolvedTargetWindowIds,
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId,
                requiresTitleForApp: requiresTitleForApp
            )
            appTargets = targeted.appTargets
            enumerationResults = targeted.results
            coverage = targeted.coverage
            discoveryEvidence = targeted.discoveryEvidence
        }
        let activationPolicyByPID = Dictionary(
            uniqueKeysWithValues: appTargets.map { ($0.app.processIdentifier, $0.app.activationPolicy) }
        )
        let appsByPID = Dictionary(
            uniqueKeysWithValues: appTargets.map { ($0.app.processIdentifier, $0.app) }
        )
        try Task.checkCancellation()
        let collection = collectFullRescanCandidates(
            enumerationResults,
            discoveryEvidence: discoveryEvidence
        )
        return try await finalizeFullRescanSnapshot(
            collection: collection,
            enumerationResults: enumerationResults,
            coverage: coverage,
            activationPolicyByPID: activationPolicyByPID,
            appsByPID: appsByPID,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            discoveryEvidence: discoveryEvidence
        )
    }

    private func targetedFullRescanEnumeration(
        scope: RescanScope,
        resolvedTargetPIDs: Set<pid_t>,
        resolvedTargetWindowIds: Set<Int>,
        discoveryEvidence initialDiscoveryEvidence: FullRescanDiscoveryEvidence,
        preservingPIDsByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>],
        requiresTitleForApp: (String?, String?) -> Bool
    ) async throws -> (
        appTargets: [FullRescanAppTarget],
        results: [FullRescanAppEnumerationResult],
        coverage: FullRescanEnumerationCoverage,
        discoveryEvidence: FullRescanDiscoveryEvidence
    ) {
        var discoveryEvidence = initialDiscoveryEvidence
        let targetedAppPIDs = scope.appPIDs
        let nativeSpaceWindowIds = scope.nativeSpaceWindowIds
        let preservedTargetWindowIds = Set(
            preservingPIDsByWindowId.compactMap { windowId, pid in
                targetedAppPIDs.contains(pid) || nativeSpaceWindowIds.contains(windowId)
                    ? windowId
                    : nil
            }
        )
        var windowServerEvidenceSucceeded = mergeTargetedWindowServerEvidence(
            windowIds: preservedTargetWindowIds,
            into: &discoveryEvidence
        )
        guard var resolution = Self.fullRescanTargetResolution(
            scope: scope,
            resolvedTargetPIDs: resolvedTargetPIDs,
            resolvedTargetWindowIds: resolvedTargetWindowIds,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        ) else {
            return (
                [],
                [],
                FullRescanEnumerationCoverage(
                    targetPIDs: [],
                    dependencyPIDs: [],
                    targetPIDsByDependencyPID: [:],
                    unavailableTargetPIDs: [],
                    unavailableDependencyPIDs: [],
                    exactWindowIds: []
                ),
                discoveryEvidence
            )
        }
        let persistentEvidencePIDs = Set(preservingPIDsByWindowId.values)
            .union(identityDependencyPIDsByWindowId.values.joined())
        var targetInspectionWindowIdsByPID: [pid_t: Set<Int>] = [:]
        for pid in resolution.targetPIDs where !resolution.explicitAppPIDs.contains(pid) {
            targetInspectionWindowIdsByPID[pid] = Set(
                resolution.targetPIDsByWindowId.compactMap { windowId, targetPIDs in
                    targetPIDs.contains(pid) ? windowId : nil
                }
            )
        }
        let targetAppTargets = fullRescanAppTargets(
            fullRescanRunningApplications(for: resolution.targetPIDs),
            discoveryEvidence: discoveryEvidence,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            persistentEvidencePIDs: persistentEvidencePIDs,
            includedPIDs: resolution.targetPIDs,
            includedWindowIdsByPID: targetInspectionWindowIdsByPID,
            allowsEvidenceFreeOneShot: true,
            requiresTitleForApp: requiresTitleForApp
        )
        var appTargets = targetAppTargets
        var attemptedPIDs = Set(targetAppTargets.map { $0.app.processIdentifier })
        var unavailableTargetPIDs = resolution.targetPIDs.subtracting(attemptedPIDs)
        var results = try await enumerateFullRescanApps(targetAppTargets).map { result in
            let windows = resolution.explicitAppPIDs.contains(result.pid)
                ? result.windows
                : result.windows.filter {
                    resolution.resolvedTargetWindowIds.contains($0.axRef.windowId)
                }
            return FullRescanAppEnumerationResult(
                pid: result.pid,
                route: result.route,
                windows: windows,
                failed: result.failed,
                callbackGeneration: result.callbackGeneration
            )
        }
        if !mergeTargetedWindowServerEvidence(
            for: results,
            into: &discoveryEvidence
        ) {
            windowServerEvidenceSucceeded = false
        }
        Self.includeFullRescanTargetWindows(
            results,
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )

        var unavailableDependencyPIDs: Set<pid_t> = []
        while true {
            try Task.checkCancellation()
            let pendingDependencyPIDs = resolution.dependencyPIDs.subtracting(attemptedPIDs)
            guard !pendingDependencyPIDs.isEmpty else { break }
            attemptedPIDs.formUnion(pendingDependencyPIDs)
            let dependencyTargets = fullRescanAppTargets(
                fullRescanRunningApplications(for: pendingDependencyPIDs),
                discoveryEvidence: discoveryEvidence,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                persistentEvidencePIDs: persistentEvidencePIDs.union(pendingDependencyPIDs),
                includedPIDs: pendingDependencyPIDs,
                includedWindowIdsByPID: Dictionary(
                    uniqueKeysWithValues: pendingDependencyPIDs.map {
                        ($0, resolution.relevantWindowIds)
                    }
                ),
                allowsEvidenceFreeOneShot: true,
                requiresTitleForApp: requiresTitleForApp
            )
            let dependencyTargetPIDs = Set(dependencyTargets.map { $0.app.processIdentifier })
            unavailableDependencyPIDs.formUnion(
                pendingDependencyPIDs.subtracting(dependencyTargetPIDs)
            )
            appTargets.append(contentsOf: dependencyTargets)
            let dependencyResults = try await enumerateFullRescanApps(dependencyTargets).map { result in
                FullRescanAppEnumerationResult(
                    pid: result.pid,
                    route: result.route,
                    windows: result.windows.filter {
                        resolution.relevantWindowIds.contains($0.axRef.windowId)
                    },
                    failed: result.failed,
                    callbackGeneration: result.callbackGeneration
                )
            }
            if !mergeTargetedWindowServerEvidence(
                for: dependencyResults,
                into: &discoveryEvidence
            ) {
                windowServerEvidenceSucceeded = false
            }
            results.append(contentsOf: dependencyResults)
            Self.includeFullRescanDependencyWindows(
                dependencyResults,
                in: &resolution,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                ownerPIDByWindowId: discoveryEvidence.ownerPIDByWindowId,
                identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
            )
        }
        if !windowServerEvidenceSucceeded {
            unavailableTargetPIDs.formUnion(resolution.targetPIDs)
        }

        return (
            appTargets,
            results,
            FullRescanEnumerationCoverage(
                targetPIDs: resolution.targetPIDs,
                dependencyPIDs: resolution.dependencyPIDs,
                targetPIDsByDependencyPID: resolution.targetPIDsByDependencyPID,
                unavailableTargetPIDs: unavailableTargetPIDs,
                unavailableDependencyPIDs: unavailableDependencyPIDs,
                exactWindowIds: resolution.relevantWindowIds
            ),
            discoveryEvidence
        )
    }

    private func targetedFullRescanDiscoveryEvidence(
        _ windowServerInfoByWindowId: [Int: WindowServerInfo]
    ) -> FullRescanDiscoveryEvidence {
        var evidence = FullRescanDiscoveryEvidence(
            pidsWithWindows: [],
            windowServerInfoByWindowId: [:],
            ownerPIDByWindowId: [:]
        )
        for (windowId, info) in windowServerInfoByWindowId where Int(info.id) == windowId {
            evidence.pidsWithWindows.insert(info.pid)
            evidence.windowServerInfoByWindowId[windowId] = info
            evidence.ownerPIDByWindowId[windowId] = info.pid
        }
        return evidence
    }

    @discardableResult
    private func mergeTargetedWindowServerEvidence(
        for results: [FullRescanAppEnumerationResult],
        into evidence: inout FullRescanDiscoveryEvidence
    ) -> Bool {
        let windowIds = Set(results.lazy.flatMap(\.windows).map(\.axRef.windowId))
        return mergeTargetedWindowServerEvidence(windowIds: windowIds, into: &evidence)
    }

    @discardableResult
    private func mergeTargetedWindowServerEvidence(
        windowIds: Set<Int>,
        into evidence: inout FullRescanDiscoveryEvidence
    ) -> Bool {
        let existingWindowIds = Set(evidence.windowServerInfoByWindowId.keys)
        let missingWindowIds = Set(
            windowIds.subtracting(existingWindowIds).compactMap(UInt32.init(exactly:))
        )
        guard !missingWindowIds.isEmpty else { return true }
        guard let windowInfoById = SkyLight.shared.queryWindowInfo(windowIds: missingWindowIds) else {
            return false
        }
        for (windowId, info) in windowInfoById {
            let key = Int(windowId)
            evidence.pidsWithWindows.insert(info.pid)
            evidence.windowServerInfoByWindowId[key] = info
            evidence.ownerPIDByWindowId[key] = info.pid
        }
        return true
    }

    private func fullRescanRunningApplications(
        for pids: Set<pid_t>
    ) -> [NSRunningApplication] {
        pids.sorted().compactMap(NSRunningApplication.init(processIdentifier:))
    }

    private func finalizeFullRescanSnapshot(
        collection initialCollection: FullRescanCandidateCollection,
        enumerationResults: [FullRescanAppEnumerationResult],
        coverage: FullRescanEnumerationCoverage,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        appsByPID: [pid_t: NSRunningApplication],
        preservingPIDsByWindowId: [Int: pid_t],
        discoveryEvidence: FullRescanDiscoveryEvidence
    ) async throws -> FullRescanEnumerationSnapshot {
        try Task.checkCancellation()
        var collection = initialCollection
        collection.failedPIDs.formUnion(coverage.unavailableTargetPIDs)
        collection.failedPIDs.formUnion(coverage.unavailableDependencyPIDs)
        var selected = Self.selectFullRescanCandidates(
            collection.candidatesByWindowId,
            activationPolicyByPID: activationPolicyByPID,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
        let failedPromotions = try await promoteOneShotCandidates(selected, appsByPID: appsByPID)
        try Task.checkCancellation()
        if !failedPromotions.isEmpty {
            collection.failedPIDs.formUnion(failedPromotions)
            for candidate in selected
                where candidate.enumerationRoute == .oneShot && failedPromotions.contains(candidate.pid)
            {
                if let preservedPID = preservingPIDsByWindowId[candidate.windowId] {
                    collection.failedPIDs.insert(preservedPID)
                }
            }
            selected.removeAll {
                $0.enumerationRoute == .oneShot && failedPromotions.contains($0.pid)
            }
        }
        var successfullyEnumeratedPIDs = Set(
            enumerationResults.lazy.filter { !$0.failed }.map(\.pid)
        )
        successfullyEnumeratedPIDs.subtract(collection.failedPIDs)
        let authoritativeTargetPIDs = Self.authoritativeFullRescanTargetPIDs(
            targetPIDs: coverage.targetPIDs,
            successfullyEnumeratedPIDs: successfullyEnumeratedPIDs,
            failedPIDs: collection.failedPIDs,
            dependencyPIDs: coverage.dependencyPIDs,
            targetPIDsByDependencyPID: coverage.targetPIDsByDependencyPID
        )

        if WindowAdmissionTrace.shared.isActive {
            for candidate in selected {
                WindowAdmissionTrace.record(
                    .init(
                        action: .fullRescanSelected,
                        pid: candidate.pid,
                        windowId: candidate.windowId,
                        axPid: candidate.axPid,
                        windowServerPid: candidate.windowServerOwnerPID,
                        reason: "final_selection",
                        callbackGeneration: candidate.callbackGeneration
                            ?? AppAXContext.contexts[candidate.pid]?.callbackGeneration,
                        manageable: candidate.isManageable,
                        axRef: candidate.axRef
                    )
                )
            }
        }
        let selectedWindowIds = Set(selected.map(\.windowId))
        collection.identityAliasesByWindowId = collection.identityAliasesByWindowId.filter {
            selectedWindowIds.contains($0.key)
        }
        let windowServerInfoByWindowId: [Int: WindowServerInfo]
        if let exactWindowIds = coverage.exactWindowIds {
            windowServerInfoByWindowId = discoveryEvidence.windowServerInfoByWindowId.filter {
                exactWindowIds.contains($0.key)
            }
        } else {
            windowServerInfoByWindowId = discoveryEvidence.windowServerInfoByWindowId
        }
        return .init(
            windows: selected,
            successfullyEnumeratedPIDs: successfullyEnumeratedPIDs,
            failedPIDs: collection.failedPIDs,
            authoritativeTargetPIDs: authoritativeTargetPIDs,
            exactWindowIds: coverage.exactWindowIds,
            identityAliasesByWindowId: collection.identityAliasesByWindowId,
            windowServerInfoByWindowId: windowServerInfoByWindowId
        )
    }

    private func fullRescanAppTargets(
        _ runningApplications: [NSRunningApplication],
        discoveryEvidence: FullRescanDiscoveryEvidence,
        preservingPIDsByWindowId: [Int: pid_t],
        persistentEvidencePIDs: Set<pid_t>,
        includedPIDs: Set<pid_t>?,
        includedWindowIdsByPID: [pid_t: Set<Int>] = [:],
        allowsEvidenceFreeOneShot: Bool,
        requiresTitleForApp: (String?, String?) -> Bool
    ) -> [FullRescanAppTarget] {
        let existingContextPIDs = Set(AppAXContext.contexts.keys)
        let preservingPIDs = Set(preservingPIDsByWindowId.values)
        return runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard includedPIDs?.contains(pid) ?? true,
                  shouldTrack(app)
            else {
                return nil
            }
            let route = Self.fullRescanEnumerationRoute(
                activationPolicy: app.activationPolicy,
                hasDiscoveryEvidence: discoveryEvidence.pidsWithWindows.contains(pid),
                hasContext: existingContextPIDs.contains(pid),
                hasPreservedState: preservingPIDs.contains(pid)
                    || persistentEvidencePIDs.contains(pid)
            ) ?? (allowsEvidenceFreeOneShot ? .oneShot : nil)
            guard let route else { return nil }
            return FullRescanAppTarget(
                app: app,
                route: route,
                inspectionContext: Self.fullRescanInspectionContext(
                    activationPolicy: app.activationPolicy,
                    bundleId: app.bundleIdentifier,
                    appName: app.localizedName,
                    requiresTitleForApp: requiresTitleForApp
                ),
                includedWindowIds: includedWindowIdsByPID[pid]
            )
        }
    }

    static func fullRescanTargetResolution(
        scope: RescanScope,
        resolvedTargetPIDs: Set<pid_t>,
        resolvedTargetWindowIds: Set<Int>,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) -> FullRescanTargetResolution? {
        guard case let .targeted(
            requestedPIDs,
            nativeSpaceIds,
            nativeSpaceWindowIdsByPID
        ) = scope else {
            return nil
        }
        let targetPIDs = requestedPIDs.union(resolvedTargetPIDs)
        var relevantWindowIds: Set<Int> = []
        var targetPIDsByWindowId: [Int: Set<pid_t>] = [:]
        for (windowId, pid) in preservingPIDsByWindowId where requestedPIDs.contains(pid) {
            relevantWindowIds.insert(windowId)
            targetPIDsByWindowId[windowId, default: []].insert(pid)
        }
        for (windowId, pid) in ownerPIDByWindowId where requestedPIDs.contains(pid) {
            relevantWindowIds.insert(windowId)
            targetPIDsByWindowId[windowId, default: []].insert(pid)
        }
        relevantWindowIds.formUnion(resolvedTargetWindowIds)
        for windowId in resolvedTargetWindowIds {
            if let pid = preservingPIDsByWindowId[windowId], targetPIDs.contains(pid) {
                targetPIDsByWindowId[windowId, default: []].insert(pid)
            }
            if let pid = ownerPIDByWindowId[windowId], targetPIDs.contains(pid) {
                targetPIDsByWindowId[windowId, default: []].insert(pid)
            }
        }
        var resolution = FullRescanTargetResolution(
            explicitAppPIDs: requestedPIDs,
            resolvedTargetPIDs: resolvedTargetPIDs,
            resolvedTargetWindowIds: resolvedTargetWindowIds,
            targetPIDs: targetPIDs,
            nativeSpaceIds: nativeSpaceIds,
            nativeSpaceWindowIdsByPID: nativeSpaceWindowIdsByPID,
            relevantWindowIds: relevantWindowIds,
            targetPIDsByWindowId: targetPIDsByWindowId,
            dependencyPIDs: [],
            targetPIDsByDependencyPID: [:]
        )
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )
        return resolution
    }

    private static func includeFullRescanTargetWindows(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        for result in results where resolution.targetPIDs.contains(result.pid) {
            for window in result.windows {
                let windowId = window.axRef.windowId
                resolution.relevantWindowIds.insert(windowId)
                resolution.targetPIDsByWindowId[windowId, default: []].insert(result.pid)
            }
        }
        includeFullRescanObservedDependencies(results, in: &resolution)
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )
    }

    private static func includeFullRescanDependencyWindows(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        includeFullRescanObservedDependencies(results, in: &resolution)
        includeFullRescanKnownDependencies(
            in: &resolution,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            ownerPIDByWindowId: ownerPIDByWindowId,
            identityDependencyPIDsByWindowId: identityDependencyPIDsByWindowId
        )
    }

    private static func includeFullRescanObservedDependencies(
        _ results: [FullRescanAppEnumerationResult],
        in resolution: inout FullRescanTargetResolution
    ) {
        for result in results {
            for window in result.windows {
                let windowId = window.axRef.windowId
                guard resolution.relevantWindowIds.contains(windowId),
                      let targetPIDs = resolution.targetPIDsByWindowId[windowId],
                      let axPid = window.axPid
                else {
                    continue
                }
                let dependentTargetPIDs = targetPIDs.subtracting([axPid])
                guard !dependentTargetPIDs.isEmpty else { continue }
                resolution.dependencyPIDs.insert(axPid)
                resolution.targetPIDsByDependencyPID[axPid, default: []]
                    .formUnion(dependentTargetPIDs)
            }
        }
    }

    private static func includeFullRescanKnownDependencies(
        in resolution: inout FullRescanTargetResolution,
        preservingPIDsByWindowId: [Int: pid_t],
        ownerPIDByWindowId: [Int: pid_t],
        identityDependencyPIDsByWindowId: [Int: Set<pid_t>]
    ) {
        for windowId in resolution.relevantWindowIds {
            guard let targetPIDs = resolution.targetPIDsByWindowId[windowId] else { continue }
            var relatedPIDs = identityDependencyPIDsByWindowId[windowId] ?? []
            if let preservedPID = preservingPIDsByWindowId[windowId] {
                relatedPIDs.insert(preservedPID)
            }
            if let ownerPID = ownerPIDByWindowId[windowId] {
                relatedPIDs.insert(ownerPID)
            }
            for pid in relatedPIDs {
                let dependentTargetPIDs = targetPIDs.subtracting([pid])
                guard !dependentTargetPIDs.isEmpty else { continue }
                resolution.dependencyPIDs.insert(pid)
                resolution.targetPIDsByDependencyPID[pid, default: []]
                    .formUnion(dependentTargetPIDs)
            }
        }
    }

    static func authoritativeFullRescanTargetPIDs(
        targetPIDs: Set<pid_t>,
        successfullyEnumeratedPIDs: Set<pid_t>,
        failedPIDs: Set<pid_t>,
        dependencyPIDs: Set<pid_t>,
        targetPIDsByDependencyPID: [pid_t: Set<pid_t>]
    ) -> Set<pid_t> {
        var authoritative = targetPIDs
            .intersection(successfullyEnumeratedPIDs)
            .subtracting(failedPIDs)
        for failedDependencyPID in dependencyPIDs.intersection(failedPIDs) {
            authoritative.subtract(targetPIDsByDependencyPID[failedDependencyPID] ?? [])
        }
        return authoritative
    }

    static func fullRescanInspectionContext(
        activationPolicy: NSApplication.ActivationPolicy,
        bundleId: String?,
        appName: String?,
        requiresTitleForApp: (String?, String?) -> Bool
    ) -> AXWindowInspectionContext {
        AXWindowInspectionContext(
            appPolicy: activationPolicy,
            bundleId: bundleId,
            includeTitle: requiresTitleForApp(bundleId, appName)
        )
    }

    private func fullRescanDiscoveryEvidence() -> FullRescanDiscoveryEvidence {
        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        var evidence = FullRescanDiscoveryEvidence(
            pidsWithWindows: Set(visibleWindows.map { $0.pid }),
            windowServerInfoByWindowId: [:],
            ownerPIDByWindowId: [:]
        )
        for window in visibleWindows {
            evidence.windowServerInfoByWindowId[Int(window.id)] = window
            evidence.ownerPIDByWindowId[Int(window.id)] = pid_t(window.pid)
        }
        let skyLightPIDCount = evidence.pidsWithWindows.count
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            FallbackFiringRecorder.shared.note(.capture, "cgWindowListNull")
            return evidence
        }
        for window in windows {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? Int,
                  let windowNumber = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0
            else { continue }
            let pid = pid_t(pidNumber)
            evidence.pidsWithWindows.insert(pid)
            evidence.ownerPIDByWindowId[windowNumber] = evidence.ownerPIDByWindowId[windowNumber] ?? pid
        }
        FallbackFiringRecorder.shared.note(
            .capture,
            "cgWindowListSupplementPids",
            evidence.pidsWithWindows.count - skyLightPIDCount
        )
        return evidence
    }

    private func collectFullRescanCandidates(
        _ results: [FullRescanAppEnumerationResult],
        discoveryEvidence: FullRescanDiscoveryEvidence
    ) -> FullRescanCandidateCollection {
        var collection = FullRescanCandidateCollection(
            candidatesByWindowId: [:],
            identityAliasesByWindowId: [:],
            failedPIDs: []
        )
        for result in results {
            if result.failed {
                collection.failedPIDs.insert(result.pid)
            }
            for window in result.windows {
                let windowId = window.axRef.windowId
                let ownerPID = discoveryEvidence.ownerPIDByWindowId[windowId]
                appendFullRescanAliases(
                    for: window,
                    logicalPID: result.pid,
                    ownerPID: ownerPID,
                    to: &collection.identityAliasesByWindowId
                )
                let candidate = FullRescanWindowCandidate(
                    enumeratedWindow: window,
                    logicalPID: result.pid,
                    windowServerInfo: discoveryEvidence.windowServerInfoByWindowId[windowId],
                    windowServerOwnerPID: ownerPID,
                    enumerationRoute: result.route,
                    callbackGeneration: result.callbackGeneration
                )
                collection.candidatesByWindowId[windowId, default: []].append(candidate)
                recordFullRescanCandidate(candidate)
            }
        }
        return collection
    }

    private func appendFullRescanAliases(
        for window: AXEnumeratedWindow,
        logicalPID: pid_t,
        ownerPID: pid_t?,
        to aliasesByWindowId: inout [Int: FullRescanWindowIdentityAliases]
    ) {
        let windowId = window.axRef.windowId
        var aliases = aliasesByWindowId[windowId] ?? .init()
        aliases.pids.insert(logicalPID)
        if let axPid = window.axPid {
            aliases.pids.insert(axPid)
        }
        if let ownerPID {
            aliases.pids.insert(ownerPID)
        }
        if !aliases.axRefs.contains(where: { CFEqual($0.element, window.axRef.element) }) {
            aliases.axRefs.append(window.axRef)
        }
        aliasesByWindowId[windowId] = aliases
    }

    private func recordFullRescanCandidate(_ candidate: FullRescanWindowCandidate) {
        WindowAdmissionTrace.record(
            .init(
                action: .fullRescanCandidate,
                pid: candidate.pid,
                windowId: candidate.windowId,
                axPid: candidate.axPid,
                windowServerPid: candidate.windowServerOwnerPID,
                callbackGeneration: candidate.callbackGeneration,
                manageable: candidate.isManageable,
                axRef: candidate.axRef
            )
        )
    }

    private func enumerateFullRescanApps(
        _ targets: [FullRescanAppTarget]
    ) async throws -> [FullRescanAppEnumerationResult] {
        try await boundedFullRescanMap(
            targets,
            maxConcurrent: maxConcurrentFullRescanEnumerations,
            priority: { $0.route == .oneShot ? .utility : nil }
        ) { target in
            try await Self.enumerateFullRescanApp(
                target.app,
                route: target.route,
                inspectionContext: target.inspectionContext,
                includedWindowIds: target.includedWindowIds
            )
        }
    }

    private nonisolated static func enumerateFullRescanApp(
        _ app: NSRunningApplication,
        route: FullRescanEnumerationRoute,
        inspectionContext: AXWindowInspectionContext,
        includedWindowIds: Set<Int>?
    ) async throws -> FullRescanAppEnumerationResult {
        try Task.checkCancellation()
        let pid = app.processIdentifier
        var callbackGeneration: UInt64?
        do {
            let windows: [AXEnumeratedWindow]
            switch route {
            case .persistent:
                guard let context = try await AppAXContext.getOrCreate(app) else {
                    recordFullRescanEnumerationFailure(app, reason: "context_unavailable")
                    return .init(
                        pid: pid,
                        route: route,
                        windows: [],
                        failed: true,
                        callbackGeneration: nil
                    )
                }
                callbackGeneration = context.callbackGeneration
                windows = try await context.getWindowsAsync(
                    timeoutSeconds: perAppTimeout,
                    includeTitle: inspectionContext.includeTitle,
                    includedWindowIds: includedWindowIds
                )
            case .oneShot:
                WindowAdmissionTrace.record(
                    .init(
                        action: .enumerationStarted,
                        pid: pid,
                        bundleId: app.bundleIdentifier
                    )
                )
                windows = try AXWindowEnumerationInspector.enumerateApplication(
                    pid: pid,
                    timeout: perAppTimeout,
                    context: inspectionContext,
                    includedWindowIds: includedWindowIds
                )
                try Task.checkCancellation()
                WindowAdmissionTrace.record(
                    .init(action: .enumerationCompleted, pid: pid, count: windows.count)
                )
            }
            return .init(
                pid: pid,
                route: route,
                windows: windows,
                failed: false,
                callbackGeneration: callbackGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordFullRescanEnumerationFailure(
                app,
                reason: String(describing: error),
                callbackGeneration: callbackGeneration
            )
            return .init(
                pid: pid,
                route: route,
                windows: [],
                failed: true,
                callbackGeneration: callbackGeneration
            )
        }
    }

    private nonisolated static func recordFullRescanEnumerationFailure(
        _ app: NSRunningApplication,
        reason: String,
        callbackGeneration: UInt64? = nil
    ) {
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationFailed,
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                reason: reason,
                callbackGeneration: callbackGeneration
            )
        )
    }

    static func selectFullRescanCandidates(
        _ candidatesByWindowId: [Int: [FullRescanWindowCandidate]],
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        preservingPIDsByWindowId: [Int: pid_t]
    ) -> [FullRescanWindowCandidate] {
        var selected: [FullRescanWindowCandidate] = []
        selected.reserveCapacity(candidatesByWindowId.count)
        for windowId in candidatesByWindowId.keys.sorted() {
            guard let candidates = candidatesByWindowId[windowId], var current = candidates.first else {
                continue
            }
            for candidate in candidates.dropFirst() {
                let preference = Self.fullRescanCandidatePreference(
                    candidate,
                    over: current,
                    activationPolicyByPID: activationPolicyByPID,
                    ownerPID: candidate.windowServerOwnerPID ?? current.windowServerOwnerPID,
                    existingPID: preservingPIDsByWindowId[windowId]
                )
                let winner = preference.prefersCandidate ? candidate : current
                let loser = preference.prefersCandidate ? current : candidate
                WindowAdmissionTrace.record(
                    .init(
                        action: .fullRescanRejected,
                        pid: loser.pid,
                        windowId: windowId,
                        axPid: loser.axPid,
                        windowServerPid: loser.windowServerOwnerPID,
                        competingPid: winner.pid,
                        reason: preference.reason.rawValue,
                        outcome: preference.prefersCandidate ? "replaced" : "not_preferred",
                        callbackGeneration: loser.callbackGeneration,
                        manageable: loser.isManageable,
                        axRef: loser.axRef
                    )
                )
                if preference.prefersCandidate {
                    current = candidate
                }
            }
            selected.append(current)
        }
        return selected
    }

    private func promoteOneShotCandidates(
        _ candidates: [FullRescanWindowCandidate],
        appsByPID: [pid_t: NSRunningApplication]
    ) async throws -> Set<pid_t> {
        try Task.checkCancellation()
        var failedPIDs: Set<pid_t> = []
        try await Self.forEachOneShotPromotionBatch(candidates) { pid, _ in
            try Task.checkCancellation()
            guard let app = appsByPID[pid] else {
                failedPIDs.insert(pid)
                return
            }
            let hadContext = AppAXContext.contexts[pid] != nil
            var callbackGeneration: UInt64?
            do {
                guard let context = try await AppAXContext.getOrCreate(app) else {
                    failedPIDs.insert(pid)
                    if !hadContext {
                        destroyContextIfPresent(for: pid, reason: "promotion-failed")
                    }
                    return
                }
                callbackGeneration = context.callbackGeneration
            } catch is CancellationError {
                if !hadContext {
                    destroyContextIfPresent(for: pid, reason: "promotion-cancelled")
                }
                throw CancellationError()
            } catch {
                failedPIDs.insert(pid)
                if !hadContext {
                    destroyContextIfPresent(for: pid, reason: "promotion-failed")
                }
                Self.recordFullRescanEnumerationFailure(
                    app,
                    reason: "promotion_\(error)",
                    callbackGeneration: callbackGeneration
                )
            }
        }
        return failedPIDs
    }

    static func oneShotPromotionCandidatesByPID(
        _ selectedCandidates: [FullRescanWindowCandidate]
    ) -> [pid_t: [FullRescanWindowCandidate]] {
        Dictionary(
            grouping: selectedCandidates.filter { $0.enumerationRoute == .oneShot },
            by: \.pid
        )
    }

    static func forEachOneShotPromotionBatch(
        _ selectedCandidates: [FullRescanWindowCandidate],
        operation: (pid_t, [FullRescanWindowCandidate]) async throws -> Void
    ) async rethrows {
        let grouped = oneShotPromotionCandidatesByPID(selectedCandidates)
        for pid in grouped.keys.sorted() {
            guard let candidates = grouped[pid] else { continue }
            try await operation(pid, candidates)
        }
    }

    func applyFramesParallel(
        _ frames: [AXFrameApplicationTarget],
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        verify: Bool = true
    ) {
        let writable = framesAllowedToWrite(frames)
        guard !writable.isEmpty else { return }
        enqueueFrameApplications(writable, isRetry: false, verify: verify, terminalObserver: terminalObserver)
    }

    func applyParkFramesParallel(_ frames: [AXFrameApplicationTarget]) {
        let writable = framesAllowedToWrite(frames)
        guard !writable.isEmpty else { return }
        dispatchParkFrameApplications(prepareParkFrameApplications(writable))
    }

    private func framesAllowedToWrite(
        _ frames: [AXFrameApplicationTarget]
    ) -> [AXFrameApplicationTarget] {
        if let interactionPolicyForWindowId {
            return frames.filter {
                !macOSHiddenAppPIDs.contains($0.pid)
                    && interactionPolicyForWindowId($0.windowId).mayWriteFrame
            }
        }
        guard !macOSHiddenAppPIDs.isEmpty else { return frames }
        return frames.filter { !macOSHiddenAppPIDs.contains($0.pid) }
    }

    func pendingParkFrameRequest(for windowId: Int) -> AXFrameApplicationRequest? {
        pendingParkFrameRequestsByWindowId[windowId]?.request
    }

    func verifiedParkFrame(for windowId: Int) -> CGRect? {
        guard let state = parkFrameTargetStatesByWindowId[windowId],
              state.isVerified
        else {
            return nil
        }
        return state.target.frame
    }

    func prepareParkFrameApplications(
        _ frames: [AXFrameApplicationTarget]
    ) -> [AXFrameApplicationRequest] {
        var requests: [AXFrameApplicationRequest] = []
        requests.reserveCapacity(frames.count)

        for target in frames {
            let windowId = target.windowId
            parkPIDByWindowId[windowId] = target.pid

            if let state = parkFrameTargetStatesByWindowId[windowId],
               state.isVerified,
               state.target.pid == target.pid,
               sameAXWindowIdentity(state.target.expectedWindow, target.expectedWindow),
               state.target.frame == target.frame
            {
                pendingParkWindowIds.remove(windowId)
                continue
            }
            pendingParkWindowIds.insert(windowId)

            if let pending = pendingParkFrameRequestsByWindowId[windowId] {
                if pending.request.pid == target.pid,
                   sameAXWindowIdentity(pending.request.expectedWindow, target.expectedWindow),
                   pending.request.frame == target.frame
                {
                    continue
                }
                AppAXContext.contexts[pending.request.pid]?.cancelParkFrameJob(for: windowId)
                pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
                FrameApplyTrace.recordEvent(
                    pid: pending.request.pid,
                    windowId: windowId,
                    outcome: "outcome=ax-park-cancelled/superseded",
                    target: pending.request.frame
                )
            }

            parkFrameTargetStatesByWindowId[windowId] = ParkFrameTargetState(
                target: target,
                isVerified: false
            )
            let request = AXFrameApplicationRequest(
                requestId: makeNextParkFrameRequestId(),
                pid: target.pid,
                windowId: windowId,
                expectedWindow: target.expectedWindow,
                frame: target.frame,
                currentFrameHint: frameLedger.lastAppliedFrame(for: windowId),
                verify: true
            )
            pendingParkFrameRequestsByWindowId[windowId] = PendingParkFrameRequest(
                request: request,
                retriesRemaining: 1
            )
            requests.append(request)
        }

        return requests.filter {
            pendingParkFrameRequestsByWindowId[$0.windowId]?.request.requestId == $0.requestId
        }
    }

    func processParkFrameApplyResults(
        _ results: [AXFrameApplyResult]
    ) -> [AXFrameApplicationRequest] {
        var retries: [AXFrameApplicationRequest] = []
        retries.reserveCapacity(results.count)

        for result in results {
            let windowId = result.windowId
            guard let pending = pendingParkFrameRequestsByWindowId[windowId],
                  pending.request.requestId == result.requestId,
                  pending.request.pid == result.pid,
                  sameAXWindowIdentity(pending.request.expectedWindow, result.expectedWindow),
                  pending.request.frame == result.targetFrame
            else {
                continue
            }

            pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
            let failureReason = parkFrameFailureReason(for: result)
            guard let failureReason else {
                parkFrameTargetStatesByWindowId[windowId] = ParkFrameTargetState(
                    target: AXFrameApplicationTarget(
                        pid: result.pid,
                        window: result.expectedWindow,
                        frame: result.targetFrame
                    ),
                    isVerified: true
                )
                parkPIDByWindowId[windowId] = result.pid
                pendingParkWindowIds.remove(windowId)
                FrameApplyTrace.shared.record(
                    .init(
                        timestamp: Date(),
                        pid: result.pid,
                        windowId: windowId,
                        outcome: "outcome=ax-park-confirmed",
                        target: result.targetFrame,
                        hint: result.currentFrameHint,
                        observed: result.writeResult.observedFrame,
                        confirmed: result.writeResult.observedFrame
                    )
                )
                continue
            }

            if failureReason == .cancelled {
                FrameApplyTrace.recordEvent(
                    pid: result.pid,
                    windowId: windowId,
                    outcome: "outcome=ax-park-cancelled/cancelled",
                    target: result.targetFrame
                )
                continue
            }

            FrameApplyTrace.shared.record(
                .init(
                    timestamp: Date(),
                    pid: result.pid,
                    windowId: windowId,
                    outcome: "outcome=ax-park-failed/\(failureReason.traceDescription)",
                    target: result.targetFrame,
                    hint: result.currentFrameHint,
                    observed: result.writeResult.observedFrame,
                    confirmed: nil
                )
            )
            guard pending.retriesRemaining > 0,
                  pendingParkWindowIds.contains(windowId)
            else {
                continue
            }

            let retry = AXFrameApplicationRequest(
                requestId: makeNextParkFrameRequestId(),
                pid: pending.request.pid,
                windowId: windowId,
                expectedWindow: pending.request.expectedWindow,
                frame: pending.request.frame,
                currentFrameHint: pending.request.currentFrameHint,
                verify: true
            )
            pendingParkFrameRequestsByWindowId[windowId] = PendingParkFrameRequest(
                request: retry,
                retriesRemaining: pending.retriesRemaining - 1
            )
            retries.append(retry)
        }

        return retries
    }

    func handleParkFrameApplyResults(_ results: [AXFrameApplyResult]) {
        dispatchParkFrameApplications(processParkFrameApplyResults(results))
    }

    private func dispatchParkFrameApplications(_ requests: [AXFrameApplicationRequest]) {
        guard !requests.isEmpty else { return }
        var requestsByPID: [pid_t: [AXFrameApplicationRequest]] = [:]
        requestsByPID.reserveCapacity(min(requests.count, 8))
        for request in requests {
            requestsByPID[request.pid, default: []].append(request)
        }

        for (pid, appFrames) in requestsByPID {
            guard let context = AppAXContext.contexts[pid] else {
                handleParkFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: $0.pid,
                            windowId: $0.windowId,
                            expectedWindow: $0.expectedWindow,
                            targetFrame: $0.frame,
                            currentFrameHint: $0.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: $0.frame,
                                currentFrameHint: $0.currentFrameHint,
                                failureReason: .contextUnavailable
                            )
                        )
                    }
                )
                continue
            }
            context.setParkFramesBatch(appFrames) { [weak self] results in
                self?.handleParkFrameApplyResults(results)
            }
        }
    }

    private func parkFrameFailureReason(for result: AXFrameApplyResult) -> AXFrameWriteFailureReason? {
        if let failureReason = result.writeResult.failureReason {
            return failureReason
        }
        guard let observedFrame = result.writeResult.observedFrame else {
            return .readbackFailed
        }
        guard observedFrame.approximatelyEqual(
            to: result.targetFrame,
            tolerance: FrameTolerance.frameWrite
        ) else {
            return .verificationMismatch
        }
        return nil
    }

    private func makeNextParkFrameRequestId() -> AXFrameRequestId {
        let requestId = nextParkFrameRequestId
        nextParkFrameRequestId &+= 1
        return requestId
    }

    private func enqueueFrameApplications(
        _ frames: [AXFrameApplicationTarget],
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: FrameApplicationTerminalObserver? = nil
    ) {
        if frameApplicationBufferInUse {
            var framesByPid: [pid_t: [AXFrameApplicationRequest]] = [:]
            framesByPid.reserveCapacity(min(frames.count, 8))
            enqueueFrameApplicationsUsingBuffer(
                frames,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver,
                framesByPid: &framesByPid
            )
            return
        }

        frameApplicationBufferInUse = true
        defer {
            for key in Array(framesByPidBuffer.keys) {
                framesByPidBuffer[key]?.removeAll(keepingCapacity: true)
            }
            frameApplicationBufferInUse = false
        }

        enqueueFrameApplicationsUsingBuffer(
            frames,
            isRetry: isRetry,
            verify: verify,
            terminalObserver: terminalObserver,
            framesByPid: &framesByPidBuffer
        )
    }

    private func enqueueFrameApplicationsUsingBuffer(
        _ frames: [AXFrameApplicationTarget],
        isRetry: Bool,
        verify: Bool,
        terminalObserver: FrameApplicationTerminalObserver?,
        framesByPid: inout [pid_t: [AXFrameApplicationRequest]]
    ) {
        framesByPid.reserveCapacity(min(frames.count, 8))
        var deferredDeliveries: [AXFrameTerminalDelivery] = []

        for target in frames {
            let pid = target.pid
            let windowId = target.windowId
            let frame = target.frame
            if inactiveWorkspaceWindowIds.contains(windowId) {
                continue
            }
            let decision = frameLedger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: target.expectedWindow,
                frame: frame,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver
            )
            if decision.shouldCancelPendingRetry {
                cancelPendingFrameRetry(for: windowId)
            }
            deferredDeliveries.append(contentsOf: decision.deliveries)
            guard let request = decision.request else { continue }
            if framesByPid[pid] == nil {
                framesByPid[pid] = []
                framesByPid[pid]?.reserveCapacity(8)
            }
            framesByPid[pid]?.append(request)
        }

        for (pid, appFrames) in framesByPid where !appFrames.isEmpty {
            guard let context = AppAXContext.contexts[pid] else {
                handleFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: pid,
                            windowId: $0.windowId,
                            expectedWindow: $0.expectedWindow,
                            targetFrame: $0.frame,
                            currentFrameHint: $0.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: $0.frame,
                                currentFrameHint: $0.currentFrameHint,
                                failureReason: .contextUnavailable
                            )
                        )
                    }
                )
                continue
            }
            context.setFramesBatch(appFrames) { [weak self] results in
                self?.handleFrameApplyResults(results)
            }
        }

        for delivery in deferredDeliveries {
            delivery.deliver()
        }
    }

    func cancelPendingFrameJobs(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        for (pid, windowId) in uniqueFrameEntries(entries) {
            AppAXContext.contexts[pid]?.cancelFrameJob(for: windowId)
            deliveries.append(contentsOf: frameLedger.cancelFrameJob(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    @discardableResult
    func cancelParkFrameJobs(
        _ entries: [(pid: pid_t, windowId: Int)],
        reason: String = "shown"
    ) -> Set<WindowToken> {
        var requiresVisibleAXTokens: Set<WindowToken> = []
        for (pid, windowId) in uniqueFrameEntries(entries) {
            let pending = pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
            let targetState = parkFrameTargetStatesByWindowId.removeValue(forKey: windowId)
            let statePID = pending?.request.pid ?? targetState?.target.pid ?? parkPIDByWindowId[windowId] ?? pid
            let target = pending?.request.frame ?? targetState?.target.frame
            let hadState = pendingParkWindowIds.remove(windowId) != nil
                || pending != nil
                || targetState != nil
                || parkPIDByWindowId[windowId] != nil
            parkPIDByWindowId.removeValue(forKey: windowId)
            if let pending {
                requiresVisibleAXTokens.insert(
                    WindowToken(pid: pending.request.pid, windowId: windowId)
                )
            }
            if let targetState {
                requiresVisibleAXTokens.insert(
                    WindowToken(pid: targetState.target.pid, windowId: windowId)
                )
            }
            AppAXContext.contexts[pid]?.cancelParkFrameJob(for: windowId)
            if statePID != pid {
                AppAXContext.contexts[statePID]?.cancelParkFrameJob(for: windowId)
            }
            if hadState {
                FrameApplyTrace.recordEvent(
                    pid: statePID,
                    windowId: windowId,
                    outcome: "outcome=ax-park-cancelled/\(reason)",
                    target: target
                )
            }
        }
        return requiresVisibleAXTokens
    }

    func suppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        let entries = uniqueFrameEntries(entries)
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.suppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
            clearSkyLightLivePosition(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func unsuppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        let entries = uniqueFrameEntries(entries)
        cancelParkFrameJobs(entries, reason: "shown")
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.unsuppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            clearSkyLightLivePosition(for: windowId)
        }
    }

    func setMacOSAppHidden(
        _ hidden: Bool,
        pid: pid_t,
        entries: [(pid: pid_t, windowId: Int)]
    ) {
        let entries = uniqueFrameEntries(entries)
        let windowIds = entries.lazy.filter { $0.pid == pid }.map(\.windowId)
        if hidden {
            macOSHiddenAppPIDs.insert(pid)
            AppAXContext.setMacOSAppHidden(true, pid: pid, windowIds: Array(windowIds))
            var deliveries: [AXFrameTerminalDelivery] = []
            for (_, windowId) in entries {
                deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
                cancelPendingFrameRetry(for: windowId)
                clearSkyLightLivePosition(for: windowId)
            }
            cancelParkFrameJobs(entries, reason: "app-hidden")
            for delivery in deliveries {
                delivery.deliver()
            }
        } else {
            macOSHiddenAppPIDs.remove(pid)
            AppAXContext.setMacOSAppHidden(false, pid: pid, windowIds: Array(windowIds))
            for (_, windowId) in entries {
                clearSkyLightLivePosition(for: windowId)
            }
        }
        if AppVisibilityTrace.isActive {
            AppVisibilityTrace.record(
                .axFence,
                pid: pid,
                visibility: hidden ? .hidden : .visible,
                outcome: hidden ? .enabled : .disabled,
                managedWindowCount: entries.lazy.filter { $0.pid == pid }.count
            )
        }
    }

    private func uniqueFrameEntries(_ entries: [(pid: pid_t, windowId: Int)]) -> [(pid: pid_t, windowId: Int)] {
        var uniqueEntries: [(pid: pid_t, windowId: Int)] = []
        uniqueEntries.reserveCapacity(entries.count)
        var seen: Set<WindowToken> = []
        for entry in entries {
            let token = WindowToken(pid: entry.pid, windowId: entry.windowId)
            guard seen.insert(token).inserted else { continue }
            uniqueEntries.append(entry)
        }
        return uniqueEntries
    }

    func applyPositionsViaSkyLight(
        _ positions: [(pid: pid_t, windowId: Int, frame: CGRect)],
        allowInactive: Bool = false
    ) {
        let filtered = positions.filter {
            (allowInactive || !inactiveWorkspaceWindowIds.contains($0.windowId))
                && !macOSHiddenAppPIDs.contains($0.pid)
                && (interactionPolicyForWindowId?($0.windowId).mayWriteFrame ?? true)
        }
        guard !filtered.isEmpty else { return }
        SkyLight.shared.batchMoveWindows(
            Self.windowServerPositions(filtered.map { (windowId: $0.windowId, frame: $0.frame) })
        )
    }

    static func windowServerPositions(
        _ positions: [(windowId: Int, frame: CGRect)]
    ) -> [(windowId: UInt32, origin: CGPoint)] {
        positions.map {
            (
                windowId: UInt32($0.windowId),
                origin: ScreenCoordinateSpace.toWindowServer(rect: $0.frame).origin
            )
        }
    }

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy != .prohibited else { return false }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        if let bundleId = app.bundleIdentifier, Self.systemUIBundleIds.contains(bundleId) {
            return false
        }

        return true
    }

    static func shouldEnumerateForFullRescan(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool
    ) -> Bool {
        fullRescanEnumerationRoute(
            activationPolicy: activationPolicy,
            hasDiscoveryEvidence: hasDiscoveryEvidence,
            hasContext: false,
            hasPreservedState: false
        ) != nil
    }

    static func fullRescanEnumerationRoute(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool,
        hasContext: Bool,
        hasPreservedState: Bool
    ) -> FullRescanEnumerationRoute? {
        guard activationPolicy != .prohibited else { return nil }
        if hasDiscoveryEvidence || hasContext || hasPreservedState {
            return .persistent
        }
        return activationPolicy == .regular ? .oneShot : nil
    }

    static func shouldPreferFullRescanCandidate(
        _ candidate: FullRescanWindowCandidate,
        over current: FullRescanWindowCandidate,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        ownerPID: pid_t?,
        existingPID: pid_t?
    ) -> Bool {
        fullRescanCandidatePreference(
            candidate,
            over: current,
            activationPolicyByPID: activationPolicyByPID,
            ownerPID: ownerPID,
            existingPID: existingPID
        ).prefersCandidate
    }

    static func fullRescanCandidatePreference(
        _ candidate: FullRescanWindowCandidate,
        over current: FullRescanWindowCandidate,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        ownerPID: pid_t?,
        existingPID: pid_t?
    ) -> FullRescanCandidatePreference {
        if candidate.isManageable != current.isManageable {
            return .init(prefersCandidate: candidate.isManageable, reason: .manageability)
        }
        let candidateIsExisting = candidate.pid == existingPID
        let currentIsExisting = current.pid == existingPID
        if candidateIsExisting != currentIsExisting {
            return .init(prefersCandidate: candidateIsExisting, reason: .preservedLogicalPID)
        }
        let candidateIsRegular = activationPolicyByPID[candidate.pid] == .regular
        let currentIsRegular = activationPolicyByPID[current.pid] == .regular
        if candidateIsRegular != currentIsRegular {
            return .init(prefersCandidate: candidateIsRegular, reason: .regularActivationPolicy)
        }
        let candidateHostsAXElement = candidate.pid == candidate.axPid
        let currentHostsAXElement = current.pid == current.axPid
        if candidateHostsAXElement != currentHostsAXElement {
            return .init(prefersCandidate: candidateHostsAXElement, reason: .axHostPID)
        }
        let candidateOwnsWindow = candidate.pid == ownerPID
        let currentOwnsWindow = current.pid == ownerPID
        if candidateOwnsWindow != currentOwnsWindow {
            return .init(prefersCandidate: candidateOwnsWindow, reason: .windowServerOwnerPID)
        }
        guard candidate.pid != current.pid else {
            return .init(prefersCandidate: false, reason: .stableFirstCandidate)
        }
        return .init(prefersCandidate: candidate.pid < current.pid, reason: .lowerPID)
    }

    private func groupedWindowIdsByPid(
        _ entries: [(pid: pid_t, windowId: Int)]
    ) -> [pid_t: [Int]] {
        var grouped: [pid_t: [Int]] = [:]
        for (pid, windowId) in entries {
            grouped[pid, default: []].append(windowId)
        }
        return grouped
    }

    func handleFrameApplyResults(_ results: [AXFrameApplyResult]) {
        for result in results {
            FrameApplyTrace.recordResult(result)
        }
        let outcome = frameLedger.handleFrameApplyResults(results) { [weak self] result in
            self?.handleAcceptedFrameApplySuccess(result)
        }
        for retry in outcome.retries {
            FrameApplyTrace.recordEvent(
                pid: retry.pid,
                windowId: retry.windowId,
                outcome: "outcome=retry-scheduled",
                target: retry.frame
            )
            scheduleFrameRetry(
                pid: retry.pid,
                windowId: retry.windowId,
                expectedWindow: retry.expectedWindow,
                frame: retry.frame
            )
        }
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        for refusal in outcome.terminalRefusals {
            FrameApplyTrace.recordEvent(
                pid: refusal.pid,
                windowId: refusal.windowId,
                outcome: "outcome=terminal-refusal/\(refusal.failureReason.traceDescription)",
                target: refusal.targetFrame
            )
            onTerminalFrameRefusal?(refusal)
        }
    }

    func handleAcceptedFrameApplySuccess(_ result: AXFrameApplyResult) {
        if isWindowParked?(result.windowId) == true {
            markParkPending(
                for: result.windowId,
                pid: result.pid,
                target: nil,
                cancellationReason: "ordinary-write"
            )
        }
        onFrameApplySucceeded?(result)
    }

    private func scheduleFrameRetry(
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect
    ) {
        cancelPendingFrameRetry(for: windowId)
        let generation = nextFrameRetryGeneration
        nextFrameRetryGeneration &+= 1
        pendingFrameRetryGenerationByWindowId[windowId] = generation
        pendingFrameRetryTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let currentWindowId = self.frameLedger.resolvedWindowId(for: windowId)
            guard self.pendingFrameRetryGenerationByWindowId[currentWindowId] == generation else { return }
            guard !self.frameLedger.hasPendingFrameWrite(for: currentWindowId) else { return }
            self.pendingFrameRetryGenerationByWindowId.removeValue(forKey: currentWindowId)
            self.pendingFrameRetryTasksByWindowId.removeValue(forKey: currentWindowId)
            self.enqueueFrameApplications(
                [
                    AXFrameApplicationTarget(
                        pid: pid,
                        window: AXWindowRef(
                            element: expectedWindow.element,
                            windowId: currentWindowId
                        ),
                        frame: frame
                    )
                ],
                isRetry: true
            )
        }
    }

    @discardableResult
    private func cancelPendingFrameRetry(for windowId: Int) -> Bool {
        guard let task = pendingFrameRetryTasksByWindowId.removeValue(forKey: windowId) else {
            pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
            return false
        }
        task.cancel()
        pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
        return true
    }

    private func cancelAllPendingFrameState() {
        let parkEntries = parkPIDByWindowId.map { (pid: $0.value, windowId: $0.key) }
        cancelParkFrameJobs(parkEntries, reason: "shutdown")
        pendingParkWindowIds.removeAll()
        pendingParkFrameRequestsByWindowId.removeAll()
        parkFrameTargetStatesByWindowId.removeAll()
        parkPIDByWindowId.removeAll()

        for (_, task) in pendingFrameRetryTasksByWindowId {
            task.cancel()
        }
        pendingFrameRetryTasksByWindowId.removeAll()
        pendingFrameRetryGenerationByWindowId.removeAll()
        macOSHiddenAppPIDs.removeAll()

        let deliveries = frameLedger.cancelAllPendingFrameState()
        for delivery in deliveries {
            delivery.deliver()
        }
    }
}
