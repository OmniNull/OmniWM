// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin
import Foundation
@testable import OmniWM
import XCTest

#if OMNIWM_LIVE_CHECKS && OMNIWM_SETTINGS_BENCH_ONLY

    @MainActor
    final class SettingsFormatBenchmarkTests: XCTestCase {
        private static let reloadFailureBound: TimeInterval = 2

        private enum Format: String, CaseIterable {
            case luau, toml
        }

        @MainActor
        private struct Fixture {
            let config: URL
            let state: URL
            let file: URL
            let source: Data
            let changed: Data

            func persistence(watching: Bool = false) -> SettingsFilePersistence {
                SettingsFilePersistence(directory: config, startWatching: watching, monitorProvider: { [] })
            }

            func stateStore() -> RuntimeStateStore {
                RuntimeStateStore(directory: state, deferSaves: false)
            }

            func store(watching: Bool = false) -> SettingsStore {
                SettingsStore(
                    persistence: persistence(watching: watching),
                    runtimeState: stateStore(),
                    autosaveEnabled: false
                )
            }
        }

        private struct Report: Encodable {
            let fixtureBytes: [String: Int]
            let rules: Int
            let hotkeys: Int
            let workspaces: Int
            let cpu: [String: Double]
            let nanoseconds: [String: [String: [UInt64]]]
        }

        private typealias Samples = [String: [UInt64]]

        func testSettingsFormatsOnOneBuild() async throws {
            let output = try XCTUnwrap(
                ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_BENCH_OUTPUT"],
                "Set OMNIWM_SETTINGS_BENCH_OUTPUT to write the benchmark report."
            )
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            var base = SettingsExport.defaults()
            if let sample = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_BENCH_FIXTURE"] {
                let url = URL(fileURLWithPath: sample)
                base = try SettingsLuauDocument(Data(contentsOf: url), at: url).export
            }
            base.animationsEnabled = false
            base.ipcEnabled = false
            base.workspaceBar.enabled = false
            var changed = base
            changed.gaps.size += 4

            let fixtures = try makeFixtures(in: root, base: base, changed: changed)
            try validate(fixtures, against: base)
            var cpu: [String: Double] = [:]

            let startupCPU = cpuSeconds()
            let (load, startup) = try measureStartup(fixtures, base: base)
            cpu["loadAndStartup"] = cpuSeconds() - startupCPU

            let reloadCPU = cpuSeconds()
            let reload = try await measureReload(fixtures, base: base, changed: changed)
            cpu["reload"] = cpuSeconds() - reloadCPU

            let inputCPU = cpuSeconds()
            let workspace = try measureWorkspaceSwitch(fixtures)
            cpu["workspaceHotkey"] = cpuSeconds() - inputCPU

            let samples = ["load": load, "startup": startup, "reload": reload, "workspaceHotkey": workspace]
            let report = Report(
                fixtureBytes: Dictionary(uniqueKeysWithValues: fixtures
                    .map { ($0.key.rawValue, $0.value.source.count) }),
                rules: base.appRules.count, hotkeys: base.hotkeyBindings.count,
                workspaces: base.workspaceConfigurations.count, cpu: cpu, nanoseconds: samples
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
        }

        private func makeFixtures(
            in root: URL, base: SettingsExport, changed: SettingsExport
        ) throws -> [Format: Fixture] {
            try Dictionary(uniqueKeysWithValues: Format.allCases.map { format in
                let config = root.appendingPathComponent(format.rawValue, isDirectory: true)
                let state = config.appendingPathComponent("state", isDirectory: true)
                try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
                let file = config.appendingPathComponent("settings.\(format.rawValue)")
                let source = try SettingsFileDocument.initialSource(base, at: file)
                try source.write(to: file)
                return (format, Fixture(
                    config: config, state: state, file: file, source: source,
                    changed: try SettingsFileDocument.initialSource(changed, at: file)
                ))
            })
        }

        private func validate(_ fixtures: [Format: Fixture], against base: SettingsExport) throws {
            for fixture in fixtures.values {
                let persistence = fixture.persistence()
                XCTAssertEqual(persistence.fileURL, fixture.file)
                let loaded = persistence.loadOutcome()
                XCTAssertNil(loaded.notice)
                XCTAssertEqual(loaded.export, base)
            }

            if let original = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_BENCH_LEGACY"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: original))
                let exported = try SettingsFileDocument(
                    data, at: URL(fileURLWithPath: original)
                ).export
                XCTAssertEqual(exported.gaps.size, base.gaps.size)
                XCTAssertEqual(exported.workspaceConfigurations, base.workspaceConfigurations)
                XCTAssertEqual(exported.appRules, base.appRules)
            }
        }

        private func order(_ pair: Int) -> [Format] {
            pair.isMultiple(of: 2) ? [.luau, .toml] : [.toml, .luau]
        }

        private func timed<T>(_ work: () throws -> T) rethrows -> (T, UInt64) {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try work()
            return (value, DispatchTime.now().uptimeNanoseconds - start)
        }

        private func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }

        private func measureStartup(
            _ fixtures: [Format: Fixture], base: SettingsExport
        ) throws -> (Samples, Samples) {
            var load: Samples = [:]
            var startup: Samples = [:]
            for pair in -8 ..< 80 {
                for format in order(pair) {
                    let fixture = try XCTUnwrap(fixtures[format])
                    let persistence = fixture.persistence()
                    let (loaded, loadTime) = timed { persistence.loadOutcome() }
                    XCTAssertNil(loaded.notice)
                    XCTAssertEqual(loaded.export, base)

                    let state = fixture.stateStore()
                    let (started, startupTime) = timed {
                        _ = SettingsFilePersistence.launchLanguage(at: fixture.file)
                        return SettingsStore(
                            persistence: fixture.persistence(),
                            runtimeState: state,
                            autosaveEnabled: false
                        )
                    }
                    XCTAssertNil(started.configNotice)
                    XCTAssertEqual(started.gaps.size, base.gaps.size)
                    if pair >= 0 {
                        load[format.rawValue, default: []].append(loadTime)
                        startup[format.rawValue, default: []].append(startupTime)
                    }
                }
            }
            return (load, startup)
        }

        private func measureReload(
            _ fixtures: [Format: Fixture], base: SettingsExport, changed: SettingsExport
        ) async throws -> Samples {
            var samples: Samples = [:]
            let watching = fixtures.mapValues { $0.store(watching: true) }
            for pair in -6 ..< 72 {
                let useChanged = pair.isMultiple(of: 2)
                for format in order(pair) {
                    let fixture = try XCTUnwrap(fixtures[format])
                    let store = try XCTUnwrap(watching[format])
                    let didApply = expectation(description: "settings file reload")
                    try (useChanged ? fixture.changed : fixture.source).write(to: fixture.file, options: .atomic)
                    let start = DispatchTime.now().uptimeNanoseconds
                    var elapsed: UInt64?
                    store.onExternalSettingsReloaded = {
                        elapsed = DispatchTime.now().uptimeNanoseconds - start
                        didApply.fulfill()
                    }
                    await fulfillment(of: [didApply], timeout: Self.reloadFailureBound)
                    store.onExternalSettingsReloaded = nil
                    XCTAssertNil(store.configNotice)
                    XCTAssertEqual(store.gaps.size, useChanged ? changed.gaps.size : base.gaps.size)
                    if pair >= 0 { samples[format.rawValue, default: []].append(try XCTUnwrap(elapsed)) }
                }
            }
            return samples
        }

        private func measureWorkspaceSwitch(_ fixtures: [Format: Fixture]) throws -> Samples {
            var samples: Samples = [:]
            let runners = try fixtures.mapValues { try WorkspaceRunner(settings: $0.store(), scratch: $0.state) }
            defer { for runner in runners.values { runner.controller.layoutRefreshController.resetState() } }
            for pair in -8 ..< 80 {
                for format in order(pair) {
                    let runner = try XCTUnwrap(runners[format])
                    for index in 0 ..< 100 {
                        let destination = index.isMultiple(of: 2) ? 1 : 0
                        let (result, elapsed) = timed {
                            runner.controller.commandHandler.handleHotkeyInvocation(runner.invocations[destination])
                        }
                        XCTAssertEqual(result, .executed)
                        XCTAssertEqual(
                            runner.controller.workspaceManager.activeWorkspace(on: runner.monitor.id)?.id,
                            runner.workspaces[destination]
                        )
                        if pair >= 0 { samples[format.rawValue, default: []].append(elapsed) }
                    }
                    runner.controller.layoutRefreshController.resetState()
                }
            }
            return samples
        }

        @MainActor
        private struct WorkspaceRunner {
            let controller: WMController
            let monitor: Monitor
            let invocations: [HotkeyInvocation]
            let workspaces: [WorkspaceDescriptor.ID]

            init(settings: SettingsStore, scratch: URL) throws {
                let frame = CGRect(x: 0, y: 0, width: 1440, height: 960)
                let displayID: CGDirectDisplayID = 473_100
                let monitor = Monitor(
                    id: .init(displayId: displayID), displayId: displayID, frame: frame,
                    visibleFrame: frame, hasNotch: false, name: "benchmark", isMain: true
                )
                let controller = WMController(
                    settings: settings,
                    clipboardHistoryDirectory: scratch,
                    diagnosticsDirectory: scratch,
                    windowFocusOperations: WindowFocusOperations(
                        activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
                    )
                )
                let engine = NiriLayoutEngine()
                engine.animationClock = controller.animationClock
                controller.niriEngine = engine
                let manager = controller.workspaceManager
                manager.applyMonitorConfigurationChange([monitor])
                manager.applySettings()
                let workspaces = try (1 ... 2).map { try XCTUnwrap(manager.workspaceId(named: String($0))) }
                _ = manager.setActiveWorkspace(workspaces[0], on: monitor.id)
                _ = manager.setInteractionMonitor(monitor.id)
                let invocations = try (0 ... 1).map { index in
                    let binding = try XCTUnwrap(settings.hotkeyBindings
                        .first { $0.command == .workspace(.switchTo(index)) })
                    let chord = try XCTUnwrap(binding.binding.chordBinding)
                    return HotkeyInvocation(
                        command: binding.command,
                        trigger: PhysicalHotkeyTrigger(
                            keyCode: chord.keyCode,
                            modifiers: chord.modifiers,
                            isRepeat: false
                        )
                    )
                }
                self.controller = controller
                self.monitor = monitor
                self.invocations = invocations
                self.workspaces = workspaces
            }
        }
    }

#endif
