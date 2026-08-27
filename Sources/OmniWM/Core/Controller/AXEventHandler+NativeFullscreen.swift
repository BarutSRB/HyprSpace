// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension AXEventHandler {
    @discardableResult
    func restoreManagedWindowFromNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) || hadRecord
        if restored {
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(entry.token)
        }
        return restored
    }
}
