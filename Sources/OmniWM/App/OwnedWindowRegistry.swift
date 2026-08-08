// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class OwnedWindowRegistry {
    static let shared = OwnedWindowRegistry()

    private let surfaceCoordinator: SurfaceCoordinator

    init(surfaceCoordinator: SurfaceCoordinator? = nil) {
        self.surfaceCoordinator = surfaceCoordinator ?? .shared
    }

    func register(_ window: NSWindow) {
        register(
            window,
            surfaceId: "utility-\(ObjectIdentifier(window).hashValue)",
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .frontmostInteractive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            )
        )
    }

    func register(
        _ window: NSWindow,
        surfaceId: String,
        policy: SurfacePolicy
    ) {
        surfaceCoordinator.register(
            window: window,
            id: surfaceId,
            policy: policy
        )
    }

    func register(
        _ window: NSWindow,
        surfaceId: String,
        kind: SurfaceKind,
        hitTestPolicy: HitTestPolicy,
        capturePolicy: CapturePolicy,
        suppressesManagedFocusRecovery: Bool
    ) {
        register(
            window,
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: kind,
                hitTestPolicy: hitTestPolicy,
                capturePolicy: capturePolicy,
                suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
            )
        )
    }

    func registerWindowNumber(
        surfaceId: String,
        policy: SurfacePolicy,
        windowNumber: Int,
        frameProvider: @escaping @MainActor () -> CGRect?,
        visibilityProvider: @escaping @MainActor () -> Bool
    ) {
        surfaceCoordinator.registerWindowNumber(
            id: surfaceId,
            windowNumber: windowNumber,
            frameProvider: frameProvider,
            visibilityProvider: visibilityProvider,
            policy: policy
        )
    }

    func registerWindowNumber(
        surfaceId: String,
        kind: SurfaceKind,
        windowNumber: Int,
        frameProvider: @escaping @MainActor () -> CGRect?,
        visibilityProvider: @escaping @MainActor () -> Bool,
        hitTestPolicy: HitTestPolicy,
        capturePolicy: CapturePolicy,
        suppressesManagedFocusRecovery: Bool
    ) {
        registerWindowNumber(
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: kind,
                hitTestPolicy: hitTestPolicy,
                capturePolicy: capturePolicy,
                suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
            ),
            windowNumber: windowNumber,
            frameProvider: frameProvider,
            visibilityProvider: visibilityProvider
        )
    }

    func unregister(_ window: NSWindow) {
        surfaceCoordinator.unregister(window: window)
    }

    func unregister(surfaceId: String) {
        surfaceCoordinator.unregister(id: surfaceId)
    }

    func contains(point: CGPoint) -> Bool {
        surfaceCoordinator.containsInteractive(point: point)
    }

    func containsGeometric(point: CGPoint) -> Bool {
        surfaceCoordinator.containsGeometric(point: point)
    }

    func visibleSurfaceInfos() -> [SurfaceScene.VisibleSurfaceInfo] {
        surfaceCoordinator.visibleSurfaceInfos()
    }

    func contains(window: NSWindow?) -> Bool {
        surfaceCoordinator.contains(window: window)
    }

    func contains(windowNumber: Int) -> Bool {
        surfaceCoordinator.contains(windowNumber: windowNumber)
    }

    var hasFrontmostWindow: Bool {
        surfaceCoordinator.hasFrontmostSuppressingWindow
    }

    var hasVisibleWindow: Bool {
        surfaceCoordinator.hasVisibleSuppressingWindow
    }

    func isCaptureEligible(windowNumber: Int) -> Bool {
        surfaceCoordinator.isCaptureEligible(windowNumber: windowNumber)
    }

    func visibleSurfaceIDs(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [String] {
        surfaceCoordinator.visibleSurfaceIDs(
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
        surfaceCoordinator.visibleWindows(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
    }
}
