// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM

enum ShellStyleFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("styles", isDirectory: true)

    static let defaults = directory.deletingLastPathComponent()
        .appendingPathComponent("Sources/OmniWM/ShellDefault", isDirectory: true)

    static func themeFiles(in layer: URL) throws -> [URL] {
        let folder = layer.appendingPathComponent("themes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func themes() throws -> [(profile: String, source: URL)] {
        let layers = [(ShellDefaults.profile, defaults)] + (try names().map { ($0, try source($0)) })
        return try layers.flatMap { profile, layer in
            try themeFiles(in: layer).map { (profile, $0) }
        }
    }

    static func names(in directory: URL = directory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { try $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent).sorted()
    }

    static func source(_ name: String, in directory: URL = directory) throws -> URL {
        guard try names(in: directory).contains(name) else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    static func install(_ name: String, into shell: URL, from directory: URL = directory) throws -> URL {
        let source = try source(name, in: directory)
        _ = try ShellFontFixture.fonts()
        _ = ShellFontLibrary.shared.fonts(in: ShellFontLibrary.folders([source]))
        let target = shell.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func installAll(into shell: URL, from directory: URL = directory) throws {
        if directory == Self.directory, !FileManager.default.fileExists(atPath: shell.path) {
            return try clone(installedTemplate.get(), to: shell)
        }
        try installEach(into: shell, from: directory)
    }

    @discardableResult
    static func prepare(
        into shell: URL, from defaults: URL? = ShellDefaults.bundled, styles: URL = directory
    ) throws -> [URL] {
        if defaults == ShellDefaults.bundled, styles == directory, !FileManager.default.fileExists(atPath: shell.path) {
            let template = try preparedTemplate.get()
            try clone(template.shell, to: shell)
            return template.backups
        }
        return try sync(into: shell, from: defaults, styles: styles)
    }

    private static func installEach(into shell: URL, from directory: URL) throws {
        for name in try names(in: directory) { try install(name, into: shell, from: directory) }
    }

    private static func sync(into shell: URL, from defaults: URL?, styles: URL) throws -> [URL] {
        let backups = ShellDefaults.sync(into: shell, from: defaults)
        try installEach(into: shell, from: styles)
        return backups
    }

    private static let templateRoot: URL = {
        atexit { try? FileManager.default.removeItem(at: ShellStyleFixture.templateRoot) }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-shell-template-\(UUID().uuidString)", isDirectory: true)
    }()

    private static let preparedTemplate = Result<(shell: URL, backups: [URL]), Error> {
        let shell = templateRoot.appendingPathComponent("prepared", isDirectory: true)
        return (shell, try sync(into: shell, from: ShellDefaults.bundled, styles: directory))
    }

    private static let installedTemplate = Result<URL, Error> {
        let shell = templateRoot.appendingPathComponent("installed", isDirectory: true)
        try installEach(into: shell, from: directory)
        return shell
    }

    private static func clone(_ template: URL, to shell: URL) throws {
        try FileManager.default.createDirectory(
            at: shell.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: template, to: shell)
    }
}
