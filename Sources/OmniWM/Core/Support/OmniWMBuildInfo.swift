// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CryptoKit
import Foundation

enum OmniWMBuildInfo {
    static var version: String {
        Bundle.main.appVersion ?? "unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    static var gitHash: String {
        Bundle.main.infoDictionary?["OMNIWMGitHash"] as? String ?? "SNAPSHOT"
    }

    static var configuration: String {
        #if DEBUG
            "debug"
        #else
            "release"
        #endif
    }

    static let executableSHA256 = Task.detached(priority: .utility) { () -> String? in
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
