// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriVisibleContainerCountTests: XCTestCase {
    private func proportion(of column: NiriContainer) -> CGFloat? {
        if case let .proportion(value) = column.width { return value }
        return nil
    }

    private func makeEngineWithColumns(_ count: Int) -> (NiriLayoutEngine, WorkspaceDescriptor.ID) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        for index in 1 ... count {
            _ = engine.addWindow(
                token: WindowToken(pid: 1, windowId: index),
                to: workspaceId,
                afterSelection: nil
            )
        }
        return (engine, workspaceId)
    }

    func testBalanceSizesReTilesExistingContainersToOneOverN() throws {
        let (engine, workspaceId) = makeEngineWithColumns(3)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 3)
        for column in engine.columns(in: workspaceId) {
            XCTAssertEqual(try XCTUnwrap(proportion(of: column)), 0.5, accuracy: 0.0001)
        }

        engine.visibleContainerCount = 3
        engine.defaultContainerPrimarySpan = nil

        let didChange = engine.balanceSizes(
            in: workspaceId,
            motion: .disabled,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: 12,
            orientation: .horizontal
        )

        XCTAssertTrue(didChange)
        for column in engine.columns(in: workspaceId) {
            XCTAssertEqual(try XCTUnwrap(proportion(of: column)), 1.0 / 3.0, accuracy: 0.0001)
        }
    }

    func testBalanceSizesReturnsFalseForEmptyWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()

        let didChange = engine.balanceSizes(
            in: workspaceId,
            motion: .disabled,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: 12,
            orientation: .horizontal
        )

        XCTAssertFalse(didChange)
    }

    func testResolvedContainerResetPrimarySpanDerivesFromVisibleContainerCountWhenAuto() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        engine.visibleContainerCount = 3
        engine.defaultContainerPrimarySpan = nil

        XCTAssertEqual(
            engine.resolvedContainerResetPrimarySpan(in: workspaceId).proportion,
            1.0 / 3.0,
            accuracy: 0.0001
        )
    }

    func testResolvedContainerResetPrimarySpanHonorsExplicitDefault() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        engine.visibleContainerCount = 3
        engine.defaultContainerPrimarySpan = 0.5

        XCTAssertEqual(
            engine.resolvedContainerResetPrimarySpan(in: workspaceId).proportion,
            0.5,
            accuracy: 0.0001
        )
    }
}
