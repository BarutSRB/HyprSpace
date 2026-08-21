// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

final class BorderSurfaceTests: XCTestCase {
    @MainActor
    private final class BorderOperationsRecorder {
        var createdWindowCount = 0
        var screencaptureExclusionCount = 0
        var releasedCount = 0
        var releasedWindowIds: [UInt32] = []
        var shapeCount = 0
        var flushCount = 0
        var moveCount = 0
        var moveAndOrderCount = 0
        var hideCount = 0
        var transactionScopeCount = 0
        var nextWindowId: UInt32 = 1001
        var createdWindowIds: [UInt32] = []
        var backingScale: CGFloat = 2
        var screenFrame = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        var contextProvider: @MainActor () -> CGContext? = { BorderOperationsRecorder.makeContext() }

        var orderingCount: Int {
            moveCount + moveAndOrderCount
        }

        func operations() -> BorderWindow.Operations {
            BorderWindow.Operations(
                createBorderWindow: { [weak self] _ in
                    guard let self else { return 0 }
                    createdWindowCount += 1
                    let windowId = nextWindowId
                    if windowId != 0 {
                        createdWindowIds.append(windowId)
                        nextWindowId += 1
                    }
                    return windowId
                },
                releaseBorderWindow: { [weak self] windowId in
                    self?.releasedCount += 1
                    self?.releasedWindowIds.append(windowId)
                },
                configureWindow: { _, _, _ in },
                setWindowTags: { _, _ in },
                excludeFromScreencaptureSelection: { [weak self] _ in self?.screencaptureExclusionCount += 1 },
                createWindowContext: { [weak self] _ in self?.contextProvider() },
                setWindowShape: { [weak self] _, _ in self?.shapeCount += 1 },
                flushWindow: { [weak self] _ in self?.flushCount += 1 },
                transactionMove: { [weak self] _, _ in self?.moveCount += 1 },
                transactionMoveAndOrder: { [weak self] _, _, _, _, _ in self?.moveAndOrderCount += 1 },
                transactionHide: { [weak self] _ in self?.hideCount += 1 },
                withTransactionScope: { [weak self] body in
                    self?.transactionScopeCount += 1
                    body()
                },
                backingScaleForFrame: { [weak self] _ in
                    guard let self else { return (2, .null) }
                    return (backingScale, screenFrame)
                }
            )
        }

        static func makeContext() -> CGContext? {
            CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
    }

    @MainActor
    private func makeApplier(
        _ recorder: BorderOperationsRecorder,
        cornerSampleProvider: @escaping @MainActor (Int) -> WindowCornerSample? = { _ in nil }
    ) -> BorderSurfaceApplier {
        BorderSurfaceApplier(
            borderWindowOperations: recorder.operations(),
            cornerSampleProvider: cornerSampleProvider
        )
    }

    private let frame = CGRect(x: 10, y: 10, width: 200, height: 150)
    private let configRed = BorderConfig(enabled: true, width: 4, color: .systemRed)
    private let configBlue = BorderConfig(enabled: true, width: 4, color: .systemBlue)

    private func token(windowId: Int = 77, pid: pid_t = 1234) -> WindowToken {
        WindowToken(pid: pid, windowId: windowId)
    }

    private func desired(
        _ config: BorderConfig,
        token: WindowToken? = nil,
        frame: CGRect? = nil
    ) -> DesiredBorderSurface {
        DesiredBorderSurface(token: token ?? self.token(), frame: frame ?? self.frame, config: config)
    }

    private func sample(
        _ radii: WindowCornerRadii,
        size: CGSize? = nil,
        source: WindowCornerSource = .resolved
    ) -> WindowCornerSample {
        WindowCornerSample(radii: radii, observedSize: size ?? frame.size, source: source)
    }

    @MainActor
    func testApplyCreatesAndRegistersBorder() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let applied = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(applied.didApply)
        XCTAssertEqual(recorder.createdWindowCount, BorderWindow.SegmentKind.allCases.count)
        XCTAssertTrue(recorder.createdWindowIds.allSatisfy {
            SurfaceCoordinator.shared.contains(windowNumber: Int($0))
        })
    }

    @MainActor
    func testApplyNilHidesAndUnregisters() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let windowIds = recorder.createdWindowIds
        let hidden = applier.apply(nil, forceOrdering: false)

        XCTAssertTrue(hidden.didApply)
        XCTAssertEqual(recorder.hideCount, BorderWindow.SegmentKind.allCases.count)
        XCTAssertTrue(windowIds.allSatisfy {
            !SurfaceCoordinator.shared.contains(windowNumber: Int($0))
        })
    }

    @MainActor
    func testBorderWindowOptsOutOfScreencaptureSelectionOncePerWindow() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertEqual(recorder.screencaptureExclusionCount, BorderWindow.SegmentKind.allCases.count)

        _ = applier.apply(desired(configRed, frame: frame.insetBy(dx: -20, dy: -20)), forceOrdering: true)
        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertEqual(recorder.createdWindowCount, BorderWindow.SegmentKind.allCases.count)
        XCTAssertEqual(recorder.screencaptureExclusionCount, BorderWindow.SegmentKind.allCases.count)
    }

    @MainActor
    func testCapacityGrowthReplacesOnlySegmentsAndRemovesReleasedRegistrations() {
        let recorder = BorderOperationsRecorder()
        recorder.screenFrame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(
            desired(configRed, frame: CGRect(x: 10, y: 10, width: 900, height: 700)),
            forceOrdering: false,
            refreshCornerRadii: false
        )

        let liveWindowIds = recorder.createdWindowIds.filter { !recorder.releasedWindowIds.contains($0) }
        XCTAssertFalse(recorder.releasedWindowIds.isEmpty)
        XCTAssertTrue(recorder.releasedWindowIds.allSatisfy {
            !SurfaceCoordinator.shared.contains(windowNumber: Int($0))
        })
        XCTAssertEqual(liveWindowIds.count, BorderWindow.SegmentKind.allCases.count)
        XCTAssertTrue(liveWindowIds.allSatisfy {
            SurfaceCoordinator.shared.contains(windowNumber: Int($0))
        })
    }

    @MainActor
    func testRepeatedIdenticalApplyIsNoOp() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let flushesAfterFirst = recorder.flushCount
        let orderingAfterFirst = recorder.orderingCount

        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertEqual(recorder.orderingCount, orderingAfterFirst)
    }

    @MainActor
    func testAnimatedSizeChangesDoNotQueryCornerRadiiAgain() {
        let recorder = BorderOperationsRecorder()
        var queriedWindowIds: [Int] = []
        let applier = makeApplier(recorder) { windowId in
            queriedWindowIds.append(windowId)
            return self.sample(
                WindowCornerRadii(topLeft: 11.5, topRight: 12, bottomLeft: 13, bottomRight: 14)
            )
        }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(
            desired(
                configRed,
                frame: CGRect(x: 10, y: 10, width: 240, height: 170)
            ),
            forceOrdering: false,
            refreshCornerRadii: false
        )
        _ = applier.apply(
            desired(
                configRed,
                frame: CGRect(x: 10, y: 10, width: 280, height: 190)
            ),
            forceOrdering: false,
            refreshCornerRadii: false
        )

        XCTAssertEqual(queriedWindowIds, [77])

        _ = applier.apply(
            desired(configRed, token: token(windowId: 78)),
            forceOrdering: false,
            refreshCornerRadii: false
        )
        XCTAssertEqual(queriedWindowIds, [77])

        _ = applier.apply(
            desired(configRed, token: token(windowId: 78)),
            forceOrdering: false,
            refreshCornerRadii: true
        )
        XCTAssertEqual(queriedWindowIds, [77, 78])
    }

    @MainActor
    func testSettledSizeRefreshQueriesCornerRadiiOnce() {
        let recorder = BorderOperationsRecorder()
        var queryCount = 0
        let settledFrame = CGRect(x: 10, y: 10, width: 280, height: 190)
        let applier = makeApplier(recorder) { _ in
            queryCount += 1
            return self.sample(
                WindowCornerRadii(uniform: 11.5),
                size: queryCount == 1 ? self.frame.size : settledFrame.size
            )
        }
        defer { applier.cleanup() }
        let settled = desired(configRed, frame: settledFrame)

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(settled, forceOrdering: false, refreshCornerRadii: false)
        XCTAssertEqual(queryCount, 1)

        _ = applier.apply(settled, forceOrdering: false, refreshCornerRadii: true)
        _ = applier.apply(settled, forceOrdering: false, refreshCornerRadii: true)

        XCTAssertEqual(queryCount, 2)
    }

    @MainActor
    func testMissingSampleRequestsOneRetryThenAcceptsSuccess() {
        let recorder = BorderOperationsRecorder()
        var samples = [
            nil,
            sample(WindowCornerRadii(uniform: 11.5))
        ] as [WindowCornerSample?]
        let applier = makeApplier(recorder) { _ in samples.removeFirst() }
        defer { applier.cleanup() }

        let first = applier.apply(desired(configRed), forceOrdering: false)
        let retry = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(first.didApply)
        XCTAssertTrue(first.needsCornerRadiiRetry)
        XCTAssertTrue(retry.didApply)
        XCTAssertFalse(retry.needsCornerRadiiRetry)
        XCTAssertTrue(samples.isEmpty)
    }

    @MainActor
    func testSecondMissingSampleExhaustsAutomaticRetry() {
        let recorder = BorderOperationsRecorder()
        var queryCount = 0
        let applier = makeApplier(recorder) { _ in
            queryCount += 1
            return nil
        }
        defer { applier.cleanup() }

        let first = applier.apply(desired(configRed), forceOrdering: false)
        let retry = applier.apply(desired(configRed), forceOrdering: false)
        let laterFullReconcile = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(first.needsCornerRadiiRetry)
        XCTAssertFalse(retry.needsCornerRadiiRetry)
        XCTAssertFalse(laterFullReconcile.needsCornerRadiiRetry)
        XCTAssertEqual(queryCount, 2)
    }

    @MainActor
    func testMissingRefreshKeepsPreviousSuccessfulSample() {
        let recorder = BorderOperationsRecorder()
        let oldRadii = WindowCornerRadii(uniform: 20)
        let newRadii = WindowCornerRadii(uniform: 9)
        let resizedFrame = CGRect(x: 10, y: 10, width: 260, height: 180)
        var samples = [
            sample(oldRadii),
            nil,
            sample(newRadii, size: resizedFrame.size)
        ] as [WindowCornerSample?]
        let applier = makeApplier(recorder) { _ in samples.removeFirst() }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let missing = applier.apply(
            desired(configRed, frame: resizedFrame),
            forceOrdering: false
        )
        let flushesWithFallback = recorder.flushCount
        let recovered = applier.apply(
            desired(configRed, frame: resizedFrame),
            forceOrdering: false
        )

        XCTAssertTrue(missing.needsCornerRadiiRetry)
        XCTAssertFalse(recovered.needsCornerRadiiRetry)
        XCTAssertGreaterThan(recorder.flushCount, flushesWithFallback)
    }

    @MainActor
    func testDifferentTokenNeverInheritsPreviousSuccessfulSample() {
        let recorder = BorderOperationsRecorder()
        var samples = [sample(WindowCornerRadii(uniform: 20))]
        let applier = makeApplier(recorder) { _ in samples.isEmpty ? nil : samples.removeFirst() }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let flushesBeforeTokenChange = recorder.flushCount
        _ = applier.apply(
            desired(configRed, token: token(windowId: 78, pid: 4321)),
            forceOrdering: false,
            refreshCornerRadii: false
        )

        XCTAssertGreaterThan(recorder.flushCount, flushesBeforeTokenChange)
        XCTAssertTrue(samples.isEmpty)
    }

    @MainActor
    func testDesiredSizeChangeAndHideResetRetryExhaustion() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let first = applier.apply(desired(configRed), forceOrdering: false)
        let exhausted = applier.apply(desired(configRed), forceOrdering: false)
        let resized = applier.apply(
            desired(
                configRed,
                frame: CGRect(x: 10, y: 10, width: 260, height: 180)
            ),
            forceOrdering: false
        )
        _ = applier.apply(nil, forceOrdering: false)
        let afterHide = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(first.needsCornerRadiiRetry)
        XCTAssertFalse(exhausted.needsCornerRadiiRetry)
        XCTAssertTrue(resized.needsCornerRadiiRetry)
        XCTAssertTrue(afterHide.needsCornerRadiiRetry)
    }

    @MainActor
    func testAnimationSizeChangeDoesNotRearmRetryExhaustion() {
        let recorder = BorderOperationsRecorder()
        var queryCount = 0
        let applier = makeApplier(recorder) { _ in
            queryCount += 1
            return nil
        }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(desired(configRed), forceOrdering: false)
        let animation = applier.apply(
            desired(
                configRed,
                frame: CGRect(x: 10, y: 10, width: 260, height: 180)
            ),
            forceOrdering: false,
            refreshCornerRadii: false
        )
        let originalSizeFullReconcile = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertFalse(animation.needsCornerRadiiRetry)
        XCTAssertFalse(originalSizeFullReconcile.needsCornerRadiiRetry)
        XCTAssertEqual(queryCount, 2)
    }

    @MainActor
    func testObservedSizeMismatchRequestsRetry() {
        let recorder = BorderOperationsRecorder()
        let desiredFrame = CGRect(x: 10, y: 10, width: 280, height: 190)
        var samples = [
            sample(WindowCornerRadii(uniform: 12), size: frame.size),
            sample(WindowCornerRadii(uniform: 12), size: desiredFrame.size)
        ]
        let applier = makeApplier(recorder) { _ in samples.removeFirst() }
        defer { applier.cleanup() }

        let first = applier.apply(
            desired(configRed, frame: desiredFrame),
            forceOrdering: false
        )
        let flushesAfterFirst = recorder.flushCount
        let retry = applier.apply(
            desired(configRed, frame: desiredFrame),
            forceOrdering: false
        )

        XCTAssertTrue(first.needsCornerRadiiRetry)
        XCTAssertFalse(retry.needsCornerRadiiRetry)
        XCTAssertTrue(samples.isEmpty)
        XCTAssertGreaterThan(recorder.flushCount, flushesAfterFirst)
    }

    @MainActor
    func testForceOrderingReordersWithoutRedraw() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let flushesAfterFirst = recorder.flushCount
        let moveAndOrdersAfterFirst = recorder.moveAndOrderCount

        _ = applier.apply(desired(configRed), forceOrdering: true)

        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertGreaterThan(recorder.moveAndOrderCount, moveAndOrdersAfterFirst)
    }

    @MainActor
    func testFailedCreateReturnsFalseThenRetries() {
        let recorder = BorderOperationsRecorder()
        recorder.nextWindowId = 0
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let firstApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertFalse(firstApplied.didApply)
        XCTAssertFalse(firstApplied.needsCornerRadiiRetry)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: 1001))

        recorder.nextWindowId = 1001
        let secondApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertTrue(secondApplied.didApply)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: 1001))
    }

    @MainActor
    func testConfigResyncedAfterHide() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(nil, forceOrdering: false)
        let flushesBeforeReshow = recorder.flushCount

        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertGreaterThan(recorder.flushCount, flushesBeforeReshow)
    }

    @MainActor
    func testNilContextFailsCreation() {
        let recorder = BorderOperationsRecorder()
        recorder.contextProvider = { nil }
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        let applied = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)

        XCTAssertFalse(applied)
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, 1)
    }

    @MainActor
    func testUpdateConfigDoesNotRedrawUntilNextUpdate() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        _ = window.update(frame: target, targetWid: 55)
        let flushesAfterFirst = recorder.flushCount

        window.updateConfig(configBlue)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)

        _ = window.update(frame: target, targetWid: 55)
        XCTAssertGreaterThan(recorder.flushCount, flushesAfterFirst)
    }

    @MainActor
    func testReshapeOnSizeChange() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)
        let shapesAfterFirst = recorder.shapeCount

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 140, height: 80), targetWid: 55)
        XCTAssertGreaterThan(recorder.shapeCount, shapesAfterFirst)
    }

    @MainActor
    func testSizeAnimationMovesPersistentSegmentsWithoutRasterOrFlush() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 800, height: 600), targetWid: 55)
        let createdAfterFirst = recorder.createdWindowCount
        let flushesAfterFirst = recorder.flushCount
        let shapesAfterFirst = recorder.shapeCount
        let scopesAfterFirst = recorder.transactionScopeCount

        for size in [
            CGSize(width: 840, height: 620),
            CGSize(width: 880, height: 640),
            CGSize(width: 920, height: 660)
        ] {
            _ = window.update(frame: CGRect(origin: .zero, size: size), targetWid: 55)
        }

        XCTAssertEqual(createdAfterFirst, BorderWindow.SegmentKind.allCases.count)
        XCTAssertEqual(recorder.createdWindowCount, createdAfterFirst)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertGreaterThan(recorder.shapeCount, shapesAfterFirst)
        XCTAssertGreaterThan(recorder.moveCount, 0)
        XCTAssertEqual(recorder.transactionScopeCount, scopesAfterFirst + 3)
    }

    @MainActor
    func testFractionalScaleSegmentBoundariesShareExactPixelEdges() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1.5
        recorder.screenFrame = CGRect(x: 0, y: 0, width: 1729, height: 1117)
        let config = BorderConfig(enabled: true, width: 3.5, color: .systemRed)
        let window = BorderWindow(config: config, operations: recorder.operations())
        let target = CGRect(x: 17.2, y: 31.4, width: 803.3, height: 607.7)
        let radii = WindowCornerRadii(
            topLeft: 10.9,
            topRight: 13.7,
            bottomLeft: 9.1,
            bottomRight: 15.5
        )

        XCTAssertTrue(window.update(frame: target, targetWid: 55, cornerRadii: radii))
        let top = try XCTUnwrap(window.frameOnScreen(for: .top))
        let bottom = try XCTUnwrap(window.frameOnScreen(for: .bottom))
        let left = try XCTUnwrap(window.frameOnScreen(for: .left))
        let right = try XCTUnwrap(window.frameOnScreen(for: .right))
        let topLeft = try XCTUnwrap(window.frameOnScreen(for: .topLeft))
        let topRight = try XCTUnwrap(window.frameOnScreen(for: .topRight))
        let bottomLeft = try XCTUnwrap(window.frameOnScreen(for: .bottomLeft))
        let bottomRight = try XCTUnwrap(window.frameOnScreen(for: .bottomRight))

        XCTAssertEqual(topLeft.maxX, top.minX)
        XCTAssertEqual(top.maxX, topRight.minX)
        XCTAssertEqual(bottomLeft.maxX, bottom.minX)
        XCTAssertEqual(bottom.maxX, bottomRight.minX)
        XCTAssertEqual(bottomLeft.maxY, left.minY)
        XCTAssertEqual(left.maxY, topLeft.minY)
        XCTAssertEqual(bottomRight.maxY, right.minY)
        XCTAssertEqual(right.maxY, topRight.minY)

        let effectiveWidth = config.width.roundedToPhysicalPixel(scale: recorder.backingScale)
        XCTAssertEqual(top.height, effectiveWidth, accuracy: 0.000_000_1)
        XCTAssertEqual(bottom.height, effectiveWidth, accuracy: 0.000_000_1)
        XCTAssertEqual(left.width, effectiveWidth, accuracy: 0.000_000_1)
        XCTAssertEqual(right.width, effectiveWidth, accuracy: 0.000_000_1)
        XCTAssertEqual(
            topLeft.width,
            (radii.topLeft + effectiveWidth).roundedToPhysicalPixel(scale: recorder.backingScale)
        )
    }

    @MainActor
    func testChangingFractionalCornerRadiiRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        _ = window.update(
            frame: target,
            targetWid: 55,
            cornerRadii: WindowCornerRadii(uniform: 9)
        )
        let flushesAfterFirst = recorder.flushCount

        _ = window.update(
            frame: target,
            targetWid: 55,
            cornerRadii: WindowCornerRadii(topLeft: 11.5, topRight: 9, bottomLeft: 8.5, bottomRight: 7)
        )
        XCTAssertGreaterThan(recorder.flushCount, flushesAfterFirst)
    }

    @MainActor
    func testDestroyReleasesWindow() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)
        XCTAssertNotNil(window.windowId)

        window.destroy()
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, BorderWindow.SegmentKind.allCases.count)
    }

    @MainActor
    func testDeinitReleasesWindow() {
        let recorder = BorderOperationsRecorder()
        var window: BorderWindow? = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window?.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)
        XCTAssertNotNil(window?.windowId)

        window = nil

        XCTAssertEqual(recorder.releasedCount, BorderWindow.SegmentKind.allCases.count)
    }
}

final class WindowCornerRadiiTests: XCTestCase {
    @MainActor
    func testParserPreservesFourFractionalValues() {
        let values = [
            NSNumber(value: 11.5),
            NSNumber(value: 12.25),
            NSNumber(value: 13.75),
            NSNumber(value: 14.5)
        ] as CFArray

        XCTAssertEqual(
            SkyLight.parseCornerRadii(values),
            WindowCornerRadii(topLeft: 11.5, topRight: 12.25, bottomLeft: 14.5, bottomRight: 13.75)
        )
    }

    @MainActor
    func testParserAcceptsUniformValueAndRejectsMalformedValues() {
        let uniform = [NSNumber(value: 11.5)] as CFArray
        let partial = [NSNumber(value: 1), NSNumber(value: 2)] as CFArray
        let excessive = [
            NSNumber(value: 1),
            NSNumber(value: 2),
            NSNumber(value: 3),
            NSNumber(value: 4),
            NSNumber(value: 5)
        ] as CFArray
        let negative = [NSNumber(value: -1)] as CFArray
        let nonfinite = [NSNumber(value: Double.nan)] as CFArray
        let nonnumber = [NSString(string: "11.5")] as CFArray

        XCTAssertEqual(SkyLight.parseCornerRadii(uniform), WindowCornerRadii(uniform: 11.5))
        XCTAssertNil(SkyLight.parseCornerRadii(partial))
        XCTAssertNil(SkyLight.parseCornerRadii(excessive))
        XCTAssertNil(SkyLight.parseCornerRadii(negative))
        XCTAssertNil(SkyLight.parseCornerRadii(nonfinite))
        XCTAssertNil(SkyLight.parseCornerRadii(nonnumber))
    }

    @MainActor
    func testCornerSampleRecordsObservedSizeAndSource() {
        let resolved = [NSNumber(value: 20)] as CFArray
        let malformedResolved = [NSNumber(value: -1)] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: resolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 20),
                observedSize: observedSize,
                source: .resolved
            )
        )
        XCTAssertEqual(
            SkyLight.cornerSample(resolved: malformedResolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 11.5),
                observedSize: observedSize,
                source: .raw
            )
        )
    }

    @MainActor
    func testCornerSampleRejectsInvalidObservedSize() {
        let raw = [NSNumber(value: 11.5)] as CFArray

        XCTAssertNil(
            SkyLight.cornerSample(
                resolved: nil,
                raw: raw,
                observedSize: CGSize(width: 0, height: 600)
            )
        )
    }

    @MainActor
    func testDiagnosticCornerSamplesParseResolvedAndRawIndependently() {
        let resolved = [NSNumber(value: 20)] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        let samples = SkyLight.diagnosticCornerSamples(
            resolved: resolved,
            raw: raw,
            observedSize: observedSize
        )

        XCTAssertEqual(samples.resolved?.radii, WindowCornerRadii(uniform: 20))
        XCTAssertEqual(samples.resolved?.source, .resolved)
        XCTAssertEqual(samples.raw?.radii, WindowCornerRadii(uniform: 11.5))
        XCTAssertEqual(samples.raw?.source, .raw)
    }

    func testNormalizationPreventsOverlappingArcs() {
        let normalized = WindowCornerRadii(uniform: 80).normalized(to: CGSize(width: 100, height: 50))

        XCTAssertEqual(normalized, WindowCornerRadii(uniform: 25))
    }

    @MainActor
    func testRoundedRectPathKeepsCornersIndependent() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = BorderWindow.roundedRectPath(
            in: rect,
            radii: WindowCornerRadii(topLeft: 40, topRight: 0, bottomLeft: 0, bottomRight: 0)
        )

        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 98)))
        XCTAssertTrue(path.contains(CGPoint(x: 98, y: 98)))
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(path.contains(CGPoint(x: 98, y: 2)))
    }

    @MainActor
    func testRoundedRectPathRejectsInvalidGeometry() {
        let path = BorderWindow.roundedRectPath(
            in: CGRect(x: 0, y: 0, width: 0, height: 10),
            radii: WindowCornerRadii(uniform: 4)
        )

        XCTAssertTrue(path.isEmpty)
    }
}
