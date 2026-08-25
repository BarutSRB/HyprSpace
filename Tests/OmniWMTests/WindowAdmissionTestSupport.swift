// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
enum WindowAdmissionTestSupport {
    static func controller(
        prefix: String = "OmniWMWindowAdmissionTests",
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(
            settings: settings,
            windowFocusOperations: windowFocusOperations
        )
    }

    static func workspace(
        named name: String,
        layoutType: LayoutType,
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: name, layoutType: layoutType)
        )
        controller.workspaceManager.applySettings()
        return controller.workspaceManager.workspaceId(for: name, createIfMissing: true)
    }

    static func drainLayoutRefreshes(_ controller: WMController) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard !Task.isCancelled else {
                XCTFail("layout refresh drain cancelled")
                return
            }
            let state = controller.layoutRefreshController.layoutState
            if state.activeRefreshTask == nil,
               state.activeRefresh == nil,
               state.pendingRefresh == nil
            {
                return
            }
            do {
                try await clock.sleep(for: .milliseconds(5))
            } catch {
                XCTFail("layout refresh drain cancelled")
                return
            }
        }
        XCTFail("layout refresh drain exceeded five seconds")
    }

    static func axRef(for token: WindowToken) -> AXWindowRef {
        AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
    }

    static func track(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> AXWindowRef {
        let axRef = axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        return axRef
    }

    static func frameRequest(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        window: AXWindowRef,
        frame: CGRect,
        isRetry: Bool = false
    ) -> AXFrameApplicationRequest? {
        ledger.prepareFrameApplication(
            pid: pid,
            windowId: window.windowId,
            expectedWindow: window,
            frame: frame,
            isRetry: isRetry,
            terminalObserver: nil
        ).request
    }

    static func frameResult(
        request: AXFrameApplicationRequest,
        observed: CGRect,
        failure: AXFrameWriteFailureReason,
        sizeError: AXError = .attributeUnsupported,
        positionError: AXError = .success
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: sizeError,
                positionError: positionError,
                failureReason: failure
            ),
            traceRequestId: request.traceRequestId
        )
    }

    static func verificationMismatchFrameResult(
        request: AXFrameApplicationRequest,
        observed: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        )
    }

    static func successfulFrameResult(request: AXFrameApplicationRequest) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: request.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }
}
