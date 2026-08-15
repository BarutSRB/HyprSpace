// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class OverviewNavigationTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)

    func testNiriHorizontalNavigationUsesVisualRowsAcrossStackedColumns() {
        let heightCases: [[[CGFloat]]] = [
            [[100, 100], [100, 100]],
            [[50, 300], [50, 300]]
        ]

        for columnHeights in heightCases {
            let fixture = makeNiriFixture(columnHeights: columnHeights)
            XCTAssertEqual(
                fixture.layout.niriColumnsByWorkspace[fixture.workspaceId]?.map(\.windowHandles),
                fixture.groups
            )

            for tileIndex in 0 ..< 2 {
                assertHorizontalPair(
                    fixture.groups[0][tileIndex],
                    fixture.groups[1][tileIndex],
                    in: fixture.layout,
                    message: "column heights \(columnHeights)"
                )
            }
        }
    }

    func testNiriHorizontalNavigationDoesNotMoveWithinOneVisibleColumn() {
        let fixture = makeNiriFixture(
            columnHeights: [[100, 100], [100, 100]],
            searchQuery: "Left"
        )

        for handle in fixture.groups[0] {
            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(
                    in: fixture.layout,
                    from: handle,
                    direction: .left
                ),
                handle
            )
            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(
                    in: fixture.layout,
                    from: handle,
                    direction: .right
                ),
                handle
            )
        }
    }

    func testNiriHorizontalNavigationPrefersGreatestVerticalOverlap() {
        let fixture = makeNiriFixture(columnHeights: [[100], [180, 20]])
        let current = fixture.groups[0][0]
        let greatestOverlap = fixture.groups[1][0]

        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(
                in: fixture.layout,
                from: current,
                direction: .right
            ),
            greatestOverlap
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(
                in: fixture.layout,
                from: current,
                direction: .left
            ),
            greatestOverlap
        )
    }

    func testGenericHorizontalNavigationUsesVisualRowsAcrossStackedGeometry() {
        let frameCases: [[[CGRect]]] = [
            [
                [
                    CGRect(x: 0, y: 500, width: 400, height: 100),
                    CGRect(x: 500, y: 500, width: 400, height: 100)
                ],
                [
                    CGRect(x: 0, y: 0, width: 400, height: 100),
                    CGRect(x: 500, y: 0, width: 400, height: 100)
                ]
            ],
            [
                [
                    CGRect(x: 0, y: 500, width: 400, height: 50),
                    CGRect(x: 500, y: 500, width: 400, height: 50)
                ],
                [
                    CGRect(x: 0, y: 0, width: 400, height: 300),
                    CGRect(x: 500, y: 0, width: 400, height: 300)
                ]
            ]
        ]

        for rowFrames in frameCases {
            let fixture = makeGenericFixture(rowFrames: rowFrames)
            for row in fixture.groups {
                assertHorizontalPair(
                    row[0],
                    row[1],
                    in: fixture.layout,
                    message: "row frames \(rowFrames)"
                )
            }
        }
    }

    func testHorizontalNavigationIgnoresSubpixelVerticalOverlap() {
        let fixture = makeGenericFixture(rowFrames: [
            [CGRect(x: 0, y: 0, width: 400, height: 100)],
            [CGRect(x: 500, y: 99.9, width: 400, height: 100)]
        ])
        let current = fixture.groups[0][0]

        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(
                in: fixture.layout,
                from: current,
                direction: .right
            ),
            current
        )
    }

    private func assertHorizontalPair(
        _ left: WindowHandle,
        _ right: WindowHandle,
        in layout: OverviewLayout,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: left, direction: .right),
            right,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: right, direction: .left),
            left,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: left, direction: .left),
            right,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: right, direction: .right),
            left,
            message,
            file: file,
            line: line
        )
    }

    private func makeNiriFixture(
        columnHeights: [[CGFloat]],
        searchQuery: String = ""
    ) -> NavigationFixture {
        let descriptor = WorkspaceDescriptor(name: "Niri Navigation")
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var handlesByColumn: [[WindowHandle]] = []
        var snapshotColumns: [NiriOverviewColumnSnapshot] = []

        for (columnIndex, heights) in columnHeights.enumerated() {
            var handles: [WindowHandle] = []
            var tiles: [NiriOverviewTileSnapshot] = []
            for (tileIndex, height) in heights.enumerated() {
                let ordinal = columnIndex * 100 + tileIndex + 1
                let token = WindowToken(pid: pid_t(80_000 + ordinal), windowId: 80_000 + ordinal)
                let handle = WindowHandle(id: token)
                let columnName = columnIndex == 0 ? "Left" : "Right"
                let tileName = tileIndex == 0 ? "Top" : "Bottom"
                windows[handle] = (
                    token: token,
                    workspaceId: descriptor.id,
                    title: "\(columnName) \(tileName)",
                    appName: "Navigation",
                    appIcon: nil,
                    frame: CGRect(x: CGFloat(columnIndex) * 500, y: 0, width: 400, height: height)
                )
                handles.append(handle)
                tiles.append(NiriOverviewTileSnapshot(token: token, preferredHeight: height))
            }
            handlesByColumn.append(handles)
            snapshotColumns.append(
                NiriOverviewColumnSnapshot(
                    index: columnIndex,
                    widthWeight: 1,
                    preferredWidth: nil,
                    tiles: tiles
                )
            )
        }

        let snapshot = NiriOverviewWorkspaceSnapshot(
            workspaceId: descriptor.id,
            columns: snapshotColumns
        )
        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: [(id: descriptor.id, name: descriptor.name, isActive: true)],
            windows: windows,
            niriSnapshotsByWorkspace: [descriptor.id: snapshot],
            screenFrame: screenFrame,
            searchQuery: searchQuery,
            scale: 1
        )
        return NavigationFixture(
            workspaceId: descriptor.id,
            layout: layout,
            groups: handlesByColumn
        )
    }

    private func makeGenericFixture(rowFrames: [[CGRect]]) -> NavigationFixture {
        let descriptor = WorkspaceDescriptor(name: "Generic Navigation")
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var handlesByRow: [[WindowHandle]] = []

        for (rowIndex, frames) in rowFrames.enumerated() {
            var handles: [WindowHandle] = []
            for (columnIndex, frame) in frames.enumerated() {
                let ordinal = rowIndex * 100 + columnIndex + 1
                let token = WindowToken(pid: pid_t(90_000 + ordinal), windowId: 90_000 + ordinal)
                let handle = WindowHandle(id: token)
                windows[handle] = (
                    token: token,
                    workspaceId: descriptor.id,
                    title: "Row \(rowIndex) Column \(columnIndex)",
                    appName: "Navigation",
                    appIcon: nil,
                    frame: frame
                )
                handles.append(handle)
            }
            handlesByRow.append(handles)
        }

        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: [(id: descriptor.id, name: descriptor.name, isActive: true)],
            windows: windows,
            screenFrame: screenFrame,
            searchQuery: "",
            scale: 1
        )
        return NavigationFixture(
            workspaceId: descriptor.id,
            layout: layout,
            groups: handlesByRow
        )
    }

    private struct NavigationFixture {
        let workspaceId: WorkspaceDescriptor.ID
        let layout: OverviewLayout
        let groups: [[WindowHandle]]
    }
}
