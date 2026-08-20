// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
private final class PerformanceCaptureSnapshotStore {
    var initialOwnerSnapshots: PerformanceOwnerSnapshots?
    var finalOwnerSnapshots: PerformanceOwnerSnapshots?
}

private struct PerformanceOwnerSnapshots {
    let refresh: LayoutRefreshController.PerformanceSnapshot?
    let topology: ServiceLifecycleManager.PerformanceSnapshot?
    let intake: EventIntake.PerformanceSnapshot?
    let input: MouseEventHandler.PerformanceSnapshot?
    let hiddenBar: HiddenBarController.PerformanceSnapshot?
    let clipboard: ClipboardHistoryService.PerformanceSnapshot?
    let secureInput: SecureInputMonitor.PerformanceSnapshot?
    let sleep: SleepPreventionManager.PerformanceSnapshot?
    let ax: AppAXContextRuntimeSnapshot
    let pidBuffer: AXManagerPIDBufferRuntimeSnapshot
    let focus: ManagedFocusRetryRuntimeSnapshot
    let surfaces: SurfaceSceneRuntimeSnapshot
}

@MainActor
extension WMController {
    var isTraceCaptureActive: Bool {
        traceCaptureCoordinator.isActive
    }

    var traceCaptureStatus: TraceCaptureStatus {
        traceCaptureCoordinator.status
    }

    @discardableResult
    func toggleTraceCaptureForUI(
        desiredState: TraceCaptureDesiredState = .toggle,
        profile: TraceCaptureProfile = .problem
    ) async -> TraceCaptureOutcome {
        let performanceSnapshots = PerformanceCaptureSnapshotStore()
        let outcome = await traceCaptureCoordinator.toggle(
            desiredState: desiredState,
            profile: profile,
            reportProvider: { [weak self] in
                guard let self else { return "status=controller_unavailable" }
                return profile == .problem
                    ? self.diagnosticsReportText()
                    : self.performanceCaptureReportText(
                        initialOwnerSnapshots: performanceSnapshots.initialOwnerSnapshots,
                        finalOwnerSnapshots: performanceSnapshots.finalOwnerSnapshots
                    )
            },
            performanceMetricsBegin: { [weak self] in
                guard profile == .performance else { return }
                performanceSnapshots.initialOwnerSnapshots = self?.beginPerformanceMetricsCapture()
            },
            performanceMetricsEnd: { [weak self] in
                guard profile == .performance else { return }
                performanceSnapshots.finalOwnerSnapshots = self?.endPerformanceMetricsCapture()
            },
            automaticEvidenceProvider: { [weak self] in
                await self?.automaticTraceEvidence() ?? "status=controller_unavailable"
            }
        )
        if case .started = outcome, profile == .problem {
            seedWindowAdmissionTrace()
        }
        return outcome
    }

    private func performanceCaptureReportText(
        initialOwnerSnapshots: PerformanceOwnerSnapshots?,
        finalOwnerSnapshots: PerformanceOwnerSnapshots?
    ) -> String {
        let snapshot = workspaceManager.reconcileSnapshot()
        let state = [
            "appVersion=\(OmniWMBuildInfo.version)",
            "build=\(OmniWMBuildInfo.build)",
            "gitHash=\(OmniWMBuildInfo.gitHash)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "enabled=\(isEnabled)",
            "locked=\(isLockScreenActive)",
            "animationsEnabled=\(settings.animationsEnabled)",
            "scrollGestureEnabled=\(settings.scrollGestureEnabled)",
            "workspaceSwipeEnabled=\(settings.workspaceSwipeEnabled)",
            "mouseWarpEnabled=\(settings.mouseWarpEnabled)",
            "bordersEnabled=\(settings.bordersEnabled)",
            "workspaceBarEnabled=\(settings.workspaceBarEnabled)",
            "hiddenBarEnabled=\(settings.hiddenBarEnabled)",
            "clipboardHistoryEnabled=\(settings.clipboardHistoryEnabled)",
            "preventSleepEnabled=\(settings.preventSleepEnabled)",
            "worldSeq=\(workspaceManager.worldSeq)",
            "monitors=\(workspaceManager.monitors.count)",
            "workspaces=\(workspaceManager.workspaces.count)",
            "windows=\(snapshot.windows.count)",
            "layouts=\(snapshot.layouts.count)",
            "viewports=\(snapshot.viewports.count)"
        ].joined(separator: "\n")
        var sections = [
            "== Product State ==",
            state
        ]
        if let finalOwnerSnapshots {
            sections.append("")
            sections.append("== Owner Metrics End ==")
            sections.append(performanceMetricsReport(finalOwnerSnapshots))
        } else if let initialOwnerSnapshots {
            sections.append("")
            sections.append("== Owner Metrics Start ==")
            sections.append(performanceMetricsReport(initialOwnerSnapshots))
        } else {
            sections.append("")
            sections.append("== Owner Metrics ==")
            sections.append("unavailable")
        }
        return sections.joined(separator: "\n")
    }

    private func beginPerformanceMetricsCapture() -> PerformanceOwnerSnapshots {
        layoutRefreshController.beginPerformanceCapture()
        serviceLifecycleManager.beginPerformanceCapture()
        eventIntake.beginPerformanceCapture()
        mouseEventHandler.beginPerformanceCapture()
        hiddenBarController.beginPerformanceCapture()
        clipboardHistoryService.beginPerformanceCapture()
        secureInputMonitor.beginPerformanceCapture()
        SleepPreventionManager.shared.beginPerformanceCapture()
        AppAXContextRuntimeMetrics.shared.beginCapture(
            initialDepths: AppAXContext.aggregateRuntimeMailboxDepths()
        )
        axManager.beginPIDBufferRuntimeCapture()
        intentLedger.beginManagedFocusRetryRuntimeCapture()
        SurfaceCoordinator.shared.beginRuntimeCapture()
        return currentPerformanceMetricsSnapshot()
    }

    private func currentPerformanceMetricsSnapshot() -> PerformanceOwnerSnapshots {
        PerformanceOwnerSnapshots(
            refresh: layoutRefreshController.performanceSnapshot(),
            topology: serviceLifecycleManager.performanceSnapshot(),
            intake: eventIntake.performanceSnapshot(),
            input: mouseEventHandler.performanceSnapshot(),
            hiddenBar: hiddenBarController.performanceSnapshot(),
            clipboard: clipboardHistoryService.performanceSnapshot(),
            secureInput: secureInputMonitor.performanceSnapshot(),
            sleep: SleepPreventionManager.shared.performanceSnapshot(),
            ax: AppAXContextRuntimeMetrics.shared.snapshot(),
            pidBuffer: axManager.pidBufferRuntimeSnapshot(),
            focus: intentLedger.managedFocusRetryRuntimeSnapshot(),
            surfaces: SurfaceCoordinator.shared.runtimeSnapshot()
        )
    }

    private func endPerformanceMetricsCapture() -> PerformanceOwnerSnapshots {
        PerformanceOwnerSnapshots(
            refresh: layoutRefreshController.endPerformanceCapture(),
            topology: serviceLifecycleManager.endPerformanceCapture(),
            intake: eventIntake.endPerformanceCapture(),
            input: mouseEventHandler.endPerformanceCapture(),
            hiddenBar: hiddenBarController.endPerformanceCapture(),
            clipboard: clipboardHistoryService.endPerformanceCapture(),
            secureInput: secureInputMonitor.endPerformanceCapture(),
            sleep: SleepPreventionManager.shared.endPerformanceCapture(),
            ax: endAXRuntimeCapture(),
            pidBuffer: endPIDBufferRuntimeCapture(),
            focus: endFocusRuntimeCapture(),
            surfaces: endSurfaceRuntimeCapture()
        )
    }

    private func endAXRuntimeCapture() -> AppAXContextRuntimeSnapshot {
        AppAXContextRuntimeMetrics.shared.endCapture()
        return AppAXContextRuntimeMetrics.shared.snapshot()
    }

    private func endPIDBufferRuntimeCapture() -> AXManagerPIDBufferRuntimeSnapshot {
        axManager.endPIDBufferRuntimeCapture()
        return axManager.pidBufferRuntimeSnapshot()
    }

    private func endFocusRuntimeCapture() -> ManagedFocusRetryRuntimeSnapshot {
        intentLedger.endManagedFocusRetryRuntimeCapture()
        return intentLedger.managedFocusRetryRuntimeSnapshot()
    }

    private func endSurfaceRuntimeCapture() -> SurfaceSceneRuntimeSnapshot {
        SurfaceCoordinator.shared.endRuntimeCapture()
        return SurfaceCoordinator.shared.runtimeSnapshot()
    }

    private func performanceMetricsReport(
        _ snapshots: PerformanceOwnerSnapshots
    ) -> String {
        var lines: [String] = []
        if let refresh = snapshots.refresh {
            lines.append(
                "refresh enqueued=\(refresh.refreshesEnqueued) merged=\(refresh.refreshesMerged)"
                    + " started=\(refresh.refreshesStarted) completed=\(refresh.refreshesCompleted)"
                    + " incomplete=\(refresh.refreshesIncomplete) lockedDeferrals=\(refresh.lockedRefreshDeferrals)"
                    + " immediateRestarts=\(refresh.immediateRefreshRestarts)"
                    + " maxRequeueStreak=\(refresh.maximumConsecutiveRequeues)"
            )
            lines.append(
                "displayLink created=\(refresh.displayLinksCreated) invalidated=\(refresh.displayLinksInvalidated)"
                    + " callbacks=\(refresh.displayLinkCallbacks)"
                    + " meaningful=\(refresh.meaningfulDisplayLinkCallbacks)"
                    + " noWork=\(refresh.noWorkDisplayLinkCallbacks)"
                    + " active=\(refresh.activeDisplayLinks)"
                    + " activeHighWater=\(refresh.activeDisplayLinkHighWater)"
            )
            lines.append(
                "displayLinkStops idle=\(refresh.displayLinkIdleStops) noWork=\(refresh.displayLinkNoWorkStops)"
                    + " monitorDisconnect=\(refresh.displayLinkMonitorDisconnectStops)"
                    + " reset=\(refresh.displayLinkResetStops)"
            )
        }
        if let topology = snapshots.topology {
            lines.append(
                "topology samples=\(topology.topologySamples) fallbacks=\(topology.topologyGlobalFallbacks)"
                    + " authoritativeStops=\(topology.authoritativeTerminations)"
                    + " fallbackStops=\(topology.globalFallbackTerminations)"
                    + " cancelledStops=\(topology.cancelledTerminations)"
                    + " supersededStops=\(topology.supersededTerminations)"
                    + " lastStop=\(topology.lastTopologyTerminalReason?.rawValue ?? "none")"
            )
        }
        if let intake = snapshots.intake {
            lines.append(
                "intake accepted=\(intake.acceptedEvents) coalesced=\(intake.coalescedEvents)"
                    + " delivered=\(intake.deliveredEvents) drains=\(intake.drainBatches)"
                    + " depth=\(intake.currentQueueDepth) maxDepth=\(intake.maximumQueueDepth)"
                    + " maxBatch=\(intake.maximumBatchSize)"
            )
            lines.append(
                "intakeCGS accepted/coalesced/delivered"
                    + " created=\(eventCategoryCounts(intake.cgsCreatedEvents))"
                    + " destroyed=\(eventCategoryCounts(intake.cgsDestroyedEvents))"
                    + " frame=\(eventCategoryCounts(intake.cgsFrameChangedEvents))"
                    + " title=\(eventCategoryCounts(intake.cgsTitleChangedEvents))"
            )
            lines.append(
                "intakeAX accepted/coalesced/delivered"
                    + " lifecycle=\(eventCategoryCounts(intake.axLifecycleEvents))"
                    + " focused=\(eventCategoryCounts(intake.axFocusedWindowChangedEvents))"
            )
        }
        if let input = snapshots.input {
            lines.append(
                "input cgEvents=\(input.cgEvents) moved=\(input.mouseMovedEvents)"
                    + " dragged=\(input.mouseDraggedEvents) scroll=\(input.scrollEvents)"
                    + " buttons=\(input.buttonEvents) droppedTrackpadScroll=\(input.droppedTrackpadScrollEvents)"
                    + " warpSamples=\(input.mouseWarpSamples)"
            )
            if let touch = input.multitouch {
                lines.append(
                    "touch raw=\(touch.rawCallbacks) stale=\(touch.staleCallbacks)"
                        + " drains=\(touch.drainBatches) overwritten=\(touch.overwrittenChanges)"
                        + " transitions=\(touch.transitionsQueued) cursorSamples=\(touch.cursorSamples)"
                        + " pending=\(touch.pendingFrames) maxPending=\(touch.maximumPendingFrames)"
                )
            }
        }
        if let hiddenBar = snapshots.hiddenBar {
            lines.append(
                "hiddenBar refreshEvents=\(hiddenBar.refreshEvents) menuQueries=\(hiddenBar.menuGuardQueries)"
                    + " tasksStarted=\(hiddenBar.reconcealTasksStarted)"
                    + " tasksCancelled=\(hiddenBar.reconcealTasksCancelled)"
                    + " deferrals=\(hiddenBar.menuGuardDeferrals)"
                    + " maxDeferrals=\(hiddenBar.maximumConsecutiveDeferrals)"
                    + " terminal=\(hiddenBar.terminalReason.map { String(describing: $0) } ?? "none")"
            )
        }
        if let clipboard = snapshots.clipboard,
           let secureInput = snapshots.secureInput,
           let sleep = snapshots.sleep
        {
            lines.append(
                "periodic clipboard=\(clipboard.timerFires) secureInput=\(secureInput.recoveryTimerFires)"
                    + " sleepTimer=\(sleep.timerFires) sleepAssertions=\(sleep.assertionRefreshes)"
            )
        }
        let ax = snapshots.ax
        lines.append(
            "ax submitted=\(ax.submitted) started=\(ax.started) completed=\(ax.completed)"
                + " cancelled=\(ax.cancelled) replaced=\(ax.replaced)"
                + " pending=\(ax.pending) inFlight=\(ax.inFlight)"
                + " pendingHighWater=\(ax.pendingHighWater) inFlightHighWater=\(ax.inFlightHighWater)"
                + " staleBeforeIPC=\(ax.staleBeforeIPC) enhancedUI=\(ax.enhancedUICalls)"
        )
        lines.append(
            "axOrdinary submitted=\(ax.ordinarySubmitted) started=\(ax.ordinaryStarted)"
                + " completed=\(ax.ordinaryCompleted) cancelled=\(ax.ordinaryCancelled)"
                + " replaced=\(ax.ordinaryReplaced) pending=\(ax.ordinaryPending)"
                + " inFlight=\(ax.ordinaryInFlight) pendingHighWater=\(ax.ordinaryPendingHighWater)"
                + " inFlightHighWater=\(ax.ordinaryInFlightHighWater)"
        )
        lines.append(
            "axPark submitted=\(ax.parkSubmitted) started=\(ax.parkStarted)"
                + " completed=\(ax.parkCompleted) cancelled=\(ax.parkCancelled)"
                + " replaced=\(ax.parkReplaced) pending=\(ax.parkPending)"
                + " inFlight=\(ax.parkInFlight) pendingHighWater=\(ax.parkPendingHighWater)"
                + " inFlightHighWater=\(ax.parkInFlightHighWater)"
        )
        lines.append(
            "axClosing submitted=\(ax.closingSubmitted) started=\(ax.closingStarted)"
                + " completed=\(ax.closingCompleted) cancelled=\(ax.closingCancelled)"
                + " replaced=\(ax.closingReplaced) pending=\(ax.closingPending)"
                + " inFlight=\(ax.closingInFlight) pendingHighWater=\(ax.closingPendingHighWater)"
                + " inFlightHighWater=\(ax.closingInFlightHighWater)"
        )
        let pidBuffer = snapshots.pidBuffer
        lines.append(
            "axQueueWait samples=\(ax.queueWaitSamples) ordinaryStarted=\(ax.ordinaryStarted)"
                + " under1ms=\(ax.queueWaitUnder1ms) under4ms=\(ax.queueWaitUnder4ms)"
                + " under16ms=\(ax.queueWaitUnder16ms) atLeast16ms=\(ax.queueWaitAtLeast16ms)"
        )
        let focus = snapshots.focus
        lines.append(
            "pidScratch current=\(pidBuffer.currentSize) highWater=\(pidBuffer.highWater)"
                + " retainedCapacity=\(pidBuffer.retainedCapacity)"
        )
        let surfaces = snapshots.surfaces
        lines.append(
            "focus attempts=\(focus.attempts) sourceChanges=\(focus.sourceChanges)"
                + " deadlineRearms=\(focus.deadlineRearms) exhaustions=\(focus.exhaustions)"
        )
        lines.append(
            "surfaces total=\(surfaces.total) live=\(surfaces.live) dead=\(surfaces.dead)"
                + " numberBacked=\(surfaces.numberBacked)"
                + " reverseEntries=\(surfaces.reverseEntries)"
                + " orphanReverseEntries=\(surfaces.orphanReverseEntries)"
                + " highWater=\(surfaces.highWater)"
        )
        lines.append(
            "surfaceKinds "
                + SurfaceKind.allCases.map {
                    "\($0.rawValue)=\(surfaces.byKind[$0, default: 0])"
                }.joined(separator: " ")
        )
        return lines.isEmpty ? "unavailable" : lines.joined(separator: "\n")
    }

    private func eventCategoryCounts(
        _ snapshot: EventIntake.EventCategoryPerformanceSnapshot
    ) -> String {
        "\(snapshot.acceptedEvents)/\(snapshot.coalescedEvents)/\(snapshot.deliveredEvents)"
    }

    private func automaticTraceEvidence() async -> String {
        guard let request = automaticAXSnapshotRequest() else {
            let snapshot = AutomaticAXSnapshot(
                generatedAt: Date().ISO8601Format(),
                reason: "no_external_target",
                pid: 0,
                windowId: nil,
                status: "unavailable",
                app: nil,
                window: nil
            )
            return await Task.detached(priority: .utility) {
                AutomaticAXSnapshotCollector.shared.encoded(snapshot)
            }.value
        }
        let snapshot = await AutomaticAXSnapshotCollector.shared.capture(request)
        return await Task.detached(priority: .utility) {
            AutomaticAXSnapshotCollector.shared.encoded(snapshot)
        }.value
    }

    private func automaticAXSnapshotRequest() -> AutomaticAXSnapshotRequest? {
        let ownPID = getpid()
        if let target = WindowAdmissionTrace.shared.finalizationTarget(excludingPID: ownPID) {
            return AutomaticAXSnapshotRequest(
                reason: "window_admission:\(target.reason)",
                pid: target.pid,
                windowId: target.windowId
            )
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID
        {
            let pid = frontmost.processIdentifier
            let token = workspaceManager.focusedToken.flatMap { $0.pid == pid ? $0 : nil }
            return AutomaticAXSnapshotRequest(
                reason: "frontmost_external",
                pid: pid,
                windowId: token?.windowId
            )
        }
        guard let token = workspaceManager.focusedToken,
              token.pid != ownPID
        else {
            return nil
        }
        return AutomaticAXSnapshotRequest(
            reason: "last_managed_focus",
            pid: token.pid,
            windowId: token.windowId
        )
    }

    private func seedWindowAdmissionTrace() {
        for pid in AppAXContext.contexts.keys.sorted() {
            guard let context = AppAXContext.contexts[pid] else { continue }
            WindowAdmissionTrace.record(
                .init(
                    action: .endpointCreated,
                    pid: pid,
                    bundleId: context.nsApp.bundleIdentifier,
                    callbackGeneration: context.callbackGeneration
                )
            )
        }
        let ownPID = getpid()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID
        {
            recordInitialTarget(
                action: .frontmostObserved,
                pid: frontmost.processIdentifier,
                bundleId: frontmost.bundleIdentifier,
                reason: "recording_start_frontmost"
            )
            return
        }
        guard let focused = workspaceManager.focusedToken,
              focused.pid != ownPID
        else { return }
        recordInitialTarget(
            action: .managedFocusObserved,
            pid: focused.pid,
            bundleId: NSRunningApplication(processIdentifier: focused.pid)?.bundleIdentifier,
            reason: "recording_start_managed_focus"
        )
    }

    private func recordInitialTarget(
        action: WindowAdmissionTraceAction,
        pid: pid_t,
        bundleId: String?,
        reason: String
    ) {
        let token = workspaceManager.focusedToken.flatMap { $0.pid == pid ? $0 : nil }
        WindowAdmissionTrace.record(
            WindowAdmissionTraceEvent(
                action: action,
                pid: pid,
                windowId: token?.windowId,
                bundleId: bundleId,
                axPid: pid,
                reason: reason,
                axRef: token.flatMap { workspaceManager.entry(for: $0)?.axRef }
            )
        )
    }
}
