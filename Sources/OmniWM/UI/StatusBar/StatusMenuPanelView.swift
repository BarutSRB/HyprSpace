// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation
import SwiftUI

enum StatusMenuKeyboardPolicy {
    static func acceptsModifiers(_ modifiers: EventModifiers, allowingShift: Bool = false) -> Bool {
        modifiers.subtracting(allowingShift ? .shift : []).isEmpty
    }
}

enum StatusMenuPage: CaseIterable, Hashable, Sendable {
    case root
    case advanced
    case diagnostics
    case help

    var title: String {
        switch self {
        case .root: "OmniWM"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        case .help: "Help & Links"
        }
    }

    var icon: String {
        switch self {
        case .root: "menubar.rectangle"
        case .advanced: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .help: "questionmark.circle"
        }
    }
}

@MainActor
@Observable
final class StatusMenuPresentation {
    var expandedPage: StatusMenuPage?
    var rootFocusRequest: StatusMenuPage?
    var rootFocusGeneration = 0
}

enum StatusMenuFocusItem: Hashable, Sendable {
    case action(String)
    case control(StatusMenuControl)
}

extension EnvironmentValues {
    @Entry var statusMenuFocus: FocusState<StatusMenuFocusItem?>.Binding? = nil
    @Entry var statusMenuControlHover: (Bool) -> Void = { _ in }
}

struct StatusMenuFocusOrder: PreferenceKey {
    static let defaultValue: [StatusMenuFocusItem] = []

    static func reduce(value: inout [StatusMenuFocusItem], nextValue: () -> [StatusMenuFocusItem]) {
        value.append(contentsOf: nextValue())
    }
}

struct StatusMenuFocusModifier: ViewModifier {
    let item: StatusMenuFocusItem

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.statusMenuFocus) private var focus

    func body(content: Content) -> some View {
        Group {
            if let focus {
                content.focused(focus, equals: item)
            } else {
                content
            }
        }
        .preference(key: StatusMenuFocusOrder.self, value: isEnabled ? [item] : [])
    }
}

struct StatusMenuPanelView: View {
    let model: StatusMenuModel
    let page: StatusMenuPage
    let presentation: StatusMenuPresentation
    let onOpenSubmenu: (StatusMenuPage, Bool) -> Void
    let onHoverSubmenu: (StatusMenuPage?, Bool) -> Void
    let onSubmenuRowFrame: (StatusMenuPage, CGRect) -> Void
    let onSubmenuEnter: () -> Void
    let onCloseSubmenu: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedItem: StatusMenuFocusItem?
    @State private var focusOrder: [StatusMenuFocusItem] = []

    var body: some View {
        VStack(spacing: 0) {
            if page == .root {
                StatusMenuPrimaryView(model: model)
                ForEach(StatusMenuPage.allCases.filter { $0 != .root }, id: \.self) { destination in
                    MenuActionRow(
                        icon: destination.icon,
                        label: destination.title,
                        showChevron: true,
                        dismissesMenu: false,
                        isExpanded: presentation.expandedPage == destination
                    ) {
                        onOpenSubmenu(destination, true)
                    }
                    .environment(\.statusMenuControlHover) { hovered in
                        onHoverSubmenu(destination, hovered)
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(StatusMenuPage.root))
                    } action: { frame in
                        onSubmenuRowFrame(destination, frame)
                    }
                }
                StatusMenuFooterView(model: model)
            } else {
                pageContent
            }
        }
        .padding(.bottom, 6)
        .frame(width: statusMenuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: StatusMenuPage.root)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
            }
            shape.strokeBorder(
                Color.primary.opacity(colorSchemeContrast == .increased ? 0.45 : 0.16),
                lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
            )
        }
        .environment(\.statusMenuFocus, $focusedItem)
        .environment(\.statusMenuControlHover) { hovered in
            if page == .root {
                onHoverSubmenu(nil, hovered)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            onContentSizeChange(size)
        }
        .onHover { hovered in
            if page != .root, hovered {
                onSubmenuEnter()
            }
        }
        .onPreferenceChange(StatusMenuFocusOrder.self) { items in
            focusOrder = items
            if focusedItem.map({ !items.contains($0) }) ?? true {
                focusedItem = items.first
            }
        }
        .onAppear {
            focusedItem = focusOrder.first
        }
        .onChange(of: presentation.rootFocusGeneration) { _, _ in
            if page == .root, let destination = presentation.rootFocusRequest {
                focusedItem = .action(destination.title)
            }
        }
        .onKeyPress(keys: [.tab, .upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard StatusMenuKeyboardPolicy.acceptsModifiers(press.modifiers, allowingShift: press.key == .tab)
            else { return .ignored }
            if press.key == .leftArrow {
                guard page != .root else { return .ignored }
                onCloseSubmenu()
                return .handled
            }
            if press.key == .rightArrow {
                guard page == .root,
                      let destination = StatusMenuPage.allCases.first(where: {
                          $0 != .root && focusedItem == .action($0.title)
                      })
                else { return .ignored }
                onOpenSubmenu(destination, true)
                return .handled
            }
            guard !focusOrder.isEmpty else { return .ignored }
            let backwards = press.key == .upArrow
                || (press.key == .tab && press.modifiers.contains(.shift))
            let offset = backwards ? -1 : 1
            if let focusedItem, let index = focusOrder.firstIndex(of: focusedItem) {
                self.focusedItem = focusOrder[(index + offset + focusOrder.count) % focusOrder.count]
            } else {
                focusedItem = backwards ? focusOrder.last : focusOrder.first
            }
            return .handled
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .root: EmptyView()
        case .advanced: StatusMenuAdvancedView(model: model)
        case .diagnostics: StatusMenuDiagnosticsView(model: model)
        case .help: StatusMenuHelpLinksView(model: model)
        }
    }
}
