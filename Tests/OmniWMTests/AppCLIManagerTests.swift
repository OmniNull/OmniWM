// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppCLIManagerTests: XCTestCase {
    func testInstallCLIIgnoresPathsThatOnlyShareHomePrefix() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OmniWMCLIInstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let siblingBinDirectory = root.appendingPathComponent("home-other/bin", isDirectory: true)
        let userBinDirectory = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        let bundleURL = root.appendingPathComponent("OmniWM.app", isDirectory: true)
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/omniwmctl")
        for directory in [
            homeDirectory,
            siblingBinDirectory,
            userBinDirectory,
            executableURL.deletingLastPathComponent()
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let fallbackDirectory = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        for (pathDirectories, expectedDirectory, directoryOnPath) in [
            ([siblingBinDirectory], fallbackDirectory, false),
            ([siblingBinDirectory, userBinDirectory], userBinDirectory, true)
        ] {
            let manager = AppCLIManager(
                environmentProvider: {
                    ["PATH": pathDirectories.map { $0.standardizedFileURL.path }.joined(separator: ":")]
                },
                bundleURLProvider: { bundleURL },
                homeDirectoryURLProvider: { homeDirectory.standardizedFileURL },
                homebrewLinkURLsProvider: { [] }
            )
            let expectedLinkURL = expectedDirectory.standardizedFileURL.appendingPathComponent("omniwmctl")

            XCTAssertEqual(
                try manager.installCLIToPATH(),
                .installed(linkURL: expectedLinkURL, directoryOnPath: directoryOnPath)
            )
            XCTAssertFalse(fileManager.fileExists(atPath: siblingBinDirectory.appendingPathComponent("omniwmctl").path))
        }
    }
}
