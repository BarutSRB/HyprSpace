// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class SpaceTopologyTests: XCTestCase {
    private func twoDisplayTopology() -> SpaceTopology {
        SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1),
                SpaceTopology.DisplaySpaces(displayIdentifier: "secondary", spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [4],
            windowSpace: [:]
        )
    }

    func testIsCurrentSpaceMatchesEachDisplay() {
        let topology = twoDisplayTopology()
        XCTAssertTrue(topology.isCurrentSpace(1))
        XCTAssertTrue(topology.isCurrentSpace(3))
        XCTAssertFalse(topology.isCurrentSpace(2))
        XCTAssertFalse(topology.isCurrentSpace(4))
        XCTAssertFalse(topology.isCurrentSpace(999))
    }

    func testIsWindowOnKnownInactiveSpace() {
        var topology = twoDisplayTopology()
        topology.windowSpace = [10: 2, 11: 3, 12: 999]
        XCTAssertTrue(topology.isWindowOnKnownInactiveSpace(10))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(11))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(12))
        XCTAssertFalse(topology.isWindowOnKnownInactiveSpace(13))
    }

    func testIsDisplayShowingFullscreenSpace() {
        var topology = twoDisplayTopology()
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace("primary"), false)
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace("secondary"), false)
        XCTAssertNil(topology.isDisplayShowingFullscreenSpace("unknown"))

        topology.displays[1].currentSpaceId = 4
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace("secondary"), true)
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace("primary"), false)
    }

    func testIsDisplayShowingFullscreenSpaceCanonicalizesUUIDCase() {
        let lowercasedUUID = "123e4567-e89b-12d3-a456-426614174000"
        let topology = SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(
                    displayIdentifier: lowercasedUUID,
                    spaceIds: [5],
                    currentSpaceId: 5
                )
            ],
            activeSpaceId: 5,
            fullscreenSpaceIds: [5],
            windowSpace: [:]
        )

        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace(lowercasedUUID.uppercased()), true)
    }

    func testNormalizingDisplayIdentifiersResolvesMainAndNumericAliases() {
        let mainUUID = "11111111-1111-4111-8111-111111111111"
        let secondaryUUID = "22222222-2222-4222-8222-222222222222"
        let mainDisplayId = CGMainDisplayID()
        let secondaryDisplayId: CGDirectDisplayID = mainDisplayId == 42 ? 43 : 42
        let monitors = [
            makeMonitor(
                displayId: mainDisplayId,
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                displayUUID: mainUUID
            ),
            makeMonitor(
                displayId: secondaryDisplayId,
                frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
                displayUUID: secondaryUUID
            )
        ]
        let topology = SpaceTopology(
            displays: [
                .init(displayIdentifier: "Main", spaceIds: [1], currentSpaceId: 1),
                .init(
                    displayIdentifier: String(secondaryDisplayId),
                    spaceIds: [2],
                    currentSpaceId: 2
                )
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [2],
            windowSpace: [:]
        ).normalizingDisplayIdentifiers(using: monitors)

        XCTAssertEqual(topology.displays.map(\.displayIdentifier), [mainUUID, secondaryUUID])
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace(mainUUID), false)
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace(secondaryUUID), true)
    }

    func testNormalizingAmbiguousUUIDMonitorsUsesRuntimeIdentifiers() {
        let duplicateUUID = "33333333-3333-4333-8333-333333333333"
        let mainDisplayId = CGMainDisplayID()
        let secondaryDisplayId: CGDirectDisplayID = mainDisplayId == 52 ? 53 : 52
        let monitors = Monitor.discardingAmbiguousDisplayUUIDs(in: [
            makeMonitor(
                displayId: mainDisplayId,
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                displayUUID: duplicateUUID
            ),
            makeMonitor(
                displayId: secondaryDisplayId,
                frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
                displayUUID: duplicateUUID
            )
        ])
        XCTAssertTrue(monitors.allSatisfy { $0.displayUUID == nil })

        let topology = SpaceTopology(
            displays: [
                .init(displayIdentifier: "Main", spaceIds: [1], currentSpaceId: 1),
                .init(
                    displayIdentifier: String(secondaryDisplayId),
                    spaceIds: [2],
                    currentSpaceId: 2
                )
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [2],
            windowSpace: [:]
        ).normalizingDisplayIdentifiers(using: monitors)

        XCTAssertEqual(
            topology.displays.map(\.displayIdentifier),
            [String(mainDisplayId), String(secondaryDisplayId)]
        )
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace(on: monitors[0]), false)
        XCTAssertEqual(topology.isDisplayShowingFullscreenSpace(on: monitors[1]), true)
    }

    func testIsDisplayShowingFullscreenSpaceRejectsAmbiguousIdentifier() {
        let topology = SpaceTopology(
            displays: [
                .init(displayIdentifier: "duplicate", spaceIds: [1], currentSpaceId: 1),
                .init(displayIdentifier: "duplicate", spaceIds: [2], currentSpaceId: 2)
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [2],
            windowSpace: [:]
        )

        XCTAssertNil(topology.isDisplayShowingFullscreenSpace("duplicate"))
    }

    func testSelectWindowSpacePrefersCurrentNonFullscreen() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [4, 2, 3]), 3)
    }

    func testSelectWindowSpaceFallsBackToKnownNonFullscreen() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [4, 2]), 2)
    }

    func testSelectWindowSpaceFallsBackToCurrentFullscreen() {
        let topology = SpaceTopology(
            displays: [
                SpaceTopology.DisplaySpaces(displayIdentifier: "d", spaceIds: [5], currentSpaceId: 5)
            ],
            activeSpaceId: 5,
            fullscreenSpaceIds: [5],
            windowSpace: [:]
        )
        XCTAssertEqual(topology.selectWindowSpace(from: [5]), 5)
    }

    func testSelectWindowSpaceFallsBackToFirstNonzero() {
        let topology = twoDisplayTopology()
        XCTAssertEqual(topology.selectWindowSpace(from: [0, 777, 888]), 777)
    }

    func testSelectWindowSpaceReturnsNilForEmptyOrZero() {
        let topology = twoDisplayTopology()
        XCTAssertNil(topology.selectWindowSpace(from: []))
        XCTAssertNil(topology.selectWindowSpace(from: [0]))
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        frame: CGRect,
        displayUUID: String?
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: String(displayId),
            displayUUID: displayUUID
        )
    }
}
