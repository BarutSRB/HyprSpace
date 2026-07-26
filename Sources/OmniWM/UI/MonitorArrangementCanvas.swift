// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct MonitorArrangementCanvas: View {
    let monitors: [Monitor]
    let displayLabels: [Monitor.ID: MonitorDisplayLabel]
    var selected: Monitor.ID? = nil
    var onSelect: ((Monitor.ID) -> Void)? = nil
    var height: CGFloat = 170

    var body: some View {
        GeometryReader { proxy in
            let rects = MonitorArrangementGeometry.canvasRects(
                forFramesYUp: monitors.map(\.frame),
                in: proxy.size,
                padding: 12
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(monitors.enumerated()), id: \.element.id) { index, monitor in
                    if rects.indices.contains(index) {
                        MonitorArrangementTile(
                            displayLabel: displayLabels[monitor.id],
                            fallbackName: monitor.name,
                            isMain: monitor.isMain,
                            isSelected: monitor.id == selected
                        )
                        .frame(width: rects[index].width, height: rects[index].height)
                        .offset(x: rects[index].minX, y: rects[index].minY)
                        .onTapGesture { onSelect?(monitor.id) }
                        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

struct MonitorArrangementTile: View {
    let displayLabel: MonitorDisplayLabel?
    let fallbackName: String
    let isMain: Bool
    var isSelected: Bool = false
    var identifierNumber: Int? = nil

    private var name: String {
        displayLabel?.name ?? fallbackName
    }

    private var accessibilityName: String {
        guard let identifierNumber else { return name }
        return "Display \(identifierNumber), \(name)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(isSelected ? 0.2 : 0.12))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.45),
                    lineWidth: isSelected ? 2 : 1
                )

            VStack(spacing: 3) {
                Text(name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)

                if let badgeText = displayLabel?.badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        .overlay(alignment: .top) {
            if isMain {
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(height: 3)
                    .padding(.horizontal, 4)
            }
        }
        .overlay(alignment: .topLeading) {
            if let identifierNumber {
                Text(identifierNumber.formatted())
                    .font(.caption2.bold())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.regularMaterial, in: Circle())
                    .padding(5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMain ? "\(accessibilityName), main display" : accessibilityName)
    }
}

struct RoutingArrangementCanvas: View {
    struct Tile: Identifiable {
        let id: Monitor.ID
        let column: Int
        let row: Int
        let displayLabel: MonitorDisplayLabel?
        let fallbackName: String
        let isMain: Bool
        var identifierNumber: Int? = nil
    }

    let tiles: [Tile]
    let selected: Monitor.ID?
    let onSelect: (Monitor.ID) -> Void
    let onPlace: (Monitor.ID, Int, Int) -> Void
    var height: CGFloat = 200

    private let spacing: CGFloat = 8
    private let padding: CGFloat = 12

    @State private var draggingID: Monitor.ID?
    @State private var dragTranslation: CGSize = .zero

    private var minColumn: Int {
        tiles.map(\.column).min() ?? 0
    }

    private var minRow: Int {
        tiles.map(\.row).min() ?? 0
    }

    private var columnCount: Int {
        (tiles.map(\.column).max() ?? 0) - minColumn + 1
    }

    private var rowCount: Int {
        (tiles.map(\.row).max() ?? 0) - minRow + 1
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = MonitorArrangementGeometry.gridFit(
                columns: columnCount,
                rows: rowCount,
                in: proxy.size,
                padding: padding,
                spacing: spacing
            )
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    let frame = MonitorArrangementGeometry.cellFrame(
                        column: tile.column - minColumn,
                        row: tile.row - minRow,
                        fit: fit,
                        spacing: spacing
                    )
                    MonitorArrangementTile(
                        displayLabel: tile.displayLabel,
                        fallbackName: tile.fallbackName,
                        isMain: tile.isMain,
                        isSelected: tile.id == selected,
                        identifierNumber: tile.identifierNumber
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(
                        x: frame.minX + (draggingID == tile.id ? dragTranslation.width : 0),
                        y: frame.minY + (draggingID == tile.id ? dragTranslation.height : 0)
                    )
                    .zIndex(draggingID == tile.id ? 1 : 0)
                    .onTapGesture { onSelect(tile.id) }
                    .gesture(dragGesture(for: tile, frame: frame, fit: fit))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func dragGesture(
        for tile: Tile,
        frame: CGRect,
        fit: MonitorArrangementGeometry.GridFit
    ) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if draggingID != tile.id {
                    draggingID = tile.id
                    onSelect(tile.id)
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                let center = CGPoint(
                    x: frame.midX + value.translation.width,
                    y: frame.midY + value.translation.height
                )
                let nearest = MonitorArrangementGeometry.nearestCell(toPoint: center, fit: fit, spacing: spacing)
                let column = min(max(nearest.column, -1), columnCount)
                let row = min(max(nearest.row, -1), rowCount)
                draggingID = nil
                dragTranslation = .zero
                onPlace(tile.id, minColumn + column, minRow + row)
            }
    }
}

struct RoutingAccessibleEditor: View {
    struct Row: Identifiable {
        let id: Monitor.ID
        let name: String
    }

    let rows: [Row]
    let onMove: (Monitor.ID, Direction) -> Void

    var body: some View {
        ForEach(rows) { row in
            LabeledContent(row.name) {
                HStack(spacing: 6) {
                    moveButton(row, .left, symbol: "arrow.left", label: "left")
                    moveButton(row, .up, symbol: "arrow.up", label: "up")
                    moveButton(row, .down, symbol: "arrow.down", label: "down")
                    moveButton(row, .right, symbol: "arrow.right", label: "right")
                }
            }
        }
    }

    private func moveButton(_ row: Row, _ direction: Direction, symbol: String, label: String) -> some View {
        Button {
            onMove(row.id, direction)
        } label: {
            Label("Move \(row.name) \(label)", systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Move \(row.name) \(label)")
    }
}
