// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension Notification.Name {
    static let shellConfigDidChange = Notification.Name("com.barut.OmniWM.shellConfigDidChange")
    static let shellWidgetsDidChange = Notification.Name("com.barut.OmniWM.shellWidgetsDidChange")
}

struct ShellBarLayout: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case builtIn
        case profile(String)
        case yours
    }

    struct Widget: Equatable, Identifiable, Sendable {
        let name: String
        let source: Source

        var id: String {
            name
        }
    }

    struct Unreadable: Error, Equatable {
        let problem: String
    }

    var leading: [String]
    var center: [String] = []
    var trailing: [String]
    let widgets: [Widget]
    let profile: String
    let customized: Bool

    static func load(shellDirectory: URL, profile: String? = nil) -> Result<ShellBarLayout, Unreadable> {
        var problems: [String] = []
        let loaded = if let profile {
            ShellConfig.load(profile: profile, shellDirectory: shellDirectory, problems: &problems)
        } else { ShellConfig.load(shellDirectory: shellDirectory, problems: &problems) }
        guard let config = loaded else {
            return .failure(Unreadable(problem: problems.last ?? "shell.toml"))
        }
        return .success(ShellBarLayout(config: config, shellDirectory: shellDirectory))
    }

    init(config: ShellConfig, shellDirectory: URL) {
        leading = config.leading
        center = config.center
        trailing = config.trailing
        widgets = Self.available(config: config, shellDirectory: shellDirectory)
        profile = config.profile
        customized = ShellProfiles.hasTopLevel(Self.keys(of: config.profile), in: shellDirectory)
    }

    init(
        leading: [String], center: [String] = [], trailing: [String], widgets: [Widget],
        profile: String, customized: Bool
    ) {
        self.leading = leading
        self.center = center
        self.trailing = trailing
        self.widgets = widgets
        self.profile = profile
        self.customized = customized
    }

    @discardableResult
    static func edit(
        shellDirectory: URL,
        unlessChanged expected: (lane: ShellLane, names: [String])? = nil,
        _ change: (inout ShellBarLayout) -> Void
    ) throws -> Bool {
        let current = try load(shellDirectory: shellDirectory).get()
        if let expected, current.names(in: expected.lane) != expected.names {
            return false
        }
        var next = current
        change(&next)
        guard next != current else { return false }
        try next.save(shellDirectory: shellDirectory)
        return true
    }

    static func reset(shellDirectory: URL) throws {
        let profile = ShellConfig.resolve(shellDirectory: shellDirectory).profile
        _ = try ShellProfiles.setTopLevel(keys(of: profile).map { ($0, nil) }, in: shellDirectory)
    }

    @discardableResult
    static func setSystemStatsEnabled(_ enabled: Bool, in shellDirectory: URL) throws -> Bool {
        var problems: [String] = []
        guard let config = ShellConfig.load(shellDirectory: shellDirectory, problems: &problems) else {
            throw Unreadable(problem: problems.last ?? "shell.toml")
        }
        var entries = [(
            ShellProfiles.key("workspaceBar", of: config.profile) + ["systemStatsButton"],
            Optional(enabled ? "true" : "false")
        )]
        if enabled, let widget = config.systemStatsWidget, config.barLane(of: widget) == nil {
            entries.append((ShellProfiles.key("trailing", of: config.profile), Self.list(config.trailing + [widget])))
        }
        return try ShellProfiles.setTopLevel(entries, in: shellDirectory)
    }

    private static func keys(of profile: String) -> [[String]] {
        ShellLane.allCases.map { ShellProfiles.key($0.rawValue, of: profile) }
    }

    @MainActor
    static func vertical(_ settings: WorkspaceBarSettings, on monitors: [Monitor]) -> Bool? {
        let orientations = Set(monitors.map { settings.resolved(for: $0) }.filter(\.enabled).map(\.position.isVertical))
        guard orientations.count <= 1 else { return nil }
        return orientations.first ?? settings.position.isVertical
    }

    static func side(_ lane: ShellLane, vertical: Bool?) -> String {
        guard let vertical else {
            return lane == .center ? side(lane, vertical: false)
                : "\(side(lane, vertical: false)) / \(side(lane, vertical: true))"
        }
        return switch (lane, vertical) {
        case (.leading, false): String(localized: "Left")
        case (.trailing, false): String(localized: "Right")
        case (.leading, true): String(localized: "Top")
        case (.trailing, true): String(localized: "Bottom")
        case (.center, _): String(localized: "Center")
        }
    }

    static func title(of name: String) -> String {
        switch name {
        case "apple-menu": String(localized: "Apple Menu")
        case "app-menu": String(localized: "App Menu")
        case "omniwm": "OmniWM"
        case "workspaces": String(localized: "Workspaces")
        case "scratchpads": String(localized: "Scratchpads")
        case "system-stats": String(localized: "System Stats")
        case "stats": String(localized: "Stats")
        case "clock": String(localized: "Clock")
        case "battery": String(localized: "Battery")
        case "volume": String(localized: "Volume")
        case "media": String(localized: "Media")
        case "calendar": String(localized: "Calendar")
        case "weather": String(localized: "Weather")
        case "hidden-bar-menu": String(localized: "Hidden Bar Menu")
        case "launcher": String(localized: "Launcher")
        case "active-window": String(localized: "Active Window")
        case "input-source": String(localized: "Input Source")
        case "wifi": String(localized: "Wi-Fi")
        case "bluetooth": String(localized: "Bluetooth")
        case "battery-details": String(localized: "Battery Details")
        case "world-clock": String(localized: "World Clock")
        case "privacy": String(localized: "Privacy")
        case "control-center": String(localized: "Control Center")
        default:
            name.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.count <= 2 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    var addable: [Widget] {
        widgets.filter { lane(of: $0.name) == nil }
    }

    func lane(of name: String) -> ShellLane? {
        ShellLane.allCases.first { names(in: $0).contains(name) }
    }

    func source(of name: String) -> Source? {
        widgets.first { $0.name == name }?.source
    }

    func names(in lane: ShellLane) -> [String] {
        switch lane {
        case .leading: leading
        case .center: center
        case .trailing: trailing
        }
    }

    mutating func add(_ name: String, to lane: ShellLane, at index: Int? = nil) {
        remove(name)
        var names = names(in: lane)
        names.insert(name, at: min(index ?? names.count, names.count))
        set(names, in: lane)
    }

    mutating func remove(_ name: String) {
        leading.removeAll { $0 == name }
        center.removeAll { $0 == name }
        trailing.removeAll { $0 == name }
    }

    mutating func move(in lane: ShellLane, from offsets: IndexSet, to destination: Int) {
        var names = names(in: lane)
        let moving = offsets.sorted().map { names[$0] }
        let before = offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) {
            names.remove(at: offset)
        }
        names.insert(contentsOf: moving, at: destination - before)
        set(names, in: lane)
    }

    mutating func shift(_ name: String, by delta: Int) {
        for lane in ShellLane.allCases {
            var names = names(in: lane)
            guard let index = names.firstIndex(of: name) else { continue }
            let target = index + delta
            guard names.indices.contains(target) else { return }
            names.swapAt(index, target)
            set(names, in: lane)
            return
        }
    }

    mutating func move(_ name: String, to lane: ShellLane) {
        guard let current = self.lane(of: name), current != lane else { return }
        let order = ShellLane.allCases
        let forward = order.firstIndex(of: lane)! > order.firstIndex(of: current)!
        add(name, to: lane, at: forward ? 0 : names(in: lane).count)
    }

    func save(shellDirectory: URL) throws {
        _ = try ShellProfiles.setTopLevel(
            ShellLane.allCases.map { (ShellProfiles.key($0.rawValue, of: profile), Self.list(names(in: $0))) },
            in: shellDirectory
        )
    }

    private mutating func set(_ names: [String], in lane: ShellLane) {
        switch lane {
        case .leading: leading = names
        case .center: center = names
        case .trailing: trailing = names
        }
    }

    private static func list(_ names: [String]) -> String {
        "[" + names.map(ShellTOMLText.quoted).joined(separator: ", ") + "]"
    }

    private static func available(config: ShellConfig, shellDirectory: URL) -> [Widget] {
        var seen: Set<String> = []
        var widgets: [Widget] = []
        let shell = shellDirectory.standardizedFileURL
        let builtIn = shellDirectory.appendingPathComponent(ShellDefaults.profile, isDirectory: true)
            .standardizedFileURL
        for directory in config.directories {
            let entries = ShellConfig.widgetFolders(in: directory)
            let source: Source = switch directory.standardizedFileURL {
            case shell: .yours
            case builtIn: .builtIn
            default: .profile(config.profile)
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                guard name != config.hiddenBarWidget, !seen.contains(name),
                      FileManager.default.fileExists(atPath: entry.appendingPathComponent("init.luau").path)
                else {
                    continue
                }
                seen.insert(name)
                widgets.append(Widget(name: name, source: source))
            }
        }
        return widgets
    }
}
