// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

@MainActor
enum LauncherHelperTestSupport {
    static var executable: URL {
        get throws {
            let url = Bundle(for: LauncherExecutionTests.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("omniwmctl")
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw LauncherFailure("The native Launcher helper was not built at \(url.path)")
            }
            return url
        }
    }

    static func transfer(
        request: LauncherLaunchRequest,
        isolateEnvironment: Bool = true,
        holdOutput: Bool = false
    ) throws -> LauncherEnvironmentTransfer {
        try LauncherEnvironmentTransfer(
            request: request, isolateEnvironment: isolateEnvironment, holdOutput: holdOutput,
            helperExecutable: executable
        )
    }

    static func run(
        _ request: LauncherLaunchRequest,
        inheriting environment: [String: String],
        isolateEnvironment: Bool = true
    ) async throws -> LauncherProcessResult {
        let transfer = try transfer(request: request, isolateEnvironment: isolateEnvironment)
        defer { transfer.cancel() }
        let result = try await LauncherProcess.run(
            executable: transfer.arguments[0], arguments: Array(transfer.arguments.dropFirst()),
            environment: environment, deadline: failureBound,
            outputLimit: request.environment.values.reduce(0) { $0 + $1.utf8.count }
                + request.arguments.reduce(0) { $0 + $1.utf8.count } + Int(getpagesize())
        )
        try await transfer.waitForDelivery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.endpoint))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.helper.folder.path))
        return result
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellCommand(_ request: LauncherLaunchRequest) -> String {
        ([request.executable] + request.arguments).map(quote).joined(separator: " ")
    }
}
