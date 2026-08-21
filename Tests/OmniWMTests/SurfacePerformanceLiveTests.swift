// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class SurfacePerformanceLiveTests: XCTestCase {
    private enum BorderScenario: String, CaseIterable, Codable {
        case translation
        case horizontalResize
        case verticalResize
    }

    private enum BorderImplementation: String, Codable {
        case legacySingle
        case segmented
    }

    private struct BorderRun: Codable {
        let implementation: BorderImplementation
        let scenario: BorderScenario
        let repetition: Int
        let frames: Int
        let refreshPeriodMicroseconds: Double
        let applyP50Microseconds: Double
        let applyP95Microseconds: Double
        let updateP95Microseconds: Double
        let applyP99Microseconds: Double
        let intervalP99Microseconds: Double
        let droppedCallbacks: Int
        let processCPUMicrosecondsPerFrame: Double?
        let processRunnableMicrosecondsPerFrame: Double?
        let instructionsPerFrame: Double?
        let cyclesPerFrame: Double?
        let energyNanojoulesPerFrame: Double?
        let surfaceCount: Int
        let windowServerMemoryBytes: UInt64?
        let surfaceIdsStable: Bool
        let surfacesReleased: Bool
    }

    private struct BorderOperationAudit: Codable {
        let implementation: BorderImplementation
        let scenario: BorderScenario
        let frames: Int
        let borderMetrics: String
    }

    private struct BorderAggregate: Codable {
        let implementation: BorderImplementation
        let scenario: BorderScenario
        let runs: Int
        let frames: Int
        let applyP50Microseconds: Double
        let applyP95Microseconds: Double
        let updateP95Microseconds: Double
        let applyP99Microseconds: Double
        let processCPUMicrosecondsPerFrame: Double?
        let processRunnableMicrosecondsPerFrame: Double?
        let instructionsPerFrame: Double?
        let cyclesPerFrame: Double?
        let energyNanojoulesPerFrame: Double?
        let droppedCallbackRate: Double
    }

    private struct BorderReport: Codable {
        let schema: Int
        let generatedAt: String
        let framesPerRun: Int
        let repetitions: Int
        let scope: String
        let optimized: Bool
        let debugCompilationCondition: Bool
        let runs: [BorderRun]
        let aggregates: [BorderAggregate]
        let operationAudits: [BorderOperationAudit]
    }

    func testLiveSegmentedBorderAgainstLegacySingleSurface() async throws {
        try requireLiveMeasurementsEnabled()
        guard let screen = NSScreen.screens.max(by: {
            $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        }) ?? NSScreen.main else {
            throw XCTSkip("No display is available")
        }
        let framesPerRun = max(120, environmentInteger("OMNIWM_SURFACE_MEASUREMENT_FRAMES", default: 720))
        let repetitions = max(2, environmentInteger("OMNIWM_SURFACE_MEASUREMENT_REPETITIONS", default: 7))
        let targetFrame = measurementFrame(on: screen)
        let targetWindow = makeMeasurementWindow(frame: targetFrame)
        defer { targetWindow.close() }
        targetWindow.orderFrontRegardless()
        await settle(for: .milliseconds(250))

        var runs: [BorderRun] = []
        for repetition in 0 ..< repetitions {
            for scenario in BorderScenario.allCases {
                let implementations: [BorderImplementation] = if (repetition + scenarioIndex(scenario)) % 2 == 0 {
                    [.legacySingle, .segmented]
                } else {
                    [.segmented, .legacySingle]
                }
                for implementation in implementations {
                    runs.append(
                        try await runBorderMeasurement(
                            implementation: implementation,
                            scenario: scenario,
                            repetition: repetition,
                            frames: framesPerRun,
                            screen: screen,
                            baseFrame: targetFrame,
                            targetWid: UInt32(targetWindow.windowNumber)
                        )
                    )
                    await settle(for: .milliseconds(180))
                }
            }
        }

        let report = BorderReport(
            schema: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            framesPerRun: framesPerRun,
            repetitions: repetitions,
            scope: "isolated-border-window-display-link",
            optimized: !_isDebugAssertConfiguration(),
            debugCompilationCondition: debugCompilationCondition,
            runs: runs,
            aggregates: aggregate(runs),
            operationAudits: BorderScenario.allCases.flatMap { scenario in
                [BorderImplementation.legacySingle, .segmented].map { implementation in
                    runBorderOperationAudit(
                        implementation: implementation,
                        scenario: scenario,
                        frames: 180,
                        baseFrame: targetFrame
                    )
                }
            }
        )
        try emit(report, label: "border-ab")

        XCTAssertEqual(runs.count, repetitions * BorderScenario.allCases.count * 2)
        XCTAssertTrue(runs.allSatisfy { $0.frames == framesPerRun })
        XCTAssertTrue(runs.allSatisfy { $0.applyP99Microseconds.isFinite })
    }

    private func runBorderMeasurement(
        implementation: BorderImplementation,
        scenario: BorderScenario,
        repetition: Int,
        frames: Int,
        screen: NSScreen,
        baseFrame: CGRect,
        targetWid: UInt32
    ) async throws -> BorderRun {
        let config = BorderConfig(enabled: true, width: 4, color: .systemBlue)
        let legacy = implementation == .legacySingle ? LegacySingleBorderProbe(config: config) : nil
        let segmented = implementation == .segmented ? BorderWindow(config: config) : nil
        let initialFrame = borderFrame(index: 0, scenario: scenario, baseFrame: baseFrame)
        var initialized = false
        SkyLight.shared.withTransactionScope {
            if let legacy {
                initialized = legacy.update(frame: initialFrame, targetWid: targetWid, forceOrdering: true)
            } else if let segmented {
                initialized = segmented.update(frame: initialFrame, targetWid: targetWid, forceOrdering: true)
            }
        }
        XCTAssertTrue(initialized)
        let initialSurfaceIds = surfaceIds(legacy: legacy, segmented: segmented)
        let expectedSurfaceCount = implementation == .legacySingle ? 1 : BorderWindow.SegmentKind.allCases.count
        XCTAssertEqual(initialSurfaceIds.count, expectedSurfaceCount)
        XCTAssertEqual(Set(initialSurfaceIds).count, expectedSurfaceCount)
        await settle(for: .milliseconds(120))

        let windowMemoryBytes = windowServerMemoryBytes(for: initialSurfaceIds)
        let resourceStart = ProcessResourceSnapshot.capture()
        let driver = SurfaceMeasurementDisplayLinkDriver(frames: frames) { index, measureUpdate in
            let frame = self.borderFrame(index: index + 1, scenario: scenario, baseFrame: baseFrame)
            SkyLight.shared.withTransactionScope {
                measureUpdate {
                    if let legacy {
                        _ = legacy.update(frame: frame, targetWid: targetWid)
                    } else if let segmented {
                        _ = segmented.update(frame: frame, targetWid: targetWid)
                    }
                }
            }
        }
        await driver.run(on: screen)
        let resourceEnd = ProcessResourceSnapshot.capture()
        let finalSurfaceIds = surfaceIds(legacy: legacy, segmented: segmented)

        legacy?.destroy()
        segmented?.destroy()
        let surfacesReleased = initialSurfaceIds.allSatisfy {
            SkyLight.shared.getWindowBounds($0) == nil
        }
        let resourceDelta = resourceStart.flatMap { start in
            resourceEnd.flatMap { start.delta(to: $0) }
        }
        let frameCount = max(1, driver.applyDurations.count)
        let frameDivisor = Double(frameCount)
        return BorderRun(
            implementation: implementation,
            scenario: scenario,
            repetition: repetition,
            frames: frameCount,
            refreshPeriodMicroseconds: driver.refreshPeriod * 1_000_000,
            applyP50Microseconds: percentile(driver.applyDurations, 0.50) * 1_000_000,
            applyP95Microseconds: percentile(driver.applyDurations, 0.95) * 1_000_000,
            updateP95Microseconds: percentile(driver.updateDurations, 0.95) * 1_000_000,
            applyP99Microseconds: percentile(driver.applyDurations, 0.99) * 1_000_000,
            intervalP99Microseconds: percentile(driver.callbackIntervals, 0.99) * 1_000_000,
            droppedCallbacks: driver.droppedCallbacks,
            processCPUMicrosecondsPerFrame: resourceDelta.map {
                ($0.userSeconds + $0.systemSeconds) * 1_000_000 / frameDivisor
            },
            processRunnableMicrosecondsPerFrame: resourceDelta.map {
                $0.runnableSeconds * 1_000_000 / frameDivisor
            },
            instructionsPerFrame: resourceDelta.map { Double($0.instructions) / frameDivisor },
            cyclesPerFrame: resourceDelta.map { Double($0.cycles) / frameDivisor },
            energyNanojoulesPerFrame: resourceDelta?.energyNanojoules.map { Double($0) / frameDivisor },
            surfaceCount: initialSurfaceIds.count,
            windowServerMemoryBytes: windowMemoryBytes,
            surfaceIdsStable: finalSurfaceIds == initialSurfaceIds,
            surfacesReleased: surfacesReleased
        )
    }

    private func runBorderOperationAudit(
        implementation: BorderImplementation,
        scenario: BorderScenario,
        frames: Int,
        baseFrame: CGRect
    ) -> BorderOperationAudit {
        let operationOwner = BorderAuditOperationOwner()
        let operations = operationOwner.makeOperations()
        let config = BorderConfig(enabled: true, width: 4, color: .systemBlue)
        let legacy = implementation == .legacySingle
            ? LegacySingleBorderProbe(config: config, operations: operations)
            : nil
        let segmented = implementation == .segmented
            ? BorderWindow(config: config, operations: operations)
            : nil
        let initialFrame = borderFrame(index: 0, scenario: scenario, baseFrame: baseFrame)
        if let legacy {
            _ = legacy.update(frame: initialFrame, targetWid: 1, forceOrdering: true)
        } else if let segmented {
            _ = segmented.update(frame: initialFrame, targetWid: 1, forceOrdering: true)
        }

        BorderOpMetricsRecorder.shared.beginCapture()
        for index in 1 ... frames {
            let frame = borderFrame(index: index, scenario: scenario, baseFrame: baseFrame)
            if let legacy {
                _ = legacy.update(frame: frame, targetWid: 1)
            } else if let segmented {
                _ = segmented.update(frame: frame, targetWid: 1)
            }
        }
        BorderOpMetricsRecorder.shared.endCapture()
        let metrics = BorderOpMetricsRecorder.shared.dump()
        legacy?.destroy()
        segmented?.destroy()
        return BorderOperationAudit(
            implementation: implementation,
            scenario: scenario,
            frames: frames,
            borderMetrics: metrics
        )
    }

    private func surfaceIds(
        legacy: LegacySingleBorderProbe?,
        segmented: BorderWindow?
    ) -> [UInt32] {
        if let wid = legacy?.windowId {
            return [wid]
        }
        return BorderWindow.SegmentKind.allCases.compactMap { segmented?.windowId(for: $0) }
    }

    private func windowServerMemoryBytes(for windowIds: [UInt32]) -> UInt64? {
        var total: UInt64 = 0
        for windowId in windowIds {
            guard let info = CGWindowListCopyWindowInfo(
                .optionIncludingWindow,
                CGWindowID(windowId)
            ) as? [[String: Any]],
                let value = info.first?[kCGWindowMemoryUsage as String] as? NSNumber
            else { return nil }
            total += value.uint64Value
        }
        return total
    }

    private func aggregate(_ runs: [BorderRun]) -> [BorderAggregate] {
        BorderScenario.allCases.flatMap { scenario -> [BorderAggregate] in
            [BorderImplementation.legacySingle, .segmented].compactMap { implementation -> BorderAggregate? in
                let matches = runs.filter {
                    $0.scenario == scenario && $0.implementation == implementation
                }
                guard !matches.isEmpty else { return nil }
                return BorderAggregate(
                    implementation: implementation,
                    scenario: scenario,
                    runs: matches.count,
                    frames: matches.reduce(0) { $0 + $1.frames },
                    applyP50Microseconds: median(matches.map(\.applyP50Microseconds)) ?? 0,
                    applyP95Microseconds: median(matches.map(\.applyP95Microseconds)) ?? 0,
                    updateP95Microseconds: median(matches.map(\.updateP95Microseconds)) ?? 0,
                    applyP99Microseconds: median(matches.map(\.applyP99Microseconds)) ?? 0,
                    processCPUMicrosecondsPerFrame: median(matches.compactMap(\.processCPUMicrosecondsPerFrame)),
                    processRunnableMicrosecondsPerFrame: median(
                        matches.compactMap(\.processRunnableMicrosecondsPerFrame)
                    ),
                    instructionsPerFrame: median(matches.compactMap(\.instructionsPerFrame)),
                    cyclesPerFrame: median(matches.compactMap(\.cyclesPerFrame)),
                    energyNanojoulesPerFrame: median(matches.compactMap(\.energyNanojoulesPerFrame)),
                    droppedCallbackRate: Double(matches.reduce(0) { $0 + $1.droppedCallbacks })
                        / Double(max(1, matches.reduce(0) { $0 + $1.frames }))
                )
            }
        }
    }

    private func borderFrame(index: Int, scenario: BorderScenario, baseFrame: CGRect) -> CGRect {
        let phase = Double(index % 180) / 180 * Double.pi * 2
        switch scenario {
        case .translation:
            return baseFrame.offsetBy(dx: CGFloat(sin(phase) * 180), dy: 0)
        case .horizontalResize:
            let widthDelta = CGFloat(sin(phase) * 190)
            return CGRect(
                x: baseFrame.midX - (baseFrame.width + widthDelta) / 2,
                y: baseFrame.minY,
                width: baseFrame.width + widthDelta,
                height: baseFrame.height
            )
        case .verticalResize:
            let heightDelta = CGFloat(cos(phase) * 120)
            return CGRect(
                x: baseFrame.minX,
                y: baseFrame.midY - (baseFrame.height + heightDelta) / 2,
                width: baseFrame.width,
                height: baseFrame.height + heightDelta
            )
        }
    }

    private func measurementFrame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(900, visible.width * 0.48)
        let height = min(620, visible.height * 0.48)
        return CGRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func makeMeasurementWindow(frame: CGRect) -> NSPanel {
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = NSColor(
            calibratedRed: 0.31,
            green: 0.13,
            blue: 0.43,
            alpha: 1
        )
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func scenarioIndex(_ scenario: BorderScenario) -> Int {
        BorderScenario.allCases.firstIndex(of: scenario) ?? 0
    }

    private var debugCompilationCondition: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * quantile).rounded(.toNearestOrAwayFromZero))
        return sorted[min(max(0, index), sorted.count - 1)]
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return percentile(values, 0.50)
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

    private func settle(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

@MainActor
private final class SurfaceMeasurementDisplayLinkDriver: NSObject {
    private let frames: Int
    private let apply: @MainActor (Int, (@MainActor () -> Void) -> Void) -> Void
    private var displayLink: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private var lastTimestamp: CFTimeInterval?
    private var index = 0

    private(set) var applyDurations: [Double] = []
    private(set) var updateDurations: [Double] = []
    private(set) var callbackIntervals: [Double] = []
    private(set) var droppedCallbacks = 0
    private(set) var refreshPeriod: Double = 0

    init(frames: Int, apply: @escaping @MainActor (Int, (@MainActor () -> Void) -> Void) -> Void) {
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
        refreshPeriod = link.duration
        if let lastTimestamp {
            let interval = link.timestamp - lastTimestamp
            callbackIntervals.append(interval)
            if link.duration > 0, interval > link.duration * 1.5 {
                droppedCallbacks += 1
            }
        }
        lastTimestamp = link.timestamp

        let started = CACurrentMediaTime()
        var updateElapsed = 0.0
        apply(index) { work in
            let updateStarted = CACurrentMediaTime()
            work()
            updateElapsed += CACurrentMediaTime() - updateStarted
        }
        applyDurations.append(CACurrentMediaTime() - started)
        updateDurations.append(updateElapsed)
        index += 1
        guard index >= frames else { return }

        link.remove(from: .main, forMode: .common)
        displayLink = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class LegacySingleBorderProbe {
    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig
    private var currentFrame: CGRect = .zero
    private var appliedFrame: CGRect = .zero
    private var origin: CGPoint = .zero
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetWid: UInt32 = 0
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadii = WindowCornerRadii(uniform: 9)
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null
    private let operations: BorderWindow.Operations

    init(config: BorderConfig, operations: BorderWindow.Operations = .live) {
        self.config = config
        self.operations = operations
    }

    isolated deinit {
        destroy()
    }

    func destroy() {
        context = nil
        if wid != 0 {
            operations.releaseBorderWindow(wid)
            wid = 0
        }
        isVisible = false
        lastOrderedTargetWid = 0
        currentCornerRadii = WindowCornerRadii(uniform: 9)
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetWid: UInt32,
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 9),
        forceOrdering: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        let scale = backingScale(for: targetFrame)
        let resolvedCornerRadii = cornerRadii.nonnegative

        var frame = targetFrame.roundedToPhysicalPixels(scale: scale)
        appliedFrame = frame
        origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
        frame.origin = .zero

        let createdWindow: Bool
        if wid == 0 {
            createWindow(frame: frame, scale: scale)
            guard wid != 0 else { return false }
            createdWindow = true
        } else {
            createdWindow = false
        }

        if scale != lastConfiguredScale, wid != 0 {
            operations.configureWindow(wid, Float(scale), false)
            lastConfiguredScale = scale
            needsRedraw = true
        }
        if frame.size != currentFrame.size {
            reshapeWindow(frame: frame)
            needsRedraw = true
        }
        if currentCornerRadii != resolvedCornerRadii {
            needsRedraw = true
        }
        currentFrame = frame
        currentCornerRadii = resolvedCornerRadii

        if needsRedraw {
            draw(frame: frame)
        }

        let needsOrdering = forceOrdering || createdWindow || !isVisible || lastOrderedTargetWid != targetWid
        move(relativeTo: targetWid, needsOrdering: needsOrdering)
        isVisible = true
        lastOrderedTargetWid = targetWid
        return true
    }

    private func backingScale(for targetFrame: CGRect) -> CGFloat {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return cachedScale
        }
        let backingInfo = operations.backingScaleForFrame(targetFrame)
        cachedScale = backingInfo.scale
        cachedScaleScreenFrame = backingInfo.screenFrame
        return cachedScale
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = operations.createBorderWindow(frame)
        guard wid != 0 else { return }
        operations.configureWindow(wid, Float(scale), false)
        lastConfiguredScale = scale
        operations.setWindowTags(wid, (1 << 1) | (1 << 9))
        operations.excludeFromScreencaptureSelection(wid)
        guard let context = operations.createWindowContext(wid) else {
            operations.releaseBorderWindow(wid)
            wid = 0
            return
        }
        context.interpolationQuality = .none
        self.context = context
    }

    private func reshapeWindow(frame: CGRect) {
        BorderOpMetricsRecorder.shared.noteReshape()
        operations.setWindowShape(wid, frame)
    }

    private func draw(frame: CGRect) {
        guard let context else { return }
        needsRedraw = false
        BorderOpMetricsRecorder.shared.noteRedraw(rasterizedArea: frame.width * frame.height)

        let borderWidth = config.width
        let outerRadii = currentCornerRadii.adding(borderWidth)
        context.saveGState()
        context.clear(frame)
        let innerPath = BorderWindow.roundedRectPath(
            in: frame.insetBy(dx: borderWidth, dy: borderWidth),
            radii: currentCornerRadii
        )
        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        context.addPath(clipPath)
        context.clip(using: .evenOdd)
        context.setFillColor(config.color.cgColor)
        context.addPath(BorderWindow.roundedRectPath(in: frame, radii: outerRadii))
        context.fillPath()
        context.restoreGState()
        context.flush()
        operations.flushWindow(wid)
        BorderOpMetricsRecorder.shared.noteFlush()
    }

    private func move(relativeTo targetWid: UInt32, needsOrdering: Bool) {
        if needsOrdering {
            BorderOpMetricsRecorder.shared.noteMoveAndOrder()
            operations.transactionMoveAndOrder(
                wid,
                origin,
                3,
                targetWid,
                .below
            )
            return
        }
        BorderOpMetricsRecorder.shared.noteMoveOnly()
        operations.transactionMove(wid, origin)
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }
}

@MainActor
private final class BorderAuditOperationOwner {
    private var nextWindowId: UInt32 = 10

    func makeOperations() -> BorderWindow.Operations {
        BorderWindow.Operations(
            createBorderWindow: { _ in
                self.nextWindowId += 1
                return self.nextWindowId
            },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            excludeFromScreencaptureSelection: { _ in },
            createWindowContext: { _ in
                CGContext(
                    data: nil,
                    width: 4,
                    height: 4,
                    bitsPerComponent: 8,
                    bytesPerRow: 16,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            },
            setWindowShape: { _, _ in },
            flushWindow: { _ in },
            transactionMove: { _, _ in },
            transactionMoveAndOrder: { _, _, _, _, _ in },
            transactionHide: { _ in },
            withTransactionScope: { body in body() },
            backingScaleForFrame: { _ in
                (
                    scale: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
                )
            }
        )
    }
}
