// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

struct MonitorSetupDraft {
    struct Cell: Hashable {
        var column: Int
        var row: Int

        func moved(_ direction: Direction) -> Cell {
            switch direction {
            case .left:
                Cell(column: column - 1, row: row)
            case .right:
                Cell(column: column + 1, row: row)
            case .up:
                Cell(column: column, row: row - 1)
            case .down:
                Cell(column: column, row: row + 1)
            }
        }
    }

    enum Readiness: Equatable {
        case ready
        case disconnected
        case monitorConfigurationChanged
    }

    private(set) var monitorIDs: Set<Monitor.ID>
    private(set) var cells: [Monitor.ID: Cell]
    var mouseWarpEnabled: Bool
    private let monitorIdentities: Set<OutputId>

    init(
        monitors: [Monitor],
        routingMode: MonitorRoutingMode,
        routingSettings: [MonitorRoutingSettings],
        mouseWarpEnabled: Bool
    ) {
        monitorIDs = Set(monitors.map(\.id))
        monitorIdentities = Set(monitors.map(OutputId.init(from:)))
        self.mouseWarpEnabled = mouseWarpEnabled

        let initialLayout: [MonitorRoutingSettings]
        if routingMode == .custom,
           let customLayout = MonitorRouting.completeLayout(routingSettings, for: monitors)
        {
            initialLayout = customLayout
        } else {
            initialLayout = MonitorRouting.seedLayout(from: monitors)
        }

        var initialCells: [Monitor.ID: Cell] = [:]
        initialCells.reserveCapacity(monitors.count)
        var occupiedCells = Set<Cell>()
        occupiedCells.reserveCapacity(monitors.count)

        for (monitor, settings) in zip(monitors, initialLayout) {
            var cell = Cell(column: settings.gridColumn, row: settings.gridRow)
            while occupiedCells.contains(cell) {
                cell.column += 1
            }
            occupiedCells.insert(cell)
            initialCells[monitor.id] = cell
        }

        cells = initialCells
        normalizeAndCompact()
    }

    var isCardinallyConnected: Bool {
        guard !cells.isEmpty else { return false }
        guard Set(cells.values).count == cells.count else { return false }

        var remaining = Set(cells.keys)
        guard let first = remaining.popFirst() else { return false }
        var frontier = [first]

        while let current = frontier.popLast() {
            guard let currentCell = cells[current] else { continue }
            let neighbors = remaining.filter { candidate in
                guard let candidateCell = cells[candidate] else { return false }
                return candidateCell.column == currentCell.column || candidateCell.row == currentCell.row
            }
            remaining.subtract(neighbors)
            frontier.append(contentsOf: neighbors)
        }

        return remaining.isEmpty
    }

    func cell(for monitorID: Monitor.ID) -> Cell? {
        cells[monitorID]
    }

    mutating func place(_ monitorID: Monitor.ID, at destination: Cell) {
        MonitorRoutingGridEditor.place(monitorID, at: destination, cells: &cells)
    }

    mutating func move(_ monitorID: Monitor.ID, direction: Direction) {
        guard let source = cells[monitorID] else { return }
        place(monitorID, at: source.moved(direction))
    }

    func readiness(for monitors: [Monitor]) -> Readiness {
        guard Set(monitors.map(\.id)) == monitorIDs,
              Set(monitors.map(OutputId.init(from:))) == monitorIdentities
        else {
            return .monitorConfigurationChanged
        }
        return isCardinallyConnected ? .ready : .disconnected
    }

    func routingSettings(
        preserving existing: [MonitorRoutingSettings],
        monitors: [Monitor]
    ) -> [MonitorRoutingSettings]? {
        guard readiness(for: monitors) == .ready else { return nil }
        let routingCells = cells.mapValues { cell in
            (column: cell.column, row: cell.row)
        }
        return MonitorSettingsTabModel.routingSettingsAfterEdit(
            existing: existing,
            monitors: monitors,
            cells: routingCells
        )
    }

    private mutating func normalizeAndCompact() {
        MonitorRoutingGridEditor.normalizeAndCompact(&cells)
    }
}

enum MonitorRoutingGridEditor {
    static func place(
        _ monitorID: Monitor.ID,
        at destination: MonitorSetupDraft.Cell,
        cells: inout [Monitor.ID: MonitorSetupDraft.Cell]
    ) {
        guard let source = cells[monitorID] else { return }
        if let occupant = cells.first(where: {
            $0.key != monitorID && $0.value == destination
        })?.key {
            cells[occupant] = source
        }
        cells[monitorID] = destination
        normalizeAndCompact(&cells)
    }

    static func normalizeAndCompact(_ cells: inout [Monitor.ID: MonitorSetupDraft.Cell]) {
        let columns = Array(Set(cells.values.map(\.column))).sorted()
        let rows = Array(Set(cells.values.map(\.row))).sorted()
        let normalizedColumns = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
        let normalizedRows = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })

        cells = cells.mapValues { cell in
            MonitorSetupDraft.Cell(
                column: normalizedColumns[cell.column] ?? 0,
                row: normalizedRows[cell.row] ?? 0
            )
        }
    }
}
