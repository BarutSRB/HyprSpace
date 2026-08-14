// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeFullscreenSlotProjectionTests: XCTestCase {
    func testDescriptorBeforeProjectionBecomesVisibleFromAcceptedSlot() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()

        let initial = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertEqual(initial.originalToken, fixture.token)
        XCTAssertFalse(initial.visible)

        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: frame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertEqual(applied.frame, frame)
        XCTAssertEqual(applied.displayContext, displayContext(for: fixture.monitor))
        XCTAssertTrue(applied.visible)
        let panel = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        XCTAssertEqual(panel.slotFrame, frame)
        XCTAssertEqual(panel.panelFrame, frame)
        XCTAssertEqual(panel.windowFrame, frame)
        XCTAssertTrue(panel.frameSynchronized)
    }

    func testUUIDLessMonitorUsesRuntimeDisplayIdentity() throws {
        let fixture = try makeFixture(displayUUID: nil)
        fixture.controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)

        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: frame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let visible = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertTrue(visible.visible)
        let visiblePanel = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        XCTAssertTrue(visiblePanel.descriptorVisible)
        XCTAssertTrue(visiblePanel.appliedVisible)
        let visibleLifecycle = try XCTUnwrap(
            fixture.controller.workspaceManager.nativeFullscreenLifecycleDiagnosticsSnapshot().records.first
        )
        XCTAssertNil(visibleLifecycle.displayUUID)
        XCTAssertEqual(visibleLifecycle.displayShowingFullscreen, false)

        fixture.controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: String(fixture.monitor.displayId),
                        spaceIds: [1],
                        currentSpaceId: 1
                    )
                ],
                activeSpaceId: 1,
                fullscreenSpaceIds: [1],
                windowSpace: [:]
            )
        )
        fixture.controller.surfaceReconciler.reconcileNow()

        let hidden = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertFalse(hidden.visible)
        let hiddenLifecycle = try XCTUnwrap(
            fixture.controller.workspaceManager.nativeFullscreenLifecycleDiagnosticsSnapshot().records.first
        )
        XCTAssertEqual(hiddenLifecycle.displayShowingFullscreen, true)
    }

    func testMissingProjectionReasonMatchesHiddenAppliedState() throws {
        let fixture = try makeFixture()

        fixture.controller.surfaceReconciler.reconcileNow()

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        let resolution = try XCTUnwrap(
            fixture.controller.surfaceReconciler.nativeFullscreenDiagnosticsSnapshot().resolutions.first
        )
        XCTAssertFalse(applied.visible)
        XCTAssertEqual(resolution.originalToken, fixture.token)
        XCTAssertEqual(resolution.reason, .projectionMissingHidden)
    }

    func testHiddenSlotReasonMatchesHiddenAppliedState() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)

        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: frame,
                    visible: false
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        let resolution = try XCTUnwrap(
            fixture.controller.surfaceReconciler.nativeFullscreenDiagnosticsSnapshot().resolutions.first
        )
        XCTAssertEqual(applied.frame, frame)
        XCTAssertFalse(applied.visible)
        XCTAssertEqual(resolution.reason, .slotHidden)
    }

    func testProjectionBeforeDescriptorIsAppliedOnFullReconcile() throws {
        let fixture = try makeFixture(suspend: false)
        let frame = CGRect(x: 220, y: 180, width: 540, height: 380)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: frame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        XCTAssertTrue(
            fixture.controller.workspaceManager.requestNativeFullscreenEnter(
                fixture.token,
                in: fixture.workspaceId
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.markNativeFullscreenSuspended(
                fixture.token,
                ownsNonManagedFocus: false
            )
        )
        fixture.controller.surfaceReconciler.reconcileNow()

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertEqual(applied.frame, frame)
        XCTAssertEqual(applied.displayContext, displayContext(for: fixture.monitor))
        XCTAssertTrue(applied.visible)
    }

    func testExplicitSlotOmissionHidesRetainedPanel() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: frame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [:],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertEqual(applied.frame, frame)
        XCTAssertFalse(applied.visible)
        let panel = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        XCTAssertEqual(panel.slotFrame, frame)
        XCTAssertFalse(panel.descriptorVisible)
        XCTAssertFalse(panel.appliedVisible)
        XCTAssertFalse(panel.windowVisible)
    }

    func testProjectionBeforeRekeyDescriptorKeepsPanelAndUsesLiveProjection() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let initialFrame = CGRect(x: 120, y: 80, width: 640, height: 480)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: initialFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )
        let initialPanelIdentity = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.panelIdentity(for: fixture.token)
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
        let replacementRecord = try XCTUnwrap(
            fixture.controller.workspaceManager.nativeFullscreenRecord(originalToken: fixture.token)
        )
        XCTAssertEqual(replacementRecord.originalToken, fixture.token)
        XCTAssertEqual(replacementRecord.currentToken, replacement)
        XCTAssertEqual(replacementRecord.transition, .suspended)
        XCTAssertEqual(fixture.controller.workspaceManager.layoutReason(for: replacement), .nativeFullscreen)
        let replacementFrame = CGRect(x: 220, y: 180, width: 540, height: 380)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: replacement,
                    frame: replacementFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let appliedBeforeDescriptor = try XCTUnwrap(
            fixture.controller.surfaceReconciler.appliedScene.placeholders.first
        )
        let replacementPanelIdentity = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.panelIdentity(for: fixture.token)
        )
        XCTAssertEqual(appliedBeforeDescriptor.currentToken, replacement)
        XCTAssertEqual(appliedBeforeDescriptor.frame, replacementFrame)
        XCTAssertTrue(appliedBeforeDescriptor.visible)
        XCTAssertEqual(initialPanelIdentity, replacementPanelIdentity)
        let panelBeforeDescriptor = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        XCTAssertEqual(panelBeforeDescriptor.originalToken, fixture.token)
        XCTAssertEqual(panelBeforeDescriptor.currentToken, replacement)
        XCTAssertEqual(panelBeforeDescriptor.workspaceId, fixture.workspaceId)
        XCTAssertEqual(panelBeforeDescriptor.slotFrame, replacementFrame)
        XCTAssertTrue(panelBeforeDescriptor.descriptorVisible)

        fixture.controller.surfaceReconciler.reconcileNow()
        let appliedAfterDescriptor = try XCTUnwrap(
            fixture.controller.surfaceReconciler.appliedScene.placeholders.first
        )
        XCTAssertEqual(appliedAfterDescriptor.currentToken, replacement)
        XCTAssertEqual(appliedAfterDescriptor.frame, replacementFrame)
        XCTAssertTrue(appliedAfterDescriptor.visible)
    }

    func testProjectionSynchronizesSelectionChangeBeforeFullReconcile() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        let projection = [
            fixture.token: NativeFullscreenSlotProjection(
                currentToken: fixture.token,
                frame: frame,
                visible: true
            )
        ]
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            projection,
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let initialPanel = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        let initialWindow = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleWindows(kind: .nativeFullscreenPlaceholder)
                .first { $0.windowNumber == initialPanel.windowNumber }
        )
        XCTAssertEqual((initialWindow.contentView?.accessibilityValue() as? NSNumber)?.boolValue, false)

        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                fixture.token,
                in: fixture.workspaceId,
                onMonitor: fixture.monitor.id
            )
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            projection,
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        let selectedPanel = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot().first
        )
        let selectedWindow = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleWindows(kind: .nativeFullscreenPlaceholder)
                .first { $0.windowNumber == selectedPanel.windowNumber }
        )
        XCTAssertTrue(applied.selected)
        XCTAssertEqual(selectedPanel.currentToken, fixture.token)
        XCTAssertEqual(selectedPanel.workspaceId, fixture.workspaceId)
        XCTAssertEqual(selectedPanel.slotFrame, frame)
        XCTAssertTrue(selectedPanel.descriptorVisible)
        XCTAssertEqual((selectedWindow.contentView?.accessibilityValue() as? NSNumber)?.boolValue, true)
    }

    func testRekeyDescriptorBeforeProjectionRetainsPriorGeometryWithoutUsingStaleToken() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let initialFrame = CGRect(x: 120, y: 80, width: 640, height: 480)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: initialFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )
        let initialPanelIdentity = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.panelIdentity(for: fixture.token)
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
        let replacementRecord = try XCTUnwrap(
            fixture.controller.workspaceManager.nativeFullscreenRecord(originalToken: fixture.token)
        )
        XCTAssertEqual(replacementRecord.originalToken, fixture.token)
        XCTAssertEqual(replacementRecord.currentToken, replacement)
        XCTAssertEqual(replacementRecord.transition, .suspended)
        XCTAssertEqual(fixture.controller.workspaceManager.layoutReason(for: replacement), .nativeFullscreen)
        fixture.controller.surfaceReconciler.reconcileNow()

        let appliedBeforeProjection = try XCTUnwrap(
            fixture.controller.surfaceReconciler.appliedScene.placeholders.first
        )
        let retainedPanelIdentity = try XCTUnwrap(
            fixture.controller.nativeFullscreenPlaceholderManager.panelIdentity(for: fixture.token)
        )
        XCTAssertEqual(appliedBeforeProjection.currentToken, replacement)
        XCTAssertEqual(appliedBeforeProjection.frame, initialFrame)
        XCTAssertTrue(appliedBeforeProjection.visible)
        XCTAssertEqual(initialPanelIdentity, retainedPanelIdentity)

        let replacementFrame = CGRect(x: 220, y: 180, width: 540, height: 380)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: replacement,
                    frame: replacementFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        let appliedAfterProjection = try XCTUnwrap(
            fixture.controller.surfaceReconciler.appliedScene.placeholders.first
        )
        XCTAssertEqual(appliedAfterProjection.currentToken, replacement)
        XCTAssertEqual(appliedAfterProjection.frame, replacementFrame)
        XCTAssertTrue(appliedAfterProjection.visible)
    }

    func testFrameAndDisplayContextChangeReachPanelTogether() throws {
        let fixture = try makeFixture()
        fixture.controller.surfaceReconciler.reconcileNow()
        let oldFrame = CGRect(x: -300, y: 100, width: 800, height: 400)
        let oldContext = NativeFullscreenDisplayContext(
            workingFrame: CGRect(x: -500, y: 0, width: 1_500, height: 900),
            scale: 1
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: oldFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: oldContext
        )

        let nextFrame = CGRect(x: -280, y: 120, width: 800, height: 400)
        let nextContext = NativeFullscreenDisplayContext(
            workingFrame: CGRect(x: 0, y: 0, width: 1_000, height: 900),
            scale: 2
        )
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: nextFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: nextContext
        )

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        let surfaceId = "native-fullscreen-placeholder-\(fixture.token.pid)-\(fixture.token.windowId)"
        let panelFrame = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceId }?.frame
        )
        XCTAssertEqual(applied.frame, nextFrame)
        XCTAssertEqual(applied.displayContext, nextContext)
        XCTAssertEqual(panelFrame, nextFrame)
    }

    func testProjectionForNonexistentWorkspaceIsDiscarded() throws {
        let fixture = try makeFixture()
        let missingWorkspaceId = WorkspaceDescriptor.ID()
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [:],
            workspaceId: missingWorkspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        XCTAssertFalse(
            fixture.controller.surfaceReconciler.nativeFullscreenProjectedWorkspaceIds.contains(missingWorkspaceId)
        )
    }

    func testStoppedServiceProjectionIsDiscarded() throws {
        let fixture = try makeFixture()
        let previousFrame = CGRect(x: 120, y: 80, width: 640, height: 480)
        let rejectedFrame = CGRect(x: 320, y: 280, width: 440, height: 280)
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: previousFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )
        fixture.controller.hasStartedServices = false
        fixture.controller.surfaceReconciler.applyAcceptedNativeFullscreenSlots(
            [
                fixture.token: NativeFullscreenSlotProjection(
                    currentToken: fixture.token,
                    frame: rejectedFrame,
                    visible: true
                )
            ],
            workspaceId: fixture.workspaceId,
            displayId: fixture.monitor.displayId,
            displayContext: displayContext(for: fixture.monitor)
        )

        fixture.controller.hasStartedServices = true
        fixture.controller.surfaceReconciler.reconcileNow()

        let applied = try XCTUnwrap(fixture.controller.surfaceReconciler.appliedScene.placeholders.first)
        XCTAssertNotEqual(applied.frame, previousFrame)
        XCTAssertNotEqual(applied.frame, rejectedFrame)
        XCTAssertFalse(applied.visible)
    }

    private func makeFixture(
        suspend: Bool = true,
        displayUUID: String? = "98101981-0198-4198-8198-101981019810",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        token: WindowToken
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNativeFullscreenSlotProjectionTests-\(UUID().uuidString)", isDirectory: true)
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
            id: .init(displayId: 98_101),
            displayId: 98_101,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Native Fullscreen Projection",
            displayUUID: displayUUID
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: monitor.displayUUID ?? String(monitor.displayId),
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
            AXWindowRef(element: AXUIElementCreateApplication(981_001), windowId: 981_101),
            pid: 981_001,
            windowId: 981_101,
            to: workspaceId
        )
        if suspend {
            XCTAssertTrue(
                controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId),
                file: file,
                line: line
            )
            XCTAssertTrue(
                controller.workspaceManager.markNativeFullscreenSuspended(
                    token,
                    ownsNonManagedFocus: false
                ),
                file: file,
                line: line
            )
        }
        return (controller, workspaceId, monitor, token)
    }

    private func displayContext(for monitor: Monitor) -> NativeFullscreenDisplayContext {
        NativeFullscreenDisplayContext(workingFrame: monitor.visibleFrame, scale: 1)
    }
}
