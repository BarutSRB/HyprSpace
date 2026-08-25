// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class IntentLedgerRetryBudgetTests: XCTestCase {
    func testManagedFocusRetryBudgetDoesNotResetWhenActivationSourceChanges() throws {
        let ledger = IntentLedger()
        let request = ledger.beginManagedRequest(
            token: WindowToken(pid: 710_001, windowId: 710_002),
            workspaceId: UUID()
        )
        let sources: [ActivationEventSource] = [
            .focusedWindowChanged,
            .workspaceDidActivateApplication,
            .cgsFrontAppChanged,
            .focusedWindowChanged,
            .workspaceDidActivateApplication
        ]
        ledger.beginManagedFocusRetryRuntimeCapture()

        for (index, source) in sources.enumerated() {
            let retried = try XCTUnwrap(
                ledger.recordRetry(
                    requestId: request.requestId,
                    source: source,
                    retryLimit: 5
                )
            )
            XCTAssertEqual(retried.retryCount, index + 1)
        }
        XCTAssertNil(
            ledger.recordRetry(
                requestId: request.requestId,
                source: .cgsFrontAppChanged,
                retryLimit: 5
            )
        )
        ledger.endManagedFocusRetryRuntimeCapture()

        XCTAssertEqual(ledger.activeManagedRequest?.retryCount, 5)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().attempts, 6)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().sourceChanges, 5)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().deadlineRearms, 5)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().exhaustions, 1)
    }
}
