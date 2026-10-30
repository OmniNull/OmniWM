// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM

enum ShellStyleFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("styles", isDirectory: true)

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
