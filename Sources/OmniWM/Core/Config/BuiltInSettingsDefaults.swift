// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum BuiltInSettingsDefaults {
    static let niriContainerPrimarySpanPresets: [Double] = [
        0.33333333333333331,
        0.5,
        0.66666666666666663
    ]

    static let workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(
            id: uuid("AD36F001-C57E-41A5-AC1D-DF5249D007F0"),
            name: "1",
            monitorAssignment: .main,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("454CECD4-5E9D-4ED1-95D7-979D48817F5F"),
            name: "2",
            monitorAssignment: .main,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("BEB842B5-E894-4791-9FD1-397C3CDD3538"),
            name: "3",
            monitorAssignment: .main,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("248AA883-2261-4D45-943C-79C0E46A232B"),
            name: "4",
            monitorAssignment: .main,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("8B8C45D6-CE9E-41D9-BD50-BE4989D5E3DE"),
            name: "5",
            monitorAssignment: .main,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("5953F2BF-A378-4266-91B2-287174C4FA4D"),
            name: "6",
            displayName: "\u{2764}\u{FE0F}",
            monitorAssignment: .secondary,
            layoutType: .niri
        ),
        WorkspaceConfiguration(
            id: uuid("A7D5E104-6985-4516-8ED5-07F144F2A33D"),
            name: "7",
            displayName: "\u{1F680}",
            monitorAssignment: .secondary,
            layoutType: .niri
        )
    ]

    static let appRules: [AppRule] = [
        AppRule(
            id: uuid("6A31F08A-4051-4354-B439-42F4C71894A3"),
            bundleId: "com.openai.codex",
            minWidth: 800,
            minHeight: 600
        ),
        AppRule(
            id: uuid("4BA546DA-2875-4BEF-B13F-1539E833B1A0"),
            bundleId: "com.eltima.cmd1.pro.mas",
            minWidth: 950,
            minHeight: 550
        ),
        AppRule(
            id: uuid("486CEFA6-69AA-4A3C-AF27-BCD38F4F138B"),
            bundleId: "com.google.Chrome",
            minWidth: 500,
            minHeight: 375
        ),
        AppRule(
            id: uuid("979F05F4-FFA2-4EDD-B23F-08A9944C759F"),
            bundleId: "dev.zed.Zed",
            minWidth: 360,
            minHeight: 240
        ),
        AppRule(
            id: uuid("81426D13-C1A5-475E-AFBC-00BBA05042D0"),
            bundleId: "com.apple.Safari",
            minWidth: 574,
            minHeight: 220
        ),
        AppRule(
            id: uuid("1CF39647-F30D-4E76-9686-79B551F1B094"),
            bundleId: "app.zen-browser.zen",
            minWidth: 500,
            minHeight: 495
        ),
        AppRule(
            id: uuid("005C00D3-F665-47F8-BDAE-D80790E9E46B"),
            bundleId: "org.mozilla.firefox",
            minWidth: 500,
            minHeight: 120
        ),
        AppRule(
            id: uuid("C21156B1-0224-4998-97E3-8F4FA65B9F3B"),
            bundleId: "company.thebrowser.dia",
            minWidth: 500,
            minHeight: 420
        ),
        AppRule(
            id: uuid("2DE9390B-0DB4-4D0C-9ABA-06F76F1D4EA9"),
            bundleId: "com.spotify.client",
            minWidth: 800,
            minHeight: 600
        ),
        AppRule(
            id: uuid("AF752D95-8497-4844-BE20-4C93E73BAEF2"),
            bundleId: "com.hnc.Discord",
            minWidth: 800,
            minHeight: 500
        ),
        AppRule(
            id: uuid("7876C9EF-437E-4D4F-9C27-B1B02F4AABCE"),
            bundleId: "com.mitchellh.ghostty",
            minWidth: 90,
            minHeight: 48
        ),
        AppRule(
            id: uuid("8ECAB78B-BCDD-4245-BC25-1609A49B1C86"),
            bundleId: "com.microsoft.Outlook",
            minWidth: 930,
            minHeight: 650
        ),
        AppRule(
            id: uuid("552FB77D-BF0E-4737-90A6-B5BC6986C579"),
            bundleId: "com.apple.MobileSMS",
            minWidth: 660,
            minHeight: 320
        )
    ]

    private static func uuid(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            fatalOffMain("Invalid built-in settings UUID: \(value)")
        }
        return uuid
    }
}
