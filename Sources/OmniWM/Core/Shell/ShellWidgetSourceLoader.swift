// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

actor ShellWidgetSourceLoader {
    struct Input: Sendable {
        let name: String
        let shellDirectory: URL
        let sourceURL: URL
        let directories: [URL]
        let profile: String
        var components: [ShellComponentInstance]?

        var contained: Bool {
            sourceURL.standardizedFileURL.path.hasPrefix(shellDirectory.standardizedFileURL.path + "/")
        }

        func relativePath(_ url: URL) -> String {
            String(url.standardizedFileURL.path.dropFirst(shellDirectory.standardizedFileURL.path.count + 1))
        }

        var layer: String {
            let folder = sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return folder.standardizedFileURL == shellDirectory.standardizedFileURL ? "" : relativePath(folder)
        }

        var libraries: [URL] {
            directories.map { $0.appendingPathComponent("lib", isDirectory: true) }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    struct Prepared: Sendable {
        let source: ShellWidgetSource
        let fingerprint: [String: SettingsFileAccess.Fingerprint]
    }

    static let sourceLimit = 1 << 20
    static let moduleLimit = 64
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.source", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func prepare(_ input: Input) throws -> Prepared {
        let source = try Self.build(input)
        return Prepared(source: source, fingerprint: Self.fingerprint(input, components: source.componentDescriptors))
    }

    static func build(_ input: Input) throws -> ShellWidgetSource {
        let main = try read(input.sourceURL)
        guard input.contained else {
            var source = ShellWidgetSource(chunk: "=\(input.name)", main: main, modules: [])
            source.isIslandRoot = input.components != nil
            source.profile = input.profile
            return source
        }
        let resolution = try input.components
            .map { try ShellComponentCatalog.resolve($0, directories: input.directories) }
        let descriptors = resolution?.descriptors ?? []
        let files = packageFiles(input, components: descriptors)
        let limit = resolution == nil ? moduleLimit : ShellComponentCatalog.rootModuleLimit
        guard files.count <= limit else {
            throw ShellScriptFailure(
                kind: .compile,
                message: "\(input.name) has \(files.count) Luau files; the limit is \(limit)"
            )
        }
        let modules = try files
            .filter { $0.url.standardizedFileURL != input.sourceURL.standardizedFileURL }
            .map { ShellWidgetSource.Module(path: $0.path, source: try read($0.url)) }
        var source = ShellWidgetSource(chunk: "@" + input.relativePath(input.sourceURL), main: main, modules: modules)
        source.isIslandRoot = input.components != nil
        source.moduleLimit = limit
        source.components = resolution?.instances ?? []
        source.componentDescriptors = descriptors
        source.assetPackages = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.widget, $0.folder) })
        source.assetPackages[input.name] = input.sourceURL.deletingLastPathComponent()
        source.profile = input.profile
        source.network = (try? ShellRootSettings.load(input.name, folder: input.sourceURL.deletingLastPathComponent()))?
            .network ?? []
        return source
    }

    static func packageFiles(_ input: Input, components: [ShellComponentDescriptor] = []) -> [(
        url: URL,
        path: String
    )] {
        guard input.contained else { return [(input.sourceURL, input.sourceURL.lastPathComponent)] }
        let own = entries(in: input.sourceURL.deletingLastPathComponent(), directories: false)
            .map { ($0, input.relativePath($0)) }
        let layer = input.layer
        let prefix = layer.isEmpty ? "lib/" : layer + "/lib/"
        var shared: Set<String> = []
        let library = input.libraries.flatMap { library in
            entries(in: library, directories: false).compactMap { file -> (URL, String)? in
                let name = String(file.standardizedFileURL.path.dropFirst(library.standardizedFileURL.path.count + 1))
                return shared.insert(name).inserted ? (file, prefix + name) : nil
            }
        }
        let componentFiles = components.flatMap { component in
            let prefix = (layer.isEmpty ? "" : layer + "/") + "widgets/" + component.widget + "/"
            return entries(in: component.folder, directories: false).map { file in
                let name = String(file.standardizedFileURL.path
                    .dropFirst(component.folder.standardizedFileURL.path.count + 1))
                return (file, prefix + name)
            }
        }
        var paths: Set<String> = []
        return (own + library + componentFiles).filter { paths.insert($0.1).inserted }
    }

    static func packageDirectories(_ input: Input, components: [ShellComponentDescriptor] = []) -> [URL] {
        guard input.contained else { return [] }
        return entries(in: input.sourceURL.deletingLastPathComponent(), directories: true)
            + input.libraries.flatMap { [$0] + entries(in: $0, directories: true) }
            + components.flatMap { [$0.folder] + entries(in: $0.folder, directories: true) }
    }

    static func fingerprint(
        _ input: Input,
        components: [ShellComponentDescriptor] = []
    ) -> [String: SettingsFileAccess.Fingerprint] {
        var result: [String: SettingsFileAccess.Fingerprint] = [:]
        for file in packageFiles(input, components: components) {
            result[file.path] = SettingsFileAccess.currentFingerprint(at: file.url)
        }
        if input.contained {
            let url = input.sourceURL.deletingLastPathComponent().appendingPathComponent("settings.toml")
            result[url.path] = SettingsFileAccess.currentFingerprint(at: url)
        }
        if let instances = input.components {
            let names = Set(instances.map(\.widget) + components.map(\.widget))
            for name in names {
                for directory in input.directories {
                    let url = directory.appendingPathComponent("widgets/\(name)/component.toml")
                    result[url.path] = SettingsFileAccess.currentFingerprint(at: url)
                }
            }
        }
        return result
    }

    private static func entries(in folder: URL, directories: Bool) -> [URL] {
        FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )?
            .compactMap { $0 as? URL }
            .filter {
                directories
                    ? (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    : $0.pathExtension == "luau"
            } ?? []
    }

    private static func read(_ url: URL) throws -> String {
        let contents = try SettingsFileAccess.readContents(at: url)
        guard contents.data.count <= sourceLimit else {
            throw ShellScriptFailure(kind: .compile, message: "\(url.lastPathComponent) is larger than 1 MiB")
        }
        return String(decoding: contents.data, as: UTF8.self)
    }
}
