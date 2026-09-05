// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

final class BorderSurfaceTests: XCTestCase {
    @MainActor
    private final class RecordingLayerPanel: BorderLayerPanel {
        var orders: [(NSWindow.OrderingMode, Int, Int)] = []
        var presentationEvents: [String] = []
        var invalidWindowNumber = false

        override var windowNumber: Int {
            invalidWindowNumber ? 0 : super.windowNumber
        }

        var shows = 0
        var hides = 0
        var closes = 0

        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            orders.append((place, otherWin, level.rawValue))
        }

        override func orderFront(_ sender: Any?) {
            shows += 1
            presentationEvents.append("show")
        }

        override func orderOut(_ sender: Any?) {
            hides += 1
            super.orderOut(sender)
        }

        override func close() {
            closes += 1
            super.close()
        }
    }

    @MainActor
    private final class BorderOperationsRecorder {
        struct OrderCall: Equatable {
            let windowId: UInt32
            let targetWindowId: UInt32
            let level: Int
            let order: SkyLightWindowOrder
        }

        struct RGBA8: Equatable {
            let red: UInt8
            let green: UInt8
            let blue: UInt8
            let alpha: UInt8
        }

        var layerPanels: [RecordingLayerPanel] = []
        var screencaptureExclusionCount = 0
        var windowInfoQueryCount = 0
        var backingScaleQueryCount = 0
        var backingScale: CGFloat = 2
        var screenFrame = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        var contextsByWindowId: [UInt32: CGContext] = [:]
        var orderCalls: [OrderCall] = []
        var failsNextCreation = false
        var windowInfoProvider: @MainActor (UInt32) -> WindowServerInfo? = {
            WindowServerInfo(id: $0, pid: 1234, level: 0, frame: .zero)
        }

        func operations() -> BorderWindow.Operations {
            BorderWindow.Operations(
                createLayerPanel: { [weak self] frame in
                    _ = NSApplication.shared
                    let panel = RecordingLayerPanel(frame: frame)
                    panel.invalidWindowNumber = self?.failsNextCreation == true
                    self?.failsNextCreation = false
                    self?.layerPanels.append(panel)
                    return panel
                },
                excludeFromScreencaptureSelection: { [weak self] _ in self?.screencaptureExclusionCount += 1 },
                queryWindowInfoDeferred: { [weak self] windowId in
                    guard let self else { return nil }
                    windowInfoQueryCount += 1
                    return windowInfoProvider(windowId)
                },
                backingScaleForFrame: { [weak self] _ in
                    guard let self else { return (2, .null) }
                    backingScaleQueryCount += 1
                    return (backingScale, screenFrame)
                },
                orderWindow: { [weak self] wid, targetWid, order in
                    guard let self, let panel = layerPanels.first(where: { $0.windowNumber == Int(wid) }) else {
                        XCTFail("Direct order must use the owned panel")
                        return
                    }
                    panel.presentationEvents.append("order")
                    orderCalls.append(OrderCall(
                        windowId: wid, targetWindowId: targetWid, level: panel.level.rawValue, order: order
                    ))
                }
            )
        }

        func rasterize(_ panel: RecordingLayerPanel) throws {
            let context = try XCTUnwrap(Self.makeContext(size: panel.borderLayer.bounds.size))
            panel.borderLayer.render(in: context)
            contextsByWindowId[UInt32(panel.windowNumber)] = context
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
    private final class DeferredLevelProbe {
        var requests: [UInt32] = []
        var onRequest: (() -> Void)?
        private var continuation: CheckedContinuation<WindowServerInfo?, Never>?

        func query(_ windowId: UInt32) async -> WindowServerInfo? {
            await withCheckedContinuation {
                XCTAssertNil(continuation)
                continuation = $0
                requests.append(windowId)
                onRequest?()
            }
        }

        func complete(_ info: WindowServerInfo?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: info)
        }

        func operations(_ recorder: BorderOperationsRecorder) -> BorderWindow.Operations {
            var operations = recorder.operations()
            operations.queryWindowInfoDeferred = { await self.query($0) }
            return operations
        }
    }

    @MainActor
    private final class DeferredCornerProbe {
        var requests: [WindowToken] = []
        var onRequest: (() -> Void)?
        private var continuation: CheckedContinuation<WindowCornerSample?, Error>?

        func query(_ token: WindowToken) async throws -> WindowCornerSample? {
            try await withCheckedThrowingContinuation {
                XCTAssertNil(continuation)
                continuation = $0
                requests.append(token)
                onRequest?()
            }
        }

        func complete(_ sample: WindowCornerSample?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: sample)
        }

        func applier(_ recorder: BorderOperationsRecorder) -> BorderSurfaceApplier {
            BorderSurfaceApplier(
                borderWindowOperations: recorder.operations(),
                cornerSampleProvider: { try await self.query($0) }
            )
        }
    }

    @MainActor
    private func makeApplier(
        _ recorder: BorderOperationsRecorder,
        cornerSampleProvider: @escaping @MainActor (WindowToken) async throws -> WindowCornerSample? = { _ in nil }
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
    private func reconcileFixture() throws -> (controller: WMController, entry: WindowState) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderMotionQueryTests")
        controller.settings.workspaceBarEnabled = false
        controller.settings.bordersEnabled = true
        let monitor = Monitor(
            id: .init(displayId: 814_101), displayId: 814_101,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: .zero,
            hasNotch: false, name: "Border Motion"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(monitor.displayId), spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [], windowSpace: [:]
        ))
        let token = WindowToken(pid: 814_102, windowId: 814_103)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(token, in: workspaceId))
        controller.hasStartedServices = true
        return (controller, try XCTUnwrap(controller.workspaceManager.entry(for: token)))
    }

    @MainActor
    private func startViewportMotion(_ controller: WMController, workspaceId: WorkspaceDescriptor.ID) {
        let previous = ViewportState()
        var next = previous
        next.springOffset(to: 500)
        controller.workspaceManager.animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId, previous: previous, next: next,
            transition: next.offsetTransition, at: 0
        )
    }

    @MainActor
    func testScheduledReconcilesDrawDuringMotionAndSampleCornersAfterSettlement() async throws {
        for fullScene in [false, true] {
            let (controller, entry) = try reconcileFixture()
            let recorder = BorderOperationsRecorder()
            recorder.windowInfoProvider = { WindowServerInfo(id: $0, pid: entry.pid, level: 0, frame: .zero) }
            var queries = 0
            let applier = makeApplier(recorder) { _ in
                queries += 1
                return self.sample(WindowCornerRadii(uniform: 13))
            }
            let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
            let resolved = expectation(description: "eligible corners resolved")
            let notify = applier.onCornerSampleResolved
            applier.onCornerSampleResolved = { notify?()
                resolved.fulfill()
            }
            defer {
                controller.hasStartedServices = false
                reconciler.cleanup()
            }
            startViewportMotion(controller, workspaceId: entry.workspaceId)
            if fullScene {
                reconciler.noteWorldChanged()
            } else {
                reconciler.noteBorderChanged()
            }

            reconciler.reconcileNow()

            XCTAssertEqual(queries, 0)
            XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
            XCTAssertEqual(reconciler.appliedScene.border?.frame, frame)
            XCTAssertNotNil(recorder.layerPanels.first?.borderLayer.path)
            XCTAssertFalse(reconciler.reconcileScheduled)
            XCTAssertFalse(controller.workspaceManager.animationDriver.tick(in: entry.workspaceId, at: 1000))
            reconciler.noteRestackOccurred()
            reconciler.reconcileAnimationTick()
            XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
            XCTAssertEqual(queries, 0)

            reconciler.reconcileNow()
            reconciler.noteBorderChanged()
            reconciler.reconcileNow()

            await fulfillment(of: [resolved], timeout: 1)
            reconciler.reconcileNow()
            XCTAssertEqual(queries, 1)
            XCTAssertNotNil(recorder.layerPanels.first?.borderLayer.path)
            XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
        }
    }

    @MainActor
    func testSettledCornerRefreshWaitsForPendingFrameVerification() async throws {
        let (controller, entry) = try reconcileFixture()
        let recorder = BorderOperationsRecorder()
        var queries = 0
        let pendingFrame = frame.offsetBy(dx: 20, dy: 0)
        let applier = makeApplier(recorder) { _ in
            queries += 1
            return self.sample(WindowCornerRadii(uniform: 13))
        }
        let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
        let resolved = expectation(description: "eligible corners resolved")
        let notify = applier.onCornerSampleResolved
        applier.onCornerSampleResolved = { notify?()
            resolved.fulfill()
        }
        defer {
            controller.hasStartedServices = false
            reconciler.cleanup()
        }
        startViewportMotion(controller, workspaceId: entry.workspaceId)
        let request = try XCTUnwrap(controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
            pid: entry.pid, window: entry.axRef, frame: pendingFrame
        )))
        XCTAssertFalse(controller.workspaceManager.animationDriver.tick(in: entry.workspaceId, at: 1000))
        reconciler.noteRestackOccurred()
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(reconciler.appliedScene.border?.frame, pendingFrame)

        let result = WindowAdmissionTestSupport.successfulFrameResult(request: request)
        controller.axManager.handleFrameApplyResults([result])
        reconciler.handleVerifiedFrameApplySuccess(result)
        reconciler.reconcileNow()

        await fulfillment(of: [resolved], timeout: 1)
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
    }

    @MainActor
    func testViewportMotionInAnotherWorkspaceDoesNotDeferBorderCorners() async throws {
        let (controller, entry) = try reconcileFixture()
        let recorder = BorderOperationsRecorder()
        var queries = 0
        let applier = makeApplier(recorder) { _ in
            queries += 1
            return self.sample(WindowCornerRadii(uniform: 13))
        }
        let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
        let resolved = expectation(description: "eligible corners resolved")
        let notify = applier.onCornerSampleResolved
        applier.onCornerSampleResolved = { notify?()
            resolved.fulfill()
        }
        defer {
            controller.hasStartedServices = false
            reconciler.cleanup()
        }
        startViewportMotion(controller, workspaceId: WorkspaceDescriptor.ID())
        reconciler.noteBorderChanged()
        reconciler.reconcileNow()

        await fulfillment(of: [resolved], timeout: 1)
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
    }

    @MainActor
    func testRepeatedIdenticalApplyIsNoOp() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let pathAfterFirst = recorder.layerPanels.first?.borderLayer.path
        let orderingAfterFirst = recorder.orderCalls.count

        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(recorder.layerPanels.first?.borderLayer.path === pathAfterFirst)
        XCTAssertEqual(recorder.orderCalls.count, orderingAfterFirst)
    }

    @MainActor
    func testForceOrderingReordersWithoutRedraw() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let pathAfterFirst = recorder.layerPanels.first?.borderLayer.path
        let moveAndOrdersAfterFirst = recorder.orderCalls.count

        _ = applier.apply(desired(configRed), forceOrdering: true)

        XCTAssertTrue(recorder.layerPanels.first?.borderLayer.path === pathAfterFirst)
        XCTAssertGreaterThan(recorder.orderCalls.count, moveAndOrdersAfterFirst)
    }

    @MainActor
    func testFailedCreateReturnsFalseThenRetries() {
        let recorder = BorderOperationsRecorder()
        recorder.failsNextCreation = true
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let firstApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertFalse(firstApplied.didApply)
        XCTAssertEqual(recorder.layerPanels.first?.closes, 1)

        let secondApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertTrue(secondApplied.didApply)
        XCTAssertEqual(recorder.layerPanels.count, 2)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: recorder.layerPanels[1].windowNumber))
    }

    @MainActor
    func testConfigResyncedAfterHide() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(nil, forceOrdering: false)
        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.fillColor?.components, [1, 0, 0, 1])

        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.fillColor?.components, [0, 0, 1, 1])
    }

    @MainActor
    func testLayerBorderPreservesSurfaceLifecycle() throws {
        let recorder = BorderOperationsRecorder()
        let applier = BorderSurfaceApplier(
            borderWindowOperations: recorder.operations(),
            cornerSampleProvider: { _ in nil }
        )
        defer { applier.cleanup() }
        XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let id = panel.windowNumber
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: id))
        XCTAssertFalse(SurfaceCoordinator.shared.isCaptureEligible(windowNumber: id))
        XCTAssertEqual(recorder.screencaptureExclusionCount, 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertEqual(panel.borderLayer.fillRule, .evenOdd)
        XCTAssertNil(panel.borderLayer.strokeColor)
        XCTAssertFalse(panel.contentView?.isFlipped ?? true)
        XCTAssertFalse(panel.borderLayer.isGeometryFlipped)
        XCTAssertNil(panel.borderLayer.animationKeys())
        for key in ["path", "fillColor", "bounds", "position", "contentsScale"] {
            XCTAssertTrue(panel.borderLayer.actions?[key] is NSNull)
        }
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(panel.presentationEvents, ["show", "order"])
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(recorder.orderCalls[0].order, .below)
        XCTAssertEqual(recorder.orderCalls[0].targetWindowId, UInt32(token().windowId))

        _ = applier.apply(nil, forceOrdering: false)
        XCTAssertGreaterThanOrEqual(panel.hides, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: id))
        _ = applier.apply(desired(configBlue), forceOrdering: false)
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertEqual(panel.shows, 2)
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "show", "order"])
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: id))
        applier.cleanup()
        XCTAssertEqual(panel.closes, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: id))
    }

    @MainActor
    func testLayerBorderTranslationResizeScaleAndColorKeepOnePanel() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        recorder.windowInfoProvider = { WindowServerInfo(id: $0, pid: 1234, level: 8, frame: .zero) }
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let path = try XCTUnwrap(panel.borderLayer.path)
        let translated = frame.offsetBy(dx: -4000, dy: 3000)
        XCTAssertTrue(window.update(frame: translated, targetToken: token()))
        XCTAssertEqual(panel.frame, translated.insetBy(dx: -4, dy: -4))
        XCTAssertTrue(panel.borderLayer.path === path)
        XCTAssertEqual(recorder.windowInfoQueryCount, 0)
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(recorder.orderCalls[0].level, 0)

        let resized = CGRect(x: 50, y: 80, width: 900, height: 700)
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.frame, resized.insetBy(dx: -4, dy: -4))
        XCTAssertEqual(panel.borderLayer.bounds.size, panel.frame.size)
        XCTAssertFalse(panel.borderLayer.path === path)
        window.updateConfig(configBlue)
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.borderLayer.fillColor?.components, [0, 0, 1, 1])
        recorder.backingScale = 2
        window.invalidateScaleCache()
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.borderLayer.contentsScale, 2)
        let scaledPath = try XCTUnwrap(panel.borderLayer.path)
        let fractional = resized.offsetBy(dx: 0.5, dy: -0.5)
        XCTAssertTrue(window.update(frame: fractional, targetToken: token()))
        XCTAssertEqual(panel.frame, fractional.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(
            panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
            fractional.insetBy(dx: -4, dy: -4)
        )
        XCTAssertTrue(panel.borderLayer.path === scaledPath)
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertNil(panel.borderLayer.animationKeys())
    }

    @MainActor
    func testLayerBorderDirectOrderingRetargetsWithoutShowingAgain() throws {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        for offset in 1 ... 100 {
            XCTAssertTrue(window.update(frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token()))
        }
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(panel.shows, 1)

        let next = token(windowId: 78)
        XCTAssertTrue(window.update(frame: frame, targetToken: next))
        XCTAssertTrue(window.update(frame: frame, targetToken: next, forceOrdering: true))
        window.reorder(relativeTo: next)
        XCTAssertEqual(recorder.orderCalls.map(\.targetWindowId), [77, 78, 78, 78])
        XCTAssertTrue(recorder.orderCalls.allSatisfy { $0.order == .below })
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "order", "order", "order"])
        XCTAssertEqual(panel.shows, 1)
        XCTAssertTrue(panel.orders.isEmpty)

        window.hide()
        window.reorder(relativeTo: next)
        XCTAssertEqual(panel.shows, 2)
        XCTAssertEqual(Array(panel.presentationEvents.suffix(2)), ["show", "order"])
        window.destroy()
        XCTAssertEqual(panel.closes, 1)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let recreated = try XCTUnwrap(recorder.layerPanels.last)
        XCTAssertFalse(recreated === panel)
        XCTAssertEqual(recreated.presentationEvents, ["show", "order"])
        XCTAssertEqual(recorder.orderCalls.last?.windowId, UInt32(recreated.windowNumber))
        XCTAssertEqual(recorder.orderCalls.last?.targetWindowId, 77)
    }

    @MainActor
    func testLayerBorderDeferredLevelUsesDirectOrderWithoutAnotherShow() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        defer { window.destroy() }
        let started = expectation(description: "level query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "level query resolved")
        window.onWindowLevelResolved = { resolved.fulfill() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let latestFrame = frame.offsetBy(dx: 120, dy: 0)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.map(\.level), [0])
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.map(\.level), [0, 8])
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "order"])
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(probe.requests, [77])
        XCTAssertEqual(panel.frame, latestFrame.insetBy(dx: -4, dy: -4).integral)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.count, 2)
    }

    @MainActor
    func testLayerBorderRasterPreservesFractionalWidthAndAsymmetricTransparentCutout() throws {
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let radii = WindowCornerRadii(topLeft: 22, topRight: 0, bottomLeft: 0, bottomRight: 11)
        let config = BorderConfig(enabled: true, width: 4.5, color: configRed.color)
        for scale: CGFloat in [1, 2] {
            let recorder = BorderOperationsRecorder()
            recorder.backingScale = scale
            let window = BorderWindow(config: config, operations: recorder.operations())
            defer { window.destroy() }
            XCTAssertTrue(window.update(frame: target, targetToken: token(), cornerRadii: radii))
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            let geometry = config.resolvedGeometry(for: target, scale: scale)
            let context = try XCTUnwrap(BorderOperationsRecorder.makeContext(size: CGSize(
                width: geometry.surfaceFrame.width * scale, height: geometry.surfaceFrame.height * scale
            )))
            context.scaleBy(x: scale, y: scale)
            panel.borderLayer.render(in: context)
            let id = UInt32(panel.windowNumber)
            recorder.contextsByWindowId[id] = context
            let w = geometry.width
            func pixel(_ x: CGFloat, _ y: CGFloat) -> BorderOperationsRecorder.RGBA8? {
                recorder.pixel(windowId: id, x: Int(x * scale), y: context.height - 1 - Int(y * scale))
            }
            let red = BorderOperationsRecorder.RGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            XCTAssertEqual(pixel(w + 50, w / 2), red)
            XCTAssertEqual(pixel(w + 50, w + 40)?.alpha, 0)
            XCTAssertEqual(pixel(w + 0.5, w + 40)?.alpha, 0)
            let cornerInset = w * 0.7
            XCTAssertEqual(pixel(cornerInset, cornerInset), red)
            XCTAssertEqual(pixel(cornerInset, geometry.surfaceFrame.height - cornerInset)?.alpha, 0)
            XCTAssertEqual(pixel(geometry.surfaceFrame.width - cornerInset, cornerInset)?.alpha, 0)
            XCTAssertEqual(
                pixel(geometry.surfaceFrame.width - cornerInset, geometry.surfaceFrame.height - cornerInset), red
            )
            XCTAssertEqual(panel.frame, geometry.surfaceFrame.integral)
            XCTAssertEqual(
                panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                geometry.surfaceFrame
            )
        }
    }

    @MainActor
    func testExteriorAnnulusExpandsSurfaceAndKeepsTargetSilhouetteTransparent() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let windowId = try XCTUnwrap(window.windowId)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        try recorder.rasterize(panel)
        let redPixel = BorderOperationsRecorder.RGBA8(red: 255, green: 0, blue: 0, alpha: 255)

        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 6, y: 16, width: 108, height: 88))
        XCTAssertEqual(panel.borderLayer.bounds, CGRect(x: 0, y: 0, width: 108, height: 88))
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
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        try recorder.rasterize(panel)

        XCTAssertEqual(config.resolvedGeometry(for: target, scale: 1).width, 5)
        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 5, y: 15, width: 110, height: 90))
        XCTAssertEqual(panel.borderLayer.bounds, CGRect(x: 0, y: 0, width: 110, height: 90))
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 55, y: 4)?.alpha, 255)
        XCTAssertEqual(recorder.pixel(windowId: windowId, x: 55, y: 5)?.alpha, 0)
    }

    @MainActor
    func testScaleInvalidationBypassesApplierEqualityAndReconfiguresExistingSurface() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder) { _ in
            self.sample(WindowCornerRadii(uniform: 9))
        }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let scaleQueries = recorder.backingScaleQueryCount
        recorder.backingScale = 1
        let creationCount = recorder.layerPanels.count

        applier.invalidateDisplayScale()
        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.backingScaleQueryCount, scaleQueries + 1)
        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.contentsScale, 1)
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
    }

    @MainActor
    func testWidthChangeReshapesExistingSurfaceAroundUnchangedTarget() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let originalPath = recorder.layerPanels.first?.borderLayer.path
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
        XCTAssertNotEqual(recorder.layerPanels.first?.borderLayer.path, originalPath)
        XCTAssertEqual(recorder.layerPanels.count, 1)
    }

    @MainActor
    func testFiveHundredSameDisplayTranslationsAvoidLevelAndScaleQueriesReshapesAndRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let queryCount = recorder.windowInfoQueryCount
        let backingScaleQueryCount = recorder.backingScaleQueryCount
        let originalPath = recorder.layerPanels.first?.borderLayer.path
        let creationCount = recorder.layerPanels.count
        let orderCount = recorder.orderCalls.count

        for offset in 1 ... 500 {
            _ = window.update(
                frame: frame.offsetBy(dx: CGFloat(offset), dy: CGFloat(offset % 20)),
                targetToken: target
            )
        }

        XCTAssertEqual(recorder.windowInfoQueryCount, queryCount)
        XCTAssertEqual(recorder.backingScaleQueryCount, backingScaleQueryCount)
        XCTAssertTrue(recorder.layerPanels.first?.borderLayer.path === originalPath)
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
        XCTAssertEqual(recorder.orderCalls.count, orderCount)
        XCTAssertEqual(
            recorder.layerPanels.first?.frame,
            frame.offsetBy(dx: 500, dy: 0).insetBy(dx: -4, dy: -4).integral
        )
    }

    @MainActor
    func testOneHundredResizesReusePanelAndUpdateLayerGeometry() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let originalPath = recorder.layerPanels.first?.borderLayer.path
        let creationCount = recorder.layerPanels.count

        for delta in 1 ... 100 {
            _ = window.update(
                frame: CGRect(
                    origin: frame.origin,
                    size: CGSize(width: frame.width + CGFloat(delta), height: frame.height)
                ),
                targetToken: target
            )
        }

        XCTAssertNotEqual(recorder.layerPanels.first?.borderLayer.path, originalPath)
        XCTAssertEqual(
            recorder.layerPanels.first?.borderLayer.bounds.size,
            CGSize(width: frame.width + 108, height: frame.height + 8)
        )
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
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
        let pathAfterFirst = recorder.layerPanels.first?.borderLayer.path

        _ = window.update(
            frame: target,
            targetToken: token(windowId: 55),
            cornerRadii: WindowCornerRadii(topLeft: 11.5, topRight: 9, bottomLeft: 8.5, bottomRight: 7)
        )
        XCTAssertNotEqual(recorder.layerPanels.first?.borderLayer.path, pathAfterFirst)
    }

    @MainActor
    func testDeinitClosesLayerPanel() throws {
        let recorder = BorderOperationsRecorder()
        var window: BorderWindow? = BorderWindow(config: configRed, operations: recorder.operations())
        XCTAssertTrue(window?.update(frame: frame, targetToken: token()) == true)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        window = nil
        XCTAssertEqual(panel.closes, 1)
    }

    @MainActor
    func testDeferredCornersDoNotInheritAnotherTargetsCache() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let started = expectation(description: "first target query")
        probe.onRequest = { started.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let fallback = panel.borderLayer.path
        let resolved = expectation(description: "first target cache")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertNotEqual(panel.borderLayer.path, fallback)
        _ = applier.apply(
            desired(configRed, token: token(windowId: 78)),
            forceOrdering: false, refreshCornerRadii: false
        )
        XCTAssertEqual(panel.borderLayer.path, fallback)
        XCTAssertEqual(probe.requests, [token()])
    }

    @MainActor
    func testDeferredCornersRearmExhaustedRetryAfterSettledSizeChangeOrHide() async {
        for hide in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            for attempt in 0 ..< 2 {
                let started = expectation(description: "query")
                probe.onRequest = { started.fulfill() }
                let resolved = expectation(description: "first failure schedules retry")
                resolved.isInverted = attempt == 1
                applier.onCornerSampleResolved = { resolved.fulfill() }
                _ = applier.apply(desired(configRed), forceOrdering: false)
                await fulfillment(of: [started], timeout: 1)
                probe.complete(nil)
                await fulfillment(of: [resolved], timeout: attempt == 1 ? 0.05 : 1)
            }
            if hide { _ = applier.apply(nil, forceOrdering: false) }
            let newFrame = hide ? frame : frame.insetBy(dx: -20, dy: 0)
            let started = expectation(description: "new geometry rearms query")
            probe.onRequest = { started.fulfill() }
            _ = applier.apply(desired(configRed, frame: newFrame), forceOrdering: false)
            await fulfillment(of: [started], timeout: 1)
            let resolved = expectation(description: "new geometry accepted")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 12), size: newFrame.size))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed, frame: newFrame), forceOrdering: false)
            XCTAssertEqual(probe.requests.count, 3)
        }
    }

    @MainActor
    func testDeferredCornersKeepMovingAndReconcileCurrentGeometry() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let started = expectation(description: "corner query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "corners resolved")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let fallbackPath = panel.borderLayer.path
        var latest = frame
        for offset in 1 ... 500 {
            latest = frame.offsetBy(dx: CGFloat(offset), dy: 0)
            let outcome = applier.apply(
                desired(configRed, frame: latest), forceOrdering: false, refreshCornerRadii: offset % 2 == 0
            )
            XCTAssertTrue(outcome.didApply)
        }
        XCTAssertEqual(probe.requests, [token()])
        XCTAssertEqual(panel.frame, latest.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(panel.borderLayer.path, fallbackPath)
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed, frame: latest), forceOrdering: false)
        XCTAssertNotEqual(panel.borderLayer.path, fallbackPath)
        XCTAssertEqual(panel.frame, latest.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(recorder.orderCalls.last?.targetWindowId, 77)
        XCTAssertEqual(recorder.orderCalls.last?.order, .below)
        XCTAssertEqual(probe.requests, [token()])
    }

    @MainActor
    func testDeferredCornersRejectTokenAndSizeABAAndCoalesceLatestRequest() async throws {
        for changeSize in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "first query")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            _ = applier.apply(desired(
                configRed,
                token: changeSize ? token() : token(windowId: 78),
                frame: changeSize ? frame.insetBy(dx: -10, dy: 0) : frame
            ), forceOrdering: false)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            let fallbackPath = panel.borderLayer.path
            let newest = expectation(description: "latest query")
            probe.onRequest = { newest.fulfill() }
            var resolvedCount = 0
            applier.onCornerSampleResolved = { resolvedCount += 1 }
            probe.complete(sample(WindowCornerRadii(uniform: 30)))
            await fulfillment(of: [newest], timeout: 1)
            XCTAssertEqual(resolvedCount, 0)
            XCTAssertEqual(panel.borderLayer.path, fallbackPath)
            XCTAssertEqual(probe.requests, [token(), token()])
            let resolved = expectation(description: "current sample")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 15)))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            XCTAssertNotEqual(panel.borderLayer.path, fallbackPath)
        }
    }

    @MainActor
    func testDeferredCornersLifecycleInvalidationRejectsEnteredRead() async throws {
        for invalidation in 0 ..< 3 {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "old lifetime")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            switch invalidation {
            case 0: _ = applier.apply(nil, forceOrdering: false)
            case 1: applier.cleanup()
            default: applier.invalidateDisplayScale()
            }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            let latest = expectation(description: "new lifetime")
            probe.onRequest = { latest.fulfill() }
            var notifications = 0
            applier.onCornerSampleResolved = { notifications += 1 }
            probe.complete(sample(WindowCornerRadii(uniform: 30)))
            await fulfillment(of: [latest], timeout: 1)
            XCTAssertEqual(notifications, 0)
            XCTAssertEqual(probe.requests, [token(), token()])
            let resolved = expectation(description: "current lifetime")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 15)))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            XCTAssertEqual(recorder.layerPanels.count, invalidation == 1 ? 2 : 1)
        }
    }

    @MainActor
    func testDeferredCornersDoNotRestartWhileHiddenOrAnimating() async {
        for hide in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "entered read")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            if hide {
                _ = applier.apply(nil, forceOrdering: false)
            } else {
                _ = applier.apply(
                    desired(configRed, frame: frame.insetBy(dx: -20, dy: 0)),
                    forceOrdering: false, refreshCornerRadii: false
                )
            }
            let unexpected = expectation(description: "no query or notification")
            unexpected.isInverted = true
            probe.onRequest = { unexpected.fulfill() }
            applier.onCornerSampleResolved = { unexpected.fulfill() }
            probe.complete(nil)
            await fulfillment(of: [unexpected], timeout: 0.05)
            XCTAssertEqual(probe.requests.count, 1)
            let settled = expectation(description: "settled query")
            probe.onRequest = { settled.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [settled], timeout: 1)
            let accepted = expectation(description: "stale failure did not spend current retry")
            applier.onCornerSampleResolved = { accepted.fulfill() }
            probe.complete(nil)
            await fulfillment(of: [accepted], timeout: 1)
        }
    }

    @MainActor
    func testDeferredCornersActualFailuresExhaustOnlyOneRetry() async {
        for invalid in [
            nil,
            sample(WindowCornerRadii(uniform: 20), size: CGSize(width: 400, height: 150)),
            sample(WindowCornerRadii(uniform: 20), size: .zero)
        ] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            for attempt in 0 ..< 2 {
                let started = expectation(description: "query \(attempt)")
                probe.onRequest = { started.fulfill() }
                let resolved = expectation(description: "retry only on first failure")
                resolved.isInverted = attempt == 1
                applier.onCornerSampleResolved = { resolved.fulfill() }
                _ = applier.apply(desired(configRed), forceOrdering: false)
                await fulfillment(of: [started], timeout: 1)
                for _ in 0 ..< 50 {
                    XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
                }
                probe.complete(invalid)
                await fulfillment(of: [resolved], timeout: attempt == 1 ? 0.05 : 1)
            }
            let unexpected = expectation(description: "exhausted budget")
            unexpected.isInverted = true
            probe.onRequest = { unexpected.fulfill() }
            _ = applier.apply(
                desired(configRed, frame: frame.insetBy(dx: -10, dy: 0)),
                forceOrdering: false, refreshCornerRadii: false
            )
            for _ in 0 ..< 50 {
                XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
            }
            await fulfillment(of: [unexpected], timeout: 0.05)
            XCTAssertEqual(probe.requests.count, 2)
        }
    }

    @MainActor
    func testDeferredCornersReuseCacheUntilCurrentSizeIsAccepted() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let first = expectation(description: "initial query")
        probe.onRequest = { first.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [first], timeout: 1)
        let resolved = expectation(description: "initial corners")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed), forceOrdering: false)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let resized = frame.insetBy(dx: -20, dy: 0)
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false, refreshCornerRadii: false)
        let cachedPath = panel.borderLayer.path
        let refresh = expectation(description: "size refresh")
        probe.onRequest = { refresh.fulfill() }
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertEqual(panel.borderLayer.path, cachedPath)
        let retry = expectation(description: "old size rejected")
        applier.onCornerSampleResolved = { retry.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 30)))
        await fulfillment(of: [retry], timeout: 1)
        let retryStarted = expectation(description: "retry")
        probe.onRequest = { retryStarted.fulfill() }
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(panel.borderLayer.path, cachedPath)
        let accepted = expectation(description: "current size accepted")
        applier.onCornerSampleResolved = { accepted.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 12), size: resized.size))
        await fulfillment(of: [accepted], timeout: 1)
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        XCTAssertNotEqual(panel.borderLayer.path, cachedPath)
        XCTAssertEqual(probe.requests.count, 3)
    }

    @MainActor
    func testDeferredLevelKeepsMovingAndAppliesLatestFrameWithoutAnotherQuery() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let applier = BorderSurfaceApplier(
            borderWindowOperations: probe.operations(recorder),
            cornerSampleProvider: { _ in nil }
        )
        defer { applier.cleanup() }
        let started = expectation(description: "query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "level resolved")
        applier.onWindowLevelResolved = { resolved.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [started], timeout: 1)
        var latestFrame = frame
        for offset in 1 ... 500 {
            latestFrame = frame.offsetBy(dx: CGFloat(offset), dy: 0)
            let outcome = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
            XCTAssertFalse(outcome.needsWindowLevelRetry)
        }
        XCTAssertEqual(probe.requests, [77])
        XCTAssertEqual(recorder.windowInfoQueryCount, 0)
        XCTAssertEqual(recorder.orderCalls.first?.level, 0)
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
        XCTAssertEqual(recorder.orderCalls.last?.level, 8)
        XCTAssertEqual(
            recorder.layerPanels.last?.frame,
            latestFrame.insetBy(dx: -4, dy: -4).integral
        )
        _ = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
        XCTAssertEqual(probe.requests, [77])
    }

    @MainActor
    func testDeferredLevelRejectsAtoBtoAAndCoalescesToLatestTarget() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        let first = expectation(description: "first A read")
        probe.onRequest = { first.fulfill() }
        _ = window.update(frame: frame, targetToken: token())
        await fulfillment(of: [first], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        _ = window.update(frame: frame, targetToken: token())
        let newest = expectation(description: "new A read")
        probe.onRequest = { newest.fulfill() }
        let resolved = expectation(description: "only current A accepted")
        window.onWindowLevelResolved = { resolved.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
        await fulfillment(of: [newest], timeout: 1)
        XCTAssertFalse(window.hasDeferredLevelUpdate)
        XCTAssertEqual(window.appliedTargetLevel, 0)
        XCTAssertEqual(probe.requests, [77, 77])
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 7, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token())
        XCTAssertEqual(window.appliedTargetLevel, 7)
        XCTAssertEqual(probe.requests.count, 2)
    }

    @MainActor
    func testDeferredLevelInvalidResultsRetryOnceWithoutFrameLoop() async {
        let invalid: [WindowServerInfo?] = [
            nil,
            WindowServerInfo(id: 78, pid: 1234, level: 8, frame: .zero),
            WindowServerInfo(id: 77, pid: 4321, level: 8, frame: .zero)
        ]
        for info in invalid {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredLevelProbe()
            let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
            for attempt in 0 ..< 2 {
                let started = expectation(description: "read \(attempt)")
                let resolved = expectation(description: "failure \(attempt)")
                probe.onRequest = { started.fulfill() }
                window.onWindowLevelResolved = { resolved.fulfill() }
                _ = window.update(frame: frame, targetToken: token())
                await fulfillment(of: [started], timeout: 1)
                let orderCount = recorder.orderCalls.count
                for offset in 1 ... 50 {
                    _ = window.update(
                        frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token()
                    )
                    XCTAssertFalse(window.needsWindowLevelRetry)
                }
                XCTAssertEqual(recorder.orderCalls.count, orderCount)
                probe.complete(info)
                await fulfillment(of: [resolved], timeout: 1)
                XCTAssertEqual(window.needsWindowLevelRetry, attempt == 0)
            }
            _ = window.update(frame: frame, targetToken: token())
            for offset in 1 ... 50 {
                _ = window.update(frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token())
            }
            XCTAssertFalse(window.needsWindowLevelRetry)
            XCTAssertEqual(probe.requests.count, 2)
            XCTAssertEqual(window.appliedTargetLevel, 0)
        }
    }

    @MainActor
    func testDeferredLevelHideAndDestroyRejectOldResultsBeforeSameTargetReturns() async {
        for destroy in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredLevelProbe()
            let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
            let first = expectation(description: "old instance read")
            probe.onRequest = { first.fulfill() }
            _ = window.update(frame: frame, targetToken: token())
            await fulfillment(of: [first], timeout: 1)
            if destroy { window.destroy() } else { window.hide() }
            _ = window.update(frame: frame, targetToken: token())
            let next = expectation(description: "new lifetime read")
            probe.onRequest = { next.fulfill() }
            probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
            await fulfillment(of: [next], timeout: 1)
            XCTAssertFalse(window.hasDeferredLevelUpdate)
            XCTAssertEqual(window.appliedTargetLevel, 0)
            let resolved = expectation(description: "current lifetime accepted")
            window.onWindowLevelResolved = { resolved.fulfill() }
            probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
            await fulfillment(of: [resolved], timeout: 1)
            _ = window.update(frame: frame, targetToken: token())
            XCTAssertEqual(window.appliedTargetLevel, 8)
            XCTAssertEqual(recorder.layerPanels.count, destroy ? 2 : 1)
        }
    }

    @MainActor
    func testDeferredLevelPendingRefreshReusesOnlySameTargetCache() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        let first = expectation(description: "first query")
        probe.onRequest = { first.fulfill() }
        _ = window.update(frame: frame, targetToken: token())
        await fulfillment(of: [first], timeout: 1)
        let resolved = expectation(description: "first level")
        window.onWindowLevelResolved = { resolved.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token())
        let refresh = expectation(description: "same target refresh")
        probe.onRequest = { refresh.fulfill() }
        window.reorder(relativeTo: token())
        XCTAssertEqual(window.appliedTargetLevel, 8)
        await fulfillment(of: [refresh], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        XCTAssertEqual(window.appliedTargetLevel, 0)
        let second = expectation(description: "new target query")
        probe.onRequest = { second.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
        await fulfillment(of: [second], timeout: 1)
        let secondResolved = expectation(description: "second target level")
        window.onWindowLevelResolved = { secondResolved.fulfill() }
        probe.complete(WindowServerInfo(id: 78, pid: 1234, level: 7, frame: .zero))
        await fulfillment(of: [secondResolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        XCTAssertEqual(window.appliedTargetLevel, 7)
        XCTAssertEqual(probe.requests, [77, 77, 78])
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
    /// Zero radii reported by the server are an invalid (not-yet-materialized)
    /// reading: the sample must fall through to raw radii, or to nil, so a square
    /// ring is never cached while rapidly cycling focus.
    func testCornerSampleTreatsZeroRadiiAsInvalidReading() {
        let zeroResolved = [
            NSNumber(value: 0),
            NSNumber(value: 0),
            NSNumber(value: 0),
            NSNumber(value: 0)
        ] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: zeroResolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 11.5),
                observedSize: observedSize,
                source: .raw
            )
        )
        XCTAssertNil(
            SkyLight.cornerSample(resolved: zeroResolved, raw: nil, observedSize: observedSize)
        )
        XCTAssertNil(
            SkyLight.cornerSample(resolved: zeroResolved, raw: zeroResolved, observedSize: observedSize)
        )
    }

    @MainActor
    /// OmniWM stores a user-selected square corner as `squareStoredRadius` (0.01),
    /// so a small nonzero reading is the truth for that window and must survive the
    /// zero-sample rejection instead of falling back to the default rounded radii.
    func testCornerSampleKeepsUserSelectedSquareRadius() {
        let square = GlobalWindowCornerPreferences.squareStoredRadius
        let radii = [
            NSNumber(value: square),
            NSNumber(value: square),
            NSNumber(value: square),
            NSNumber(value: square)
        ] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: radii, raw: nil, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: square),
                observedSize: observedSize,
                source: .resolved
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
    /// Live bounds win for border placement even while an AX write is still pending,
    /// because apps apply writes late and the ring must hug what is presented.
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
        ], reason: "test")
        XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: fixture.entry.windowId))
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)
    }

    @MainActor
    /// When live bounds cannot be queried, a pending AX write is the next best
    /// authority for the border frame.
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
    /// After an AX write settles, a divergent live frame is used for the border.
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
    /// With no live bounds and no pending write, the cached layout frame backs up
    /// border placement.
    func testBorderFrameFallsBackToCacheWhenLiveBoundsAreUnavailable() throws {
        let fixture = try borderFrameFixture()
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in nil })

        XCTAssertEqual(world.borderFrame(for: fixture.entry), fixture.entry.floatingState?.lastFrame)
    }

    @MainActor
    /// Animation keeps the cached frame during ticks but the completed derivation
    /// returns to live bounds.
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
