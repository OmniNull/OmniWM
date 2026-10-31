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
        for name in try names(in: directory) { try install(name, into: shell, from: directory) }
    }

    @discardableResult
    static func prepare(
        into shell: URL, from defaults: URL? = ShellDefaults.bundled, styles: URL = directory
    ) throws -> [URL] {
        let backups = ShellDefaults.sync(into: shell, from: defaults)
        try installAll(into: shell, from: styles)
        return backups
    }
}
