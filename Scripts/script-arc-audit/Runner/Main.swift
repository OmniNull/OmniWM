// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWM

@main
enum ScriptARCRunner {
    static func main() {
        let port = Port()
        RunLoop.main.add(port, forMode: .default)
        Task { @MainActor in
            do {
                let directory = URL(fileURLWithPath: CommandLine.arguments[1])
                if CommandLine.arguments.contains("--lifetime") {
                    try await runScriptARCWorkerLifetime(directory: directory)
                    try await runScriptARCSnapshotLifetime(directory: directory)
                    try runScriptARCWorkspaceKeys(directory: directory, measured: false)
                } else if CommandLine.arguments.contains("--workspace-keys") {
                    try runScriptARCWorkspaceKeys(directory: directory, calibratePlatform: true)
                } else if CommandLine.arguments.contains("--window-details-platform") {
                    try await runScriptARCWindowDetailsPlatform(directory: directory)
                } else {
                    try await runScriptARCAudit(
                        directory: directory, observeDelivery: CommandLine.arguments.contains("--observe-delivery")
                    )
                }
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("script-arc-audit: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        withExtendedLifetime(port) { CFRunLoopRun() }
    }
}
