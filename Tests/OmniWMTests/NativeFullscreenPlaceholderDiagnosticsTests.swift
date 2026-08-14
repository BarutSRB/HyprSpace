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
        var evaluated = false

        func makeRecord() -> NativeFullscreenPlaceholderTrace.Record {
            evaluated = true
            return NativeFullscreenPlaceholderTrace.makeRecord(.panelMoved)
        }

        NativeFullscreenPlaceholderTrace.record(makeRecord())

        XCTAssertFalse(evaluated)
        XCTAssertEqual(NativeFullscreenPlaceholderTrace.shared.dump(), "none")
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
        let context = NativeFullscreenCardDisplayContext(
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
        let context = NativeFullscreenCardDisplayContext(
            workingFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            scale: 1
        )
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        defer {
            manager.removeAll()
            NativeFullscreenPlaceholderTrace.shared.endCapture()
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

        let dump = NativeFullscreenPlaceholderTrace.shared.dump()
        XCTAssertTrue(dump.contains("op=panel_created original=982001:982101"))
        XCTAssertTrue(dump.contains("op=panel_moved"))
        XCTAssertTrue(dump.contains("slot=(140,100 700x500)"))
        XCTAssertTrue(dump.contains("op=panel_hidden"))
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
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected capture artifact")
        }

        let body = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(body.contains("== Native Fullscreen Placeholder Trace =="))
        XCTAssertTrue(body.contains("op=projection_accepted original=982002:982102"))
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
        let context = NativeFullscreenCardDisplayContext(
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
        XCTAssertNotNil(panel.cardFrame)
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
        let context = NativeFullscreenCardDisplayContext(
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
        let unknown = panelDiagnostics(skyLightCaptureExcluded: nil)
        let excluded = panelDiagnostics(skyLightCaptureExcluded: true)
        let included = panelDiagnostics(skyLightCaptureExcluded: false)

        XCTAssertTrue(unknown.captureSummary.contains("skyLightExcluded=unknown"))
        XCTAssertTrue(excluded.captureSummary.contains("skyLightExcluded=true"))
        XCTAssertTrue(included.captureSummary.contains("skyLightExcluded=false"))
    }

    func testPanelFrameSynchronizationAllowsOnePhysicalPixel() {
        let synchronized = panelDiagnostics(
            skyLightCaptureExcluded: nil,
            cardFrame: CGRect(x: 10, y: 10, width: 181.5, height: 64),
            windowFrame: CGRect(x: 10, y: 10, width: 182, height: 64)
        )
        let desynchronized = panelDiagnostics(
            skyLightCaptureExcluded: nil,
            cardFrame: CGRect(x: 10, y: 10, width: 181.5, height: 64),
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
        cardFrame: CGRect? = nil,
        windowFrame: CGRect = .zero
    ) -> NativeFullscreenPanelDiagnostics {
        NativeFullscreenPanelDiagnostics(
            originalToken: WindowToken(pid: 1, windowId: 2),
            currentToken: WindowToken(pid: 1, windowId: 2),
            workspaceId: WorkspaceDescriptor.ID(),
            slotFrame: .zero,
            displayContext: NativeFullscreenCardDisplayContext(workingFrame: .zero, scale: 2),
            cardFrame: cardFrame,
            windowFrame: windowFrame,
            cardMode: nil,
            descriptorVisible: false,
            appliedVisible: false,
            windowVisible: false,
            windowNumber: 3,
            level: 0,
            orderedIndex: 0,
            onActiveSpace: false,
            collectionBehavior: 0,
            registeredWindowNumber: 3,
            registryCaptureEligible: false,
            skyLightCaptureExcluded: skyLightCaptureExcluded,
            excludedWindowNumber: nil,
            captureRetryIndex: 0,
            captureRetryPending: false,
            captureRetryExhausted: false
        )
    }
}
