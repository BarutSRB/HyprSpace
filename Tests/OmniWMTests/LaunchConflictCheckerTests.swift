// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class LaunchConflictCheckerTests: XCTestCase {
    func testEveryBundleIdentifierMatchesItsWindowManager() {
        var pid: pid_t = 10
        for manager in ConflictingWindowManager.allCases {
            for bundleIdentifier in manager.bundleIdentifiers {
                let conflicts = LaunchConflictChecker.conflicts(
                    in: [snapshot(pid: pid, bundleIdentifier: bundleIdentifier)]
                )
                XCTAssertEqual(conflicts, [manager], bundleIdentifier)
                pid += 1
            }
        }
    }

    func testEveryExecutableNameMatchesItsWindowManager() {
        var pid: pid_t = 100
        for manager in ConflictingWindowManager.allCases {
            for executableName in manager.executableNames {
                let conflicts = LaunchConflictChecker.conflicts(
                    in: [snapshot(pid: pid, executableName: executableName)]
                )
                XCTAssertEqual(conflicts, [manager], executableName)
                pid += 1
            }
        }
    }

    func testAdditionalCatalogIdentitiesMatchExpectedWindowManagers() {
        let identities: [(manager: ConflictingWindowManager, snapshots: [LaunchProcessSnapshot])] = [
            (.glide, [
                snapshot(pid: 150, bundleIdentifier: "org.glidewm.glide"),
                snapshot(pid: 151, executableName: "glide_server")
            ]),
            (.komorebi, [snapshot(pid: 152, executableName: "komorebi")]),
            (.parket, [
                snapshot(pid: 153, bundleIdentifier: "com.parket.app"),
                snapshot(pid: 154, executableName: "parket")
            ]),
            (.tangrid, [
                snapshot(pid: 155, bundleIdentifier: "com.wrapper.Tangrid"),
                snapshot(pid: 156, executableName: "Tangrid")
            ]),
            (.trimWM, [
                snapshot(pid: 157, bundleIdentifier: "de.cornz.TrimWM"),
                snapshot(pid: 158, executableName: "TrimWM")
            ]),
            (.yashiki, [
                snapshot(pid: 159, bundleIdentifier: "dev.typester.yashiki"),
                snapshot(pid: 160, executableName: "yashiki")
            ])
        ]

        for identity in identities {
            for processSnapshot in identity.snapshots {
                XCTAssertEqual(
                    LaunchConflictChecker.conflicts(in: [processSnapshot]),
                    [identity.manager],
                    processSnapshot.bundleIdentifier
                        ?? processSnapshot.executableName
                        ?? identity.manager.displayName
                )
            }
        }
    }

    func testMatcherUsesCatalogOrderAndDeduplicatesProducts() {
        let snapshots = ConflictingWindowManager.allCases.reversed().enumerated().flatMap { index, manager in
            let bundleOrExecutableSnapshot = manager.bundleIdentifiers.first.map {
                snapshot(pid: pid_t(index + 200), bundleIdentifier: $0)
            } ?? snapshot(pid: pid_t(index + 200), executableName: manager.executableNames[0])
            return [
                bundleOrExecutableSnapshot,
                snapshot(pid: pid_t(index + 300), executableName: manager.executableNames[0])
            ]
        }

        XCTAssertEqual(
            LaunchConflictChecker.conflicts(in: snapshots),
            [
                .omniWM,
                .aeroSpace,
                .amethyst,
                .bobrwm,
                .glide,
                .komorebi,
                .nehir,
                .paneru,
                .parket,
                .rift,
                .tangrid,
                .trimWM,
                .yabai,
                .yashiki
            ]
        )
    }

    func testMatcherRejectsClientHelpersCaseVariantsAndSubstringMatches() {
        let executableNames = [
            "aerospace",
            "glide",
            "komorebic",
            "komorebi-bar",
            "rift-cli",
            "nehirctl",
            "bobrwm",
            "bobrwm-cli",
            "bobrwm-swipe",
            "omniwmctl",
            "Hammerspoon",
            "PaperWM",
            "skhd",
            "yabai-helper",
            "paneru-helper",
            "AeroSpaceHelper"
        ]
        let snapshots = executableNames.enumerated().map { index, executableName in
            snapshot(pid: pid_t(index + 400), executableName: executableName)
        }

        XCTAssertTrue(LaunchConflictChecker.conflicts(in: snapshots).isEmpty)
    }

    func testMatcherRejectsBundleIdentifierCaseVariantsAndSubstringMatches() {
        let bundleIdentifiers = [
            "COM.BARUT.OMNIWM",
            "com.barut.OmniWM.helper",
            "prefix.bobko.aerospace",
            "com.amethyst.Amethyst.beta",
            "dev.guria.nehirctl",
            "org.hammerspoon.Hammerspoon",
            "com.jackielii.skhd"
        ]
        let snapshots = bundleIdentifiers.enumerated().map { index, bundleIdentifier in
            snapshot(pid: pid_t(index + 450), bundleIdentifier: bundleIdentifier)
        }

        XCTAssertTrue(LaunchConflictChecker.conflicts(in: snapshots).isEmpty)
    }

    func testScanFindsHeadlessProcessWithoutRunningApplicationEntry() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: { [] },
                processSnapshots: { _ in [self.snapshot(pid: 501, executableName: "yabai")] },
                currentPID: { 500 }
            )
        )

        XCTAssertEqual(checker.scan(), .blocked(.conflicts([.yabai])))
    }

    func testScanFindsHeadlessKomorebiWithoutBundleIdentity() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: { [] },
                processSnapshots: { _ in
                    [self.snapshot(pid: 551, executableName: "komorebi")]
                },
                currentPID: { 550 }
            )
        )

        XCTAssertEqual(checker.scan(), .blocked(.conflicts([.komorebi])))
    }

    func testScanExcludesCurrentProcessButFindsSecondOmniWMInstance() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: {
                    [
                        self.snapshot(
                            pid: 601,
                            bundleIdentifier: "com.barut.OmniWM",
                            executableName: "OmniWM"
                        ),
                        self.snapshot(
                            pid: 602,
                            bundleIdentifier: "com.barut.OmniWM",
                            executableName: "OmniWM"
                        )
                    ]
                },
                processSnapshots: { _ in [] },
                currentPID: { 601 }
            )
        )

        XCTAssertEqual(checker.scan(), .blocked(.conflicts([.omniWM])))
    }

    func testScanIsClearWhenOnlyCurrentOmniWMMatches() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: {
                    [self.snapshot(pid: 701, bundleIdentifier: "com.barut.OmniWM")]
                },
                processSnapshots: { _ in
                    [self.snapshot(pid: 701, executableName: "OmniWM")]
                },
                currentPID: { 701 }
            )
        )

        XCTAssertEqual(checker.scan(), .clear)
    }

    func testScanFailsClosedWhenProcessInventoryFails() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: { [] },
                processSnapshots: { _ in throw LaunchProcessScanError.inventoryUnavailable },
                currentPID: { 801 }
            )
        )

        XCTAssertEqual(checker.scan(), .blocked(.scanUnavailable))
    }

    func testScanFailureTakesPrecedenceOverPartialApplicationMatches() {
        let checker = LaunchConflictChecker(
            environment: .init(
                applicationSnapshots: {
                    [self.snapshot(pid: 851, bundleIdentifier: "bobko.aerospace")]
                },
                processSnapshots: { _ in throw LaunchProcessScanError.inventoryIncomplete },
                currentPID: { 850 }
            )
        )

        XCTAssertEqual(checker.scan(), .blocked(.scanUnavailable))
    }

    func testProcessScannerIgnoresProcessesThatExitDuringResolution() throws {
        let snapshots = try LaunchProcessScanner.snapshots(
            environment: .init(
                processIDs: { [901, 902, 0] },
                executableResolution: { pid in
                    pid == 901 ? .identified("yabai") : .exited
                }
            )
        )

        XCTAssertEqual(snapshots, [snapshot(pid: 901, executableName: "yabai")])
    }

    func testProcessScannerExcludesCurrentPIDBeforeResolution() throws {
        var resolvedPIDs: [pid_t] = []
        let snapshots = try LaunchProcessScanner.snapshots(
            excludingPID: 951,
            environment: .init(
                processIDs: { [951, 952] },
                executableResolution: { pid in
                    resolvedPIDs.append(pid)
                    return .identified("process-\(pid)")
                }
            )
        )

        XCTAssertEqual(resolvedPIDs, [952])
        XCTAssertEqual(snapshots, [snapshot(pid: 952, executableName: "process-952")])
    }

    func testProcessScannerRejectsLiveUnidentifiedProcess() {
        XCTAssertThrowsError(
            try LaunchProcessScanner.snapshots(
                environment: .init(
                    processIDs: { [1_001] },
                    executableResolution: { _ in .unavailable }
                )
            )
        ) { error in
            XCTAssertEqual(error as? LaunchProcessScanError, .processIdentityUnavailable(1_001))
        }
    }

    func testProcessScannerTreatsZombieAsExited() {
        XCTAssertEqual(
            LaunchProcessScanner.unidentifiedResolution(
                processStatus: UInt32(SZOMB),
                processExited: false
            ),
            .exited
        )
        XCTAssertEqual(
            LaunchProcessScanner.unidentifiedResolution(
                processStatus: UInt32(SRUN),
                processExited: false
            ),
            .unavailable
        )
    }

    func testProcessStatusIdentifiesZombie() {
        var childPID: pid_t = 0
        let executable = "/usr/bin/true"
        let spawnResult = executable.withCString { path in
            var arguments = [UnsafeMutablePointer(mutating: path), nil]
            return posix_spawn(
                &childPID,
                path,
                nil,
                nil,
                &arguments,
                environ
            )
        }
        guard spawnResult == 0 else {
            XCTFail("posix_spawn failed: \(spawnResult)")
            return
        }
        defer {
            var status: Int32 = 0
            _ = waitpid(childPID, &status, 0)
        }

        var observedStatus: UInt32?
        for _ in 0 ..< 500 {
            observedStatus = LaunchProcessScanner.processStatus(pid: childPID)
            if observedStatus == UInt32(SZOMB) {
                break
            }
            usleep(1_000)
        }

        XCTAssertEqual(observedStatus, UInt32(SZOMB))
    }

    private func snapshot(
        pid: pid_t,
        bundleIdentifier: String? = nil,
        executableName: String? = nil
    ) -> LaunchProcessSnapshot {
        LaunchProcessSnapshot(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName
        )
    }
}

@MainActor
final class LaunchConflictGateTests: XCTestCase {
    func testGateRetriesConflictUntilScanClears() {
        var results: [LaunchConflictCheckResult] = [
            .blocked(.conflicts([.aeroSpace, .yabai])),
            .clear
        ]
        var presentedReasons: [LaunchConflictBlockReason] = []
        var bootstrapCount = 0
        var quitCount = 0
        var focusRestored = false

        LaunchConflictGate.run(
            scan: { results.removeFirst() },
            present: { reason in
                XCTAssertEqual(bootstrapCount, 0)
                presentedReasons.append(reason)
                focusRestored = true
                return .checkAgain
            },
            onClear: {
                XCTAssertTrue(focusRestored)
                bootstrapCount += 1
            },
            onQuit: { quitCount += 1 }
        )

        XCTAssertEqual(presentedReasons, [.conflicts([.aeroSpace, .yabai])])
        XCTAssertEqual(bootstrapCount, 1)
        XCTAssertEqual(quitCount, 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testGateRetriesUnavailableScanUntilScanClears() {
        var results: [LaunchConflictCheckResult] = [
            .blocked(.scanUnavailable),
            .clear
        ]
        var bootstrapCount = 0

        LaunchConflictGate.run(
            scan: { results.removeFirst() },
            present: { _ in
                XCTAssertEqual(bootstrapCount, 0)
                return .checkAgain
            },
            onClear: { bootstrapCount += 1 },
            onQuit: { XCTFail("Unexpected quit") }
        )

        XCTAssertEqual(bootstrapCount, 1)
        XCTAssertTrue(results.isEmpty)
    }

    func testGateBootstrapsImmediatelyWhenScanIsClear() {
        var scanCount = 0
        var bootstrapCount = 0

        LaunchConflictGate.run(
            scan: {
                scanCount += 1
                return .clear
            },
            present: { _ in
                XCTFail("Unexpected presentation")
                return .quit
            },
            onClear: { bootstrapCount += 1 },
            onQuit: { XCTFail("Unexpected quit") }
        )

        XCTAssertEqual(scanCount, 1)
        XCTAssertEqual(bootstrapCount, 1)
    }

    func testGateQuitsWithoutRescanning() {
        var scanCount = 0
        var bootstrapCount = 0
        var quitCount = 0
        LaunchConflictGate.run(
            scan: {
                scanCount += 1
                return .blocked(.conflicts([.amethyst]))
            },
            present: { _ in
                XCTAssertEqual(bootstrapCount, 0)
                return .quit
            },
            onClear: { bootstrapCount += 1 },
            onQuit: { quitCount += 1 }
        )

        XCTAssertEqual(scanCount, 1)
        XCTAssertEqual(bootstrapCount, 0)
        XCTAssertEqual(quitCount, 1)
    }
}
