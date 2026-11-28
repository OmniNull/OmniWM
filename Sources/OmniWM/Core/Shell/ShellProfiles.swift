// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum ShellProfiles {
    private static let reserved: Set<String> = ["widgets", "themes", "shaders", "lib", "fonts", ShellStrings.folder]

    static func names(in shellDirectory: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: shellDirectory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let profiles = entries
            .filter { entry in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .map(\.lastPathComponent)
            .filter { !reserved.contains($0) && $0 != ShellDefaults.profile }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [ShellDefaults.profile] + profiles
    }

    static func isStyleName(_ name: String) -> Bool {
        ShellConfig.isName(name) && !reserved.contains(name) && name != ShellDefaults.profile
    }

    static func problem(selecting name: String, in shellDirectory: URL) -> String? {
        let folder = shellDirectory.appendingPathComponent(name)
        guard ShellConfig.isName(name), FileManager.default.fileExists(atPath: folder.path) else {
            return "shell.luau: no profile folder named \(name)"
        }
        return ShellStyleManifest.problem(in: folder).map { "\(name)/\($0)" }
    }

    static func select(_ name: String, in shellDirectory: URL) throws -> Bool {
        guard names(in: shellDirectory).contains(name) else { throw CocoaError(.fileNoSuchFile) }
        _ = try ShellStyleManifest.load(in: shellDirectory.appendingPathComponent(name))
        if name == ShellDefaults.profile, try personalValues(in: shellDirectory)["profile"] == nil { return false }
        return try setNodes([(["profile"], .string(name))], in: shellDirectory)
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
                .filter { $0.pathExtension == "luau" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        let builtIn = ["native", ShellWallpaperPalette.themeName]
        return builtIn + Set(names).subtracting(builtIn)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func selectTheme(
        _ name: String, scheme: ShellWallpaperScheme? = nil, profile: String? = nil, in shellDirectory: URL
    ) throws -> Bool {
        let config = try config(profile: profile, in: shellDirectory)
        guard themes(of: config).contains(name) else { throw CocoaError(.fileNoSuchFile) }
        var changes: [([String], SettingsLuauValue?)] = []
        if name != config.themeName {
            changes.append((key("theme", of: config.profile), name == config.styleThemeName ? nil : .string(name)))
        }
        if let scheme, scheme != config.wallpaperScheme {
            changes.append((key("scheme", of: config.profile), .string(scheme.rawValue)))
        }
        guard !changes.isEmpty else { return false }
        return try setNodes(changes, in: shellDirectory)
    }

    static func selectScheme(
        _ scheme: ShellWallpaperScheme, profile: String? = nil, in shellDirectory: URL
    ) throws -> Bool {
        let config = try config(profile: profile, in: shellDirectory)
        guard scheme != config.wallpaperScheme else { return false }
        return try setNodes(
            [(key("scheme", of: config.profile), .string(scheme.rawValue))],
            in: shellDirectory
        )
    }

    static func config(profile: String?, in shellDirectory: URL) throws -> ShellConfig {
        guard let profile else { return ShellConfig.resolve(shellDirectory: shellDirectory) }
        var problems: [String] = []
        guard let config = ShellConfig.load(profile: profile, shellDirectory: shellDirectory, problems: &problems),
              config.profile == profile
        else { throw ShellBarLayout.Unreadable(problem: problems.last ?? profile) }
        return config
    }

    static func sharedWeather(in shellDirectory: URL) throws -> ShellWeatherLocation? {
        guard let weather = try personalValues(in: shellDirectory)["weather"] else { return nil }
        var config = ShellConfig()
        var problems: [String] = []
        ShellConfig.applyServices(["weather": weather], to: &config, &problems)
        return config.weather
    }

    private static func personalValues(in shellDirectory: URL) throws -> SettingsLuauValue {
        let url = shellDirectory.appendingPathComponent("shell.luau")
        guard FileManager.default.fileExists(atPath: url.path) else { return .record([:]) }
        return try ShellLuauDocument.load(at: url).value
    }

    static func setNodes(_ entries: [([String], SettingsLuauValue?)], in shellDirectory: URL) throws -> Bool {
        try ShellLuauDocument.write(entries, in: shellDirectory)
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
