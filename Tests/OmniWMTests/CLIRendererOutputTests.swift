// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLIRendererOutputTests: XCTestCase {
    private func windowResponse(title: String) -> IPCResponse {
        IPCResponse.success(
            id: "1",
            kind: .query,
            result: IPCResult(
                windows: IPCWindowsQueryResult(
                    windows: [IPCWindowQuerySnapshot(id: "w-1", title: title)]
                )
            )
        )
    }

    func testTSVEscapesNewlineAndTabInWindowTitle() throws {
        let response = windowResponse(title: "Progress\tbar\r\nsecond")
        let output = try CLIRenderer.responseOutput(response, format: .tsv)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let body = text.trimmingCharacters(in: .newlines)
        let lines = body.components(separatedBy: "\n")

        // A single window must occupy exactly one data row beneath the header.
        XCTAssertEqual(lines.count, 2)

        let dataFields = lines[1].components(separatedBy: "\t")
        // The windows table has 10 columns; a tab inside the title must not add a column.
        XCTAssertEqual(dataFields.count, 10)
        XCTAssertFalse(dataFields.contains { $0.contains("\t") || $0.contains("\n") || $0.contains("\r") })
    }

    func testTableKeepsTitleOnSingleRow() throws {
        let response = windowResponse(title: "Progress\tbar\r\nsecond")
        let output = try CLIRenderer.responseOutput(response, format: .table)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let body = text.trimmingCharacters(in: .newlines)
        let lines = body.components(separatedBy: "\n")

        // Header, separator, and exactly one data row — a newline in the title must not split it.
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines.contains { $0.contains("\n") || $0.contains("\r") })
    }

    func testPlainTitleIsUnchanged() throws {
        let response = windowResponse(title: "Clean title")
        let output = try CLIRenderer.responseOutput(response, format: .tsv)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        XCTAssertTrue(text.contains("Clean title"))
    }
}
