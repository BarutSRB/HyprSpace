// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation

struct AXWindowFactsDTO: Codable, Equatable, Sendable {
    var role: String?
    var subrole: String?
    var title: String?
    var hasCloseButton: Bool
    var hasFullscreenButton: Bool
    var fullscreenButtonEnabled: Bool?
    var hasZoomButton: Bool
    var hasMinimizeButton: Bool
    var appPolicy: String?
    var bundleId: String?
    var attributeFetchSucceeded: Bool
    var isMain: Bool?
    var isModal: Bool?

    init(from model: AXWindowFacts) {
        role = model.role
        subrole = model.subrole
        title = model.title
        hasCloseButton = model.hasCloseButton
        hasFullscreenButton = model.hasFullscreenButton
        fullscreenButtonEnabled = model.fullscreenButtonEnabled
        hasZoomButton = model.hasZoomButton
        hasMinimizeButton = model.hasMinimizeButton
        appPolicy = model.appPolicy.flatMap(Self.string(from:))
        bundleId = model.bundleId
        attributeFetchSucceeded = model.attributeFetchSucceeded
        isMain = model.isMain
        isModal = model.isModal
    }

    private static func string(from policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        case .regular: "regular"
        @unknown default: "regular"
        }
    }
}

struct WindowSizeConstraintsDTO: Codable, Equatable, Sendable {
    var minWidth: Double
    var minHeight: Double
    var maxWidth: Double
    var maxHeight: Double
    var isFixed: Bool

    init(from model: WindowSizeConstraints) {
        minWidth = model.minSize.width
        minHeight = model.minSize.height
        maxWidth = model.maxSize.width
        maxHeight = model.maxSize.height
        isFixed = model.isFixed
    }
}

struct WindowServerInfoDTO: Codable, Equatable, Sendable {
    var id: UInt32
    var pid: Int32
    var level: Int32
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
    var tags: UInt64
    var attributes: UInt32
    var parentId: UInt32
    var title: String?

    init(from model: WindowServerInfo) {
        id = model.id
        pid = model.pid
        level = model.level
        frameX = model.frame.minX
        frameY = model.frame.minY
        frameWidth = model.frame.width
        frameHeight = model.frame.height
        tags = model.tags
        attributes = model.attributes
        parentId = model.parentId
        title = model.title
    }
}

struct WindowClassificationInput: Codable, Equatable, Sendable {
    var appName: String?
    var ax: AXWindowFactsDTO
    var sizeConstraints: WindowSizeConstraintsDTO?
    var windowServer: WindowServerInfoDTO?
    var appFullscreen: Bool
    var manualOverride: ManualWindowOverride?
}

struct WindowClassificationDecisionDTO: Codable, Equatable, Sendable {
    var disposition: String
    var source: String
    var heuristicReasons: [String]
    var deferredReason: String?
    var layoutDecisionKind: String
    var workspaceName: String?
    var minWidth: Double?
    var minHeight: Double?
    var initialNiriContainerPrimarySpan: Double?

    init(from decision: WindowDecision) {
        disposition = Self.string(from: decision.disposition)
        source = Self.string(from: decision.source)
        heuristicReasons = decision.heuristicReasons.map(\.rawValue)
        deferredReason = decision.deferredReason?.rawValue
        layoutDecisionKind = decision.layoutDecisionKind.rawValue
        workspaceName = decision.workspaceName
        minWidth = decision.ruleEffects.minWidth
        minHeight = decision.ruleEffects.minHeight
        initialNiriContainerPrimarySpan = decision.admissionHints.initialNiriContainerPrimarySpan
    }

    static func string(from disposition: WindowDecisionDisposition) -> String {
        switch disposition {
        case .floating: "floating"
        case .managed: "managed"
        case .undecided: "undecided"
        case .unmanaged: "unmanaged"
        }
    }

    static func string(from source: WindowDecisionSource) -> String {
        switch source {
        case let .builtInRule(name): "builtInRule(\(name))"
        case .heuristic: "heuristic"
        case .manualOverride: "manualOverride"
        case let .userRule(ruleId): "userRule(\(ruleId.uuidString))"
        }
    }
}
