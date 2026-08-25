// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreMedia
import CoreVideo
import Foundation
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import XCTest

@MainActor
final class SurfacePresentationLiveTests: XCTestCase {
    private struct RailPresentationReport: Codable {
        let schema: Int
        let generatedAt: String
        let requestedFrames: Int
        let displayRefreshRate: Int
        let captureScale: Double
        let captureCallbacks: Int
        let frameStatusCounts: [String: Int]
        let completeFrames: Int
        let locatedFrames: Int
        let calibrationDetectedOffsetPixels: Double
        let calibrationRealigned: Bool
        let movementBearingFrames: Int
        let baselineOffsetPixels: Double
        let alignedWithinOnePixel: Int
        let alignedRate: Double
        let signedErrorHistogram: [String: Int]
        let lagVerdict: String
        let railBehindSamples: Int
        let clientBehindSamples: Int
        let absoluteErrorP50Pixels: Double
        let absoluteErrorP95Pixels: Double
        let absoluteErrorP99Pixels: Double
        let absoluteErrorMaxPixels: Double
        let slsDeferredSubmissions: Int
        let slsSubmissionFailures: Int
        let displayLinkDroppedCallbacks: Int
    }

    private struct BorderPresentationRGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    private struct BorderPresentationSample {
        let label: String
        let point: CGPoint
    }

    private struct BorderPresentationBitmap {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: [UInt8]

        init?(image: CGImage) {
            let bitmapWidth = image.width
            let bitmapHeight = image.height
            let bitmapBytesPerRow = bitmapWidth * 4
            var storage = [UInt8](repeating: 0, count: bitmapBytesPerRow * bitmapHeight)
            let rendered = storage.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: bitmapWidth,
                    height: bitmapHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bitmapBytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))
                return true
            }
            guard rendered else { return nil }
            width = bitmapWidth
            height = bitmapHeight
            bytesPerRow = bitmapBytesPerRow
            bytes = storage
        }

        func medianColor(at point: CGPoint, radius: Int = 2) -> BorderPresentationRGB? {
            let centerX = Int(point.x.rounded())
            let centerY = Int(point.y.rounded())
            guard centerX >= 0, centerX < width, centerY >= 0, centerY < height else { return nil }
            var reds: [Int] = []
            var greens: [Int] = []
            var blues: [Int] = []
            for y in max(0, centerY - radius) ... min(height - 1, centerY + radius) {
                for x in max(0, centerX - radius) ... min(width - 1, centerX + radius) {
                    let offset = y * bytesPerRow + x * 4
                    reds.append(Int(bytes[offset]))
                    greens.append(Int(bytes[offset + 1]))
                    blues.append(Int(bytes[offset + 2]))
                }
            }
            reds.sort()
            greens.sort()
            blues.sort()
            let index = reds.count / 2
            return BorderPresentationRGB(red: reds[index], green: greens[index], blue: blues[index])
        }
    }

    @MainActor
    private final class LiveBorderOperationsRecorder {
        private let live = BorderWindow.Operations.live
        private(set) var createdWindowCount = 0
        private(set) var releasedWindowCount = 0
        private(set) var contextCount = 0
        private(set) var shapeCount = 0
        private(set) var flushCount = 0

        func operations() -> BorderWindow.Operations {
            var operations = live
            operations.createBorderWindow = { [weak self] frame in
                guard let self else { return 0 }
                let windowId = live.createBorderWindow(frame)
                if windowId != 0 {
                    createdWindowCount += 1
                }
                return windowId
            }
            operations.releaseBorderWindow = { [weak self] windowId in
                self?.releasedWindowCount += 1
                self?.live.releaseBorderWindow(windowId)
            }
            operations.createWindowContext = { [weak self] windowId in
                guard let self else { return nil }
                let context = live.createWindowContext(windowId)
                if context != nil {
                    contextCount += 1
                }
                return context
            }
            operations.setWindowShape = { [weak self] windowId, frame in
                self?.shapeCount += 1
                self?.live.setWindowShape(windowId, frame)
            }
            operations.flushWindow = { [weak self] windowId in
                self?.flushCount += 1
                self?.live.flushWindow(windowId)
            }
            return operations
        }
    }

    func testLiveBorderPresentsConfiguredColorsAcrossResize() async throws {
        try requireLiveMeasurementsEnabled()
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        guard let screen = NSScreen.screens.max(by: {
            $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        }) ?? NSScreen.main,
            let displayId = screen.displayId
        else {
            throw XCTSkip("No measurable display is available")
        }

        let largeFrame = borderPresentationFrame(on: screen)
        let smallFrame = CGRect(origin: largeFrame.origin, size: CGSize(width: 360, height: 240))
        let clientWindow = makeClientWindow(
            frame: smallFrame,
            backgroundColor: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        )
        let operationRecorder = LiveBorderOperationsRecorder()
        let redConfig = BorderConfig(
            enabled: true,
            width: 12,
            color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        let blueConfig = BorderConfig(
            enabled: true,
            width: 12,
            color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        let greenConfig = BorderConfig(
            enabled: true,
            width: 12,
            color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )
        let borderWindow = BorderWindow(config: redConfig, operations: operationRecorder.operations())
        defer {
            borderWindow.destroy()
            clientWindow.close()
        }

        clientWindow.orderFrontRegardless()
        await settle(for: .milliseconds(250))

        let shareable = try await SCShareableContent.currentProcess
        guard let display = shareable.displays.first(where: { $0.displayID == displayId }) else {
            throw XCTSkip("ScreenCaptureKit did not expose the target display")
        }
        let captureRegion = ScreenCoordinateSpace.toWindowServer(rect: largeFrame).intersection(display.frame)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(1, Int((captureRegion.width * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((captureRegion.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsDisplay = true
        configuration.shouldBeOpaque = true

        XCTAssertTrue(
            borderWindow.update(
                frame: smallFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12),
                forceOrdering: true
            )
        )
        let initialWindowId = try XCTUnwrap(borderWindow.windowId)
        XCTAssertEqual(operationRecorder.createdWindowCount, 1)
        XCTAssertEqual(operationRecorder.contextCount, 1)
        XCTAssertEqual(operationRecorder.flushCount, 1)
        try await assertBorderPresentation(
            borderWindow,
            expected: BorderPresentationRGB(red: 255, green: 0, blue: 0),
            captureRegion: captureRegion,
            filter: filter,
            configuration: configuration,
            label: "border-red-small"
        )

        let flushesBeforeBlue = operationRecorder.flushCount
        borderWindow.updateConfig(blueConfig)
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeBlue)
        XCTAssertTrue(
            borderWindow.update(
                frame: smallFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeBlue + 1)
        XCTAssertEqual(borderWindow.windowId, initialWindowId)
        try await assertBorderPresentation(
            borderWindow,
            expected: BorderPresentationRGB(red: 0, green: 0, blue: 255),
            captureRegion: captureRegion,
            filter: filter,
            configuration: configuration,
            label: "border-blue-small"
        )

        let flushesBeforeIdenticalUpdate = operationRecorder.flushCount
        XCTAssertTrue(
            borderWindow.update(
                frame: smallFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeIdenticalUpdate)

        let flushesBeforeGrowth = operationRecorder.flushCount
        let shapesBeforeGrowth = operationRecorder.shapeCount
        clientWindow.setFrame(largeFrame, display: true)
        XCTAssertTrue(
            borderWindow.update(
                frame: largeFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeGrowth + 1)
        XCTAssertEqual(operationRecorder.shapeCount, shapesBeforeGrowth + 1)
        XCTAssertEqual(borderWindow.windowId, initialWindowId)
        try await assertBorderPresentation(
            borderWindow,
            expected: BorderPresentationRGB(red: 0, green: 0, blue: 255),
            captureRegion: captureRegion,
            filter: filter,
            configuration: configuration,
            label: "border-blue-large"
        )

        let flushesBeforeGreen = operationRecorder.flushCount
        borderWindow.updateConfig(greenConfig)
        XCTAssertTrue(
            borderWindow.update(
                frame: largeFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeGreen + 1)
        try await assertBorderPresentation(
            borderWindow,
            expected: BorderPresentationRGB(red: 0, green: 255, blue: 0),
            captureRegion: captureRegion,
            filter: filter,
            configuration: configuration,
            label: "border-green-large"
        )

        let flushesBeforeResizeCycle = operationRecorder.flushCount
        let shapesBeforeResizeCycle = operationRecorder.shapeCount
        clientWindow.setFrame(smallFrame, display: true)
        XCTAssertTrue(
            borderWindow.update(
                frame: smallFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        clientWindow.setFrame(largeFrame, display: true)
        XCTAssertTrue(
            borderWindow.update(
                frame: largeFrame,
                targetWid: UInt32(clientWindow.windowNumber),
                cornerRadii: WindowCornerRadii(uniform: 12)
            )
        )
        XCTAssertEqual(operationRecorder.flushCount, flushesBeforeResizeCycle + 2)
        XCTAssertEqual(operationRecorder.shapeCount, shapesBeforeResizeCycle + 2)
        XCTAssertEqual(operationRecorder.createdWindowCount, 1)
        XCTAssertEqual(operationRecorder.releasedWindowCount, 0)
        XCTAssertEqual(borderWindow.windowId, initialWindowId)
        try await assertBorderPresentation(
            borderWindow,
            expected: BorderPresentationRGB(red: 0, green: 255, blue: 0),
            captureRegion: captureRegion,
            filter: filter,
            configuration: configuration,
            label: "border-green-regrown"
        )
    }

    func testLiveTabRailPresentationAlignsWithSLSClientFrames() async throws {
        try requireLiveMeasurementsEnabled()
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        guard let screen = NSScreen.screens.max(by: {
            $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        }) ?? NSScreen.main,
            let displayId = screen.displayId
        else {
            throw XCTSkip("No measurable display is available")
        }

        let requestedFrames = max(240, environmentInteger("OMNIWM_RAIL_MEASUREMENT_FRAMES", default: 900))
        let baseFrame = clientFrame(on: screen)
        let clientWindow = makeClientWindow(frame: baseFrame)
        let manager = TabRailManager()
        defer {
            manager.removeAll()
            clientWindow.close()
        }
        clientWindow.orderFrontRegardless()

        let workspaceId = WorkspaceDescriptor.ID()
        let owner = TabRailOwner.niriColumn(NodeId())
        let key = TabRailKey(workspaceId: workspaceId, owner: owner)
        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 1,
            tileFrame: baseFrame,
            tabCount: 3,
            activeVisualIndex: 1,
            activeWindowId: clientWindow.windowNumber
        )
        manager.updateRails([info], forceOrdering: true)
        let railWindow = try XCTUnwrap(manager.existingWindow(for: key))
        railWindow.displayIfNeeded()
        railWindow.contentView?.display()
        await settle(for: .milliseconds(350))

        let shareable = try await SCShareableContent.currentProcess
        guard let display = shareable.displays.first(where: { $0.displayID == displayId }) else {
            throw XCTSkip("ScreenCaptureKit did not expose the target display")
        }
        let clientWid = CGWindowID(clientWindow.windowNumber)
        let railWid = CGWindowID(railWindow.windowNumber)
        guard let clientCaptureWindow = shareable.windows.first(where: { $0.windowID == clientWid }),
              let railCaptureWindow = shareable.windows.first(where: { $0.windowID == railWid })
        else {
            throw XCTSkip("ScreenCaptureKit did not expose both measurement windows")
        }
        guard clientCaptureWindow.isOnScreen, railCaptureWindow.isOnScreen else {
            throw XCTSkip("Both measurement windows must be on-screen")
        }

        let captureRegion = captureRegionForRailMotion(baseFrame: baseFrame, displayFrame: display.frame)
        let filter = SCContentFilter(
            display: display,
            including: [clientCaptureWindow, railCaptureWindow]
        )
        let captureScale = CGFloat(filter.pointPixelScale)
        let output = RailCompositeCaptureOutput(
            clientWidthPixels: Int((baseFrame.width * captureScale).rounded()),
            backgroundColor: CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [1, 1, 1, 1]
            )!
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int((captureRegion.width * captureScale).rounded())
        configuration.height = Int((captureRegion.height * captureScale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = .zero
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.backgroundColor = output.backgroundColor
        configuration.ignoreShadowsDisplay = true
        configuration.shouldBeOpaque = true
        if let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"],
           let image = try? await SCScreenshotManager.captureImage(
               contentFilter: filter,
               configuration: configuration
           )
        {
            let representation = NSBitmapImageRep(cgImage: image)
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("rail-calibration.png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? representation.representation(using: .png, properties: [:])?.write(to: url)
            let railFilter = SCContentFilter(desktopIndependentWindow: railCaptureWindow)
            let railConfiguration = SCStreamConfiguration()
            railConfiguration.width = max(1, Int((railCaptureWindow.frame.width * captureScale).rounded()))
            railConfiguration.height = max(1, Int((railCaptureWindow.frame.height * captureScale).rounded()))
            railConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            railConfiguration.showsCursor = false
            if let railImage = try? await SCScreenshotManager.captureImage(
                contentFilter: railFilter,
                configuration: railConfiguration
            ) {
                let railRepresentation = NSBitmapImageRep(cgImage: railImage)
                let railURL = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("rail-window-calibration.png")
                try? railRepresentation.representation(using: .png, properties: [:])?.write(to: railURL)
            }
        }

        let outputQueue = DispatchQueue(label: "com.omniwm.surface-presentation-capture", qos: .userInteractive)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        let baselineReady = await waitUntil(timeout: .seconds(3)) {
            output.snapshot().locatedSamples.count >= 1
        }
        guard baselineReady else {
            try? await stream.stopCapture()
            outputQueue.sync {}
            let snapshot = output.snapshot()
            XCTFail(
                "ScreenCaptureKit produced no locatable composite frame"
                    + " callbacks=\(snapshot.callbacks) complete=\(snapshot.completeFrames)"
            )
            return
        }
        let baselineSnapshot = output.snapshot()
        let baselineOffset = median(baselineSnapshot.locatedSamples.map(\.relativeOffsetPixels))
        let initialDisplayTime = baselineSnapshot.locatedSamples.last?.displayTime ?? 0
        let calibrationFrame = baseFrame.offsetBy(dx: 24, dy: 0)
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: calibrationFrame,
                visibleTileFrame: calibrationFrame
            )
        ], in: workspaceId)
        let calibrationDetected = await waitUntil(timeout: .seconds(2)) {
            output.snapshot().locatedSamples.last.map {
                $0.displayTime > initialDisplayTime
                    && abs($0.relativeOffsetPixels - baselineOffset) >= 20 * captureScale
            } == true
        }
        let calibrationOffset = output.snapshot().locatedSamples.last.map {
            $0.relativeOffsetPixels - baselineOffset
        } ?? 0
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: baseFrame, visibleTileFrame: baseFrame)
        ], in: workspaceId)
        let calibrationRealigned = await waitUntil(timeout: .seconds(2)) {
            output.snapshot().locatedSamples.last.map {
                abs($0.relativeOffsetPixels - baselineOffset) <= 1
            } == true
        }
        guard calibrationDetected, calibrationRealigned else {
            try? await stream.stopCapture()
            outputQueue.sync {}
            XCTFail(
                "Rail pixel calibration failed"
                    + " detected=\(calibrationDetected) realigned=\(calibrationRealigned)"
                    + " offset=\(calibrationOffset)"
            )
            return
        }
        let baselineDisplayTime = output.snapshot().locatedSamples.last?.displayTime ?? 0

        let driver = RailPresentationDisplayLinkDriver(frames: requestedFrames) { index in
            let frame = self.railMotionFrame(index: index, baseFrame: baseFrame)
            let command = TabRailGeometryCommand(key: key, tileFrame: frame, visibleTileFrame: frame)
            SkyLight.shared.withTransactionScope {
                let result = SkyLight.shared.batchMoveWindows([
                    (
                        windowId: UInt32(clientWindow.windowNumber),
                        origin: ScreenCoordinateSpace.toWindowServer(rect: frame).origin
                    )
                ])
                manager.applyAnimationGeometry([command], in: workspaceId)
                switch result {
                case .deferred:
                    output.noteDeferredSubmission()
                case .submitted:
                    break
                case .unavailable:
                    output.noteSubmissionFailure()
                }
            }
        }
        await driver.run(on: screen)
        await settle(for: .milliseconds(500))
        try await stream.stopCapture()
        outputQueue.sync {}

        let snapshot = output.snapshot()
        let motionSamples = snapshot.locatedSamples
            .filter { $0.displayTime > baselineDisplayTime }
            .sorted { $0.displayTime < $1.displayTime }
        let movementSamples = movementBearingSamples(motionSamples)
        let absoluteErrors = movementSamples.map {
            abs($0.relativeOffsetPixels - baselineOffset)
        }
        let signedErrors = movementSamples.map {
            $0.relativeOffsetPixels - baselineOffset
        }
        let signedErrorHistogram = Dictionary(grouping: signedErrors) {
            String(Int($0.rounded()))
        }.mapValues(\.count)
        let aligned = absoluteErrors.filter { $0 <= 1 }.count
        let alignedRate = Double(aligned) / Double(max(1, absoluteErrors.count))
        let report = RailPresentationReport(
            schema: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            requestedFrames: requestedFrames,
            displayRefreshRate: screen.maximumFramesPerSecond,
            captureScale: captureScale,
            captureCallbacks: snapshot.callbacks,
            frameStatusCounts: Dictionary(uniqueKeysWithValues: snapshot.frameStatusCounts.map {
                (frameStatusLabel($0.key), $0.value)
            }),
            completeFrames: snapshot.completeFrames,
            locatedFrames: snapshot.locatedSamples.count,
            calibrationDetectedOffsetPixels: calibrationOffset,
            calibrationRealigned: calibrationRealigned,
            movementBearingFrames: movementSamples.count,
            baselineOffsetPixels: baselineOffset,
            alignedWithinOnePixel: aligned,
            alignedRate: alignedRate,
            signedErrorHistogram: signedErrorHistogram,
            lagVerdict: lagVerdict(signedErrors: signedErrors),
            railBehindSamples: signedErrors.filter { $0 < -0.5 }.count,
            clientBehindSamples: signedErrors.filter { $0 > 0.5 }.count,
            absoluteErrorP50Pixels: percentile(absoluteErrors, 0.50),
            absoluteErrorP95Pixels: percentile(absoluteErrors, 0.95),
            absoluteErrorP99Pixels: percentile(absoluteErrors, 0.99),
            absoluteErrorMaxPixels: absoluteErrors.max() ?? 0,
            slsDeferredSubmissions: snapshot.deferredSubmissions,
            slsSubmissionFailures: snapshot.submissionFailures,
            displayLinkDroppedCallbacks: driver.droppedCallbacks
        )
        try emit(report, label: "rail-presentation")

        XCTAssertGreaterThanOrEqual(movementSamples.count, requestedFrames / 4)
        XCTAssertEqual(snapshot.submissionFailures, 0)
        XCTAssertEqual(snapshot.frameStatusCounts[SCFrameStatus.blank.rawValue, default: 0], 0)
        XCTAssertEqual(snapshot.frameStatusCounts[SCFrameStatus.suspended.rawValue, default: 0], 0)
        XCTAssertGreaterThanOrEqual(alignedRate, 0.99)
        XCTAssertLessThanOrEqual(percentile(absoluteErrors, 0.99), 1)
        XCTAssertLessThanOrEqual(absoluteErrors.max() ?? 0, 1)
    }

    private func clientFrame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.midX - 150,
            y: visible.midY - 120,
            width: 300,
            height: 240
        )
    }

    private func borderPresentationFrame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.midX - 260,
            y: visible.midY - 180,
            width: 520,
            height: 360
        )
    }

    private func makeClientWindow(
        frame: CGRect,
        backgroundColor: NSColor = NSColor(
            calibratedRed: 1,
            green: 0,
            blue: 1,
            alpha: 1
        )
    ) -> NSPanel {
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = backgroundColor
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func borderPresentationSamples(
        for borderWindow: BorderWindow
    ) throws -> [BorderPresentationSample] {
        let frame = try XCTUnwrap(borderWindow.frameOnScreen)
        let edgeInset: CGFloat = 6
        let outerCornerRadius: CGFloat = 24
        let annulusRadius: CGFloat = 18
        let diagonalOffset = annulusRadius / sqrt(2)
        let cornerInset = outerCornerRadius - diagonalOffset
        return [
            BorderPresentationSample(label: "top", point: CGPoint(x: frame.midX, y: frame.maxY - edgeInset)),
            BorderPresentationSample(label: "bottom", point: CGPoint(x: frame.midX, y: frame.minY + edgeInset)),
            BorderPresentationSample(label: "left", point: CGPoint(x: frame.minX + edgeInset, y: frame.midY)),
            BorderPresentationSample(label: "right", point: CGPoint(x: frame.maxX - edgeInset, y: frame.midY)),
            BorderPresentationSample(
                label: "top-left",
                point: CGPoint(x: frame.minX + cornerInset, y: frame.maxY - cornerInset)
            ),
            BorderPresentationSample(
                label: "top-right",
                point: CGPoint(x: frame.maxX - cornerInset, y: frame.maxY - cornerInset)
            ),
            BorderPresentationSample(
                label: "bottom-left",
                point: CGPoint(x: frame.minX + cornerInset, y: frame.minY + cornerInset)
            ),
            BorderPresentationSample(
                label: "bottom-right",
                point: CGPoint(x: frame.maxX - cornerInset, y: frame.minY + cornerInset)
            )
        ]
    }

    private func assertBorderPresentation(
        _ borderWindow: BorderWindow,
        expected: BorderPresentationRGB,
        captureRegion: CGRect,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        label: String
    ) async throws {
        let samples = try borderPresentationSamples(for: borderWindow)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var lastImage: CGImage?
        var lastMismatches: [String] = []
        repeat {
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ),
                let bitmap = BorderPresentationBitmap(image: image)
            {
                lastImage = image
                lastMismatches = samples.compactMap { sample in
                    let point = borderPresentationPixelPoint(
                        for: sample.point,
                        captureRegion: captureRegion,
                        bitmap: bitmap
                    )
                    guard let actual = bitmap.medianColor(at: point) else {
                        return "\(sample.label)=out-of-bounds"
                    }
                    guard borderPresentationColor(actual, matches: expected) else {
                        return "\(sample.label)=\(actual.red),\(actual.green),\(actual.blue)"
                    }
                    return nil
                }
                if lastMismatches.isEmpty {
                    try writeBorderPresentationImage(image, label: label)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline

        if let lastImage {
            try writeBorderPresentationImage(lastImage, label: "\(label)-failed")
        }
        XCTFail(
            "Border presentation did not reach \(expected.red),\(expected.green),\(expected.blue): "
                + lastMismatches.joined(separator: "; ")
        )
    }

    private func borderPresentationPixelPoint(
        for appKitPoint: CGPoint,
        captureRegion: CGRect,
        bitmap: BorderPresentationBitmap
    ) -> CGPoint {
        let windowServerPoint = ScreenCoordinateSpace.toWindowServer(point: appKitPoint)
        return CGPoint(
            x: (windowServerPoint.x - captureRegion.minX) / captureRegion.width * CGFloat(bitmap.width),
            y: (windowServerPoint.y - captureRegion.minY) / captureRegion.height * CGFloat(bitmap.height)
        )
    }

    private func borderPresentationColor(
        _ actual: BorderPresentationRGB,
        matches expected: BorderPresentationRGB
    ) -> Bool {
        abs(actual.red - expected.red) <= 16
            && abs(actual.green - expected.green) <= 16
            && abs(actual.blue - expected.blue) <= 16
    }

    private func writeBorderPresentationImage(_ image: CGImage, label: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"] else {
            return
        }
        let representation = NSBitmapImageRep(cgImage: image)
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(label).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try representation.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func captureRegionForRailMotion(baseFrame: CGRect, displayFrame: CGRect) -> CGRect {
        let left = railMotionFrame(index: 0, baseFrame: baseFrame)
        let right = railMotionFrame(index: 180, baseFrame: baseFrame)
        let appKitBounds = left.union(right).insetBy(dx: -48, dy: -48)
        return ScreenCoordinateSpace.toWindowServer(rect: appKitBounds).intersection(displayFrame)
    }

    private static let railSweepFrames = 250
    private static let railSweepSettleSamples = 25
    private static let railSweepStepPixels: CGFloat = 2

    private func railMotionFrame(index: Int, baseFrame: CGRect) -> CGRect {
        let phase = index % Self.railSweepFrames
        let offset = CGFloat(phase) * Self.railSweepStepPixels
        return baseFrame.offsetBy(dx: offset, dy: 0)
    }

    private func movementBearingSamples(
        _ samples: [RailCompositeCaptureOutput.LocatedSample]
    ) -> [RailCompositeCaptureOutput.LocatedSample] {
        guard var previous = samples.first else { return [] }
        var result: [RailCompositeCaptureOutput.LocatedSample] = []
        var samplesSinceReset = Int.max
        for sample in samples.dropFirst() {
            let movedForward = sample.clientOriginPixels > previous.clientOriginPixels
                || sample.railAnchorPixels > previous.railAnchorPixels
            let sweepReset = sample.clientOriginPixels < previous.clientOriginPixels
                || sample.railAnchorPixels < previous.railAnchorPixels
            if sweepReset {
                samplesSinceReset = 0
            } else if movedForward {
                if samplesSinceReset >= Self.railSweepSettleSamples {
                    result.append(sample)
                }
                samplesSinceReset = samplesSinceReset == Int.max ? Int.max : samplesSinceReset + 1
            }
            previous = sample
        }
        return result
    }

    private func lagVerdict(signedErrors: [Double]) -> String {
        let behind = signedErrors.filter { $0 < -0.5 }.count
        let ahead = signedErrors.filter { $0 > 0.5 }.count
        guard behind + ahead > 0 else { return "aligned" }
        let ratio = Double(max(behind, ahead)) / Double(behind + ahead)
        guard ratio >= 0.8 else { return "mixed" }
        return behind > ahead ? "rail-lags-client" : "client-lags-rail"
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * quantile).rounded(.toNearestOrAwayFromZero))
        return sorted[min(max(0, index), sorted.count - 1)]
    }

    private func median(_ values: [Double]) -> Double {
        percentile(values, 0.50)
    }

    private func frameStatusLabel(_ rawValue: Int) -> String {
        guard let status = SCFrameStatus(rawValue: rawValue) else {
            return "unknown-\(rawValue)"
        }
        switch status {
        case .complete:
            return "complete"
        case .idle:
            return "idle"
        case .blank:
            return "blank"
        case .suspended:
            return "suspended"
        case .started:
            return "started"
        case .stopped:
            return "stopped"
        @unknown default:
            return "unknown-\(rawValue)"
        }
    }

    private func environmentInteger(_ key: String, default defaultValue: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? defaultValue
    }

    private func requireLiveMeasurementsEnabled() throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SURFACE_MEASUREMENTS"] == "1" else {
            throw XCTSkip("Set OMNIWM_RUN_SURFACE_MEASUREMENTS=1 to run live surface measurements")
        }
    }

    private func emit<T: Encodable>(_ report: T, label: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("OMNIWM_SURFACE_MEASUREMENT_BEGIN \(label)")
        print(text)
        print("OMNIWM_SURFACE_MEASUREMENT_END \(label)")
        if let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("\(label).json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        return false
    }

    private func settle(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

private final class RailCompositeCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    struct LocatedSample: Sendable {
        let displayTime: UInt64
        let clientOriginPixels: Int
        let railAnchorPixels: Int

        var relativeOffsetPixels: Double {
            Double(railAnchorPixels - clientOriginPixels)
        }
    }

    struct Snapshot: Sendable {
        let callbacks: Int
        let frameStatusCounts: [Int: Int]
        let completeFrames: Int
        let locatedSamples: [LocatedSample]
        let deferredSubmissions: Int
        let submissionFailures: Int
    }

    private struct State {
        var callbacks = 0
        var frameStatusCounts: [Int: Int] = [:]
        var completeFrames = 0
        var locatedSamples: [LocatedSample] = []
        var deferredSubmissions = 0
        var submissionFailures = 0
    }

    private let clientWidthPixels: Int
    let backgroundColor: CGColor
    private let lock = NSLock()
    private var state = State()

    init(clientWidthPixels: Int, backgroundColor: CGColor) {
        self.clientWidthPixels = clientWidthPixels
        self.backgroundColor = backgroundColor
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        lock.withLock { state.callbacks += 1 }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let statusNumber = attachment[.status] as? NSNumber,
            let status = SCFrameStatus(rawValue: statusNumber.intValue)
        else { return }
        lock.withLock {
            state.frameStatusCounts[status.rawValue, default: 0] += 1
            if status == .complete {
                state.completeFrames += 1
            }
        }
        guard status == .complete,
              let displayTime = (attachment[.displayTime] as? NSNumber)?.uint64Value,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        guard let located = locateWindows(in: pixelBuffer, displayTime: displayTime) else { return }
        lock.withLock { state.locatedSamples.append(located) }
    }

    func noteDeferredSubmission() {
        lock.withLock { state.deferredSubmissions += 1 }
    }

    func noteSubmissionFailure() {
        lock.withLock { state.submissionFailures += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                callbacks: state.callbacks,
                frameStatusCounts: state.frameStatusCounts,
                completeFrames: state.completeFrames,
                locatedSamples: state.locatedSamples,
                deferredSubmissions: state.deferredSubmissions,
                submissionFailures: state.submissionFailures
            )
        }
    }

    private func locateWindows(
        in pixelBuffer: CVPixelBuffer,
        displayTime: UInt64
    ) -> LocatedSample? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let middleY = height / 2
        let rowRange = max(0, middleY - 3) ... min(height - 1, middleY + 3)
        var clientRight = -1

        for y in rowRange {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0 ..< width where isClientPixel(row.advanced(by: x * 4)) {
                clientRight = max(clientRight, x)
            }
        }
        guard clientRight >= clientWidthPixels - 1 else { return nil }
        let clientOrigin = clientRight - clientWidthPixels + 1
        let scanMinX = max(0, clientOrigin - 6)
        let scanMaxX = min(width - 1, clientOrigin + 28)
        var railAnchor: Int?

        for x in scanMinX ... scanMaxX {
            var railPixelCount = 0
            for y in 0 ..< height {
                let pixel = bytes.advanced(by: y * bytesPerRow + x * 4)
                if isRailPixel(pixel) {
                    railPixelCount += 1
                }
            }
            if railPixelCount >= 8, railPixelCount < max(16, height * 3 / 4) {
                railAnchor = x
                break
            }
        }
        guard let railAnchor else { return nil }
        return LocatedSample(
            displayTime: displayTime,
            clientOriginPixels: clientOrigin,
            railAnchorPixels: railAnchor
        )
    }

    private func isClientPixel(_ pixel: UnsafePointer<UInt8>) -> Bool {
        let blue = pixel[0]
        let green = pixel[1]
        let red = pixel[2]
        let alpha = pixel[3]
        return blue >= 225 && red >= 225 && green <= 100 && alpha >= 225
    }

    private func isRailPixel(_ pixel: UnsafePointer<UInt8>) -> Bool {
        let blue = pixel[0]
        let green = pixel[1]
        let red = pixel[2]
        let alpha = pixel[3]
        let isBackground = green >= 240 && red >= 240 && blue >= 240
        return alpha >= 32 && !isBackground && !isClientPixel(pixel)
    }
}

@MainActor
private final class RailPresentationDisplayLinkDriver: NSObject {
    private let frames: Int
    private let apply: @MainActor (Int) -> Void
    private var displayLink: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private var lastTimestamp: CFTimeInterval?
    private var index = 0

    private(set) var droppedCallbacks = 0

    init(frames: Int, apply: @escaping @MainActor (Int) -> Void) {
        self.frames = frames
        self.apply = apply
    }

    func run(on screen: NSScreen) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let displayLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
            self.displayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let lastTimestamp, link.duration > 0, link.timestamp - lastTimestamp > link.duration * 1.5 {
            droppedCallbacks += 1
        }
        lastTimestamp = link.timestamp
        apply(index)
        index += 1
        guard index >= frames else { return }
        link.remove(from: .main, forMode: .common)
        displayLink = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
