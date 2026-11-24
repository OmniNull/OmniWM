// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellLane: String, Equatable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

struct ShellDrawerConfig: Equatable {
    enum Edge: String, CaseIterable {
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
    var island = false
}

struct ShellConfig: Equatable {
    static let bundledScratchpads = "scratchpads"
    static let bundledWorkspaces = "workspaces"

    var profile = ShellDefaults.profile
    var directories: [URL] = []
    var helperFiles: Set<URL> = []
    var barLayoutCustomized = false
    var themeName = "native"
    var styleThemeName = "native"
    var theme = ShellTheme.native
    var wallpaperScheme = ShellWallpaperScheme.tonalSpot
    var leading: [String] = []
    var center: [String] = []
    var trailing: [String] = []
    var priority: [String] = []
    var widgetSettings: [String: [UInt8]] = [:]
    var widgetIntervals: [String: Double] = [:]
    var scratchpadIcons = 3
    var weather: ShellWeatherLocation?
    var barOverride: WorkspaceBarProfileOverride?
    var barShader: ShellBarShader?
    var hiddenBarOverride: HiddenBarProfileOverride?
    var hiddenBarWidget: String?
    var systemStatsWidget: String?
    var drawers: [ShellDrawerConfig] = []
    var styleDrawers: Set<String> = []
    var island: ShellIslandConfig?

    static func bundledWidget(_ name: String) -> URL? {
        isName(name) ? ShellDefaults.bundledFile("widgets/\(name)/init.luau") : nil
    }

    func widget(_ name: String) -> URL? {
        Self.isName(name) ? file("widgets/\(name)/init.luau") : nil
    }

    func builtInWidget(_ name: String, replacing source: URL) -> URL? {
        guard Self.isName(name) else { return nil }
        let managed = directories.last?.appendingPathComponent("widgets/\(name)/init.luau")
        return [Self.bundledWidget(name), managed].lazy.compactMap(\.self).first {
            $0.standardizedFileURL != source.standardizedFileURL
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func file(_ path: String) -> URL? {
        directories.lazy
            .map { $0.appendingPathComponent(path) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func widgetFolders(in layer: URL) -> [URL] {
        let widgets = layer.appendingPathComponent("widgets", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: widgets,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.map { widgets.appendingPathComponent($0.lastPathComponent, isDirectory: true) }.filter { entry in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory
                .boolValue
        }
    }
}

extension ShellConfig {
    static func isName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }

    static let profilesKey = "profiles"
    private static let topKeys: Set = ["profile", "weather", profilesKey]
    private static let profileKeys: Set = [
        "theme", "scheme", "leading", "center", "trailing", "priority", "widgets", "weather", "hiddenBarWidget",
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

    static func load(
        _ shellDirectory: URL,
        profile: String? = nil,
        skippingBrokenLayers: Bool,
        problems: inout [String],
        onFailure: (Set<URL>) -> Void = { _ in }
    ) -> ShellConfig? {
        var config = ShellConfig()
        guard var top = layer(in: shellDirectory, packageRoot: nil, files: &config.helperFiles, &problems) ??
            (skippingBrokenLayers ? [:] : nil)
        else {
            onFailure(config.helperFiles)
            return nil
        }
        if let profile { top["profile"] = .string(profile) }
        selectProfile(top, in: shellDirectory, for: &config, &problems)
        var table: [String: SettingsLuauValue] = [:]
        for directory in config.directories.reversed() where directory != shellDirectory {
            guard let next = layer(in: directory, packageRoot: directory, files: &config.helperFiles, &problems) ??
                (skippingBrokenLayers ? [:] : nil)
            else {
                onFailure(config.helperFiles)
                return nil
            }
            table = merged(table, next)
        }
        if case let .string(name)? = table["theme"] {
            config.styleThemeName = name
        }
        if case let .record(drawers)? = table["drawer"] {
            config.styleDrawers = Set(drawers.keys)
        }
        let own = ownLayer(top, profile: config.profile, &problems)
        config.barLayoutCustomized = ["leading", "center", "trailing", "priority"].contains { own[$0] != nil }
        table = merged(table, own)
        applyProfile(table, own: own, to: &config, &problems)
        return config
    }

    private static func applyProfile(
        _ table: [String: SettingsLuauValue], own: [String: SettingsLuauValue],
        to config: inout ShellConfig, _ problems: inout [String]
    ) {
        unknownKeys(in: table, known: profileKeys, of: "shell.luau", &problems)
        config.themeName = config.styleThemeName
        if case let .string(name)? = table["theme"] {
            config.themeName = name
        }
        if let scheme = table["scheme"] {
            if case let .string(name) = scheme, let value = ShellWallpaperScheme(rawValue: name) {
                config.wallpaperScheme = value
            } else {
                let names = ShellWallpaperScheme.allCases.map(\.rawValue).joined(separator: ", ")
                report("shell.luau: scheme must be one of \(names)", &problems)
            }
        }
        config.leading = names(table["leading"], key: "leading", &problems)
        config.center = names(table["center"], key: "center", &problems)
        config.trailing = names(table["trailing"], key: "trailing", &problems)
        config.priority = names(table["priority"], key: "priority", &problems)
        if case let .record(widgets)? = table["widgets"] {
            applyWidgetSettings(widgets, to: &config, &problems)
        }
        applyServices(table, to: &config, &problems)
        config.barShader = ShellBarShader.parse(table["barShader"], problems: &problems)
        applyComponentTrust(own, to: &config)
        applyBarSettings(table, to: &config, &problems)
    }

    private static func applyComponentTrust(_ own: [String: SettingsLuauValue], to config: inout ShellConfig) {
        if var island = config.island {
            let userInstances: [ShellComponentInstance]
            if case let .record(ownIsland)? = own["island"] {
                userInstances = (try? ShellComponentCatalog.instances(in: ownIsland["components"])) ?? []
            } else {
                userInstances = []
            }
            for index in island.components.indices {
                let configured = island.components[index]
                let trusted = userInstances.first { $0.id == configured.id && $0.widget == configured.widget }
                island.components[index].capabilities = trusted?.capabilities
            }
            config.island = island
        }
    }

    private static func applyBarSettings(
        _ table: [String: SettingsLuauValue], to config: inout ShellConfig, _ problems: inout [String]
    ) {
        var bar: [String: SettingsLuauValue] = [:]
        if case let .record(themeBar)? = loadTheme(into: &config, &problems)?["workspaceBar"] {
            bar = themeBar
        }
        if case let .record(profileBar)? = table["workspaceBar"] {
            bar = merged(bar, profileBar)
        }
        let room = room(in: table, island: config.island, problems: &problems)
        config.barOverride = barOverride(
            bar,
            profile: config.profile,
            theme: config.theme,
            &problems,
            themeColors: true,
            room: room
        )
        if let monitors = table["monitorBarOverrides"] {
            do {
                config.barOverride?
                    .monitorOverrides = try (monitors == .record([:]) ? SettingsLuauValue.list([]) : monitors)
                    .decode([MonitorBarSettings].self)
            } catch {
                report("shell.luau: monitorBarOverrides must contain valid monitor bar settings", &problems)
            }
        }
    }

    private static func ownLayer(
        _ top: [String: SettingsLuauValue],
        profile: String,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue] {
        for key in top.keys.sorted() where !topKeys.contains(key) {
            report(
                profileKeys.contains(key)
                    ? "shell.luau: \(key) belongs in \(profilesKey)[\(SettingsLuauValue.quoted(profile))], the settings for the \(profile) profile"
                    : "shell.luau has unknown key \(key)",
                &problems
            )
        }
        var own: [String: SettingsLuauValue] = [:]
        if case let .record(weather)? = top["weather"] {
            own["weather"] = .record(weather)
        }
        switch top[profilesKey] {
        case nil:
            break
        case let .record(profiles)?:
            if case let .record(settings)? = profiles[profile] {
                own = merged(own, settings)
            } else if profiles[profile] != nil {
                report(
                    "shell.luau: \(profilesKey)[\(SettingsLuauValue.quoted(profile))] must be a table of settings",
                    &problems
                )
            }
        default:
            report("shell.luau: \(profilesKey) must be a table of profile settings", &problems)
        }
        return own
    }

    private static func selectProfile(
        _ top: [String: SettingsLuauValue],
        in shellDirectory: URL,
        for config: inout ShellConfig,
        _ problems: inout [String]
    ) {
        if case let .string(name)? = top["profile"] {
            if let problem = ShellProfiles.problem(selecting: name, in: shellDirectory) {
                report("\(problem), using \(ShellDefaults.profile)", &problems)
            } else {
                config.profile = name
            }
        }
        config.directories = directories(for: config.profile, in: shellDirectory)
    }

    static func directories(for profile: String, in shellDirectory: URL) -> [URL] {
        let names = profile == ShellDefaults.profile ? [profile] : [profile, ShellDefaults.profile]
        return [shellDirectory] + names.map { shellDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    private static func applyWidgetSettings(
        _ widgets: [String: SettingsLuauValue],
        to config: inout ShellConfig,
        _ problems: inout [String]
    ) {
        for (name, node) in widgets {
            guard case .record = node else {
                report("shell.luau: widgets[\(SettingsLuauValue.quoted(name))] must be a table of settings", &problems)
                continue
            }
            var writer = ShellValueWriter()
            encode(node, into: &writer)
            config.widgetSettings[name] = writer.bytes
            if case let .record(settings) = node,
               let interval = number(settings["interval"]).flatMap(ShellWidgetDeclaration.validInterval)
            {
                config.widgetIntervals[name] = interval
            }
            if name == bundledScratchpads, case let .record(settings) = node,
               let icons = number(settings["shownWindows"])
            {
                config.scratchpadIcons = Int(min(6, max(0, icons)))
            }
        }
    }

    private static func loadTheme(
        into config: inout ShellConfig,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue]? {
        guard config.themeName != "native" else { return nil }
        let path = "themes/\(config.themeName).luau"
        let themeURL = isName(config.themeName) ? config.file(path) ?? ShellDefaults.bundledFile(path) : nil
        if themeURL == nil, config.themeName == ShellWallpaperPalette.themeName {
            return nil
        }
        guard let themeURL else {
            report("shell.luau: no theme named \(config.themeName)", &problems)
            config.themeName = "native"
            return nil
        }
        let owner = themeURL.deletingLastPathComponent().deletingLastPathComponent()
        let root = owner.standardizedFileURL.path == config.directories.first?.standardizedFileURL.path ? nil : owner
        guard let theme = decode(themeURL, packageRoot: root, files: &config.helperFiles, &problems) else {
            config.themeName = "native"
            return nil
        }
        unknownKeys(in: theme, known: themeKeys, of: "Theme \(config.themeName)", &problems)
        config.theme = ShellTheme(values: theme, name: config.themeName, problems: &problems)
        return theme
    }

    static func unknownKeys(
        in table: [String: SettingsLuauValue],
        known: Set<String>,
        of place: String,
        path: String? = nil,
        _ problems: inout [String]
    ) {
        for key in table.keys.sorted() where !known.contains(key) {
            if let path {
                report("\(place): \(SettingsLuauValue.fieldPath(key, in: path)) is an unknown key", &problems)
            } else {
                report("\(place) has unknown key \(key)", &problems)
            }
        }
    }

    private static let barOverrideID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func barOverride(
        _ table: [String: SettingsLuauValue],
        profile: String,
        theme: ShellTheme,
        _ problems: inout [String],
        themeColors: Bool,
        room: WorkspaceBarRoom? = nil
    ) -> WorkspaceBarProfileOverride? {
        var bar = WorkspaceBarProfileOverride(profile: profile, settings: MonitorBarSettings(
            id: barOverrideID,
            monitorName: ""
        ))
        bar.usesThemeColors = themeColors
        bar.room = room
        for (key, node) in table.sorted(by: { $0.key < $1.key })
            where !applyDisplayKey(key, node, to: &bar.settings) && !applyGlobalKey(key, node, theme: theme, to: &bar)
        {
            let path = SettingsLuauValue.fieldPath(key, in: "workspaceBar")
            let color = WorkspaceBarProfileOverride.colorKeys.contains { $0.key == key }
            report(
                color
                    ? "\(path) must be a palette role such as \"surface\" or \"surface/0.8\""
                    : "\(path) is not a bar setting a shell profile or theme can override",
                &problems
            )
        }
        return bar.overriddenKeys.isEmpty ? nil : bar
    }

    private static func applyDisplayKey(
        _ key: String,
        _ node: SettingsLuauValue,
        to bar: inout MonitorBarSettings
    ) -> Bool {
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
        _ node: SettingsLuauValue,
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
                  let color = try? node.decode(SettingsColor.self),
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

    static func names(_ node: SettingsLuauValue?, key: String, _ problems: inout [String]) -> [String] {
        guard let node else { return [] }
        guard let values = node.shellArray else {
            report("shell.luau: \(key) must be a list of widget names", &problems)
            return []
        }
        var names: [String] = []
        for value in values {
            guard case let .string(name) = value else {
                report("shell.luau: \(key) must contain widget names", &problems)
                continue
            }
            names.append(name)
        }
        return names
    }

    private static func merged(
        _ base: [String: SettingsLuauValue],
        _ overlay: [String: SettingsLuauValue]
    ) -> [String: SettingsLuauValue] {
        base.merging(overlay) { current, next in
            if case .list = current, next == .record([:]) { return .list([]) }
            guard case let .record(current) = current, case let .record(next) = next else { return next }
            return .record(merged(current, next))
        }
    }
}
