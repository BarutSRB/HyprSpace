// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import os
import XCTest

@MainActor
final class MainThreadAXSpanTraceTests: XCTestCase {
    func testSpansRecordOnlyOnTheMainThreadWhileACaptureIsActive() {
        let trace = MainThreadAXSpanTrace.shared
        var calls = 0

        let inactive = MainThreadAXSpanTrace.measure(.readFrame, pid: 7, windowId: 9) {
            calls += 1
            return 41
        }
        XCTAssertEqual(inactive, 41)
        XCTAssertEqual(trace.dump(), "none")

        trace.beginCapture()
        defer { trace.endCapture() }
        let onMain = MainThreadAXSpanTrace.measure(.readFrame, pid: 7, windowId: 9) {
            calls += 1
            return 42
        } succeeded: { $0 == 42 }
        let offMainResult = OSAllocatedUnfairLock(initialState: 0)
        let offMainDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let value = MainThreadAXSpanTrace.measure(.readSubrole, pid: 7, windowId: 9) { 43 }
            offMainResult.withLock { $0 = value }
            offMainDone.signal()
        }
        offMainDone.wait()
        let offMain = offMainResult.withLock { $0 }

        XCTAssertEqual(onMain, 42)
        XCTAssertEqual(offMain, 43)
        XCTAssertEqual(calls, 2)
        let dump = trace.dump()
        XCTAssertTrue(dump.contains("scope=main-thread-sync"))
        XCTAssertTrue(dump.contains("op=read-frame pid=7 win=9"))
        XCTAssertTrue(dump.contains("outcome=success"))
        XCTAssertFalse(dump.contains("read-subrole"))
    }

    func testThrowingSpanRecordsAFailureAndRethrows() {
        let trace = MainThreadAXSpanTrace.shared
        trace.beginCapture()
        defer { trace.endCapture() }

        XCTAssertThrowsError(
            try MainThreadAXSpanTrace.measure(.readFrame, windowId: 3) { () throws(AXErrorWrapper) -> CGRect in
                throw .cannotGetAttribute
            }
        )
        let failed = MainThreadAXSpanTrace
            .measure(.setNativeFullscreen, pid: 5, windowId: 6) { false } succeeded: { $0 }

        XCTAssertFalse(failed)
        let dump = trace.dump()
        XCTAssertTrue(dump.contains("op=read-frame pid=0 win=3"))
        XCTAssertTrue(dump.contains("op=set-native-fullscreen pid=5 win=6"))
        XCTAssertEqual(dump.components(separatedBy: "outcome=failure").count - 1, 2)
        XCTAssertFalse(dump.contains("outcome=success"))
    }
}
