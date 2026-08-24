// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLIRendererOutputTests: XCTestCase {
    private func windowResponse(title: String) -> IPCResponse {
        windowResponse(titles: [title])
    }

    private func windowResponse(titles: [String], workspace: IPCWorkspaceRef? = nil) -> IPCResponse {
        return IPCResponse.success(
            id: "1",
            kind: .query,
            result: IPCResult(
                windows: IPCWindowsQueryResult(
                    windows: titles.enumerated().map { index, title in
                        IPCWindowQuerySnapshot(id: "w-\(index)", workspace: workspace, title: title)
                    }
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

        XCTAssertEqual(lines.count, 2)

        let dataFields = lines[1].components(separatedBy: "\t")
        XCTAssertEqual(dataFields.count, 10)
        XCTAssertEqual(dataFields[3], "Progress bar  second")
    }

    func testTableKeepsTitleOnSingleRow() throws {
        let response = windowResponse(title: "Progress\tbar\r\nsecond")
        let output = try CLIRenderer.responseOutput(response, format: .table)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let body = text.trimmingCharacters(in: .newlines)
        let lines = body.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(body.contains("\t"))
        XCTAssertFalse(body.contains("\r"))
        XCTAssertTrue(lines[2].contains("Progress bar  second"))
    }

    func testPlainTitleIsUnchanged() throws {
        let response = windowResponse(title: "Clean title")
        let output = try CLIRenderer.responseOutput(response, format: .tsv)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let dataRow = try XCTUnwrap(text.split(separator: "\n").last)
        let dataFields = dataRow.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(dataFields[3], "Clean title")
    }

    func testHumanReadableFormatsReplaceTerminalControls() throws {
        let title = "NUL\u{0}TAB\tLF\nCR\rESC\u{1B}DEL\u{7F}C1\u{80}NEL\u{85}CSI\u{9B}LS\u{2028}PS\u{2029}END"
        let expectedTitle = "NUL TAB LF CR ESC DEL C1 NEL CSI LS PS END"
        let response = windowResponse(title: title)

        let tsvOutput = try CLIRenderer.responseOutput(response, format: .tsv)
        let tsvText = try XCTUnwrap(String(data: tsvOutput.data, encoding: .utf8))
        let dataRow = try XCTUnwrap(tsvText.split(separator: "\n").last)
        let dataFields = dataRow.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(dataFields[3], Substring(expectedTitle))

        for format in [CLIOutputFormat.table, .text] {
            let output = try CLIRenderer.responseOutput(response, format: format)
            let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
            let dataRow = try XCTUnwrap(text.split(separator: "\n").last)
            XCTAssertTrue(dataRow.contains(expectedTitle))
        }
    }

    func testTSVPreservesUnicodeFormatScalars() throws {
        let title = "Résumé 👩‍💻"
        let response = windowResponse(title: title)
        let output = try CLIRenderer.responseOutput(response, format: .tsv)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let dataRow = try XCTUnwrap(text.split(separator: "\n").last)
        let dataFields = dataRow.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(dataFields[3], Substring(title))
    }

    func testJSONPreservesTerminalControls() throws {
        let response = windowResponse(title: "ESC\u{1B}CSI\u{9B}LS\u{2028}PS\u{2029}")
        let output = try CLIRenderer.responseOutput(response, format: .json)
        XCTAssertEqual(try IPCWire.decodeResponse(from: output.data), response)
    }

    func testDisplayFullscreenGapsColumnUsesTrueFalseAndIsOmittedWhenUnrequested() throws {
        let response = IPCResponse.success(
            id: "1",
            kind: .query,
            result: IPCResult(
                displays: IPCDisplaysQueryResult(
                    displays: [
                        IPCDisplayQuerySnapshot(id: "left", fullscreenUsesOuterGaps: true),
                        IPCDisplayQuerySnapshot(id: "right", fullscreenUsesOuterGaps: false)
                    ]
                )
            )
        )
        let output = try CLIRenderer.responseOutput(response, format: .tsv)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let lines = text.split(separator: "\n")
        let headers = try XCTUnwrap(lines.first).split(separator: "\t", omittingEmptySubsequences: false)
        let column = try XCTUnwrap(headers.firstIndex(of: "FULLSCREEN GAPS"))

        XCTAssertEqual(lines[1].split(separator: "\t", omittingEmptySubsequences: false)[column], "true")
        XCTAssertEqual(lines[2].split(separator: "\t", omittingEmptySubsequences: false)[column], "false")

        let omittedResponse = IPCResponse.success(
            id: "2",
            kind: .query,
            result: IPCResult(
                displays: IPCDisplaysQueryResult(
                    displays: [IPCDisplayQuerySnapshot(id: "left")]
                )
            )
        )
        let omittedOutput = try CLIRenderer.responseOutput(omittedResponse, format: .tsv)
        let omittedText = try XCTUnwrap(String(data: omittedOutput.data, encoding: .utf8))
        XCTAssertFalse(omittedText.contains("FULLSCREEN GAPS"))
    }

    func testTablePreservesAndAlignsUnicodeTitles() throws {
        let titles = [
            "abcdefgh",
            "abc🚀xyz",
            "界e\u{301}abcde",
            "👩🏽‍💻🇨🇦1️⃣ab"
        ]
        let workspace = IPCWorkspaceRef(id: "workspace", rawName: "next", displayName: "NEXT", number: nil)
        let response = windowResponse(titles: titles, workspace: workspace)
        let output = try CLIRenderer.responseOutput(response, format: .table)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
        let rows = text.split(separator: "\n").dropFirst(2)

        XCTAssertEqual(rows.count, titles.count)

        let markerColumns = try zip(rows, titles).map { row, title in
            XCTAssertTrue(row.contains(title))
            let marker = try XCTUnwrap(row.range(of: "NEXT"))
            return TerminalCellWidth.measure(row[..<marker.lowerBound])
        }

        XCTAssertEqual(Set(markerColumns).count, 1)
    }
}
