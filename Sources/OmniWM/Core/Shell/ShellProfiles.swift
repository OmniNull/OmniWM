// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum ShellProfiles {
    private static let reserved: Set<String> = ["widgets", "themes", "shaders", "lib"]

    static func names(in shellDirectory: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: shellDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let profiles = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !reserved.contains($0) && $0 != ShellDefaults.profile }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [ShellDefaults.profile] + profiles
    }

    static func select(_ name: String, in shellDirectory: URL) throws -> Bool {
        guard names(in: shellDirectory).contains(name) else { throw CocoaError(.fileNoSuchFile) }
        let original = try contents(in: shellDirectory)
        let present = try ShellTOMLText.contains(["profile"], in: original)
        guard present || name != ShellDefaults.profile else { return false }
        return try write(
            ShellTOMLText.setting([(["profile"], ShellTOMLText.quoted(name))], in: original),
            over: original,
            in: shellDirectory
        )
    }

    static func key(_ key: String, of profile: String) -> [String] {
        [ShellConfig.profilesKey, profile, key]
    }

    static func themes(of config: ShellConfig) -> [String] {
        let layers = config.directories + [ShellDefaults.bundled].compactMap(\.self)
        let names = layers.flatMap { layer in
            ((try? FileManager.default.contentsOfDirectory(
                at: layer.appendingPathComponent("themes", isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { $0.pathExtension == "toml" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        let builtIn = ["native", ShellWallpaperPalette.themeName]
        return builtIn + Set(names).subtracting(builtIn)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func selectTheme(_ name: String, in shellDirectory: URL) throws -> Bool {
        let config = ShellConfig.resolve(shellDirectory: shellDirectory)
        guard themes(of: config).contains(name) else { throw CocoaError(.fileNoSuchFile) }
        guard name != config.themeName else { return false }
        return try setTopLevel(
            [(key("theme", of: config.profile), name == config.styleThemeName ? nil : ShellTOMLText.quoted(name))],
            in: shellDirectory
        )
    }

    static func selectScheme(_ scheme: ShellWallpaperScheme, in shellDirectory: URL) throws -> Bool {
        let config = ShellConfig.resolve(shellDirectory: shellDirectory)
        guard scheme != config.wallpaperScheme else { return false }
        return try setTopLevel(
            [(key("scheme", of: config.profile), ShellTOMLText.quoted(scheme.rawValue))],
            in: shellDirectory
        )
    }

    static func hasTopLevel(_ keys: [[String]], in shellDirectory: URL) -> Bool {
        guard let text = try? contents(in: shellDirectory) else { return false }
        return keys.contains { (try? ShellTOMLText.contains($0, in: text)) == true }
    }

    static func setTopLevel(_ entries: [(key: [String], value: String?)], in shellDirectory: URL) throws -> Bool {
        let original = try contents(in: shellDirectory)
        return try write(ShellTOMLText.setting(entries, in: original), over: original, in: shellDirectory)
    }

    static func setValue<Value: Encodable>(_ value: Value?, at key: [String], in shellDirectory: URL) throws -> Bool {
        let original = try contents(in: shellDirectory)
        let node = try value.map { try ShellTOMLText.node($0) }
        return try write(ShellTOMLText.settingNodes([(key, node)], in: original), over: original, in: shellDirectory)
    }

    static func setNodes(_ entries: [(key: [String], value: TOMLNode?)], in shellDirectory: URL) throws -> Bool {
        let original = try contents(in: shellDirectory)
        return try write(ShellTOMLText.settingNodes(entries, in: original), over: original, in: shellDirectory)
    }

    static func reset(_ key: [String], in shellDirectory: URL) throws -> Bool {
        try setTopLevel([(key, nil)], in: shellDirectory)
    }

    private static func contents(in shellDirectory: URL) throws -> String {
        let url = shellDirectory.appendingPathComponent("shell.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return String(decoding: try SettingsFileAccess.readContents(at: url).data, as: UTF8.self)
    }

    private static func write(_ updated: String, over original: String, in shellDirectory: URL) throws -> Bool {
        guard updated != original else { return false }
        try SettingsFileAccess.writeAtomically(
            Data(updated.utf8),
            at: shellDirectory.appendingPathComponent("shell.toml")
        )
        return true
    }

    static func eject(_ item: String, config: ShellConfig, shellDirectory: URL) throws -> URL? {
        let profile = shellDirectory.appendingPathComponent(config.profile, isDirectory: true)
        let managed = FileManager.default.fileExists(atPath: profile.appendingPathComponent(".manifest.json").path)
        let destination = managed ? shellDirectory : profile
        let source: URL
        let target: URL
        if item.hasPrefix("lib/") {
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !item.contains("\\"), let file = config.file(item) ?? ShellDefaults.bundledFile(item)
            else { throw CocoaError(.fileNoSuchFile) }
            source = file
            target = destination.appendingPathComponent(item)
        } else {
            guard ShellComponentCatalog.validName(item),
                  let entry = config.file("widgets/\(item)/component.luau")
                  ?? config.widget(item) ?? ShellConfig.bundledWidget(item)
            else { throw CocoaError(.fileNoSuchFile) }
            source = entry.deletingLastPathComponent()
            target = destination.appendingPathComponent("widgets/\(item)", isDirectory: true)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        try SettingsFileAccess.ensureDirectoryExists(at: target.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func create(_ widget: String, in shellDirectory: URL) throws -> Bool {
        var problems: [String] = []
        guard let config = ShellConfig.load(shellDirectory: shellDirectory, problems: &problems) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let folder = shellDirectory.appendingPathComponent("\(config.profile)/widgets/\(widget)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return false }
        try SettingsFileAccess.ensureDirectoryExists(at: folder)
        try SettingsFileAccess.writeAtomically(
            Data(starter(widget).utf8),
            at: folder.appendingPathComponent("init.luau")
        )
        return true
    }

    private static func starter(_ widget: String) -> String {
        """
        function render(ctx)
            return ui.row{ gap = 6, pad = 2, radius = 4, hover = "foreground/0.12", onClick = ui.popout,
                ui.symbol{ name = "sparkles" },
                ui.text{ text = "\(widget)" } }
        end

        function popout(ctx)
            return ui.column{ gap = 6, pad = 12,
                ui.text{ text = "\(widget)", style = "bold" },
                ui.text{ text = ctx.data.date .. " " .. ctx.data.clock, color = "secondaryForeground" } }
        end

        function trigger(ctx, event)
            omniwm.log("trigger", event.name, event.value)
        end

        """
    }

    @MainActor
    static func openFolder(_ shellDirectory: URL) {
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: shellDirectory)
            NSWorkspace.shared.open(shellDirectory)
        } catch {
            Log.shell.error("Failed to open \(shellDirectory.path): \(error.localizedDescription)")
        }
    }
}
