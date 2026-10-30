// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellConfigurationInputs: Sendable {
    struct Prepared: Sendable {
        let config: ShellConfig
        let problems: [String]
    }

    private let directory: URL
    let files: [String: SettingsFileAccess.Fingerprint]
    let paths: [URL]
    let recursivePaths: [URL]
    let widgets: [String]

    let metadata: [String: SettingsFileAccess.Fingerprint]

    var sources: [String: SettingsFileAccess.Fingerprint] {
        files.filter { $0.key != directory.appendingPathComponent("shell.toml").path }
    }

    init(directory: URL, config: ShellConfig) throws {
        let recursivePaths = Set([directory] + config.directories)
        var paths = SettingsFileObservationDirectories.paths(for: directory)
        paths.insert(directory)
        let directory = try SettingsFileAccess.canonicalURL(for: directory)
        paths.formUnion([directory, directory.deletingLastPathComponent()])
        let prefix = directory.standardizedFileURL.path + "/"
        let directories = try config.directories.compactMap { url -> URL? in
            paths.formUnion(SettingsFileObservationDirectories.paths(for: url))
            do { return try SettingsFileAccess.canonicalURL(for: url) }
            catch let error as POSIXError where error.code == .ENOENT { return nil }
        }
        let roots = Set([directory] + directories.filter { !$0.path.hasPrefix(prefix) })
        var scan = DirectoryScan(paths: paths, recursivePaths: recursivePaths)
        for root in roots { scan.include(root) }
        self.directory = directory
        files = scan.files
        metadata = scan.files.filter {
            let name = URL(fileURLWithPath: $0.key).lastPathComponent
            return name == "settings.toml" || name == "component.toml" || name == "init.luau"
                || name == "component.luau"
        }
        self.paths = scan.paths.sorted { $0.path < $1.path }
        self.recursivePaths = scan.recursivePaths.sorted { $0.path < $1.path }
        widgets = scan.widgets.sorted()
    }

    private struct DirectoryScan {
        var paths: Set<URL>
        var recursivePaths: Set<URL>
        var files: [String: SettingsFileAccess.Fingerprint] = [:]
        var widgets: Set<String> = []

        mutating func include(_ directory: URL, ancestors: Set<URL> = []) {
            guard let target = try? SettingsFileAccess.canonicalURL(for: directory),
                  !ancestors.contains(target)
            else { return }
            paths.insert(directory)
            let ancestors = ancestors.union([target])
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                let file = directory.appendingPathComponent(entry.lastPathComponent)
                guard var values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                else { continue }
                paths.insert(file)
                if values.isSymbolicLink == true {
                    recursivePaths.insert(file)
                    paths.formUnion(SettingsFileObservationDirectories.paths(for: file))
                    guard let resolved = try? SettingsFileAccess.canonicalURL(for: file),
                          let targetValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
                    else { continue }
                    values = targetValues
                }
                if values.isDirectory == true {
                    if file.deletingLastPathComponent().lastPathComponent == "widgets" {
                        widgets.insert(file.lastPathComponent)
                    }
                    include(file, ancestors: ancestors)
                } else {
                    files[file.path] = SettingsFileAccess.currentFingerprint(at: file)
                }
            }
        }
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
        return Self(
            directory: directory, files: files, metadata: metadata,
            paths: paths, recursivePaths: recursivePaths, widgets: widgets
        )
    }

    private init(
        directory: URL, files: [String: SettingsFileAccess.Fingerprint],
        metadata: [String: SettingsFileAccess.Fingerprint],
        paths: [URL], recursivePaths: [URL], widgets: [String]
    ) {
        self.directory = directory
        self.files = files
        self.metadata = metadata
        self.paths = paths
        self.recursivePaths = recursivePaths
        self.widgets = widgets
    }

    static func recoveryPaths(
        _ directory: URL, config: ShellConfig, previous: Self?
    ) -> (paths: [URL], recursivePaths: [URL]) {
        let profiles = ShellProfiles.names(in: directory).map { directory.appendingPathComponent($0) }
        let recursivePaths = Set((previous?.recursivePaths ?? []) + [directory] + config.directories + profiles)
        var paths = Set(previous?.paths ?? [])
        for directory in recursivePaths {
            let file = directory.appendingPathComponent("shell.toml")
            paths.formUnion(SettingsFileObservationDirectories.paths(for: file))
            paths.formUnion([directory, file])
        }
        return (paths.sorted { $0.path < $1.path }, recursivePaths.sorted { $0.path < $1.path })
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
