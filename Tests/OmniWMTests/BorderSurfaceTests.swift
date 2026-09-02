// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

final class BorderSurfaceTests: XCTestCase {
    @MainActor
    private final class BorderOperationsRecorder {
        enum PresentationOperation: Equatable {
            case shape(windowId: UInt32, frame: CGRect)
            case flush(windowId: UInt32)
        }

        struct MoveAndOrderCall: Equatable {
            let windowId: UInt32
            let origin: CGPoint
            let level: Int32
            let targetWindowId: UInt32
            let order: SkyLightWindowOrder
        }

        struct RGBA8: Equatable {
            let red: UInt8
            let green: UInt8
            let blue: UInt8
            let alpha: UInt8
        }

        var createdWindowCount = 0
        var configureCount = 0
        var screencaptureExclusionCount = 0
        var releasedCount = 0
        var shapeCount = 0
        var flushCount = 0
        var moveCount = 0
        var moveAndOrderCount = 0
        var hideCount = 0
        var windowInfoQueryCount = 0
        var backingScaleQueryCount = 0
        var nextWindowId: UInt32 = 1001
        var createdWindowIds: [UInt32] = []
        var createdFramesByWindowId: [UInt32: CGRect] = [:]
        var backingScale: CGFloat = 2
        var screenFrame = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        var presentationOperations: [PresentationOperation] = []
        var contextsByWindowId: [UInt32: CGContext] = [:]
        var moveAndOrderCalls: [MoveAndOrderCall] = []
        var queriedWindowIds: [UInt32] = []
        var windowInfoProvider: @MainActor (UInt32) -> WindowServerInfo? = {
            WindowServerInfo(id: $0, pid: 1234, level: 0, frame: .zero)
        }

        var contextProvider: @MainActor (UInt32, CGRect) -> CGContext? = { _, frame in
            BorderOperationsRecorder.makeContext(size: frame.size)
        }

        var orderingCount: Int {
            moveCount + moveAndOrderCount
        }

        func operations() -> BorderWindow.Operations {
            BorderWindow.Operations(
                createBorderWindow: { [weak self] frame in
                    guard let self else { return 0 }
                    createdWindowCount += 1
                    let windowId = nextWindowId
                    if windowId != 0 {
                        createdWindowIds.append(windowId)
                        createdFramesByWindowId[windowId] = frame
                        nextWindowId += 1
                    }
                    return windowId
                },
                releaseBorderWindow: { [weak self] windowId in
                    self?.releasedCount += 1
                    self?.createdFramesByWindowId.removeValue(forKey: windowId)
                    self?.contextsByWindowId.removeValue(forKey: windowId)
                },
                configureWindow: { [weak self] _, _, _ in self?.configureCount += 1 },
                setWindowTags: { _, _ in },
                excludeFromScreencaptureSelection: { [weak self] _ in self?.screencaptureExclusionCount += 1 },
                createWindowContext: { [weak self] windowId in
                    guard let self,
                          let frame = createdFramesByWindowId[windowId],
                          let context = contextProvider(windowId, frame)
                    else { return nil }
                    contextsByWindowId[windowId] = context
                    return context
                },
                setWindowShape: { [weak self] windowId, frame in
                    self?.shapeCount += 1
                    self?.presentationOperations.append(.shape(windowId: windowId, frame: frame))
                },
                flushWindow: { [weak self] windowId in
                    self?.flushCount += 1
                    self?.presentationOperations.append(.flush(windowId: windowId))
                },
                transactionMove: { [weak self] _, _ in self?.moveCount += 1 },
                transactionMoveAndOrder: { [weak self] windowId, origin, level, targetWindowId, order in
                    self?.moveAndOrderCount += 1
                    self?.moveAndOrderCalls.append(
                        MoveAndOrderCall(
                            windowId: windowId,
                            origin: origin,
                            level: level,
                            targetWindowId: targetWindowId,
                            order: order
                        )
                    )
                },
                transactionHide: { [weak self] _ in self?.hideCount += 1 },
                queryWindowInfo: { [weak self] windowId in
                    guard let self else { return nil }
                    windowInfoQueryCount += 1
                    queriedWindowIds.append(windowId)
                    return windowInfoProvider(windowId)
                },
                backingScaleForFrame: { [weak self] _ in
                    guard let self else { return (2, .null) }
                    backingScaleQueryCount += 1
                    return (backingScale, screenFrame)
                }
            )
        }

        static func makeContext(size: CGSize) -> CGContext? {
            let width = max(1, Int(ceil(size.width)))
            let height = max(1, Int(ceil(size.height)))
            return CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        func pixel(windowId: UInt32, x: Int, y: Int) -> RGBA8? {
            guard let context = contextsByWindowId[windowId],
                  let data = context.data,
                  x >= 0,
                  x < context.width,
                  y >= 0,
                  y < context.height
            else { return nil }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let offset = y * context.bytesPerRow + x * 4
            return RGBA8(
                red: bytes[offset],
                green: bytes[offset + 1],
                blue: bytes[offset + 2],
                alpha: bytes[offset + 3]
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
    private let configRed = BorderConfig(
        enabled: true,
        width: 4,
        color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
    )
    private let configBlue = BorderConfig(
        enabled: true,
        width: 4,
        color: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
    )

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
        XCTAssertEqual(recorder.createdWindowCount, 1)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: Int(recorder.createdWindowIds[0])))
    }

    @MainActor
    func testApplyNilHidesAndUnregisters() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let windowId = recorder.createdWindowIds[0]
        let hidden = applier.apply(nil, forceOrdering: false)

        XCTAssertTrue(hidden.didApply)
        XCTAssertEqual(recorder.hideCount, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: Int(windowId)))
    }

    @MainActor
    func testBorderWindowOptsOutOfScreencaptureSelectionOncePerWindow() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertEqual(recorder.screencaptureExclusionCount, 1)

        _ = applier.apply(desired(configRed, frame: frame.insetBy(dx: -20, dy: -20)), forceOrdering: true)
        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertEqual(recorder.createdWindowCount, 1)
        XCTAssertEqual(recorder.screencaptureExclusionCount, 1)
    }

    @MainActor
    func testResizeKeepsSingleWindowAndRegistration() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let windowId = recorder.createdWindowIds[0]
        _ = applier.apply(
            desired(configRed, frame: CGRect(x: 10, y: 10, width: 900, height: 700)),
            forceOrdering: false,
            refreshCornerRadii: false
        )

        XCTAssertEqual(recorder.createdWindowCount, 1)
        XCTAssertEqual(recorder.releasedCount, 0)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: Int(windowId)))
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
    func testExteriorAnnulusExpandsSurfaceAndKeepsTargetSilhouetteTransparent() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let windowId = try XCTUnwrap(window.windowId)
        let redPixel = BorderOperationsRecorder.RGBA8(red: 255, green: 0, blue: 0, alpha: 255)

        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 6, y: 16, width: 108, height: 88))
        XCTAssertEqual(recorder.createdFramesByWindowId[windowId], CGRect(x: 0, y: 0, width: 108, height: 88))
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 2), redPixel)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 44)?.alpha, 0)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 5, y: 44)?.alpha, 0)

        let safeInterior = BorderWindow.roundedRectPath(
            in: CGRect(x: 5, y: 5, width: 98, height: 78),
            radii: WindowCornerRadii(uniform: 8)
        )
        var nontransparentInteriorPixels = 0
        for y in 5 ..< 83 {
            for x in 5 ..< 103 where safeInterior.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                if recorder.pixel(windowId: windowId, x: x, y: y)?.alpha != 0 {
                    nontransparentInteriorPixels += 1
                }
            }
        }
        XCTAssertEqual(nontransparentInteriorPixels, 0)
    }

    @MainActor
    func testFractionalWidthUsesTheSamePhysicalPixelClearanceForSurfaceAndDrawing() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let config = BorderConfig(
            enabled: true,
            width: 4.5,
            color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let window = BorderWindow(config: config, operations: recorder.operations())
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let windowId = try XCTUnwrap(window.windowId)

        XCTAssertEqual(config.resolvedGeometry(for: target, scale: 1).width, 5)
        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 5, y: 15, width: 110, height: 90))
        XCTAssertEqual(recorder.createdFramesByWindowId[windowId], CGRect(x: 0, y: 0, width: 110, height: 90))
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 55, y: 4)?.alpha, 255)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 55, y: 5)?.alpha, 0)
    }

    @MainActor
    func testOrderingUsesValidatedTargetLevelAndDoesNotQueryDuringTranslation() {
        let recorder = BorderOperationsRecorder()
        let target = token(windowId: 55)
        recorder.windowInfoProvider = {
            WindowServerInfo(id: $0, pid: target.pid, level: 8, frame: .zero)
        }
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: frame, targetToken: target)

        XCTAssertEqual(recorder.windowInfoQueryCount, 1)
        XCTAssertEqual(
            recorder.moveAndOrderCalls.last,
            BorderOperationsRecorder.MoveAndOrderCall(
                windowId: 1001,
                origin: ScreenCoordinateSpace.toWindowServer(rect: frame.insetBy(dx: -4, dy: -4)).origin,
                level: 8,
                targetWindowId: 55,
                order: .below
            )
        )

        _ = window.update(frame: frame.offsetBy(dx: 20, dy: 30), targetToken: target)

        XCTAssertEqual(recorder.windowInfoQueryCount, 1)
        XCTAssertEqual(recorder.moveCount, 1)

        window.reorder(relativeTo: target)

        XCTAssertEqual(recorder.windowInfoQueryCount, 2)
        XCTAssertEqual(recorder.moveAndOrderCalls.last?.level, 8)
    }

    @MainActor
    func testWindowLevelFailureRetriesOnceAndValidatesPIDAndWID() {
        let recorder = BorderOperationsRecorder()
        let target = token(windowId: 55)
        var responses = [
            WindowServerInfo(id: 56, pid: target.pid, level: 9, frame: .zero),
            WindowServerInfo(id: 55, pid: target.pid + 1, level: 9, frame: .zero),
            WindowServerInfo(id: 55, pid: target.pid, level: 7, frame: .zero)
        ] as [WindowServerInfo?]
        recorder.windowInfoProvider = { _ in responses.removeFirst() }
        let applier = makeApplier(recorder) { _ in
            self.sample(WindowCornerRadii(uniform: 9))
        }
        defer { applier.cleanup() }

        let first = applier.apply(desired(configRed, token: target), forceOrdering: false)
        let retry = applier.apply(desired(configRed, token: target), forceOrdering: false)
        let forced = applier.apply(desired(configRed, token: target), forceOrdering: true)

        XCTAssertTrue(first.needsWindowLevelRetry)
        XCTAssertFalse(retry.needsWindowLevelRetry)
        XCTAssertFalse(forced.needsWindowLevelRetry)
        XCTAssertEqual(recorder.moveAndOrderCalls.map(\.level), [0, 0, 7])
        XCTAssertTrue(responses.isEmpty)
    }

    @MainActor
    func testWindowLevelFailureReusesCacheOnlyForSameTarget() {
        let recorder = BorderOperationsRecorder()
        let firstTarget = token(windowId: 55)
        let secondTarget = token(windowId: 56)
        var firstQuery = true
        recorder.windowInfoProvider = { windowId in
            guard firstQuery else { return nil }
            firstQuery = false
            return WindowServerInfo(id: windowId, pid: firstTarget.pid, level: 8, frame: .zero)
        }
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: frame, targetToken: firstTarget)
        _ = window.update(frame: frame, targetToken: firstTarget, forceOrdering: true)
        _ = window.update(frame: frame, targetToken: firstTarget)
        _ = window.update(frame: frame, targetToken: secondTarget)

        XCTAssertEqual(recorder.moveAndOrderCalls.map(\.level), [8, 8, 8, 0])
        XCTAssertTrue(window.needsWindowLevelRetry)
    }

    @MainActor
    func testScaleInvalidationBypassesApplierEqualityAndReconfiguresExistingSurface() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder) { _ in
            self.sample(WindowCornerRadii(uniform: 9))
        }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let configureCount = recorder.configureCount
        let flushCount = recorder.flushCount
        let creationCount = recorder.createdWindowCount

        applier.invalidateDisplayScale()
        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.configureCount, configureCount + 1)
        XCTAssertEqual(recorder.flushCount, flushCount + 1)
        XCTAssertEqual(recorder.createdWindowCount, creationCount)
    }

    @MainActor
    func testWidthChangeReshapesExistingSurfaceAroundUnchangedTarget() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let shapeCount = recorder.shapeCount
        let flushCount = recorder.flushCount
        window.updateConfig(
            BorderConfig(
                enabled: true,
                width: 8,
                color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
            )
        )
        _ = window.update(frame: frame, targetToken: target)

        XCTAssertEqual(window.targetFrameOnScreen, frame)
        XCTAssertEqual(window.frameOnScreen, frame.insetBy(dx: -8, dy: -8))
        XCTAssertEqual(recorder.shapeCount, shapeCount + 1)
        XCTAssertEqual(recorder.flushCount, flushCount + 1)
        XCTAssertEqual(recorder.createdWindowCount, 1)
    }

    @MainActor
    func testFiveHundredSameDisplayTranslationsAvoidLevelAndScaleQueriesReshapesAndRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let queryCount = recorder.windowInfoQueryCount
        let backingScaleQueryCount = recorder.backingScaleQueryCount
        let shapeCount = recorder.shapeCount
        let flushCount = recorder.flushCount
        let creationCount = recorder.createdWindowCount
        let moveCount = recorder.moveCount

        for offset in 1 ... 500 {
            _ = window.update(
                frame: frame.offsetBy(dx: CGFloat(offset), dy: CGFloat(offset % 20)),
                targetToken: target
            )
        }

        XCTAssertEqual(recorder.windowInfoQueryCount, queryCount)
        XCTAssertEqual(recorder.backingScaleQueryCount, backingScaleQueryCount)
        XCTAssertEqual(recorder.shapeCount, shapeCount)
        XCTAssertEqual(recorder.flushCount, flushCount)
        XCTAssertEqual(recorder.createdWindowCount, creationCount)
        XCTAssertEqual(recorder.moveCount, moveCount + 500)
    }

    @MainActor
    func testOneHundredResizesReuseSurfaceAndPerformOneShapeAndFlushEach() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let shapeCount = recorder.shapeCount
        let flushCount = recorder.flushCount
        let creationCount = recorder.createdWindowCount

        for delta in 1 ... 100 {
            _ = window.update(
                frame: CGRect(
                    origin: frame.origin,
                    size: CGSize(width: frame.width + CGFloat(delta), height: frame.height)
                ),
                targetToken: target
            )
        }

        XCTAssertEqual(recorder.shapeCount, shapeCount + 100)
        XCTAssertEqual(recorder.flushCount, flushCount + 100)
        XCTAssertEqual(recorder.createdWindowCount, creationCount)
    }

    @MainActor
    func testNilContextFailsCreation() {
        let recorder = BorderOperationsRecorder()
        recorder.contextProvider = { _, _ in nil }
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        let applied = window.update(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            targetToken: token(windowId: 55)
        )

        XCTAssertFalse(applied)
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, 1)
    }

    @MainActor
    func testColorChangeRepaintsPixelsOnNextUpdate() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let red = BorderConfig(
            enabled: true,
            width: 4,
            color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let blue = BorderConfig(
            enabled: true,
            width: 4,
            color: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let window = BorderWindow(config: red, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let windowId = try XCTUnwrap(window.windowId)
        let redPixel = BorderOperationsRecorder.RGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let bluePixel = BorderOperationsRecorder.RGBA8(red: 0, green: 0, blue: 255, alpha: 255)

        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 2), redPixel)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 44)?.alpha, 0)

        let flushesAfterFirst = recorder.flushCount
        let createdAfterFirst = recorder.createdWindowCount
        recorder.presentationOperations.removeAll()

        window.updateConfig(blue)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertTrue(recorder.presentationOperations.isEmpty)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 2), redPixel)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 44)?.alpha, 0)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))

        XCTAssertEqual(recorder.flushCount, flushesAfterFirst + 1)
        XCTAssertEqual(recorder.createdWindowCount, createdAfterFirst)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 2), bluePixel)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 54, y: 44)?.alpha, 0)
        XCTAssertEqual(recorder.presentationOperations, [.flush(windowId: windowId)])
    }

    @MainActor
    func testSizeChangeShapesBeforeFullRedraw() throws {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        XCTAssertTrue(
            window.update(
                frame: CGRect(x: 0, y: 0, width: 100, height: 80),
                targetToken: token(windowId: 55)
            )
        )
        let windowId = try XCTUnwrap(window.windowId)
        let shapesAfterFirst = recorder.shapeCount
        let flushesAfterFirst = recorder.flushCount
        let createdAfterFirst = recorder.createdWindowCount
        recorder.presentationOperations.removeAll()

        XCTAssertTrue(
            window.update(
                frame: CGRect(x: 0, y: 0, width: 140, height: 80),
                targetToken: token(windowId: 55)
            )
        )

        XCTAssertEqual(recorder.shapeCount, shapesAfterFirst + 1)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst + 1)
        XCTAssertEqual(recorder.createdWindowCount, createdAfterFirst)
        XCTAssertEqual(window.windowId, windowId)
        XCTAssertEqual(
            recorder.presentationOperations,
            [
                .shape(windowId: windowId, frame: CGRect(x: 0, y: 0, width: 148, height: 88)),
                .flush(windowId: windowId)
            ]
        )
    }

    @MainActor
    func testTranslationMovesWithoutReshapeOrRedraw() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            targetToken: token(windowId: 55)
        )
        let createdAfterFirst = recorder.createdWindowCount
        let flushesAfterFirst = recorder.flushCount
        let shapesAfterFirst = recorder.shapeCount
        let movesAfterFirst = recorder.moveCount

        _ = window.update(
            frame: CGRect(x: 40, y: 30, width: 100, height: 80),
            targetToken: token(windowId: 55)
        )

        XCTAssertEqual(recorder.createdWindowCount, createdAfterFirst)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertEqual(recorder.shapeCount, shapesAfterFirst)
        XCTAssertEqual(recorder.moveCount, movesAfterFirst + 1)
        XCTAssertEqual(window.targetFrameOnScreen, CGRect(x: 40, y: 30, width: 100, height: 80))
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 36, y: 26, width: 108, height: 88))
    }

    @MainActor
    func testChangingFractionalCornerRadiiRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        _ = window.update(
            frame: target,
            targetToken: token(windowId: 55),
            cornerRadii: WindowCornerRadii(uniform: 9)
        )
        let flushesAfterFirst = recorder.flushCount

        _ = window.update(
            frame: target,
            targetToken: token(windowId: 55),
            cornerRadii: WindowCornerRadii(topLeft: 11.5, topRight: 9, bottomLeft: 8.5, bottomRight: 7)
        )
        XCTAssertGreaterThan(recorder.flushCount, flushesAfterFirst)
    }

    @MainActor
    func testDestroyReleasesWindow() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            targetToken: token(windowId: 55)
        )
        XCTAssertNotNil(window.windowId)

        window.destroy()
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, 1)
    }

    @MainActor
    func testDeinitReleasesWindow() {
        let recorder = BorderOperationsRecorder()
        var window: BorderWindow? = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window?.update(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            targetToken: token(windowId: 55)
        )
        XCTAssertNotNil(window?.windowId)

        window = nil

        XCTAssertEqual(recorder.releasedCount, 1)
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

    @MainActor
    private func borderFrameFixture() throws -> (controller: WMController, entry: WindowState) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderSurfaceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 813_101, windowId: 813_102)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        let cached = CGRect(x: 80, y: 90, width: 700, height: 500)
        controller.workspaceManager.updateFloatingGeometry(frame: cached, for: token)
        return (controller, try XCTUnwrap(controller.workspaceManager.entry(for: token)))
    }

    @MainActor
    func testBorderFramePrefersLiveBoundsEvenWhileAXWriteIsPending() throws {
        let fixture = try borderFrameFixture()
        let pending = CGRect(x: 10, y: 20, width: 900, height: 600)
        let live = CGRect(x: 40, y: 50, width: 800, height: 500)
        let target = AXFrameApplicationTarget(
            pid: fixture.entry.pid,
            window: fixture.entry.axRef,
            frame: pending
        )
        XCTAssertNotNil(fixture.controller.axManager.stageFrameWrite(for: target))

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)

        fixture.controller.axManager.cancelPendingFrameJobs([
            (pid: fixture.entry.pid, windowId: fixture.entry.windowId)
        ])
        XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: fixture.entry.windowId))
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)
    }

    @MainActor
    func testBorderFrameFallsBackToPendingAXWriteWhenLiveBoundsAreUnavailable() throws {
        let fixture = try borderFrameFixture()
        let pending = CGRect(x: 10, y: 20, width: 900, height: 600)
        let target = AXFrameApplicationTarget(
            pid: fixture.entry.pid,
            window: fixture.entry.axRef,
            frame: pending
        )
        XCTAssertNotNil(fixture.controller.axManager.stageFrameWrite(for: target))

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in nil })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), pending)
    }

    @MainActor
    func testBorderFrameUsesDivergentLiveBoundsAfterAXWriteSettles() throws {
        let fixture = try borderFrameFixture()
        let live = CGRect(x: 40, y: 50, width: 800, height: 500)
        fixture.controller.axManager.confirmFrameWrite(
            for: fixture.entry.windowId,
            frame: CGRect(x: 10, y: 20, width: 900, height: 600)
        )

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)
    }

    @MainActor
    func testBorderFrameFallsBackToCacheWhenLiveBoundsAreUnavailable() throws {
        let fixture = try borderFrameFixture()
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in nil })

        XCTAssertEqual(world.borderFrame(for: fixture.entry), fixture.entry.floatingState?.lastFrame)
    }

    @MainActor
    func testCompletedBorderDerivationReturnsToLiveBoundsAfterAnimation() throws {
        let fixture = try borderFrameFixture()
        fixture.controller.hasStartedServices = true
        fixture.controller.settings.bordersEnabled = true
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(
            fixture.entry.token,
            in: fixture.entry.workspaceId
        ))
        let cached = try XCTUnwrap(fixture.entry.floatingState?.lastFrame)
        let live = CGRect(x: 140, y: 150, width: 800, height: 500)
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        let previous = DesiredBorderSurface(
            token: fixture.entry.token,
            frame: cached,
            config: BorderConfig.from(settings: fixture.controller.settings)
        )

        XCTAssertEqual(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous)?.frame, cached)
        XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world)?.frame, live)
    }

    @MainActor
    func testFloatingToTilingBorderFrameUsesAcceptedTiledFrameOverStaleObservedFrame() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderSurfaceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 813_001, windowId: 813_002)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 80, y: 90, width: 700, height: 500)
        controller.workspaceManager.updateFloatingGeometry(frame: floatingFrame, for: token)
        let floatingEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(WorldView(controller: controller).cachedBorderFrame(for: floatingEntry), floatingFrame)

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: token))
        let tiledFrame = CGRect(x: 12, y: 18, width: 1_100, height: 760)
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: tiledFrame)
        let tiledEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

        XCTAssertEqual(tiledEntry.observedState.frame, floatingFrame)
        XCTAssertEqual(WorldView(controller: controller).cachedBorderFrame(for: tiledEntry), tiledFrame)
    }
}
