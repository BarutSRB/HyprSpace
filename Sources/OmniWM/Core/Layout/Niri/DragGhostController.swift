// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ScreenCaptureKit

@MainActor
final class DragGhostController {
    private var ghostWindow: DragGhostWindow?
    private var captureTask: Task<Void, Never>?
    private var isActive: Bool = false
    private var swapTargetOverlay: SwapTargetOverlay?
    private let surfaceCoordinator: SurfaceCoordinator
    private let captureAccessAllowed: @MainActor () -> Bool

    init(
        surfaceCoordinator: SurfaceCoordinator = .shared,
        captureAccessAllowed: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.surfaceCoordinator = surfaceCoordinator
        self.captureAccessAllowed = captureAccessAllowed
    }

    isolated deinit {
        destroy()
    }

    func beginDrag(windowId: Int, originalFrame: CGRect, cursorLocation: CGPoint) {
        isActive = true

        captureTask?.cancel()
        guard captureAccessAllowed() else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }

            let scaledSize = CGSize(
                width: originalFrame.width * 0.5,
                height: originalFrame.height * 0.5
            )

            if let thumbnail = await captureWindowThumbnail(windowId: windowId, targetSize: scaledSize) {
                guard isActive, !Task.isCancelled else { return }

                if ghostWindow == nil {
                    ghostWindow = DragGhostWindow(surfaceCoordinator: surfaceCoordinator)
                }

                ghostWindow?.setImage(thumbnail, size: scaledSize)
                ghostWindow?.showAt(cursorLocation: cursorLocation)
            }
        }
    }

    func updatePosition(cursorLocation: CGPoint) {
        guard isActive else { return }
        ghostWindow?.moveTo(cursorLocation: cursorLocation)
    }

    func endDrag() {
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        ghostWindow?.hideGhost()
        hideSwapTarget()
    }

    func showSwapTarget(frame: CGRect) {
        guard isActive else { return }
        if swapTargetOverlay == nil {
            swapTargetOverlay = SwapTargetOverlay(surfaceCoordinator: surfaceCoordinator)
        }
        swapTargetOverlay?.show(at: frame)
    }

    func hideSwapTarget() {
        swapTargetOverlay?.hide()
    }

    func destroy() {
        endDrag()
        ghostWindow?.destroy()
        ghostWindow = nil
        swapTargetOverlay?.destroy()
        swapTargetOverlay = nil
    }

    private func captureWindowThumbnail(windowId: Int, targetSize: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowId) }) else {
                FallbackFiringRecorder.shared.note(.capture, "dragGhostWindowMapMiss")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(targetSize.width)
            config.height = Int(targetSize.height)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "dragGhostCaptureException")
            return nil
        }
    }
}
