// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class SkyLightNativeSpaceInventoryTests: XCTestCase {
    func testMergePreservesPerSpaceOrderAndDeduplicatesWindows() throws {
        let first = windowInfo(id: 101, tags: 0x1)
        let second = windowInfo(id: 102, tags: 0x2 | 0x8000_0000)

        let inventory = try XCTUnwrap(
            SkyLight.mergeNativeSpaceWindowInventory(
                windowIdsBySpace: [
                    11: [102, 101, 102],
                    12: [101]
                ],
                windowInfoById: [
                    101: first,
                    102: second
                ]
            )
        )

        XCTAssertEqual(inventory[11], [second, first])
        XCTAssertEqual(inventory[12], [first])
    }

    func testMergeKeepsAuthoritativeEmptySpacesAndRawMembership() throws {
        let parented = windowInfo(id: 201, level: 25, tags: 0, parentId: 99)
        let inventory = try XCTUnwrap(
            SkyLight.mergeNativeSpaceWindowInventory(
                windowIdsBySpace: [
                    21: [],
                    22: [201]
                ],
                windowInfoById: [201: parented]
            )
        )

        XCTAssertEqual(inventory[21], [])
        XCTAssertEqual(inventory[22], [parented])
        XCTAssertEqual(Set(inventory.keys), [21, 22])
    }

    func testMergeRejectsIncompleteBulkWindowDetails() {
        XCTAssertNil(
            SkyLight.mergeNativeSpaceWindowInventory(
                windowIdsBySpace: [31: [301, 302]],
                windowInfoById: [301: windowInfo(id: 301, tags: 0x1)]
            )
        )
    }

    func testSuitabilityRequiresTopLevelSupportedApplicationWindow() {
        XCTAssertTrue(SkyLight.isSuitableNativeSpaceWindow(windowInfo(id: 401, tags: 0x1)))
        XCTAssertTrue(
            SkyLight.isSuitableNativeSpaceWindow(
                windowInfo(id: 402, level: 3, tags: 0x2 | 0x8000_0000)
            )
        )
        XCTAssertFalse(
            SkyLight.isSuitableNativeSpaceWindow(
                windowInfo(id: 403, tags: 0x1, parentId: 99)
            )
        )
        XCTAssertFalse(
            SkyLight.isSuitableNativeSpaceWindow(
                windowInfo(id: 404, level: 25, tags: 0x1)
            )
        )
        XCTAssertTrue(SkyLight.isSuitableNativeSpaceWindow(windowInfo(id: 405, tags: 0x2)))
        XCTAssertFalse(SkyLight.isSuitableNativeSpaceWindow(windowInfo(id: 406, tags: 0)))
        XCTAssertFalse(
            SkyLight.isSuitableNativeSpaceWindow(
                WindowServerInfo(
                    id: 407,
                    pid: 0,
                    level: 0,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    tags: 0x1
                )
            )
        )
    }

    private func windowInfo(
        id: UInt32,
        level: Int32 = 0,
        tags: UInt64,
        parentId: UInt32 = 0
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: id,
            pid: Int32(id + 1_000),
            level: level,
            frame: CGRect(x: CGFloat(id), y: 40, width: 800, height: 600),
            tags: tags,
            attributes: 0,
            parentId: parentId
        )
    }
}
