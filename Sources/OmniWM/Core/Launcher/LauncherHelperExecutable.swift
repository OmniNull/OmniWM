// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct LauncherHelperExecutable: Sendable {
    let folder: URL
    let executable: URL

    init(executable source: URL? = nil) throws {
        let target = try source ?? Self.bundledExecutable()
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: target.path) else {
            throw LauncherFailure(String(localized: "The bundled launcher helper could not be found."))
        }
        folder = URL(fileURLWithPath: "/private/tmp/omniwm-launch-" + UUID().uuidString, isDirectory: true)
        executable = folder.appendingPathComponent("omniwmctl")
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try manager.createSymbolicLink(at: executable, withDestinationURL: target)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func bundledExecutable() throws -> URL {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("omniwmctl"),
            Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("omniwmctl")
        ]
        guard let executable = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw LauncherFailure(String(localized: "The bundled launcher helper could not be found."))
        }
        return executable
    }
}
