// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@available(macOS 27.0, *)
@MainActor
final class FoundationModelsIssueEngine: IssueRewriting {
    var availability: IssueAIAvailability {
        return .modelNotReady
    }

    func rewrite(_ freeform: String, hotkeyContext: String) async throws -> RewrittenIssue {
        throw IssueReportError.generationFailed("AI model not available in this build")
    }
}
