// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct EventTapTeardownOperations {
    var disableTap: (CFMachPort) -> Void
    var removeRunLoopSource: (CFRunLoop, CFRunLoopSource, CFRunLoopMode) -> Void
    var invalidateTap: (CFMachPort) -> Void

    static var live: EventTapTeardownOperations {
        EventTapTeardownOperations(
            disableTap: { CGEvent.tapEnable(tap: $0, enable: false) },
            removeRunLoopSource: { CFRunLoopRemoveSource($0, $1, $2) },
            invalidateTap: { CFMachPortInvalidate($0) }
        )
    }
}

enum EventTapTeardown {
    static func tearDown(
        tap: inout CFMachPort?,
        runLoopSource: inout CFRunLoopSource?,
        runLoop: CFRunLoop = CFRunLoopGetMain(),
        mode: CFRunLoopMode = .commonModes,
        operations: EventTapTeardownOperations = .live
    ) {
        let currentTap = tap
        let currentSource = runLoopSource
        if let currentTap {
            operations.disableTap(currentTap)
        }
        if let currentSource {
            operations.removeRunLoopSource(runLoop, currentSource, mode)
        }
        if let currentTap {
            operations.invalidateTap(currentTap)
        }
        runLoopSource = nil
        tap = nil
    }
}
