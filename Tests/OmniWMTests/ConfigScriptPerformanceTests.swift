// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

#if OMNIWM_LIVE_CHECKS
    private extension ConfigScriptGeneration {
        func profiledLoad(_ url: URL, hyperMask: UInt32) -> (ConfigScriptLoad, UInt64) {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let result = load(fileURL: url, hyperMask: hyperMask)
            return (result, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
        }
    }

    @MainActor
    final class ConfigScriptPerformanceTests: XCTestCase {
        private struct Sample {
            let workerCPU: UInt64
            let mainCPU: UInt64
            let wall: UInt64
            let heapPeak: Int
        }

        func testLoadAndReload() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: root, startWatching: false),
                runtimeState: RuntimeStateStore(directory: root, deferSaves: false),
                autosaveEnabled: false
            )
            settings.hotkeyBindings = []
            let url = root.appendingPathComponent("init.luau")
            for count in [2, 200] {
                let initial = source(count: count, firstAmount: 12)
                let changed = source(count: count, firstAmount: 8)
                var samples = [[Sample]](repeating: [], count: 3)
                let samplesPerPhase = 20
                for _ in 0 ..< samplesPerPhase {
                    let loader = ConfigScriptLoader()
                    var publications = 0
                    var registrations = 0
                    let controller = ConfigScriptController(fileURL: url, settings: settings) { rows in
                        publications += 1
                        registrations = HotkeyCenter.registrationPlan(for: rows).registrations.count
                    }
                    for (phase, contents) in [initial, changed, changed].enumerated() {
                        try contents.write(to: url, options: .atomic)
                        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        let (load, workerCPU) = await loader.makeGeneration().profiledLoad(
                            url,
                            hyperMask: settings.hyperKeyModifiers.carbonMask
                        )
                        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        controller.apply(load, hyperMask: settings.hyperKeyModifiers.carbonMask)
                        let mainCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu
                        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall
                        let evaluation = try XCTUnwrap(load.result.get())
                        XCTAssertNil(controller.diagnostic)
                        XCTAssertEqual(registrations, count)
                        XCTAssertEqual(publications, phase == 0 ? 1 : 2)
                        XCTAssertEqual(omni_config_live_vm_count(), 0)
                        samples[phase].append(Sample(
                            workerCPU: workerCPU,
                            mainCPU: mainCPU,
                            wall: elapsed,
                            heapPeak: evaluation.peakBytes
                        ))
                    }
                }
                for (name, values) in zip(["load", "reload", "same"], samples) {
                    print("CONFIG_PERF bindings=\(count) phase=\(name) n=\(values.count)"
                        + " worker_cpu_ns=\(distribution(values.map(\.workerCPU)))"
                        + " main_cpu_ns=\(distribution(values.map(\.mainCPU)))"
                        + " wall_ns=\(distribution(values.map(\.wall)))"
                        + " heap_peak_bytes=\(try XCTUnwrap(values.map(\.heapPeak).max())) live_vms=0")
                }
            }
        }

        private func source(count: Int, firstAmount: Int) -> Data {
            let keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let modifiers = [
                "Control",
                "Option",
                "Command",
                "Shift",
                "Control+Option",
                "Control+Shift",
                "Option+Shift",
                "Command+Shift"
            ]
            let chords = modifiers.flatMap { modifier in keys.map { "\(modifier)+\($0)" } }
            let demoChords = ["Control+Option+J", "Control+Option+K"]
            let chosen = count == demoChords.count ? demoChords : Array(chords.prefix(count))
            XCTAssertEqual(chosen.count, count)
            let bindings = chosen.enumerated().map { index, chord in
                let percent = index == 0 ? firstAmount : 4
                return #"wm.keymap.set("\#(chord)", wm.cmd("set-container-primary-span", "+\#(percent)%"))"#
            }
            return Data((["local wm = omniwm"] + bindings).joined(separator: "\n").utf8)
        }

        private func distribution(_ values: [UInt64]) -> String {
            let sorted = values.sorted()
            let median = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[(sorted.count * 95 + 99) / 100 - 1]
            return "\(median)/\(p95)"
        }
    }

    extension ConfigScriptPerformanceTests {
        private struct Change {
            let name: String
            let amount: Int
            let width: Int
            let publishesKeys: Bool
            let rebuildsRules: Bool
        }

        func testModuleAndRuleReload() async throws {
            let scratch = try measureDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let controller = benchmarkController(at: scratch)
            for count in [2, 200] {
                for modular in [false, true] {
                    try await measureGenerations(count: count, modular: modular, root: scratch, wm: controller)
                }
            }
        }

        private func measureGenerations(count: Int, modular: Bool, root: URL, wm: WMController) async throws {
            let url = root.appendingPathComponent("init.luau")
            let changes = [
                Change(name: "load", amount: 12, width: 350, publishesKeys: true, rebuildsRules: true),
                Change(name: "key", amount: 8, width: 350, publishesKeys: true, rebuildsRules: false),
                Change(name: "rule", amount: 8, width: 420, publishesKeys: false, rebuildsRules: true),
                Change(name: "same", amount: 8, width: 420, publishesKeys: false, rebuildsRules: false)
            ]
            var samples = [[Sample]](repeating: [], count: changes.count)
            let samplesPerPhase = 20
            let moduleCount = modular ? 2 : 0
            for _ in 0 ..< samplesPerPhase {
                wm.settings.setScriptAppRules([])
                wm.updateAppRules()
                let loader = ConfigScriptLoader()
                var publications = 0
                let controller = ConfigScriptController(fileURL: url, settings: wm.settings) { rows in
                    publications += 1
                    XCTAssertEqual(HotkeyCenter.registrationPlan(for: rows).registrations.count, count)
                }
                controller.onRulesChanged = { wm.updateAppRules() }
                for (index, change) in changes.enumerated() {
                    try writeGeneration(at: url, change: change, count: count, modular: modular)
                    let beforeKeys = publications
                    let beforeBuild = wm.windowRuleEngine.rebuildCount
                    let beforeScan = try XCTUnwrap(wm.layoutRefreshController.performanceSnapshot()).refreshesEnqueued
                    let mask = wm.settings.hyperKeyModifiers.carbonMask
                    let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let (load, workerCPU) = await loader.makeGeneration().profiledLoad(url, hyperMask: mask)
                    let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                    let applied = controller.apply(load, hyperMask: mask)
                    let mainCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu
                    let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall
                    let evaluation = try XCTUnwrap(load.result.get())
                    XCTAssertTrue(applied)
                    XCTAssertNil(controller.diagnostic)
                    XCTAssertEqual(publications - beforeKeys, change.publishesKeys ? 1 : 0)
                    XCTAssertEqual(wm.windowRuleEngine.rebuildCount - beforeBuild, change.rebuildsRules ? 1 : 0)
                    let afterScan = try XCTUnwrap(wm.layoutRefreshController.performanceSnapshot()).refreshesEnqueued
                    XCTAssertEqual(afterScan - beforeScan, change.rebuildsRules ? 1 : 0)
                    XCTAssertEqual(evaluation.moduleReads, moduleCount)
                    XCTAssertEqual(evaluation.moduleExecutions, moduleCount)
                    XCTAssertEqual(omni_config_live_vm_count(), 0)
                    samples[index].append(Sample(
                        workerCPU: workerCPU,
                        mainCPU: mainCPU,
                        wall: elapsed,
                        heapPeak: evaluation.peakBytes
                    ))
                }
            }
            for (change, values) in zip(changes, samples) {
                print("CONFIG_GRAPH bindings=\(count) modules=\(moduleCount) phase=\(change.name) n=\(values.count)"
                    + " worker_cpu_ns=\(distribution(values.map(\.workerCPU))) main_cpu_ns=\(distribution(values.map(\.mainCPU)))"
                    + " wall_ns=\(distribution(values.map(\.wall))) heap_peak_bytes=\(try XCTUnwrap(values.map(\.heapPeak).max()))"
                    + " module_reads=\(moduleCount) module_executions=\(moduleCount)"
                    + " key_publications=\(change.publishesKeys ? 1 : 0) rebuilds=\(change.rebuildsRules ? 1 : 0)"
                    + " rescan_requests=\(change.rebuildsRules ? 1 : 0) live_vms=0")
            }
        }

        private func writeGeneration(at url: URL, change: Change, count: Int, modular: Bool) throws {
            let bindings = source(count: count, firstAmount: change.amount)
            let rule = "omniwm.rule{bundleId='bench.window',minWidth=\(change.width)}"
            if modular {
                let parent = url.deletingLastPathComponent()
                try (bindings + Data("\nreturn true".utf8)).write(
                    to: parent.appendingPathComponent("keys.luau"),
                    options: .atomic
                )
                try Data((rule + "\nreturn true").utf8).write(
                    to: parent.appendingPathComponent("rules.luau"),
                    options: .atomic
                )
                try Data("require('./keys')\nrequire('./keys')\nrequire('./rules')".utf8).write(
                    to: url,
                    options: .atomic
                )
            } else {
                try (bindings + Data(("\n" + rule).utf8)).write(to: url, options: .atomic)
            }
        }

        private func measureDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func benchmarkController(at root: URL) -> WMController {
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: root, startWatching: false),
                runtimeState: RuntimeStateStore(directory: root, deferSaves: false), autosaveEnabled: false
            )
            settings.hotkeyBindings = []
            settings.appRules = []
            let wm = WMController(settings: settings, clipboardHistoryDirectory: root, diagnosticsDirectory: root)
            wm.layoutRefreshController.suspendForLockScreen()
            wm.layoutRefreshController.beginPerformanceCapture()
            return wm
        }

        func testObservedModuleSave() async throws {
            let root = try measureDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let wm = benchmarkController(at: root)
            let url = root.appendingPathComponent("init.luau")
            let module = root.appendingPathComponent("rules.luau")
            try Data("require('./rules')".utf8).write(to: url)
            let controller = ConfigScriptController(fileURL: url, settings: wm.settings) { _ in
                XCTFail("The rule-only fixture has no hotkeys")
            }
            controller.onRulesChanged = { wm.updateAppRules() }
            let started = expectation(description: "Watch the missing module")
            controller.onReloadProcessed = { started.fulfill() }
            controller.start()
            defer { controller.stop() }
            await fulfillment(of: [started], timeout: failureBound)
            XCTAssertNotNil(controller.diagnostic)
            var samples: [UInt64] = []
            let sampleCount = 20
            for index in 1 ... sampleCount {
                let edited = expectation(description: "Publish module save \(index)")
                let data = Data("omniwm.rule{bundleId='bench.window',minWidth=\(index)}\nreturn true".utf8)
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                controller.onReloadProcessed = {
                    samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
                    edited.fulfill()
                }
                try data.write(to: module, options: .atomic)
                await fulfillment(of: [edited], timeout: failureBound)
                XCTAssertNil(controller.diagnostic)
                XCTAssertEqual(wm.settings.effectiveAppRules.first?.minWidth, Double(index))
            }
            XCTAssertEqual(samples.count, sampleCount)
            print("CONFIG_VNODE n=\(samples.count) wall_ns=\(distribution(samples))")
        }
    }
#endif
