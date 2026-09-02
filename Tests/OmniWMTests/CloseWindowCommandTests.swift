// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CloseWindowCommandTests: XCTestCase {
    func testCloseFocusedWindowSpecRegistered() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .closeFocusedWindow))

        XCTAssertEqual(spec.id, "closeFocusedWindow")
        XCTAssertEqual(spec.title, "Close Focused Window")
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.ipcCommandName, .closeFocusedWindow)
        XCTAssertNotNil(spec.ipcDescriptor)
        XCTAssertEqual(HotkeyBindingRegistry.command(for: "closeFocusedWindow"), .closeFocusedWindow)
    }

    func testCloseFocusedWindowJSONRoundTripAndManifestResolves() throws {
        XCTAssertEqual(IPCCommandRequest.closeFocusedWindow.name, .closeFocusedWindow)
        let data = try JSONEncoder().encode(IPCCommandRequest.closeFocusedWindow)
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), .closeFocusedWindow)

        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["close-focused-window"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .closeFocusedWindow })
        XCTAssertEqual(descriptor.commandWords, ["close-focused-window"])
        XCTAssertEqual(try IPCCommandRequest(name: descriptor.name, argumentValues: []), .closeFocusedWindow)
    }

    func testParserBuildsWindowCloseRequest() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "window", "close", "ow_x"])
        guard case let .window(request) = parsed.request.payload else {
            return XCTFail("expected a window payload")
        }
        XCTAssertEqual(request, IPCWindowRequest(name: .close, windowId: "ow_x"))
        XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "window", "close"]))
        XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "window", "close", "ow_x", "extra"]))
    }

    func testHelpAndCompletionsExposeWindowClose() {
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl window close <opaque-id>"))
        XCTAssertTrue(CLIParser.usageText.contains("close-focused-window"))
        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            XCTAssertTrue(script.contains("close"))
            XCTAssertTrue(script.contains("close-focused-window"))
        }
    }

    func testWindowActionFailedMapsToErrorAndRejectedExitCode() {
        let response = IPCApplicationBridge.response(for: .windowActionFailed, id: "close", kind: .window)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.code, .windowActionFailed)
        XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
    }

    @MainActor
    func testRouterRejectsMalformedStaleAndUnknownWindowIds() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "CloseWindowCommandTests")
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(IPCWindowRequest(name: .close, windowId: "nope")), .invalidArguments)
        XCTAssertEqual(
            router.handle(IPCWindowRequest(
                name: .close,
                windowId: IPCWindowOpaqueID.encode(pid: 492_001, windowId: 1, sessionToken: "other")
            )),
            .staleWindowId
        )
        XCTAssertEqual(
            router.handle(IPCWindowRequest(
                name: .close,
                windowId: IPCWindowOpaqueID.encode(pid: 492_001, windowId: 1, sessionToken: "test")
            )),
            .notFound
        )
        XCTAssertEqual(controller.closeFocusedWindow(), .notFound)
    }

    @MainActor
    func testWindowCloseReportsWindowActionFailedAndRetainsEntry() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "CloseWindowCommandTests")
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Close"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = WindowToken(pid: 492_002, windowId: 492_102)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        let result = router.handle(IPCWindowRequest(
            name: .close,
            windowId: IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: "test")
        ))

        XCTAssertEqual(result, .windowActionFailed)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }
}
