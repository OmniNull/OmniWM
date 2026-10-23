// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

enum ShellLane: String, Equatable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

struct ShellDrawerConfig: Equatable {
    enum Edge: String {
        case left
        case right
        case top
        case bottom
    }

    let id: String
    let edge: Edge
    let widgets: [String]
    let hover: Bool
    var reach: CGFloat = 1
    var width: CGFloat?
    var closesOnLeave = false
    var chrome = true
}

struct ShellConfig: Equatable {
    static let bundledScratchpads = "scratchpads"

    var profile = ShellDefaults.profile
    var directories: [URL] = []
    var themeName = "native"
    var styleThemeName = "native"
    var theme = ShellTheme.native
    var wallpaperScheme = ShellWallpaperScheme.tonalSpot
    var leading: [String] = []
    var center: [String] = []
    var trailing: [String] = []
    var widgetSettings: [String: [UInt8]] = [:]
    var widgetIntervals: [String: Double] = [:]
    var weather: ShellWeatherLocation?
    var barOverride: WorkspaceBarProfileOverride?
    var barShader: ShellBarShader?
    var hiddenBarOverride: HiddenBarProfileOverride?
    var hiddenBarWidget: String?
    var systemStatsWidget: String?
    var drawers: [ShellDrawerConfig] = []
    var island: ShellIslandConfig?

    static func bundledWidget(_ name: String) -> URL? {
        isName(name) ? ShellDefaults.bundledFile("widgets/\(name)/init.luau") : nil
    }

    func widget(_ name: String) -> URL? {
        Self.isName(name) ? file("widgets/\(name)/init.luau") : nil
    }

    func file(_ path: String) -> URL? {
        directories.lazy
            .map { $0.appendingPathComponent(path) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func widgetFolders(in layer: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: layer.appendingPathComponent("widgets", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory
                .boolValue
        }
    }

    func barLane(of widget: String) -> ShellLane? {
        ShellLane.allCases.first { lane in
            switch lane {
            case .leading: leading.contains(widget)
            case .center: center.contains(widget)
            case .trailing: trailing.contains(widget)
            }
        }
    }

    func lane(of widget: String) -> (lane: ShellLane, rank: Int) {
        if let index = leading.firstIndex(of: widget) {
            return (.leading, index)
        }
        if let index = center.firstIndex(of: widget) {
            return (.center, index)
        }
        return (.trailing, trailing.firstIndex(of: widget) ?? trailing.count)
    }
}

extension ShellConfig {
    static func isName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }

    static let profilesKey = "profiles"
    private static let topKeys: Set = ["profile", "weather", profilesKey]
    private static let profileKeys: Set = [
        "theme", "scheme", "leading", "center", "trailing", "widgets", "weather", "hiddenBarWidget",
        "systemStatsWidget", "drawer", "workspaceBar", "hiddenBar", "monitorBarOverrides", "island", "barShader"
    ]
    private static let themeKeys: Set = ["light", "dark", "workspaceBar"]

    static func load(shellDirectory: URL, problems: inout [String]) -> ShellConfig? {
        load(shellDirectory, skippingBrokenLayers: false, problems: &problems)
    }

    static func load(profile: String, shellDirectory: URL, problems: inout [String]) -> ShellConfig? {
        load(shellDirectory, profile: profile, skippingBrokenLayers: false, problems: &problems)
    }

    static func resolve(shellDirectory: URL) -> ShellConfig {
        var problems: [String] = []
        return resolve(shellDirectory: shellDirectory, problems: &problems)
    }

    static func resolve(shellDirectory: URL, problems: inout [String]) -> ShellConfig {
        if let config = load(shellDirectory: shellDirectory, problems: &problems) {
            return config
        }
        problems = []
        return load(shellDirectory, skippingBrokenLayers: true, problems: &problems) ?? ShellConfig()
    }

    static func report(_ problem: String, _ problems: inout [String]) {
        Log.shell.error(problem)
        problems.append(problem)
    }

    private static func load(
        _ shellDirectory: URL,
        profile: String? = nil,
        skippingBrokenLayers: Bool,
        problems: inout [String]
    ) -> ShellConfig? {
        var config = ShellConfig()
        guard var top = layer(in: shellDirectory, &problems) ?? (skippingBrokenLayers ? [:] : nil) else { return nil }
        if let profile { top["profile"] = .string(profile) }
        selectProfile(top, in: shellDirectory, for: &config, &problems)
        var table: [String: TOMLNode] = [:]
        for directory in config.directories.reversed() where directory != shellDirectory {
            guard let next = layer(in: directory, &problems) ?? (skippingBrokenLayers ? [:] : nil) else { return nil }
            table = merged(table, next)
        }
        if case let .string(name)? = table["theme"] {
            config.styleThemeName = name
        }
        let own = ownLayer(top, profile: config.profile, &problems)
        table = merged(table, own)
        applyProfile(table, own: own, to: &config, &problems)
        return config
    }

    private static func applyProfile(
        _ table: [String: TOMLNode], own: [String: TOMLNode],
        to config: inout ShellConfig, _ problems: inout [String]
    ) {
        unknownKeys(in: table, known: profileKeys, of: "shell.toml", &problems)
        config.themeName = config.styleThemeName
        if case let .string(name)? = table["theme"] {
            config.themeName = name
        }
        if let scheme = table["scheme"] {
            if case let .string(name) = scheme, let value = ShellWallpaperScheme(rawValue: name) {
                config.wallpaperScheme = value
            } else {
                let names = ShellWallpaperScheme.allCases.map(\.rawValue).joined(separator: ", ")
                report("shell.toml: scheme must be one of \(names)", &problems)
            }
        }
        config.leading = names(table["leading"], key: "leading", &problems)
        config.center = names(table["center"], key: "center", &problems)
        config.trailing = names(table["trailing"], key: "trailing", &problems)
        if case let .table(widgets)? = table["widgets"] {
            applyWidgetSettings(widgets, to: &config, &problems)
        }
        applyServices(table, to: &config, &problems)
        config.barShader = ShellBarShader.parse(table["barShader"], problems: &problems)
        applyComponentTrust(own, to: &config)
        applyBarSettings(table, to: &config, &problems)
    }

    private static func applyComponentTrust(_ own: [String: TOMLNode], to config: inout ShellConfig) {
        if var island = config.island {
            let userInstances: [ShellComponentInstance]
            if case let .table(ownIsland)? = own["island"] {
                userInstances = (try? ShellComponentCatalog.instances(from: ownIsland["components"])) ?? []
            } else {
                userInstances = []
            }
            for index in island.components.indices {
                let configured = island.components[index]
                let trusted = userInstances.first { $0.id == configured.id && $0.widget == configured.widget }
                island.components[index].provider = trusted?.provider ?? false
                island.components[index].capabilities = trusted?.capabilities
            }
            config.island = island
        }
    }

    private static func applyBarSettings(
        _ table: [String: TOMLNode], to config: inout ShellConfig, _ problems: inout [String]
    ) {
        var bar: [String: TOMLNode] = [:]
        if case let .table(themeBar)? = loadTheme(into: &config, &problems)?["workspaceBar"] {
            bar = themeBar
        }
        if case let .table(profileBar)? = table["workspaceBar"] {
            bar = merged(bar, profileBar)
        }
        config.barOverride = barOverride(
            bar,
            profile: config.profile,
            theme: config.theme,
            &problems,
            themeColors: true
        )
        if let monitors = table["monitorBarOverrides"] {
            do {
                config.barOverride?.monitorOverrides = try ShellTOMLText.decode(
                    [MonitorBarSettings].self,
                    from: monitors
                )
            } catch {
                report("shell.toml: monitorBarOverrides must contain valid monitor bar settings", &problems)
            }
        }
    }

    private static func ownLayer(
        _ top: [String: TOMLNode],
        profile: String,
        _ problems: inout [String]
    ) -> [String: TOMLNode] {
        for key in top.keys.sorted() where !topKeys.contains(key) {
            report(
                profileKeys.contains(key)
                    ? "shell.toml: \(key) belongs in [\(profilesKey).\(profile)], the settings for the \(profile) profile"
                    : "shell.toml has unknown key \(key)",
                &problems
            )
        }
        var own: [String: TOMLNode] = [:]
        if case let .table(weather)? = top["weather"] {
            own["weather"] = .table(weather)
        }
        switch top[profilesKey] {
        case nil:
            break
        case let .table(profiles)?:
            if case let .table(settings)? = profiles[profile] {
                own = merged(own, settings)
            } else if profiles[profile] != nil {
                report("shell.toml: [\(profilesKey).\(profile)] must be a table of settings", &problems)
            }
        default:
            report("shell.toml: \(profilesKey) must be a table of profile settings", &problems)
        }
        return own
    }

    private static func selectProfile(
        _ top: [String: TOMLNode],
        in shellDirectory: URL,
        for config: inout ShellConfig,
        _ problems: inout [String]
    ) {
        if case let .string(name)? = top["profile"] {
            if isName(name), FileManager.default.fileExists(atPath: shellDirectory.appendingPathComponent(name).path) {
                config.profile = name
            } else {
                report("shell.toml: no profile folder named \(name), using \(ShellDefaults.profile)", &problems)
            }
        }
        config.directories = [shellDirectory]
        for name in [config.profile, ShellDefaults.profile] {
            let directory = shellDirectory.appendingPathComponent(name, isDirectory: true)
            if !config.directories.contains(directory) {
                config.directories.append(directory)
            }
        }
    }

    private static func applyWidgetSettings(
        _ widgets: [String: TOMLNode],
        to config: inout ShellConfig,
        _ problems: inout [String]
    ) {
        for (name, node) in widgets {
            guard case .table = node else {
                report("shell.toml: [widgets.\(name)] must be a table of settings", &problems)
                continue
            }
            var writer = ShellValueWriter()
            encode(node, into: &writer)
            config.widgetSettings[name] = writer.bytes
            if case let .table(settings) = node,
               let interval = number(settings["interval"]).flatMap(ShellWidgetDeclaration.validInterval)
            {
                config.widgetIntervals[name] = interval
            }
        }
    }

    private static func loadTheme(into config: inout ShellConfig, _ problems: inout [String]) -> [String: TOMLNode]? {
        guard config.themeName != "native" else { return nil }
        let path = "themes/\(config.themeName).toml"
        let themeURL = isName(config.themeName) ? config.file(path) ?? ShellDefaults.bundledFile(path) : nil
        if themeURL == nil, config.themeName == ShellWallpaperPalette.themeName {
            return nil
        }
        guard let themeURL else {
            report("shell.toml: no theme named \(config.themeName)", &problems)
            config.themeName = "native"
            return nil
        }
        guard let theme = decode(themeURL, &problems) else {
            config.themeName = "native"
            return nil
        }
        unknownKeys(in: theme, known: themeKeys, of: "Theme \(config.themeName)", &problems)
        config.theme = ShellTheme(toml: theme, name: config.themeName, problems: &problems)
        return theme
    }

    static func unknownKeys(
        in table: [String: TOMLNode],
        known: Set<String>,
        of place: String,
        _ problems: inout [String]
    ) {
        for key in table.keys.sorted() where !known.contains(key) {
            report("\(place) has unknown key \(key)", &problems)
        }
    }

    private static let barOverrideID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func barOverride(
        _ table: [String: TOMLNode],
        profile: String,
        theme: ShellTheme,
        _ problems: inout [String],
        themeColors: Bool
    ) -> WorkspaceBarProfileOverride? {
        var bar = WorkspaceBarProfileOverride(profile: profile, settings: MonitorBarSettings(
            id: barOverrideID,
            monitorName: ""
        ))
        bar.usesThemeColors = themeColors
        for (key, node) in table.sorted(by: { $0.key < $1.key })
            where !applyDisplayKey(key, node, to: &bar.settings) && !applyGlobalKey(key, node, theme: theme, to: &bar)
        {
            let color = WorkspaceBarProfileOverride.colorKeys.contains { $0.key == key }
            report(
                color
                    ? "[workspaceBar] \(key) must be a palette role such as \"surface\" or \"surface/0.8\""
                    : "[workspaceBar] \(key) is not a bar setting a shell profile or theme can override",
                &problems
            )
        }
        return bar.overriddenKeys.isEmpty ? nil : bar
    }

    private static func applyDisplayKey(_ key: String, _ node: TOMLNode, to bar: inout MonitorBarSettings) -> Bool {
        if let flag = MonitorBarSettings.flagKeys.first(where: { $0.key == key }), case let .boolean(value) = node {
            bar[keyPath: flag.path] = value
        } else if let entry = MonitorBarSettings.numberKeys.first(where: { $0.key == key }), let value = number(node) {
            bar[keyPath: entry.path] = min(max(value, entry.range.lowerBound), entry.range.upperBound)
        } else if key == "position", case let .string(raw) = node, let value = WorkspaceBarPosition(rawValue: raw) {
            bar.position = value
        } else if key == "notchMode", case let .string(raw) = node, let value = WorkspaceBarNotchMode(rawValue: raw) {
            bar.notchMode = value
        } else if key == "fullWidthNotchMode", case let .string(raw) = node,
                  let value = WorkspaceBarFullWidthNotchMode(rawValue: raw)
        {
            bar.fullWidthNotchMode = value
        } else if key == "windowLevel", case let .string(raw) = node,
                  let value = WorkspaceBarWindowLevel(rawValue: raw)
        {
            bar.windowLevel = value
        } else {
            return false
        }
        return true
    }

    private static func applyGlobalKey(
        _ key: String,
        _ node: TOMLNode,
        theme: ShellTheme,
        to bar: inout WorkspaceBarProfileOverride
    ) -> Bool {
        if let flag = WorkspaceBarProfileOverride.flagKeys.first(where: { $0.key == key }),
           case let .boolean(value) = node
        {
            bar[keyPath: flag.path] = value
        } else if let entry = WorkspaceBarProfileOverride.numberKeys.first(where: { $0.key == key }),
                  let value = number(node)
        {
            bar[keyPath: entry.path] = min(max(value, entry.range.lowerBound), entry.range.upperBound)
        } else if let entry = WorkspaceBarProfileOverride.colorKeys.first(where: { $0.key == key }),
                  case let .string(text) = node, let color = ShellThemeColor(text, theme: theme)
        {
            bar[keyPath: entry.path] = color
        } else if key == "accentColor" || key == "textColor",
                  let color = try? ShellTOMLText.decode(SettingsColor.self, from: node),
                  [color.red, color.green, color.blue, color.alpha]
                      .allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
        {
            if key == "accentColor" { bar.accentColor = color } else { bar.textColor = color }
        } else if key == "notificationBadges", case let .string(raw) = node,
                  let value = WorkspaceBarNotificationBadgeMode(rawValue: raw)
        {
            bar.notificationBadges = value
        } else if key == "revealModifier", case let .string(raw) = node,
                  let value = WorkspaceBarRevealModifier(rawValue: raw)
        {
            bar.revealModifier = value
        } else {
            return false
        }
        return true
    }

    static func names(_ node: TOMLNode?, key: String, _ problems: inout [String]) -> [String] {
        guard let node else { return [] }
        guard case let .array(values) = node else {
            report("shell.toml: \(key) must be a list of widget names", &problems)
            return []
        }
        var names: [String] = []
        for value in values {
            guard case let .string(name) = value else {
                report("shell.toml: \(key) must contain widget names", &problems)
                continue
            }
            names.append(name)
        }
        return names
    }

    private static func layer(in directory: URL, _ problems: inout [String]) -> [String: TOMLNode]? {
        let url = directory.appendingPathComponent("shell.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return decode(url, &problems)
    }

    private static func merged(_ base: [String: TOMLNode], _ overlay: [String: TOMLNode]) -> [String: TOMLNode] {
        base.merging(overlay) { current, next in
            guard case let .table(current) = current, case let .table(next) = next else { return next }
            return .table(merged(current, next))
        }
    }

    private static func decode(_ url: URL, _ problems: inout [String]) -> [String: TOMLNode]? {
        do {
            let data = try SettingsFileAccess.readContents(at: url).data
            return try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        } catch {
            let name = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            report("\(name): \(error.localizedDescription)", &problems)
            return nil
        }
    }
}
