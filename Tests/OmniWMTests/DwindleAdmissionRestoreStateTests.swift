// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DwindleAdmissionRestoreStateTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private struct Session {
        let settings: SettingsStore
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID

        @MainActor var manager: WorkspaceManager {
            controller.workspaceManager
        }
    }

    func testPersistedDwindlePlacementRoundTripsAndDecodesLegacyIntent() throws {
        let placement = PersistedDwindlePlacement(
            steps: [step(.horizontal, 1.0, 1), step(.vertical, 0.8, 0)],
            memberIndex: 1,
            isActiveMember: true
        )
        let intent = makeIntent(dwindlePlacement: placement)
        let data = try JSONEncoder().encode(intent)
        XCTAssertEqual(try JSONDecoder().decode(PersistedRestoreIntent.self, from: data), intent)

        let legacyData = try JSONEncoder().encode(makeIntent(dwindlePlacement: nil))
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("dwindlePlacement"))
        XCTAssertNil(try JSONDecoder().decode(PersistedRestoreIntent.self, from: legacyData).dwindlePlacement)
    }

    func testCapturedPrunedPathKeepsStoredDeeperSteps() {
        let stored = PersistedDwindlePlacement(
            steps: [step(.horizontal, 1.0, 1), step(.vertical, 1.2, 1)],
            memberIndex: 0,
            isActiveMember: true
        )
        let pruned = PersistedDwindlePlacement(
            steps: [step(.horizontal, 1.0, 1)],
            memberIndex: 0,
            isActiveMember: false
        )
        XCTAssertEqual(
            pruned.preservingPrunedSteps(of: stored),
            PersistedDwindlePlacement(steps: stored.steps, memberIndex: 0, isActiveMember: false)
        )
        XCTAssertEqual(
            PersistedDwindlePlacement(steps: [], memberIndex: 0, isActiveMember: true)
                .preservingPrunedSteps(of: stored),
            stored
        )

        let moved = PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 0)], memberIndex: 0, isActiveMember: true)
        XCTAssertEqual(moved.preservingPrunedSteps(of: stored), moved)
        let deeper = PersistedDwindlePlacement(
            steps: stored.steps + [step(.horizontal, 1.0, 0)],
            memberIndex: 0,
            isActiveMember: true
        )
        XCTAssertEqual(deeper.preservingPrunedSteps(of: stored), deeper)
        XCTAssertEqual(pruned.preservingPrunedSteps(of: nil), pruned)
    }

    func testRestoreIsOrderIndependent() {
        let a = WindowToken(pid: 1, windowId: 1)
        let b = WindowToken(pid: 2, windowId: 2)
        let c = WindowToken(pid: 3, windowId: 3)
        let placements = threeWindowPlacements(a: a, b: b, c: c)

        for order in permutations([a, b, c]) {
            let engine = DwindleLayoutEngine()
            let ws = WorkspaceDescriptor.ID()
            XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: order, in: ws), "\(order)")
            XCTAssertEqual(engine.persistedPlacements(in: ws), placements, "\(order)")
            XCTAssertEqual(engine.tileCount(in: ws), 3)
            XCTAssertEqual(engine.root(for: ws)?.splitOrientation, .horizontal)
            XCTAssertEqual(engine.root(for: ws)?.splitRatio, 1.0)
            XCTAssertEqual(engine.findNode(for: b, in: ws)?.parent?.splitRatio, 1.2)
            XCTAssertEqual(engine.findNode(for: b, in: ws)?.parent?.splitOrientation, .vertical)
            XCTAssertFalse(engine.calculateLayout(for: ws, screen: screen).isEmpty)
        }
    }

    func testIncrementalArrivalsRebuildFromPlacementsAndPruneMissingWindows() {
        let a = WindowToken(pid: 1, windowId: 1)
        let b = WindowToken(pid: 2, windowId: 2)
        let c = WindowToken(pid: 3, windowId: 3)
        let placements = threeWindowPlacements(a: a, b: b, c: c)
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [c], in: ws))
        XCTAssertEqual(
            engine.persistedPlacements(in: ws),
            [c: PersistedDwindlePlacement(steps: [], memberIndex: 0, isActiveMember: true)]
        )

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [c, a], in: ws))
        XCTAssertEqual(
            engine.persistedPlacements(in: ws),
            [
                a: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 0)], memberIndex: 0, isActiveMember: true),
                c: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 1)], memberIndex: 0, isActiveMember: true)
            ]
        )
        XCTAssertFalse(engine.restoreInitialPlacements(placements, matching: [c, a], in: ws))

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [c, a, b], in: ws))
        XCTAssertEqual(engine.persistedPlacements(in: ws), placements)
        XCTAssertEqual(engine.tileCount(in: ws), 3)
    }

    func testGroupMembersRestoreByMemberIndexAndActiveFlag() throws {
        let a = WindowToken(pid: 1, windowId: 1)
        let b = WindowToken(pid: 2, windowId: 2)
        let c = WindowToken(pid: 3, windowId: 3)
        let placements: [WindowToken: PersistedDwindlePlacement] = [
            a: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 0)], memberIndex: 1, isActiveMember: false),
            b: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 0)], memberIndex: 0, isActiveMember: true),
            c: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 1)], memberIndex: 0, isActiveMember: true)
        ]
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [a, c, b], in: ws))

        let groupNode = try XCTUnwrap(engine.findNode(for: a, in: ws))
        XCTAssertTrue(groupNode === engine.findNode(for: b, in: ws))
        XCTAssertEqual(groupNode.tile?.members.map(\.token), [b, a])
        XCTAssertEqual(groupNode.tile?.activeToken, b)
        XCTAssertFalse(groupNode === engine.findNode(for: c, in: ws))
        XCTAssertEqual(engine.tileCount(in: ws), 2)
        XCTAssertEqual(engine.persistedPlacements(in: ws), placements)
    }

    func testConflictingOrMalformedPlacementsFallBackToNormalInsertion() {
        let a = WindowToken(pid: 1, windowId: 1)
        let b = WindowToken(pid: 2, windowId: 2)
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()

        let leafVersusSplit: [WindowToken: PersistedDwindlePlacement] = [
            a: PersistedDwindlePlacement(steps: [], memberIndex: 0, isActiveMember: true),
            b: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 1)], memberIndex: 0, isActiveMember: true)
        ]
        XCTAssertFalse(engine.restoreInitialPlacements(leafVersusSplit, matching: [a, b], in: ws))
        XCTAssertFalse(engine.restoreInitialPlacements(leafVersusSplit, matching: [b, a], in: ws))

        let badChildIndex: [WindowToken: PersistedDwindlePlacement] = [
            a: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 2)], memberIndex: 0, isActiveMember: true)
        ]
        XCTAssertFalse(engine.restoreInitialPlacements(badChildIndex, matching: [a], in: ws))

        XCTAssertEqual(engine.tileCount(in: ws), 0)
        XCTAssertNil(engine.findNode(for: a, in: ws))
        XCTAssertNil(engine.findNode(for: b, in: ws))
    }

    func testRestoreSkipsWhenAnUnplacedWindowIsPresent() {
        let x = WindowToken(pid: 9, windowId: 9)
        let a = WindowToken(pid: 1, windowId: 1)
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        _ = engine.addWindow(token: x, to: ws, activeWindowFrame: nil)
        let placements = [a: PersistedDwindlePlacement(
            steps: [step(.horizontal, 1.0, 0)],
            memberIndex: 0,
            isActiveMember: true
        )]

        XCTAssertFalse(engine.restoreInitialPlacements(placements, matching: [x, a], in: ws))
        XCTAssertEqual(engine.tileCount(in: ws), 1)
        XCTAssertNil(engine.findNode(for: a, in: ws))
    }

    func testDwindleLayoutPassCapturesPlacementsIntoRestoreIntents() throws {
        let root = makeRoot()
        let session = try makeSession(root: root)
        let tokens = (1 ... 3).map { admit(index: $0, pidBase: 474_000, session: session) }
        runLayoutPass(session)

        let placements = session.engine.persistedPlacements(in: session.workspaceId)
        XCTAssertEqual(placements.count, 3)
        for token in tokens {
            XCTAssertEqual(session.manager.restoreIntent(for: token)?.dwindlePlacement, placements[token])
        }
        XCTAssertEqual(placements[tokens[0]]?.steps.map(\.childIndex), [0])
        XCTAssertEqual(placements[tokens[1]]?.steps.map(\.childIndex), [1, 0])
        XCTAssertEqual(placements[tokens[2]]?.steps.map(\.childIndex), [1, 1])
        XCTAssertEqual(
            placements[tokens[0]]?.steps.first?.orientation,
            session.engine.root(for: session.workspaceId)?.splitOrientation
        )

        session.manager.flushPersistedWindowRestoreCatalogNow()
        let catalog = session.settings.loadPersistedWindowRestoreCatalog()
        for (offset, token) in tokens.enumerated() {
            let entry = try XCTUnwrap(catalog.entries.first {
                $0.key.matches(metadata(index: offset + 1, workspaceId: session.workspaceId))
            })
            XCTAssertEqual(entry.restoreIntent.dwindlePlacement, placements[token])
        }
    }

    func testThreeWindowTreeRestoresAcrossSimulatedRestart() throws {
        let root = makeRoot()
        let first = try makeSession(root: root)
        let firstTokens = (1 ... 3).map { admit(index: $0, pidBase: 475_000, session: first) }
        runLayoutPass(first)
        let firstPlacements = first.engine.persistedPlacements(in: first.workspaceId)
        let expected = Dictionary(uniqueKeysWithValues: firstTokens.enumerated().map { (
            $0.offset + 1,
            firstPlacements[$0.element]
        ) })
        first.manager.flushPersistedWindowRestoreCatalogNow()

        let second = try makeSession(root: root)
        let third = admit(index: 3, pidBase: 476_000, session: second)
        XCTAssertEqual(second.manager.restoreIntent(for: third)?.dwindlePlacement, expected[3])
        runLayoutPass(second)
        XCTAssertEqual(second.engine.tileCount(in: second.workspaceId), 1)
        XCTAssertEqual(second.manager.restoreIntent(for: third)?.dwindlePlacement, expected[3])

        let firstWindow = admit(index: 1, pidBase: 476_000, session: second)
        let secondWindow = admit(index: 2, pidBase: 476_000, session: second)
        runLayoutPass(second)

        let restored = second.engine.persistedPlacements(in: second.workspaceId)
        XCTAssertEqual(restored[firstWindow], expected[1])
        XCTAssertEqual(restored[secondWindow], expected[2])
        XCTAssertEqual(restored[third], expected[3])
        XCTAssertEqual(second.engine.tileCount(in: second.workspaceId), 3)
    }

    private func step(
        _ orientation: DwindleOrientation,
        _ ratio: CGFloat,
        _ childIndex: Int
    ) -> PersistedDwindleSplitStep {
        PersistedDwindleSplitStep(orientation: orientation, ratio: ratio, childIndex: childIndex)
    }

    private func threeWindowPlacements(
        a: WindowToken,
        b: WindowToken,
        c: WindowToken
    ) -> [WindowToken: PersistedDwindlePlacement] {
        [
            a: PersistedDwindlePlacement(steps: [step(.horizontal, 1.0, 0)], memberIndex: 0, isActiveMember: true),
            b: PersistedDwindlePlacement(
                steps: [step(.horizontal, 1.0, 1), step(.vertical, 1.2, 0)],
                memberIndex: 0,
                isActiveMember: true
            ),
            c: PersistedDwindlePlacement(
                steps: [step(.horizontal, 1.0, 1), step(.vertical, 1.2, 1)],
                memberIndex: 0,
                isActiveMember: true
            )
        ]
    }

    private func permutations(_ tokens: [WindowToken]) -> [[WindowToken]] {
        guard tokens.count > 1 else { return [tokens] }
        return tokens.indices.flatMap { index -> [[WindowToken]] in
            var rest = tokens
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    private func makeIntent(dwindlePlacement: PersistedDwindlePlacement?) -> PersistedRestoreIntent {
        PersistedRestoreIntent(
            workspaceName: "1",
            topologyProfile: TopologyProfile(monitors: []),
            preferredMonitor: nil,
            floatingFrame: nil,
            normalizedFloatingOrigin: nil,
            restoreToFloating: false,
            rescueEligible: false,
            dwindlePlacement: dwindlePlacement
        )
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DwindleAdmissionRestoreStateTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeSession(root: URL) throws -> Session {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let monitor = Monitor(
            id: .init(displayId: 474_100),
            displayId: 474_100,
            frame: screen,
            visibleFrame: screen,
            hasNotch: false,
            name: "Restore"
        )
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .dwindle
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.layoutRefreshController.resetState()
        return Session(settings: settings, controller: controller, engine: engine, workspaceId: workspaceId)
    }

    private func metadata(index: Int, workspaceId: WorkspaceDescriptor.ID) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: "com.example.dwindle-restore-\(index)",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Window \(index)",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
    }

    private func admit(index: Int, pidBase: pid_t, session: Session) -> WindowToken {
        let token = WindowToken(pid: pidBase + pid_t(index), windowId: 100 + index)
        _ = session.manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: session.workspaceId,
            managedReplacementMetadata: metadata(index: index, workspaceId: session.workspaceId)
        )
        return token
    }

    private func runLayoutPass(_ session: Session) {
        let plans = session.manager.withBatchedLayoutBuild {
            session.controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [session.workspaceId])
        }
        for plan in plans {
            session.manager.setDwindleRestorePlacements(plan.dwindleRestorePlacements)
        }
    }
}
