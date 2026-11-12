// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin
import GhosttyKit
@testable import OmniWM
import Synchronization
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class LauncherTerminalLiveTests: XCTestCase {
        func testRealExternalTerminalsRunAllFourShellsInFreshSessions() async throws {
            let existing = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            var created: [NSRunningApplication] = []
            defer { created.forEach { $0.forceTerminate() } }
            var reusedPIDs: [LauncherTerminal: pid_t] = [:]
            var sessions: [(LauncherTerminalSession, pid_t)] = []
            var directories: [URL] = []
            defer { directories.forEach { try? FileManager.default.removeItem(at: $0) } }
            for terminal in [LauncherTerminal.terminal, .terminal, .iterm, .iterm, .ghostty, .kitty] {
                let directory = try temporaryDirectory()
                directories.append(directory)
                print("Launcher live session: \(terminal.title), previous PID: \(reusedPIDs[terminal] ?? 0)")
                let marker = directory.appendingPathComponent("complete")
                let done = expectation(description: "\(terminal.title) executed all shells")
                let watcher = try watch(marker: marker, expectation: done)
                defer { watcher.cancel() }
                let request = try await shellMatrix(directory: directory, terminal: terminal)
                let session = try await LauncherExternalTerminal.launch(terminal, request: request)
                let app = session.application
                if !existing.contains(app.processIdentifier),
                   !created.contains(where: { $0.processIdentifier == app.processIdentifier })
                {
                    created.append(app)
                }
                if terminal == .terminal || terminal == .iterm {
                    if let pid = reusedPIDs[terminal] { XCTAssertEqual(app.processIdentifier, pid) }
                    reusedPIDs[terminal] = app.processIdentifier
                }
                await fulfillment(of: [done], timeout: failureBound)
                try verifyShellMarkers(in: directory)
                if terminal == .terminal || terminal == .iterm {
                    let pidText = try String(
                        contentsOf: directory.appendingPathComponent("helper-pid"),
                        encoding: .utf8
                    )
                    let pid = try XCTUnwrap(Int32(pidText))
                    sessions.append((session, pid))
                }
            }
            for (session, pid) in sessions {
                let exited = expectation(description: "Task helper exited after Return")
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
                source.setEventHandler { @Sendable in exited.fulfill() }
                source.resume()
                defer { source.cancel() }
                try await session.sendReturn()
                await fulfillment(of: [exited], timeout: failureBound)
                try await session.close()
            }
        }

        func testBuiltInTerminalRunsAllShellsAndRetainsOutputAcrossReload() async throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(
                    directory: directory.appendingPathComponent("config"),
                    startWatching: false
                ),
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            let controller = QuakeTerminalController(settings: settings, motionPolicy: MotionPolicy())
            defer { controller.cleanup() }
            let exit = expectation(description: "Built-in command completed")
            let request = try await shellMatrix(directory: directory, terminal: .builtIn)
            XCTAssertTrue(controller.launch(request))
            let view = try XCTUnwrap(controller.launcherSurfaces.first)
            view.onCommandExit = { exit.fulfill() }
            controller.ghosttyRuntime.reloadConfiguration(for: controller)
            await fulfillment(of: [exit], timeout: failureBound)
            try verifyShellMarkers(in: directory)
            let surface = try XCTUnwrap(view.ghosttySurface)
            XCTAssertTrue(ghostty_surface_process_exited(surface))
            XCTAssertEqual(controller.launcherSurfaces.count, 1)
        }

        func testRealNixApplicationOpensThroughItsAliasResolvedURL() async throws {
            let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OMNIWM_TEST_NIX_APP"])
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let alias = directory.appendingPathComponent("Alacritty.app")
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            try URL.writeBookmarkData(
                target.bookmarkData(
                    options: .suitableForBookmarkFile,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ),
                to: alias
            )
            let url = try XCTUnwrap(ApplicationCatalogFilter.resolvedBundleURL(alias.path))
            let options = NSWorkspace.OpenConfiguration()
            options.createsNewApplicationInstance = true
            options.activates = false
            options.arguments = ["-e", "/usr/bin/true"]
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
            defer { app.terminate() }
            XCTAssertEqual(app.bundleIdentifier, Bundle(url: target)?.bundleIdentifier)
        }

        private func temporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-native-\(UUID())")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func shellMatrix(directory: URL, terminal: LauncherTerminal) async throws -> LauncherLaunchRequest {
            let environmentCache = LauncherEnvironmentCache(helperExecutable: try LauncherHelperTestSupport.executable)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let shells: [(LauncherShell, String, String)] = [
                (
                    .nushell,
                    root.appendingPathComponent(".cache/flake-tools/bin/nu").path,
                    "let omniwm_value = 'nushell'"
                ),
                (.fish, root.appendingPathComponent(".cache/flake-tools/bin/fish").path, "set omniwm_value fish"),
                (.zsh, "/bin/zsh", "omniwm_value=zsh"),
                (.bash, "/bin/bash", "omniwm_value=bash")
            ]
            var commands = ["[ -n \"${TERM:-}\" ] && [ \"$TERM\" != dumb ] || exit 2"]
            var values: [String: String] = [:]
            for (shell, path, assignment) in shells {
                var configuration = LauncherConfiguration()
                configuration.shell = shell
                configuration.shellExecutable = path
                configuration.terminal = terminal
                var entry = LauncherEntry()
                entry.name = shell.rawValue
                let file = directory.appendingPathComponent(shell.rawValue)
                let temporary = file.appendingPathExtension("tmp")
                let redirect = shell == .nushell ? "out>" : ">"
                entry.command = assignment + "; /usr/bin/printf '%s' $omniwm_value \(redirect) \(LauncherHelperTestSupport.quote(temporary.path)); /bin/mv \(LauncherHelperTestSupport.quote(temporary.path)) \(LauncherHelperTestSupport.quote(file.path))"
                let request = try await LauncherLaunchRequest.prepare(
                    entry: entry, configuration: configuration, environmentCache: environmentCache
                )
                values = request.environment
                commands.append(LauncherHelperTestSupport.shellCommand(request) + " || exit 1")
            }
            let marker = directory.appendingPathComponent("complete")
            commands
                .append(
                    "/usr/bin/printf '%s' \"$PPID\" > \(LauncherHelperTestSupport.quote(directory.appendingPathComponent("helper-pid").path))"
                )
            commands.append("/usr/bin/touch \(LauncherHelperTestSupport.quote(marker.path))")
            return LauncherLaunchRequest(
                executable: "/bin/sh", arguments: ["-c", commands.joined(separator: "\n")],
                directory: directory.path, environment: values
            )
        }

        private func verifyShellMarkers(in directory: URL) throws {
            for shell in [LauncherShell.nushell, .fish, .zsh, .bash] {
                XCTAssertEqual(
                    try String(contentsOf: directory.appendingPathComponent(shell.rawValue), encoding: .utf8),
                    shell.rawValue
                )
            }
        }

        private func watch(marker: URL, expectation: XCTestExpectation) throws -> DispatchSourceFileSystemObject {
            let descriptor = open(marker.deletingLastPathComponent().path, O_EVTONLY)
            guard descriptor >= 0 else { throw LauncherFailure("Could not observe test completion") }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: .global()
            )
            let fulfilled = Mutex(false)
            source.setEventHandler { @Sendable in
                if FileManager.default.fileExists(atPath: marker.path) {
                    let first = fulfilled.withLock { value in
                        guard !value else { return false }
                        value = true
                        return true
                    }
                    if first { expectation.fulfill() }
                }
            }
            source.setCancelHandler { @Sendable in close(descriptor) }
            source.resume()
            return source
        }
    }
#endif
