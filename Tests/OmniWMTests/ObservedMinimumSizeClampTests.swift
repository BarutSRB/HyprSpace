// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ObservedMinimumSizeClampTests: XCTestCase {
    func testStableClampGrowsOnlyRefusedAxesAndDoesNotInvalidateDuplicates() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setObservedMinSize(CGSize(width: 500, height: 620), for: fixture.token))
        var invalidatedWorkspaces: [WorkspaceDescriptor.ID?] = []
        manager.onRuntimeInvalidation = { workspaceId, domains, _ in
            if domains.contains(.layout) {
                invalidatedWorkspaces.append(workspaceId)
            }
        }
        let target = CGRect(x: 20, y: 30, width: 400, height: 300)
        let result = clampResult(
            fixture,
            target: target,
            observed: CGRect(x: 20, y: 30, width: 520, height: 300)
        )

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(result)

        XCTAssertEqual(manager.observedMinSize(for: fixture.token), CGSize(width: 520, height: 620))
        XCTAssertEqual(invalidatedWorkspaces, [fixture.workspaceId])
        let adoptedSeq = manager.worldSeq

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(result)
        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(
            clampResult(fixture, target: target, observed: CGRect(x: 20, y: 30, width: 510, height: 300))
        )

        XCTAssertEqual(manager.observedMinSize(for: fixture.token), CGSize(width: 520, height: 620))
        XCTAssertEqual(invalidatedWorkspaces, [fixture.workspaceId])
        XCTAssertEqual(manager.worldSeq, adoptedSeq)

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(
            clampResult(fixture, target: target, observed: CGRect(x: 20, y: target.maxY - 700, width: 400, height: 700))
        )

        XCTAssertEqual(manager.observedMinSize(for: fixture.token), CGSize(width: 520, height: 700))
        XCTAssertEqual(invalidatedWorkspaces, [fixture.workspaceId, fixture.workspaceId])
    }

    func testStableClampRejectsWrongProcessAndReplacedAXIdentity() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let target = CGRect(x: 20, y: 30, width: 400, height: 300)
        let observed = CGRect(x: 20, y: 30, width: 520, height: 300)
        let originalResult = clampResult(fixture, target: target, observed: observed)

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(
            clampResult(fixture, target: target, observed: observed, pid: fixture.token.pid + 1)
        )
        XCTAssertNil(manager.observedMinSize(for: fixture.token))

        XCTAssertNotNil(manager.removeWindow(pid: fixture.token.pid, windowId: fixture.token.windowId))
        let replacement = AXWindowRef(
            element: AXUIElementCreateApplication(fixture.token.pid + 1),
            windowId: fixture.token.windowId
        )
        let replacementToken = manager.addWindow(
            replacement,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            to: fixture.workspaceId
        )
        XCTAssertFalse(sameAXWindowIdentity(fixture.window, replacement))

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(originalResult)

        XCTAssertNil(manager.observedMinSize(for: replacementToken))
        XCTAssertTrue(sameAXWindowIdentity(try XCTUnwrap(manager.entry(for: replacementToken)).axRef, replacement))

        fixture.controller.adoptObservedMinimumAfterStableSizeClamp(
            clampResult(fixture, target: target, observed: observed, window: replacement)
        )
        XCTAssertEqual(manager.observedMinSize(for: replacementToken), CGSize(width: 520, height: 1))
    }

    func testStableClampDoesNotLearnFromFloatingFullscreenOrHiddenWindows() throws {
        for state in ["floating", "fullscreen", "parked", "app-hidden"] {
            let fixture = try makeFixture()
            let manager = fixture.controller.workspaceManager
            switch state {
            case "floating":
                XCTAssertTrue(manager.setWindowMode(.floating, for: fixture.token))
            case "fullscreen":
                manager.setLayoutReason(.nativeFullscreen, for: fixture.token)
            case "parked":
                manager.setHiddenState(
                    HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .layoutTransient(.left)),
                    for: fixture.token
                )
            default:
                manager.setAppHidden(true, pid: fixture.token.pid, source: .service)
            }
            let initialSeq = manager.worldSeq

            fixture.controller.adoptObservedMinimumAfterStableSizeClamp(
                clampResult(
                    fixture,
                    target: CGRect(x: 20, y: 30, width: 400, height: 300),
                    observed: CGRect(x: 20, y: 30, width: 520, height: 300)
                )
            )

            XCTAssertNil(manager.observedMinSize(for: fixture.token), state)
            XCTAssertEqual(manager.worldSeq, initialSeq, state)
        }
    }

    func testObservedMinimumSurvivesFrameInvalidationAndRepacksThreeColumns() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let monitor = Monitor(
            id: .init(displayId: 467_601),
            displayId: 467_601,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            hasNotch: false,
            name: "Clamp packing"
        )
        manager.applyMonitorConfigurationChange([monitor])
        controller.settings.animationsEnabled = false
        controller.settings.gapSize = 12
        manager.setGaps(to: 12)
        controller.settings.outerGapLeft = 0
        controller.settings.outerGapRight = 0
        controller.settings.outerGapTop = 0
        controller.settings.outerGapBottom = 0
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        engine.defaultContainerPrimarySpan = 1.0 / 3.0
        engine.visibleContainerCount = 3
        var tokens = [fixture.token]
        for index in 1 ... 2 {
            let token = WindowToken(pid: fixture.token.pid + pid_t(index), windowId: fixture.token.windowId + index)
            _ = WindowAdmissionTestSupport.track(token, in: fixture.workspaceId, controller: controller)
            tokens.append(token)
        }
        for token in tokens {
            manager.setCachedConstraints(.unconstrained, for: token)
        }
        let initialPlan = try XCTUnwrap(manager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId]).first
        })
        let target = try XCTUnwrap(initialPlan.diff.frameChanges.first { $0.token == fixture.token }?.frame)
        let accepted = CGRect(origin: target.origin, size: CGSize(width: target.width + 120, height: target.height))

        controller.adoptObservedMinimumAfterStableSizeClamp(clampResult(fixture, target: target, observed: accepted))
        controller.axManager.confirmFrameWrite(for: fixture.token.windowId, frame: accepted)
        controller.axManager.invalidateAppliedFrame(for: fixture.token.windowId)

        XCTAssertNil(controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
        XCTAssertEqual(manager.observedMinSize(for: fixture.token), CGSize(width: accepted.width, height: 1))
        let plan = try XCTUnwrap(manager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId]).first
        })
        let frames = Dictionary(uniqueKeysWithValues: plan.diff.frameChanges.map { ($0.token, $0.frame) })
        XCTAssertEqual(frames.count, 3)
        let first = try XCTUnwrap(frames[fixture.token])
        XCTAssertEqual(first.width, accepted.width, accuracy: 0.5)
        let orderedFrames = frames.values.sorted { $0.minX < $1.minX }
        XCTAssertGreaterThan(
            try XCTUnwrap(orderedFrames.last).maxX - XCTUnwrap(orderedFrames.first).minX,
            monitor.visibleFrame.width
        )
        for index in 1 ..< orderedFrames.count {
            XCTAssertEqual(orderedFrames[index].minX - orderedFrames[index - 1].maxX, 12, accuracy: 0.5)
        }
        XCTAssertEqual(
            try XCTUnwrap(engine.findNode(for: fixture.token, in: fixture.workspaceId)).constraints.minSize.width,
            accepted.width,
            accuracy: 0.5
        )

        controller.axManager.confirmFrameWrite(for: fixture.token.windowId, frame: first)

        XCTAssertEqual(
            controller.axManager.animationFrameComponents(
                for: fixture.token.windowId,
                targetFrame: first.offsetBy(dx: -100, dy: 0)
            ),
            .position
        )
    }

    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let window: AXWindowRef
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMObservedMinimumSizeClampTests")
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 467_591, windowId: 467_691)
        let window = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        return Fixture(controller: controller, workspaceId: workspaceId, token: token, window: window)
    }

    private func clampResult(
        _ fixture: Fixture,
        target: CGRect,
        observed: CGRect,
        pid: pid_t? = nil,
        window: AXWindowRef? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: 1,
            pid: pid ?? fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: window ?? fixture.window,
            targetFrame: target,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        )
    }
}
