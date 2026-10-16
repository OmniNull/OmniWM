// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellConfigurationInputs: Sendable {
    struct Prepared: Sendable {
        let config: ShellConfig
        let problems: [String]
    }

    private let directory: URL
    let files: [String: SettingsFileAccess.Fingerprint]
    let paths: [URL]
    let widgets: [String]

    let metadata: [String: SettingsFileAccess.Fingerprint]

    init(directory: URL, config: ShellConfig) throws {
        let directory = try SettingsFileAccess.canonicalURL(for: directory)
        var files: [String: SettingsFileAccess.Fingerprint] = [:]
        var paths: Set<URL> = [directory, directory.deletingLastPathComponent()]
        var widgets: Set<String> = []
        let prefix = directory.standardizedFileURL.path + "/"
        let directories = try config.directories.compactMap { url -> URL? in
            do { return try SettingsFileAccess.canonicalURL(for: url) }
            catch let error as POSIXError where error.code == .ENOENT { return nil }
        }
        let roots = Set([directory] + directories.filter { !$0.path.hasPrefix(prefix) })
        for root in roots {
            paths.insert(root)
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            while let file = entries?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
                paths.insert(file)
                if values.isDirectory == true {
                    if file.deletingLastPathComponent().lastPathComponent == "widgets" {
                        widgets.insert(file.lastPathComponent)
                    }
                } else {
                    files[file.path] = SettingsFileAccess.currentFingerprint(at: file)
                }
            }
        }
        self.directory = directory
        self.files = files
        metadata = files.filter {
            let name = URL(fileURLWithPath: $0.key).lastPathComponent
            return name == "settings.toml" || name == "component.toml" || name == "init.luau"
                || name == "component.luau"
        }
        self.paths = paths.sorted { $0.path < $1.path }
        self.widgets = widgets.sorted()
    }

    func updatingConfiguration() -> Self {
        var files = files
        for path in files.keys where URL(fileURLWithPath: path).pathExtension == "toml"
            && !path.contains("/widgets/")
        {
            files[path] = SettingsFileAccess.currentFingerprint(at: URL(fileURLWithPath: path))
        }
        let rootFile = directory.appendingPathComponent("shell.toml")
        files[rootFile.path] = SettingsFileAccess.currentFingerprint(at: rootFile)
        let paths = files[rootFile.path] == nil || paths.contains(rootFile) ? paths : (paths + [rootFile]).sorted {
            $0.path < $1.path
        }
        return Self(directory: directory, files: files, metadata: metadata, paths: paths, widgets: widgets)
    }

    private init(
        directory: URL, files: [String: SettingsFileAccess.Fingerprint],
        metadata: [String: SettingsFileAccess.Fingerprint],
        paths: [URL], widgets: [String]
    ) {
        self.directory = directory
        self.files = files
        self.metadata = metadata
        self.paths = paths
        self.widgets = widgets
    }

    static func load(in directory: URL, profile: String? = nil) throws -> Prepared {
        var problems: [String] = []
        let value = if let profile {
            ShellConfig.load(profile: profile, shellDirectory: directory, problems: &problems)
        } else { ShellConfig.load(shellDirectory: directory, problems: &problems) }
        guard let value else { throw ShellBarLayout.Unreadable(problem: problems.last ?? "shell.toml") }
        return Prepared(config: value, problems: problems)
    }
}
