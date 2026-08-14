// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import ScreenCaptureKit

struct CapturedIcon: Sendable {
    let image: CGImage
    let scale: CGFloat
}

enum HiddenBarIconCaptureService {
    static func captureVisible(_ items: [ResolvedMenuBarItem]) async -> [MenuBarItemKey: CapturedIcon] {
        guard !items.isEmpty else { return [:] }
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        guard let icons = await captureMenuBarBand(items) else {
            FallbackFiringRecorder.shared.note(.capture, "hiddenBarVisibleCaptureFailed")
            return [:]
        }
        return icons
    }

    static func captureVisible(
        _ items: [ResolvedMenuBarItem],
        timeout: Duration
    ) async -> [MenuBarItemKey: CapturedIcon] {
        let state = RunLoopResumeState<[MenuBarItemKey: CapturedIcon]>()
        let captureTask = Task {
            let icons = await captureVisible(items)
            guard let continuation = state.takeContinuation(orStore: .success(icons)) else { return }
            continuation.resume(returning: icons)
        }

        return (try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingResult = state.install(continuation) {
                    continuation.resume(with: pendingResult)
                    return
                }
                Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    captureTask.cancel()
                    guard let continuation = state.takeContinuation(orStore: .success([:])) else { return }
                    continuation.resume(returning: [:])
                }
            }
        } onCancel: {
            captureTask.cancel()
            guard let continuation = state.takeContinuation(orStore: .failure(CancellationError())) else { return }
            continuation.resume(throwing: CancellationError())
        }) ?? [:]
    }

    private static func captureMenuBarBand(
        _ items: [ResolvedMenuBarItem]
    ) async -> [MenuBarItemKey: CapturedIcon]? {
        let bounds = items.map(\.bounds)
        let union = bounds.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return nil }

        let display = content.displays
            .map { ($0, $0.frame.intersection(union)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
        guard let display else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.sourceRect = CGRect(
            x: union.origin.x - display.frame.origin.x,
            y: union.origin.y - display.frame.origin.y,
            width: union.width,
            height: union.height
        )
        configuration.width = Int((union.width * scale).rounded())
        configuration.height = Int((union.height * scale).rounded())

        guard let composite = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ), !isEffectivelyTransparent(composite) else { return nil }

        var result: [MenuBarItemKey: CapturedIcon] = [:]
        let rects = cropRects(bounds: bounds, union: union, scale: scale)
        for (item, rect) in zip(items, rects) {
            guard let cropped = composite.cropping(to: rect),
                  !isEffectivelyTransparent(cropped)
            else { continue }
            result[item.key] = CapturedIcon(image: cropped, scale: scale)
        }
        return result.isEmpty ? nil : result
    }

    static func cropRects(bounds: [CGRect], union: CGRect, scale: CGFloat) -> [CGRect] {
        bounds.map { rect in
            CGRect(
                x: (rect.origin.x - union.origin.x) * scale,
                y: (rect.origin.y - union.origin.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
    }

    static func isEffectivelyTransparent(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }
        switch image.alphaInfo {
        case .none,
             .noneSkipFirst,
             .noneSkipLast:
            return false
        default:
            break
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel[3] == 0
    }
}
