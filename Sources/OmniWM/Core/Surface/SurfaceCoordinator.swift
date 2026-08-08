// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class SurfaceCoordinator {
    static let shared = SurfaceCoordinator()

    private let scene: SurfaceScene

    init(scene: SurfaceScene? = nil) {
        self.scene = scene ?? SurfaceScene()
    }

    func register(
        window: NSWindow,
        id: String,
        policy: SurfacePolicy
    ) {
        scene.register(
            window: window,
            node: SurfaceScene.SurfaceNode(
                id: id,
                policy: policy,
                window: window,
                windowNumber: window.windowNumber > 0 ? window.windowNumber : nil,
                frameProvider: nil,
                visibilityProvider: nil
            )
        )
    }

    func registerWindowNumber(
        id: String,
        windowNumber: Int,
        frameProvider: @escaping @MainActor () -> CGRect?,
        visibilityProvider: @escaping @MainActor () -> Bool,
        policy: SurfacePolicy
    ) {
        scene.registerWindowNumber(
            node: SurfaceScene.SurfaceNode(
                id: id,
                policy: policy,
                window: nil,
                windowNumber: windowNumber,
                frameProvider: frameProvider,
                visibilityProvider: visibilityProvider
            )
        )
    }

    func unregister(window: NSWindow) {
        scene.unregister(window: window)
    }

    func unregister(id: String) {
        scene.unregister(id: id)
    }

    func contains(window: NSWindow?) -> Bool {
        scene.contains(window: window)
    }

    func contains(windowNumber: Int) -> Bool {
        scene.contains(windowNumber: windowNumber)
    }

    func containsInteractive(point: CGPoint) -> Bool {
        scene.containsInteractive(point: point)
    }

    func containsGeometric(point: CGPoint) -> Bool {
        scene.containsGeometric(point: point)
    }

    func visibleSurfaceInfos() -> [SurfaceScene.VisibleSurfaceInfo] {
        scene.visibleSurfaceInfos()
    }

    var hasFrontmostSuppressingWindow: Bool {
        scene.hasFrontmostSuppressingWindow
    }

    var hasVisibleSuppressingWindow: Bool {
        scene.hasVisibleSuppressingWindow
    }

    func isCaptureEligible(windowNumber: Int) -> Bool {
        scene.isCaptureEligible(windowNumber: windowNumber)
    }

    func visibleSurfaceIDs(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [String] {
        scene.visibleSurfaceIDs(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
    }

    func visibleWindows(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [NSWindow] {
        scene.visibleWindows(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
    }
}
