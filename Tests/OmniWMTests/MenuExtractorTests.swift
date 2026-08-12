// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

private func menuAXErrorValue(_ error: AXError) -> AXValue? {
    var error = error
    return AXValueCreate(.axError, &error)
}

@MainActor
private final class MenuExtractorTarget: NSObject, NSMenuDelegate {
    @objc func activate(_: NSMenuItem) {}
}

@MainActor
final class MenuExtractorTests: XCTestCase {
    func testNestedMenuConstructionDisablesAutomaticEnabling() throws {
        let itemElement = AXUIElementCreateApplication(91_510)
        let submenuRoot = AXUIElementCreateApplication(91_511)
        let target = MenuExtractorTarget()
        let snapshot = MenuItemSnapshot(
            element: itemElement,
            attributes: [
                "AXTitle": "Nested",
                "AXRole": "AXMenuItem",
                "AXEnabled": false
            ],
            submenuRoot: submenuRoot
        )
        let extractor = MenuExtractor()

        let items = extractor.makeSubmenuItems(
            from: [snapshot],
            target: target,
            action: #selector(MenuExtractorTarget.activate(_:))
        )
        let submenu = try XCTUnwrap(items.first?.submenu)

        XCTAssertFalse(submenu.autoenablesItems)
        XCTAssertTrue(submenu.delegate === target)
        XCTAssertTrue(submenu.axRootElement.map { CFEqual($0, submenuRoot) } == true)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertNotEqual(items[0].action, #selector(MenuExtractorTarget.activate(_:)))
    }

    func testEmptyChildrenAndUnavailableChildrenAreDistinct() throws {
        let root = AXUIElementCreateApplication(91_520)
        let emptyExtractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [AXUIElement]() },
                readAttributes: { _, _, _ in
                    XCTFail("Empty children should not trigger item reads")
                    return []
                }
            )
        )

        let emptyItems = try emptyExtractor.buildSubmenu(from: root, target: nil, action: nil)
        XCTAssertTrue(emptyItems.isEmpty)

        let unavailableExtractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in throw MenuExtractionError.ax(.cannotComplete) },
                readAttributes: { _, _, _ in [] }
            )
        )

        XCTAssertThrowsError(
            try unavailableExtractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testSubmenuSnapshotAbortsWhenSecondItemReadFails() {
        let root = AXUIElementCreateApplication(91_530)
        let first = AXUIElementCreateApplication(91_531)
        let second = AXUIElementCreateApplication(91_532)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [first, second] },
                readAttributes: { element, attributes, _ in
                    if CFEqual(element, first) {
                        return self.attributeValues(
                            attributes,
                            values: [
                                "AXTitle": "First",
                                "AXRole": "AXMenuItem",
                                "AXEnabled": true
                            ]
                        )
                    }
                    throw MenuExtractionError.ax(.cannotComplete)
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testMissingEnabledEvidenceCreatesDisabledNonActionableItem() throws {
        let root = AXUIElementCreateApplication(91_540)
        let child = AXUIElementCreateApplication(91_541)
        let target = MenuExtractorTarget()
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: ["AXTitle": "Missing enabled", "AXRole": "AXMenuItem"]
                    )
                }
            )
        )

        let items = try extractor.buildSubmenu(
            from: root,
            target: target,
            action: #selector(MenuExtractorTarget.activate(_:))
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertNil(items[0].target)
        XCTAssertNil(items[0].action)
    }

    func testUnavailableNestedRoleDoesNotBecomeActionableLeaf() {
        let root = AXUIElementCreateApplication(91_550)
        let child = AXUIElementCreateApplication(91_551)
        let submenuRoot = AXUIElementCreateApplication(91_552)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { element, _, _ in
                    if CFEqual(element, root) { return [child] }
                    throw MenuExtractionError.ax(.cannotComplete)
                },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "Nested",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": true,
                            "AXChildren": [submenuRoot]
                        ]
                    )
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .ax(.cannotComplete))
        }
    }

    func testMissingRequiredRoleFailsSnapshot() {
        let root = AXUIElementCreateApplication(91_560)
        let child = AXUIElementCreateApplication(91_561)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(attributes, values: ["AXTitle": "Missing role"])
                }
            )
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .invalidResponse)
        }
    }

    func testEmptyTitledMenuItemBuildsSeparator() throws {
        let root = AXUIElementCreateApplication(91_562)
        let child = AXUIElementCreateApplication(91_563)
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { _, _, _ in [child] },
                readAttributes: { _, attributes, _ in
                    self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": false
                        ]
                    )
                }
            )
        )

        let items = try extractor.buildSubmenu(from: root, target: nil, action: nil)

        XCTAssertTrue(items.isEmpty)
    }

    func testDecoderOmitsNullNoValueAndUnsupportedSlots() throws {
        let decoded = try MenuExtractor.decodeAttributeValues(
            names: ["title", "null", "missing", "unsupported"],
            values: [
                "Visible",
                kCFNull as Any,
                try XCTUnwrap(menuAXErrorValue(.noValue)),
                try XCTUnwrap(menuAXErrorValue(.attributeUnsupported))
            ]
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded["title"] as? String, "Visible")
    }

    func testDecoderRejectsTransientAXErrors() throws {
        for axError in [AXError.cannotComplete, .invalidUIElement, .failure] {
            let value = try XCTUnwrap(menuAXErrorValue(axError))

            XCTAssertThrowsError(
                try MenuExtractor.decodeAttributeValues(names: ["value"], values: [value])
            ) { error in
                XCTAssertEqual(error as? MenuExtractionError, .ax(axError))
            }
        }
    }

    func testDecoderRejectsMismatchedValueCount() {
        XCTAssertThrowsError(
            try MenuExtractor.decodeAttributeValues(names: ["one", "two"], values: ["value"])
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .invalidResponse)
        }
    }

    func testSubmenuReadsReceiveOneShrinkingDeadlineBudget() throws {
        let root = AXUIElementCreateApplication(91_570)
        let child = AXUIElementCreateApplication(91_571)
        var now: TimeInterval = 10
        var timeouts: [Float] = []
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { now },
                readAttribute: { _, _, timeout in
                    timeouts.append(timeout)
                    now += 0.1
                    return [child]
                },
                readAttributes: { _, attributes, timeout in
                    timeouts.append(timeout)
                    now += 0.05
                    return self.attributeValues(
                        attributes,
                        values: [
                            "AXTitle": "Timed",
                            "AXRole": "AXMenuItem",
                            "AXEnabled": true
                        ]
                    )
                }
            ),
            submenuTimeout: 0.25
        )

        let items = try extractor.buildSubmenu(from: root, target: nil, action: nil)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertEqual(timeouts[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(timeouts[1], 0.15, accuracy: 0.001)
    }

    func testExpiredDeadlineSkipsNextAXRead() {
        let root = AXUIElementCreateApplication(91_580)
        let child = AXUIElementCreateApplication(91_581)
        var now: TimeInterval = 0
        var attributeReadCount = 0
        let extractor = MenuExtractor(
            environment: MenuExtractorEnvironment(
                now: { now },
                readAttribute: { _, _, _ in
                    now = 0.25
                    return [child]
                },
                readAttributes: { _, _, _ in
                    attributeReadCount += 1
                    return []
                }
            ),
            submenuTimeout: 0.25
        )

        XCTAssertThrowsError(
            try extractor.buildSubmenu(from: root, target: nil, action: nil)
        ) { error in
            XCTAssertEqual(error as? MenuExtractionError, .deadlineExceeded)
        }
        XCTAssertEqual(attributeReadCount, 0)
    }

    func testMessagingTimeoutResetsExactElementWhenOperationThrows() {
        enum ProbeError: Error {
            case expected
        }

        let element = AXUIElementCreateApplication(91_590)
        var elements: [AXUIElement] = []
        var timeouts: [Float] = []

        XCTAssertThrowsError(
            try MenuExtractor.withMessagingTimeout(
                on: element,
                timeout: 0.25,
                setter: { configuredElement, timeout in
                    elements.append(configuredElement)
                    timeouts.append(timeout)
                    return .success
                }
            ) {
                throw ProbeError.expected
            }
        )

        XCTAssertEqual(timeouts, [0.25, 0])
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements.allSatisfy { CFEqual($0, element) })
    }

    private func attributeValues(
        _ attributes: CFArray,
        values: [String: Any]
    ) -> [Any] {
        let names = attributes as! [String]
        return names.map { values[$0] ?? (kCFNull as Any) }
    }
}
