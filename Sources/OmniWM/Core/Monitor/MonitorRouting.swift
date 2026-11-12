// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum MonitorRouting {
    enum Adjacency: Equatable {
        case monitor(Monitor)
        case edge
        case fallBackToMacOS
    }

    static func arrangementIndex(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> Int? {
        guard !monitors.isEmpty else { return nil }
        var selectedIndex: Int?
        var selectedCount = Int.max

        for index in arrangements.indices {
            let layout = arrangements[index].monitors
            guard layout.count >= monitors.count,
                  layout.count < selectedCount,
                  monitors.allSatisfy({ MonitorSettingsStore.get(for: $0, in: layout) != nil })
            else { continue }
            if layout.count == monitors.count { return index }
            selectedIndex = index
            selectedCount = layout.count
        }

        return selectedIndex
    }

    static func exactArrangementIndex(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> Int? {
        guard let index = arrangementIndex(for: monitors, in: arrangements),
              arrangements[index].monitors.count == monitors.count
        else { return nil }
        return index
    }

    static func layout(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> [MonitorRoutingSettings] {
        guard let index = arrangementIndex(for: monitors, in: arrangements) else { return [] }
        return arrangements[index].monitors
    }

    static func store(
        _ layout: [MonitorRoutingSettings],
        for monitors: [Monitor],
        in arrangements: inout [MonitorArrangement]
    ) {
        guard !monitors.isEmpty else { return }
        if let index = exactArrangementIndex(for: monitors, in: arrangements) {
            arrangements[index].monitors = layout
        } else {
            arrangements.append(MonitorArrangement(monitors: layout))
        }
    }

    static func gridAdjacent(
        from source: Monitor,
        direction: Direction,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor],
        wrapAround: Bool
    ) -> Adjacency {
        guard let grid = Grid(layout: layout, monitors: monitors) else { return .fallBackToMacOS }
        return grid.adjacent(from: source.id, direction: direction, wrapAround: wrapAround)
    }

    struct Grid {
        private let monitors: [Monitor]
        private let cells: [GridCell]

        init?(layout: [MonitorRoutingSettings], monitors: [Monitor]) {
            guard let completeLayout = MonitorRouting.completeLayout(layout, for: monitors) else { return nil }
            self.monitors = monitors
            cells = completeLayout.map { GridCell(column: $0.gridColumn, row: $0.gridRow) }
        }

        func adjacent(from source: Monitor.ID, direction: Direction, wrapAround: Bool) -> Adjacency {
            guard let originIndex = monitors.firstIndex(where: { $0.id == source }) else { return .fallBackToMacOS }
            let origin = cells[originIndex]
            var nearest: (index: Int, offset: Int)?
            var farthestBehind: (index: Int, offset: Int)?
            for index in cells.indices where index != originIndex && cells[index].sharesLine(
                with: origin,
                direction: direction
            ) {
                let offset = cells[index].offset(from: origin, direction: direction)
                if offset > 0, offset < nearest?.offset ?? .max { nearest = (index, offset) }
                if offset < farthestBehind?.offset ?? .max { farthestBehind = (index, offset) }
            }
            if let nearest { return .monitor(monitors[nearest.index]) }
            guard wrapAround, let farthestBehind else { return .edge }
            return .monitor(monitors[farthestBehind.index])
        }
    }

    static func completeLayout(
        _ layout: [MonitorRoutingSettings],
        for monitors: [Monitor]
    ) -> [MonitorRoutingSettings]? {
        var completeLayout: [MonitorRoutingSettings] = []
        completeLayout.reserveCapacity(monitors.count)
        var occupiedCells = Set<GridCell>()
        occupiedCells.reserveCapacity(monitors.count)

        for monitor in monitors {
            guard let settings = MonitorSettingsStore.get(for: monitor, in: layout) else {
                return nil
            }
            let cell = GridCell(column: settings.gridColumn, row: settings.gridRow)
            guard occupiedCells.insert(cell).inserted else { return nil }
            completeLayout.append(settings)
        }

        return completeLayout
    }

    static func seedLayout(from monitors: [Monitor]) -> [MonitorRoutingSettings] {
        let columns = sortedDistinct(monitors.map(\.frame.center.x), ascending: true)
        let rows = sortedDistinct(monitors.map(\.frame.center.y), ascending: false)
        return monitors.map { monitor in
            MonitorRoutingSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: monitor.displayUUID,
                monitorDisplayId: monitor.displayId,
                gridColumn: columns.firstIndex(of: monitor.frame.center.x) ?? 0,
                gridRow: rows.firstIndex(of: monitor.frame.center.y) ?? 0
            )
        }
    }

    private static func sortedDistinct(_ values: [CGFloat], ascending: Bool) -> [CGFloat] {
        let unique = Array(Set(values))
        return ascending ? unique.sorted() : unique.sorted(by: >)
    }
}

private struct GridCell: Hashable {
    let column: Int
    let row: Int

    func sharesLine(with origin: GridCell, direction: Direction) -> Bool {
        switch direction {
        case .left,
             .right: row == origin.row
        case .up,
             .down: column == origin.column
        }
    }

    func offset(from origin: GridCell, direction: Direction) -> Int {
        switch direction {
        case .right: column - origin.column
        case .left: origin.column - column
        case .down: row - origin.row
        case .up: origin.row - row
        }
    }
}
