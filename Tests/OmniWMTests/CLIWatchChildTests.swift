// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

final class CLIWatchChildTests: XCTestCase {
    func testExecutablePathPreservesEmptyEntriesAndSearchOrder() throws {
        let fileManager = FileManager.default
        let executableName = "omniwm-watch-path-\(UUID().uuidString)"
        let currentExecutableURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(executableName)
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("OmniWMWatchPath-\(UUID().uuidString)", isDirectory: true)
        let pathExecutableURL = directoryURL.appendingPathComponent(executableName)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: currentExecutableURL)
            try? fileManager.removeItem(at: directoryURL)
        }
        for url in [currentExecutableURL, pathExecutableURL] {
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let missingDirectoryPath = directoryURL.appendingPathComponent("missing", isDirectory: true).path
        for (path, expected) in [
            ("", currentExecutableURL.path),
            (":\(directoryURL.path)", currentExecutableURL.path),
            ("\(missingDirectoryPath)::\(directoryURL.path)", currentExecutableURL.path),
            ("\(missingDirectoryPath):", currentExecutableURL.path),
            ("\(directoryURL.path):", pathExecutableURL.path),
            (directoryURL.path, pathExecutableURL.path)
        ] {
            XCTAssertEqual(
                try CLIWatchChild.resolveExecutablePath(named: executableName, environment: ["PATH": path]),
                expected,
                path
            )
        }
        XCTAssertThrowsError(
            try CLIWatchChild.resolveExecutablePath(named: executableName, environment: ["PATH": missingDirectoryPath])
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOENT)
        }
    }
}
