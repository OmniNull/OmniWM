// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

extension ShellConfig {
    private static let drawerKeys: Set = ["edge", "widgets", "hover", "reach", "width", "close", "chrome"]

    private static let weatherKeys: Set = ["city", "latitude", "longitude", "units", "refresh"]

    static func applyServices(
        _ table: [String: TOMLNode],
        to config: inout ShellConfig,
        _ problems: inout [String]
    ) {
        config.island = islandConfig(table["island"], &problems)
        if case let .table(weather)? = table["weather"] {
            unknownKeys(in: weather, known: weatherKeys, of: "shell.toml: [weather]", &problems)
            config.weather = weatherLocation(weather, &problems)
        }
        if case let .string(name)? = table["hiddenBarWidget"] {
            config.hiddenBarWidget = isName(name) ? name : nil
        }
        if case let .string(name)? = table["systemStatsWidget"] {
            config.systemStatsWidget = isName(name) ? name : nil
        }
        if case let .table(drawers)? = table["drawer"] {
            config.drawers = drawers.keys.sorted().compactMap { drawer($0, drawers[$0], &problems) }
        }
        if case let .table(hiddenBar)? = table["hiddenBar"] {
            config.hiddenBarOverride = hiddenBarOverride(hiddenBar, profile: config.profile, &problems)
        }
    }

    private static func islandConfig(_ node: TOMLNode?, _ problems: inout [String]) -> ShellIslandConfig? {
        guard let node else { return nil }
        guard case let .table(table) = node else {
            report("shell.toml: [island] must be a table", &problems)
            return nil
        }
        unknownKeys(
            in: table,
            known: ["root", "displays", "width", "height", "fullscreen", "components"],
            of: "shell.toml: [island]",
            &problems
        )
        var island = ShellIslandConfig()
        if let root = table["root"] {
            guard case let .string(name) = root, isName(name) else {
                report("shell.toml: [island] root must be a widget name", &problems)
                return nil
            }
            island.root = name
        }
        if let displays = table["displays"] {
            guard case let .string(name) = displays, let value = ShellIslandConfig.Displays(rawValue: name) else {
                report("shell.toml: [island] displays must be notch, main or all", &problems)
                return nil
            }
            island.displays = value
        }
        if let fullscreen = table["fullscreen"] {
            guard case let .string(name) = fullscreen, let value = ShellIslandConfig.Fullscreen(rawValue: name) else {
                report("shell.toml: [island] fullscreen must be hide or show", &problems)
                return nil
            }
            island.fullscreen = value
        }
        guard applyIslandSize(table, to: &island, &problems) else { return nil }
        do {
            island.components = try ShellComponentCatalog.instances(from: table["components"])
        } catch {
            report("shell.toml: \(error.localizedDescription)", &problems)
            return nil
        }
        return island
    }

    private static func applyIslandSize(
        _ table: [String: TOMLNode], to island: inout ShellIslandConfig, _ problems: inout [String]
    ) -> Bool {
        for key in ["width", "height"] where table[key] != nil {
            guard let value = number(table[key]), value.isFinite, (1 ... 8192).contains(value) else {
                report("shell.toml: [island] \(key) must be a finite number between 1 and 8192", &problems)
                return false
            }
            if key == "width" { island.width = value } else { island.height = value }
        }
        return true
    }

    private static func hiddenBarOverride(
        _ table: [String: TOMLNode],
        profile: String,
        _ problems: inout [String]
    ) -> HiddenBarProfileOverride? {
        var hiddenBar = HiddenBarProfileOverride(profile: profile)
        for (key, node) in table.sorted(by: { $0.key < $1.key }) {
            if key == "enabled", case let .boolean(value) = node {
                hiddenBar.enabled = value
            } else if key == "rehideIntervalSeconds", let value = number(node) {
                hiddenBar.rehideIntervalSeconds = HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(value)
            } else {
                report("shell.toml: [hiddenBar] \(key) is not a Hidden Bar setting a profile can override", &problems)
            }
        }
        return hiddenBar.overriddenKeys.isEmpty ? nil : hiddenBar
    }

    private static func drawer(_ id: String, _ node: TOMLNode?, _ problems: inout [String]) -> ShellDrawerConfig? {
        guard isName(id), case let .table(table)? = node else {
            report("shell.toml: [drawer.\(id)] must be a table with a name", &problems)
            return nil
        }
        unknownKeys(in: table, known: drawerKeys, of: "shell.toml: [drawer.\(id)]", &problems)
        var edge = ShellDrawerConfig.Edge.right
        if let node = table["edge"] {
            guard case let .string(name) = node, let parsed = ShellDrawerConfig.Edge(rawValue: name) else {
                report("shell.toml: [drawer.\(id)] edge must be left, right, top or bottom", &problems)
                return nil
            }
            edge = parsed
        }
        let widgets = names(table["widgets"], key: "[drawer.\(id)] widgets", &problems).filter(isName)
        guard !widgets.isEmpty else {
            report("shell.toml: [drawer.\(id)] needs at least one widget", &problems)
            return nil
        }
        var drawer = ShellDrawerConfig(id: id, edge: edge, widgets: widgets, hover: table["hover"] == .boolean(true))
        if let reach = number(table["reach"]) {
            drawer.reach = CGFloat(min(max(reach, 1), 100))
        }
        drawer.width = number(table["width"]).map { CGFloat(max($0, 1)) }
        switch table["close"] {
        case nil,
             .string("outside")?: break
        case .string("leave")?: drawer.closesOnLeave = true
        default: report("shell.toml: [drawer.\(id)] close must be \"outside\" or \"leave\"", &problems)
        }
        if case let .boolean(chrome)? = table["chrome"] {
            drawer.chrome = chrome
        }
        return drawer
    }
}
