// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellProviderReviewExampleFixture {
    static func copy(to apps: URL) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = apps.appendingPathComponent("provider-review", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("website/public/examples/omnishell/apps/provider-review"),
            to: folder
        )
        let executable = folder.appendingPathComponent("provider")
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("Tests/Fixtures/ShellProviderReview/provider.pl"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return folder
    }
}
