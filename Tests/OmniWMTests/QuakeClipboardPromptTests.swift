// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import GhosttyKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeClipboardPromptTests: XCTestCase {
    private final class AttachmentFlag {
        var value = true
    }

    func testCompletionResolvesOnceAndSecondResolutionIsNoOp() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let origin = NSObject()
        var completion: (@MainActor (Bool) -> Void)?
        var resolutions: [Bool] = []

        coordinator.request(
            origin: origin,
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: {},
            resolve: { resolutions.append($0) }
        )

        XCTAssertTrue(coordinator.hasActivePrompt)
        completion?(true)
        completion?(true)
        XCTAssertEqual(resolutions, [true])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testSecondRequestWhileActiveIsDeniedImmediately() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var firstCompletion: (@MainActor (Bool) -> Void)?
        var firstResolutions: [Bool] = []
        var secondPresented = false
        var secondResolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { firstCompletion = $0 },
            dismiss: {},
            resolve: { firstResolutions.append($0) }
        )
        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { _ in secondPresented = true },
            dismiss: {},
            resolve: { secondResolutions.append($0) }
        )

        XCTAssertFalse(secondPresented)
        XCTAssertEqual(secondResolutions, [false])
        XCTAssertEqual(firstResolutions, [])
        XCTAssertTrue(coordinator.hasActivePrompt)

        firstCompletion?(true)
        XCTAssertEqual(firstResolutions, [true])
        XCTAssertEqual(secondResolutions, [false])
    }

    func testCancelForOriginDismissesAndResolvesDenyExactlyOnce() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let origin = NSObject()
        var completion: (@MainActor (Bool) -> Void)?
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: origin,
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelPrompt(for: origin)

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)

        completion?(true)
        coordinator.cancelPrompt(for: origin)
        coordinator.cancelActivePrompt()
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
    }

    func testCancelForDifferentOriginKeepsPromptActive() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let promptOrigin = NSObject()
        let otherOrigin = NSObject()
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: promptOrigin,
            isOriginAttached: { true },
            present: { _ in },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelPrompt(for: otherOrigin)

        XCTAssertTrue(coordinator.hasActivePrompt)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(resolutions, [])
    }

    func testCancelActivePromptResolvesDenyExactlyOnce() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var completion: (@MainActor (Bool) -> Void)?
        var dismissCount = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { completion = $0 },
            dismiss: { dismissCount += 1 },
            resolve: { resolutions.append($0) }
        )
        coordinator.cancelActivePrompt()
        coordinator.cancelActivePrompt()
        completion?(true)

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testAllowAfterOriginDetachedResolvesDenyAndSkipsWrite() {
        let coordinator = QuakeClipboardPromptCoordinator()
        let originAttached = AttachmentFlag()
        var completion: (@MainActor (Bool) -> Void)?
        var appliedWrites = 0
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { originAttached.value },
            present: { completion = $0 },
            dismiss: {},
            resolve: { allowed in
                resolutions.append(allowed)
                if allowed {
                    appliedWrites += 1
                }
            }
        )
        originAttached.value = false
        completion?(true)

        XCTAssertEqual(resolutions, [false])
        XCTAssertEqual(appliedWrites, 0)
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testRequestWithDetachedOriginIsDeniedWithoutPresenting() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var presented = false
        var resolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { false },
            present: { _ in presented = true },
            dismiss: {},
            resolve: { resolutions.append($0) }
        )

        XCTAssertFalse(presented)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testNewRequestPresentsAfterPriorResolution() {
        let coordinator = QuakeClipboardPromptCoordinator()
        var firstCompletion: (@MainActor (Bool) -> Void)?
        var secondPresented = false
        var secondResolutions: [Bool] = []

        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { firstCompletion = $0 },
            dismiss: {},
            resolve: { _ in }
        )
        firstCompletion?(false)
        coordinator.request(
            origin: NSObject(),
            isOriginAttached: { true },
            present: { _ in secondPresented = true },
            dismiss: {},
            resolve: { secondResolutions.append($0) }
        )

        XCTAssertTrue(secondPresented)
        XCTAssertTrue(coordinator.hasActivePrompt)
        XCTAssertEqual(secondResolutions, [])
    }

    func testClipboardContentUsesExplicitLength() {
        let bytes: [UInt8] = [65, 0, 66]
        let content = bytes.withUnsafeBytes { buffer in
            "text/plain".withCString { mime in
                GhosttyClipboardContent(ghostty_clipboard_content_s(
                    mime: mime,
                    data: buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    len: buffer.count
                ))
            }
        }

        XCTAssertEqual(content?.mime, "text/plain")
        XCTAssertEqual(content?.data, Data(bytes))
        XCTAssertEqual(content?.string?.utf8.map(\.self), bytes)
    }

    func testClipboardPayloadPreviewPrefersTextAndSummarizesBinaryContent() {
        let text = GhosttyClipboardPayload(
            contents: [GhosttyClipboardContent(mime: "text/plain", data: Data("hello".utf8))],
            available: ["text/plain"]
        )
        let binary = GhosttyClipboardPayload(
            contents: [GhosttyClipboardContent(mime: "image/png", data: Data([0, 1, 2]))],
            available: ["image/png"]
        )

        XCTAssertEqual(text.preview, "hello")
        XCTAssertEqual(binary.preview, "image/png (3 bytes)")
    }

    func testClipboardPayloadPreservesInvalidUTF8AsBinaryContent() {
        let content = GhosttyClipboardContent(mime: "text/plain", data: Data([0xFF, 0xFE]))
        let payload = GhosttyClipboardPayload(contents: [content], available: ["text/plain"])

        XCTAssertNil(content.string)
        XCTAssertEqual(payload.preview, "text/plain (2 bytes)")
        XCTAssertEqual(payload.contents.first?.data, Data([0xFF, 0xFE]))
    }

    func testKittyClipboardRequestsUseReadAndWritePrompts() {
        XCTAssertEqual(
            QuakeTerminalController.ClipboardPromptKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ),
            .read
        )
        XCTAssertEqual(
            QuakeTerminalController.ClipboardPromptKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE),
            .write
        )
        XCTAssertNil(QuakeTerminalController.ClipboardPromptKind(GHOSTTY_CLIPBOARD_REQUEST_LIST))

        let read = QuakeTerminalController.protectedClipboardAlert(
            kind: .read,
            contents: "payload"
        )
        let write = QuakeTerminalController.protectedClipboardAlert(
            kind: .write,
            contents: "payload"
        )

        XCTAssertEqual(read.messageText, "Allow Clipboard Read?")
        XCTAssertEqual(write.messageText, "Allow Clipboard Write?")
    }

    func testClipboardPromptUsesProgramNameAndRememberOption() {
        let alert = QuakeTerminalController.protectedClipboardAlert(
            kind: .read,
            contents: "payload",
            programName: "remote-shell",
            canRemember: true
        )

        XCTAssertTrue(alert.informativeText.contains("\"remote-shell\""))
        XCTAssertEqual(
            (alert.accessoryView as? NSButton)?.title,
            "Remember this choice for the session"
        )
    }

    func testClipboardPromptDefaultsToDeny() {
        for kind in [QuakeTerminalController.ClipboardPromptKind.read, .write, .unsafePaste] {
            let alert = QuakeTerminalController.protectedClipboardAlert(kind: kind, contents: "payload")
            XCTAssertEqual(alert.buttons.first?.title, "Deny")
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons.last?.title, "Allow")
        }
    }

    func testClipboardPromptResponseMapsSecondButtonToAllow() {
        XCTAssertFalse(QuakeTerminalController.clipboardPromptResponseAllows(.alertFirstButtonReturn))
        XCTAssertTrue(QuakeTerminalController.clipboardPromptResponseAllows(.alertSecondButtonReturn))
        XCTAssertFalse(QuakeTerminalController.clipboardPromptResponseAllows(.cancel))
    }
}
