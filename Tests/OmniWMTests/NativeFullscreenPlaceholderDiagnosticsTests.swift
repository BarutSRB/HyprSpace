// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeFullscreenPlaceholderDiagnosticsTests: XCTestCase {
    func testTraceInactiveDoesNotEvaluateRecordAutoclosure() {
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        NativeFullscreenPlaceholderTrace.shared.endCapture()
        NativeFullscreenPlaceholderTrace.motion.beginCapture()
        NativeFullscreenPlaceholderTrace.motion.endCapture()
        var evaluated = false

        func makeRecord() -> NativeFullscreenPlaceholderTrace.Record {
            evaluated = true
            return NativeFullscreenPlaceholderTrace.makeRecord(.panelMoved)
        }

        NativeFullscreenPlaceholderTrace.record(makeRecord())

        XCTAssertFalse(evaluated)
        XCTAssertEqual(NativeFullscreenPlaceholderTrace.shared.dump(), "none")
        XCTAssertEqual(NativeFullscreenPlaceholderTrace.motion.dump(), "none")
    }

    func testTraceFormatsMediaTimeAndSelection() {
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        defer { NativeFullscreenPlaceholderTrace.shared.endCapture() }

        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .surfaceApplied,
                originalToken: WindowToken(pid: 982_003, windowId: 982_103),
                visible: true,
                selected: true,
                reason: .accepted
            )
        )

        let dump = NativeFullscreenPlaceholderTrace.shared.dump()
        XCTAssertTrue(dump.hasPrefix("t="))
        XCTAssertTrue(dump.contains("op=surface_applied"))
        XCTAssertTrue(dump.contains("selected=true"))
    }

    func testMotionTraceCannotEvictLifecycleEvidence() {
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        NativeFullscreenPlaceholderTrace.motion.beginCapture()
        defer {
            NativeFullscreenPlaceholderTrace.shared.endCapture()
            NativeFullscreenPlaceholderTrace.motion.endCapture()
        }
        let token = WindowToken(pid: 982_004, windowId: 982_104)

        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .recordUpsert,
                originalToken: token,
                currentToken: token,
                transition: .suspended
            )
        )
        for offset in 0 ..< 5_000 {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    offset.isMultiple(of: 2) ? .panelMoved : .panelResized,
                    originalToken: token,
                    currentToken: token,
                    panelFrame: CGRect(x: offset, y: 0, width: 500, height: 400)
                )
            )
        }

        let lifecycleDump = NativeFullscreenPlaceholderTrace.shared.dump()
        let motionDump = NativeFullscreenPlaceholderTrace.motion.dump()
        XCTAssertTrue(lifecycleDump.contains("op=record_upsert original=982004:982104"))
        XCTAssertFalse(lifecycleDump.contains("op=panel_moved"))
        XCTAssertFalse(lifecycleDump.contains("op=panel_resized"))
        XCTAssertTrue(motionDump.hasPrefix("incomplete=true evicted="))
        XCTAssertEqual(motionDump.split(separator: "\n").count, 2_049)
    }

    func testLifecycleAndDeadlineOperationsAreTraced() throws {
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        defer { NativeFullscreenPlaceholderTrace.shared.endCapture() }
        let fixture = try makeFixture()
        XCTAssertTrue(fixture.controller.workspaceManager.restoreNativeFullscreenRecord(for: fixture.token))

        let dump = NativeFullscreenPlaceholderTrace.shared.dump()
        XCTAssertTrue(dump.contains("op=record_upsert original=982001:982101"))
        XCTAssertTrue(dump.contains("transition=enter_requested generation=1"))
        XCTAssertTrue(dump.contains("op=deadline_scheduled"))
        XCTAssertTrue(dump.contains("op=deadline_cancelled original=982001:982101"))
        XCTAssertTrue(dump.contains("op=record_removed original=982001:982101"))
    }

    func testProjectionTraceRejectsWrongDisplayAndSuppressesGeometryOnlyAcceptance() throws {
        let fixture = try makeFixture()
        defer {
            fixture.controller.nativeFullscreenPlaceholderManager.removeAll()
            fixture.controller.surfaceReconciler.cleanup()
            NativeFullscreenPlaceholderTrace.shared.endCapture()
        }
        fixture.controller.surfaceReconciler.reconcileNow()
        let context = NativeFullscreenDisplayContext(
            workingFrame: fixture.monitor.visibleFrame,
            scale: 1
        )
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        let firstSlot = NativeFullscreenSlotProjection(
            currentToken: fixture.token,
            frame: CGRect(x: 100, y: 100, width: 700, height: 500),
            visible: true
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [fixture.token: firstSlot],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId + 1,
            displayContext: context
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [fixture.token: firstSlot],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: context
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: CGRect(x: 140, y: 100, width: 700, height: 500),
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: context
        )

        let dump = NativeFullscreenPlaceholderTrace.shared.dump()
        XCTAssertTrue(dump.contains("op=projection_discarded"))
        XCTAssertTrue(dump.contains("display=98202"))
        XCTAssertTrue(dump.contains("reason=display_mismatch"))
        XCTAssertEqual(dump.components(separatedBy: "op=projection_accepted").count - 1, 1)
        XCTAssertEqual(dump.components(separatedBy: "op=surface_applied").count - 1, 1)
    }

    func testActualPanelMotionAndVisibilityOperationsAreTraced() {
        let manager = NativeFullscreenPlaceholderManager()
        let originalToken = WindowToken(pid: 982_001, windowId: 982_101)
        let workspaceId = WorkspaceDescriptor.ID()
        let context = NativeFullscreenDisplayContext(
            workingFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            scale: 1
        )
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        NativeFullscreenPlaceholderTrace.motion.beginCapture()
        defer {
            manager.removeAll()
            NativeFullscreenPlaceholderTrace.shared.endCapture()
            NativeFullscreenPlaceholderTrace.motion.endCapture()
        }

        manager.apply([
            NativeFullscreenPlaceholderUpdate(
                originalToken: originalToken,
                currentToken: originalToken,
                workspaceId: workspaceId,
                frame: CGRect(x: 100, y: 100, width: 700, height: 500),
                displayContext: context,
                selected: false,
                visible: true
            )
        ])
        manager.moveForAnimation(
            NativeFullscreenPlaceholderUpdate(
                originalToken: originalToken,
                currentToken: originalToken,
                workspaceId: workspaceId,
                frame: CGRect(x: 140, y: 100, width: 700, height: 500),
                displayContext: context,
                selected: false,
                visible: true
            )
        )
        manager.apply([
            NativeFullscreenPlaceholderUpdate(
                originalToken: originalToken,
                currentToken: originalToken,
                workspaceId: workspaceId,
                frame: CGRect(x: 140, y: 100, width: 700, height: 500),
                displayContext: context,
                selected: false,
                visible: false
            )
        ])

        let lifecycleDump = NativeFullscreenPlaceholderTrace.shared.dump()
        let motionDump = NativeFullscreenPlaceholderTrace.motion.dump()
        let lifecycleLines = lifecycleDump.split(separator: "\n").map(String.init)
        let createdIndex = lifecycleLines.firstIndex { $0.contains("op=panel_created") }
        let captureLines = lifecycleLines.enumerated().filter { $0.element.contains("op=capture_") }
        guard let createdIndex else { return XCTFail("missing panel_created trace") }
        XCTAssertFalse(captureLines.isEmpty)
        XCTAssertTrue(captureLines.allSatisfy { $0.offset > createdIndex })
        XCTAssertTrue(
            captureLines.allSatisfy {
                $0.element.contains("current=982001:982101")
                    && $0.element.contains("workspace=\(workspaceId.uuidString)")
            }
        )
        let exclusionLines = captureLines.filter { $0.element.contains("op=capture_excluded") }
        if exclusionLines.isEmpty {
            XCTAssertTrue(captureLines.contains { $0.element.contains("op=capture_retry_scheduled") })
        } else {
            XCTAssertTrue(
                exclusionLines.allSatisfy {
                    $0.element.contains("reason=capture_verified")
                        || $0.element.contains("reason=capture_unverified")
                }
            )
        }
        XCTAssertTrue(lifecycleDump.contains("op=panel_created original=982001:982101"))
        XCTAssertTrue(lifecycleDump.contains("op=panel_hidden"))
        XCTAssertTrue(motionDump.contains("op=panel_moved"))
        XCTAssertTrue(motionDump.contains("slot=(140,100 700x500)"))
        let panel = manager.diagnosticsSnapshot().first
        XCTAssertEqual(panel?.slotFrame, CGRect(x: 140, y: 100, width: 700, height: 500))
        XCTAssertEqual(panel?.panelFrame, CGRect(x: 140, y: 100, width: 700, height: 500))
    }

    func testDefaultCoordinatorIncludesNativeFullscreenTrace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNativeFullscreenTrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory)

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected capture to start")
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .projectionAccepted,
                originalToken: WindowToken(pid: 982_002, windowId: 982_102),
                workspaceId: WorkspaceDescriptor.ID(),
                displayId: 98_202,
                slotFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
                workingFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
                scale: 2,
                visible: true,
                reason: .accepted
            )
        )
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .panelMoved,
                originalToken: WindowToken(pid: 982_002, windowId: 982_102),
                panelFrame: CGRect(x: 20, y: 20, width: 300, height: 200)
            )
        )
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected capture artifact")
        }

        let body = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(body.contains("== Native Fullscreen Placeholder Trace =="))
        XCTAssertTrue(body.contains("== Native Fullscreen Placeholder Motion Trace =="))
        XCTAssertTrue(body.contains("op=projection_accepted original=982002:982102"))
        XCTAssertTrue(body.contains("op=panel_moved original=982002:982102"))
        XCTAssertTrue(body.contains("working=(0,0 1440x860) scale=2.00"))
    }

    func testReportIncludesHiddenRetainedPanelAndAllJoinStages() throws {
        let fixture = try makeFixture()
        defer {
            fixture.controller.nativeFullscreenPlaceholderManager.removeAll()
            fixture.controller.surfaceReconciler.cleanup()
        }
        fixture.controller.surfaceReconciler.reconcileNow()
        let slot = CGRect(x: 120, y: 80, width: 640, height: 480)
        let context = NativeFullscreenDisplayContext(
            workingFrame: fixture.monitor.visibleFrame,
            scale: 2
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: slot,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: context
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [:],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: context
        )

        let snapshot = NativeFullscreenPlaceholderDiagnosticsSnapshot.capture(fixture.controller)
        let panel = try XCTUnwrap(snapshot.panels.first)
        let report = snapshot.formatted()
        let surfaceId = "native-fullscreen-placeholder-\(fixture.token.pid)-\(fixture.token.windowId)"

        XCTAssertFalse(panel.windowVisible)
        XCTAssertFalse(panel.appliedVisible)
        XCTAssertNotNil(panel.panelFrame)
        XCTAssertTrue(panel.frameSynchronized)
        XCTAssertEqual(panel.displayContext, context)
        XCTAssertFalse(
            fixture.controller.ownedWindowRegistry.visibleSurfaceInfos().contains { $0.id == surfaceId }
        )
        XCTAssertTrue(report.contains("original=982001:982101 resolution=slot_missing"))
        XCTAssertTrue(report.contains("record current=982001:982101 workspace=\(fixture.workspaceId.uuidString)"))
        XCTAssertTrue(report.contains("descriptor current=982001:982101"))
        XCTAssertTrue(
            report.contains(
                "acceptedProjection workspace=\(fixture.workspaceId.uuidString) display=98201"
            )
        )
        XCTAssertTrue(report.contains("slots=0"))
        XCTAssertTrue(report.contains("acceptedSlot=none"))
        XCTAssertTrue(report.contains("applied current=982001:982101"))
        XCTAssertTrue(report.contains("panel current=982001:982101"))
        XCTAssertTrue(report.contains("actual="))
        XCTAssertTrue(report.contains("windowVisible=false"))
        XCTAssertTrue(report.contains("collection=[canJoinAllSpaces,stationary,ignoresCycle]"))
        XCTAssertTrue(report.contains("registryCaptureEligible=false"))
        XCTAssertTrue(report.contains("skyLightExcluded="))
        XCTAssertTrue(report.contains("retryIndex="))
    }

    func testReportUsesReconcilerRetentionReasonAfterRekey() throws {
        let fixture = try makeFixture()
        defer {
            fixture.controller.nativeFullscreenPlaceholderManager.removeAll()
            fixture.controller.surfaceReconciler.cleanup()
        }
        fixture.controller.surfaceReconciler.reconcileNow()
        let context = NativeFullscreenDisplayContext(
            workingFrame: fixture.monitor.visibleFrame,
            scale: 1
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: CGRect(x: 120, y: 80, width: 640, height: 480),
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: context
        )
        let replacement = WindowToken(pid: fixture.token.pid, windowId: fixture.token.windowId + 1)
        XCTAssertNotNil(
            fixture.controller.workspaceManager.rekeyWindow(
                from: fixture.token,
                to: replacement,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(replacement.pid),
                    windowId: replacement.windowId
                )
            )
        )
        fixture.controller.surfaceReconciler.reconcileNow()

        let report = NativeFullscreenPlaceholderDiagnosticsSnapshot.capture(fixture.controller).formatted()

        XCTAssertTrue(report.contains("original=982001:982101 resolution=slot_token_mismatch_retained"))
        XCTAssertTrue(report.contains("record current=982001:982102"))
        XCTAssertTrue(report.contains("descriptor current=982001:982102"))
        XCTAssertTrue(report.contains("acceptedSlot current=982001:982101"))
        XCTAssertTrue(report.contains("applied current=982001:982102"))
        XCTAssertFalse(report.contains("descriptor-token-mismatch"))
    }

    func testCaptureSummaryPreservesUnknownAndVerifiedStates() {
        let unknown = panelDiagnostics(
            skyLightCaptureExcluded: nil,
            captureExclusionOutcome: .acceptedUnverified
        )
        let excluded = panelDiagnostics(
            skyLightCaptureExcluded: true,
            captureExclusionOutcome: .verified
        )
        let included = panelDiagnostics(
            skyLightCaptureExcluded: false,
            captureExclusionOutcome: .failed
        )

        XCTAssertTrue(unknown.captureSummary.contains("skyLightExcluded=unknown"))
        XCTAssertTrue(unknown.captureSummary.contains("exclusionOutcome=accepted_unverified"))
        XCTAssertTrue(excluded.captureSummary.contains("skyLightExcluded=true"))
        XCTAssertTrue(excluded.captureSummary.contains("exclusionOutcome=verified"))
        XCTAssertTrue(included.captureSummary.contains("skyLightExcluded=false"))
        XCTAssertTrue(included.captureSummary.contains("exclusionOutcome=failed"))
    }

    func testCaptureExclusionOutcomePreservesTriStateVerification() {
        XCTAssertEqual(
            NativeFullscreenCaptureExclusionOutcome.resolve(writeAccepted: false, readback: nil),
            .failed
        )
        XCTAssertEqual(
            NativeFullscreenCaptureExclusionOutcome.resolve(writeAccepted: true, readback: false),
            .failed
        )
        XCTAssertEqual(
            NativeFullscreenCaptureExclusionOutcome.resolve(writeAccepted: true, readback: nil),
            .acceptedUnverified
        )
        XCTAssertEqual(
            NativeFullscreenCaptureExclusionOutcome.resolve(writeAccepted: true, readback: true),
            .verified
        )
    }

    func testReportIdentifiesPanelOrderedOffActiveSpace() {
        let token = WindowToken(pid: 982_005, windowId: 982_105)
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 100, y: 100, width: 700, height: 500)
        let descriptor = NativeFullscreenPlaceholderUpdate(
            originalToken: token,
            currentToken: token,
            workspaceId: workspaceId,
            frame: frame,
            displayContext: NativeFullscreenDisplayContext(
                workingFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
                scale: 2
            ),
            selected: false,
            visible: true
        )
        let snapshot = NativeFullscreenPlaceholderDiagnosticsSnapshot(
            servicesStarted: true,
            lifecycle: NativeFullscreenLifecycleDiagnosticsSnapshot(
                records: [
                    .init(
                        originalToken: token,
                        currentToken: token,
                        workspaceId: workspaceId,
                        transition: "suspended",
                        generation: 1,
                        deadlineArmed: false,
                        entryPresent: true,
                        layoutReason: "nativeFullscreen",
                        workspaceVisible: true,
                        appHidden: false,
                        cornerHidden: false,
                        displayId: 1,
                        displayUUID: "display",
                        displayShowingFullscreen: false
                    )
                ],
                isNonManagedFocusActive: false,
                nonManagedFocusToken: nil,
                activeFocusOwnerToken: nil,
                renderableFocusToken: nil
            ),
            surface: NativeFullscreenSurfaceDiagnosticsSnapshot(
                descriptors: [descriptor],
                acceptedProjections: [],
                acceptedSlots: [],
                applied: [descriptor],
                resolutions: [.init(originalToken: token, reason: .accepted)],
                appliedDuplicateOriginalTokens: []
            ),
            panels: [
                panelDiagnostics(
                    skyLightCaptureExcluded: nil,
                    panelFrame: frame,
                    windowFrame: frame,
                    originalToken: token,
                    workspaceId: workspaceId,
                    descriptorVisible: true,
                    appliedVisible: true,
                    windowVisible: false,
                    onActiveSpace: false
                )
            ]
        )

        let report = snapshot.formatted()
        XCTAssertTrue(report.contains("original=982005:982105 resolution=panel-off-active-space"))
        XCTAssertFalse(report.contains("resolution=ordering-failed"))
    }

    func testPanelFrameSynchronizationAllowsOnePhysicalPixel() {
        let synchronized = panelDiagnostics(
            skyLightCaptureExcluded: nil,
            panelFrame: CGRect(x: 10, y: 10, width: 181.5, height: 64),
            windowFrame: CGRect(x: 10, y: 10, width: 182, height: 64)
        )
        let desynchronized = panelDiagnostics(
            skyLightCaptureExcluded: nil,
            panelFrame: CGRect(x: 10, y: 10, width: 181.5, height: 64),
            windowFrame: CGRect(x: 12, y: 10, width: 184, height: 64)
        )

        XCTAssertTrue(synchronized.frameSynchronized)
        XCTAssertFalse(desynchronized.frameSynchronized)
    }

    func testReportIdentifiesTemporaryEntryLoss() {
        let originalToken = WindowToken(pid: 10, windowId: 20)
        let workspaceId = WorkspaceDescriptor.ID()
        let descriptor = NativeFullscreenPlaceholderUpdate(
            originalToken: originalToken,
            currentToken: originalToken,
            workspaceId: workspaceId,
            frame: .zero,
            displayContext: nil,
            selected: false,
            visible: false
        )
        let snapshot = NativeFullscreenPlaceholderDiagnosticsSnapshot(
            servicesStarted: true,
            lifecycle: NativeFullscreenLifecycleDiagnosticsSnapshot(
                records: [
                    .init(
                        originalToken: originalToken,
                        currentToken: originalToken,
                        workspaceId: workspaceId,
                        transition: "suspended",
                        generation: 2,
                        deadlineArmed: false,
                        entryPresent: false,
                        layoutReason: nil,
                        workspaceVisible: true,
                        appHidden: false,
                        cornerHidden: false,
                        displayId: 1,
                        displayUUID: "display",
                        displayShowingFullscreen: false
                    )
                ],
                isNonManagedFocusActive: false,
                nonManagedFocusToken: nil,
                activeFocusOwnerToken: nil,
                renderableFocusToken: nil
            ),
            surface: NativeFullscreenSurfaceDiagnosticsSnapshot(
                descriptors: [descriptor],
                acceptedProjections: [],
                acceptedSlots: [],
                applied: [descriptor],
                resolutions: [
                    .init(originalToken: originalToken, reason: .layoutNotNativeFullscreen)
                ],
                appliedDuplicateOriginalTokens: []
            ),
            panels: []
        )

        XCTAssertTrue(snapshot.formatted().contains("original=10:20 resolution=entry-missing"))
    }

    private func makeFixture() throws -> (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        token: WindowToken
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNativeFullscreenDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.hasStartedServices = true
        let monitor = Monitor(
            id: .init(displayId: 98_201),
            displayId: 98_201,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: "Native Fullscreen Diagnostics",
            displayUUID: "98201982-0198-4298-8298-201982019820"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: try XCTUnwrap(monitor.displayUUID),
                        spaceIds: [1],
                        currentSpaceId: 1
                    )
                ],
                activeSpaceId: 1,
                fullscreenSpaceIds: [],
                windowSpace: [:]
            )
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(982_001), windowId: 982_101),
            pid: 982_001,
            windowId: 982_101,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertTrue(
            controller.workspaceManager.markNativeFullscreenSuspended(
                token,
                ownsNonManagedFocus: false
            )
        )
        return (controller, workspaceId, monitor, token)
    }

    private func panelDiagnostics(
        skyLightCaptureExcluded: Bool?,
        panelFrame: CGRect? = nil,
        windowFrame: CGRect = .zero,
        originalToken: WindowToken = WindowToken(pid: 1, windowId: 2),
        workspaceId: WorkspaceDescriptor.ID = WorkspaceDescriptor.ID(),
        descriptorVisible: Bool = false,
        appliedVisible: Bool = false,
        windowVisible: Bool = false,
        onActiveSpace: Bool = false,
        captureExclusionOutcome: NativeFullscreenCaptureExclusionOutcome? = nil
    ) -> NativeFullscreenPanelDiagnostics {
        NativeFullscreenPanelDiagnostics(
            originalToken: originalToken,
            currentToken: originalToken,
            workspaceId: workspaceId,
            slotFrame: panelFrame ?? .zero,
            displayContext: NativeFullscreenDisplayContext(workingFrame: .zero, scale: 2),
            panelFrame: panelFrame,
            windowFrame: windowFrame,
            descriptorVisible: descriptorVisible,
            appliedVisible: appliedVisible,
            windowVisible: windowVisible,
            windowNumber: 3,
            level: 0,
            orderedIndex: 0,
            onActiveSpace: onActiveSpace,
            collectionBehavior: 0,
            registeredWindowNumber: 3,
            registryCaptureEligible: false,
            skyLightCaptureExcluded: skyLightCaptureExcluded,
            excludedWindowNumber: nil,
            captureExclusionOutcome: captureExclusionOutcome,
            captureRetryIndex: 0,
            captureRetryPending: false,
            captureRetryExhausted: false
        )
    }
}
