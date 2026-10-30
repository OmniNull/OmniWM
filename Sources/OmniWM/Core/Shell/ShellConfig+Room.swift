// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

extension ShellConfig {
    static func room(
        in profile: [String: TOMLNode], island: ShellIslandConfig?, problems: inout [String]
    ) -> WorkspaceBarRoom? {
        guard case let .table(islandTable)? = profile["island"], let node = islandTable["room"], let island else {
            return nil
        }
        do {
            return try ShellRoomParser(profile: profile, island: island).parse(node)
        } catch {
            report("shell.toml: [island.room] \(error.localizedDescription)", &problems)
            return nil
        }
    }
}

private struct ShellRoomParser {
    private struct Problem: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    let profile: [String: TOMLNode]
    let island: ShellIslandConfig

    private var settings: [String: TOMLNode] {
        guard case let .table(widgets)? = profile["widgets"], case let .table(root)? = widgets[island.root] else {
            return [:]
        }
        return root
    }

    func parse(_ node: TOMLNode) throws -> WorkspaceBarRoom {
        let table = try table(node, keys: ["setting", "size", "variants", "dock"], name: "room")
        let selector = try name(table["setting"], field: "setting")
        let sizeKey = try table["size"].map { try name($0, field: "size") }
        let size = try sizeKey.flatMap { settings[$0] }.map { try number($0, field: "size setting") } ?? 1
        guard size >= 0 else { throw Problem("size setting must be nonnegative") }
        guard case let .string(selection)? = settings[selector] else {
            throw Problem("setting \(selector) must name a string root setting")
        }
        let (resolved, edge) = try variant(table["variants"], selection: selection, size: size)
        var selected = resolved
        if let dock = table["dock"], let value = try activeDock(dock, size: size), let edge {
            selected.dock = WorkspaceBarRoom.Dock(edge: edge, value: value)
        }
        return selected
    }

    private func variant(
        _ node: TOMLNode?, selection: String, size: Double
    ) throws -> (WorkspaceBarRoom, WorkspaceBarRoom.Edge?) {
        guard case let .table(variants)? = node, !variants.isEmpty else {
            throw Problem("variants must contain at least one named variant")
        }
        var selected: WorkspaceBarRoom?
        var selectedDock: WorkspaceBarRoom.Edge?
        for (key, node) in variants.sorted(by: { $0.key < $1.key }) {
            let variant = try self.table(
                node, keys: Set(WorkspaceBarRoom.Edge.allCases.map(\.rawValue) + ["dock"]), name: "variant \(key)"
            )
            var room = WorkspaceBarRoom(displays: island.displays)
            for edge in WorkspaceBarRoom.Edge.allCases {
                if let node = variant[edge.rawValue] {
                    room.edges[edge] = try reservation(node, edge: edge, size: size)
                }
            }
            var dock: WorkspaceBarRoom.Edge?
            if let node = variant["dock"] {
                guard case let .string(raw) = node, let edge = WorkspaceBarRoom.Edge(rawValue: raw) else {
                    throw Problem("variant \(key) dock must be top, left, right or bottom")
                }
                dock = edge
            }
            if key == selection {
                selected = room
                selectedDock = dock
            }
        }
        guard let selected else { throw Problem("unknown variant \(selection)") }
        return (selected, selectedDock)
    }

    private func activeDock(_ node: TOMLNode, size: Double) throws -> CGFloat? {
        let dock = try table(node, keys: ["base", "scaled", "when", "unless"], name: "dock")
        let value = try value(dock, size: size, name: "dock")
        guard case let .array(conditions)? = dock["when"], !conditions.isEmpty else {
            throw Problem("dock.when must contain root setting names")
        }
        let keys = try conditions.map { try name($0, field: "dock.when") }
        let unless = try dock["unless"].map { try name($0, field: "dock.unless") }
        let active = keys.contains { key in
            switch settings[key] {
            case .boolean(true)?: true
            case let .array(values)?: !values.isEmpty
            default: false
            }
        }
        return active && unless.flatMap({ settings[$0] }) != .boolean(true) ? value : nil
    }

    private func reservation(
        _ node: TOMLNode, edge: WorkspaceBarRoom.Edge, size: Double
    ) throws -> WorkspaceBarRoom.Reservation {
        let keys: Set<String> = edge == .top ? ["base", "scaled", "mode", "clear"] : ["base", "scaled", "mode"]
        let table = try table(node, keys: keys, name: edge.rawValue)
        guard case let .string(raw)? = table["mode"], let mode = WorkspaceBarRoom.Mode(rawValue: raw) else {
            throw Problem("\(edge.rawValue).mode must be add or total")
        }
        let clear: WorkspaceBarRoom.Clearance
        if let node = table["clear"] {
            guard case let .string(raw) = node, let value = WorkspaceBarRoom.Clearance(rawValue: raw) else {
                throw Problem("top.clear must be none, notch or menuBar")
            }
            clear = value
        } else {
            clear = .none
        }
        return try WorkspaceBarRoom.Reservation(
            value: value(table, size: size, name: edge.rawValue),
            mode: mode,
            clear: clear
        )
    }

    private func value(_ table: [String: TOMLNode], size: Double, name: String) throws -> CGFloat {
        let base = try table["base"].map { try number($0, field: "\(name).base") } ?? 0
        let scaled = try table["scaled"].map { try number($0, field: "\(name).scaled") } ?? 0
        let value = floor(base + scaled * size + 0.5)
        guard value.isFinite, value >= 0 else { throw Problem("\(name) must resolve to a finite nonnegative size") }
        return CGFloat(value)
    }

    private func table(_ node: TOMLNode, keys: Set<String>, name: String) throws -> [String: TOMLNode] {
        guard case let .table(table) = node else { throw Problem("\(name) must be a table") }
        if let key = table.keys.sorted().first(where: { !keys.contains($0) }) {
            throw Problem("\(name) has unknown key \(key)")
        }
        return table
    }

    private func name(_ node: TOMLNode?, field: String) throws -> String {
        guard case let .string(value)? = node, ShellConfig.isName(value) else {
            throw Problem("\(field) must be a root setting name")
        }
        return value
    }

    private func number(_ node: TOMLNode, field: String) throws -> Double {
        guard let value = ShellConfig.number(node),
              value.isFinite else { throw Problem("\(field) must be a finite number") }
        return value
    }
}
