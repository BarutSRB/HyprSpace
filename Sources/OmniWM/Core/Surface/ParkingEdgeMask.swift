// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class ParkingEdgeMaskManager {
    private var windowsByKey: [ParkingEdgeMaskKey: ParkingEdgeMaskWindow] = [:]

    isolated deinit {
        for window in windowsByKey.values {
            window.destroy()
        }
    }

    func apply(_ masks: [DesiredParkingEdgeMask]) {
        var staleKeys = Set(windowsByKey.keys)

        for mask in masks {
            staleKeys.remove(mask.key)
            let window = windowsByKey[mask.key] ?? {
                let window = ParkingEdgeMaskWindow(key: mask.key)
                windowsByKey[mask.key] = window
                return window
            }()
            window.apply(frame: mask.frame)
        }

        for key in staleKeys {
            windowsByKey.removeValue(forKey: key)?.destroy()
        }
    }

    func removeAll() {
        for window in windowsByKey.values {
            window.destroy()
        }
        windowsByKey.removeAll()
    }
}

@MainActor
private final class ParkingEdgeMaskWindow: NSPanel {
    private let surfaceId: String
    private var appliedFrame: CGRect?

    init(key: ParkingEdgeMaskKey) {
        surfaceId = "parking-edge-mask-\(key.monitorId.displayId)-\(key.side.rawValue)"

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        level = .statusBar
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let maskView = NSView(frame: .zero)
        maskView.wantsLayer = true
        maskView.layer?.backgroundColor = NSColor.black.cgColor
        contentView = maskView

        let maskWindowNumber = windowNumber
        if maskWindowNumber > 0 {
            SkyLight.shared.excludeFromScreencaptureWindowSelection(UInt32(maskWindowNumber))
        }

        SurfaceCoordinator.shared.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .parkingEdgeMask,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func apply(frame: CGRect) {
        if appliedFrame != frame || self.frame != frame {
            setFrame(frame, display: true)
            contentView?.frame = CGRect(origin: .zero, size: frame.size)
            appliedFrame = frame
        }

        if !isVisible {
            orderFrontRegardless()
        }
    }

    func destroy() {
        SurfaceCoordinator.shared.unregister(id: surfaceId)
        orderOut(nil)
        close()
    }
}
