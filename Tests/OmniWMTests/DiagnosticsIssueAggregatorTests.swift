// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DiagnosticsIssueAggregatorTests: XCTestCase {
    private let commandPaletteAdvisoryID = "hotkey-advisory:openCommandPalette"

    func testAggregatorSurfacesHotkeyAdvisoryAtDefaultsAndDropsWhenUnassigned() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.hotkeyBindings = HotkeyBindingRegistry.defaults()
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)

        let atDefaults = DiagnosticsIssueAggregator.applicableIssues(
            controller: controller,
            systemHotkeyQuery: { _ in true }
        )
        XCTAssertTrue(atDefaults.contains { $0.id == commandPaletteAdvisoryID })

        var reassigned = HotkeyBindingRegistry.defaults()
        if let index = reassigned.firstIndex(where: { $0.id == "openCommandPalette" }) {
            reassigned[index].binding = .unassigned
        }
        settings.hotkeyBindings = reassigned

        let afterUnassign = DiagnosticsIssueAggregator.applicableIssues(
            controller: controller,
            systemHotkeyQuery: { _ in true }
        )
        XCTAssertFalse(afterUnassign.contains { $0.id == commandPaletteAdvisoryID })
    }

    func testUpdatingHotkeyBindingsRefreshesStoredSidedHyperAdvisory() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.hotkeyBindings = HotkeyBindingRegistry.defaults()
        settings.updateTrigger(for: "openCommandPalette", newTrigger: .unassigned)
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        let sidedHyperID = "hotkey-sided-hyper:focusPrevious"
        let chord = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: KeySymbolMapper.hyperModifiers)

        settings.updateTrigger(
            for: "focusPrevious",
            newTrigger: .chord(chord.settingSide(.left))
        )
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        XCTAssertTrue(controller.diagnosticsIssues.contains { $0.id == sidedHyperID })

        settings.updateTrigger(for: "focusPrevious", newTrigger: .chord(chord))
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        XCTAssertFalse(controller.diagnosticsIssues.contains { $0.id == sidedHyperID })
    }

    func testAggregatorIsDeterministicAcrossCalls() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let first = DiagnosticsIssueAggregator.applicableIssues(
            controller: controller,
            systemHotkeyQuery: { _ in false }
        )
        let second = DiagnosticsIssueAggregator.applicableIssues(
            controller: controller,
            systemHotkeyQuery: { _ in false }
        )
        XCTAssertEqual(first, second)
    }

    func testRefreshDiagnosticsIssuesMatchesAggregator() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.updateTrigger(for: "openCommandPalette", newTrigger: .unassigned)
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)

        XCTAssertTrue(controller.diagnosticsIssues.isEmpty)
        controller.refreshDiagnosticsIssues()
        XCTAssertEqual(
            controller.diagnosticsIssues,
            DiagnosticsIssueAggregator.applicableIssues(
                controller: controller,
                systemHotkeyQuery: { _ in
                    XCTFail("The default-only guard should skip the system query")
                    return true
                }
            )
        )
    }

    func testScriptLoadErrorIsListedUntilTheScriptLoads() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        settings.onConfigNoticeChanged = { [weak controller] in controller?.refreshDiagnosticsIssues() }
        let configDirectory = settings.settingsFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory.deletingLastPathComponent()) }
        let scriptURL = configDirectory.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false)
        try Data("omniwm.cmd.mistyped()".utf8).write(to: scriptURL)
        defer { controller.stopConfigScript() }

        try await reloaded(controller) { controller.startConfigScript(at: scriptURL) }
        let loadError = try XCTUnwrap(settings.configScriptLoadError)
        let issue = try XCTUnwrap(controller.diagnosticsIssues
            .first { $0.kind == .configScriptFailed(message: loadError) })
        XCTAssertEqual(issue.configFileURL, scriptURL)

        try await reloaded(controller) { try Data().write(to: scriptURL, options: .atomic) }
        XCTAssertNil(settings.configScriptLoadError)
        XCTAssertFalse(controller.diagnosticsIssues.contains { $0.kind == .configScriptFailed(message: loadError) })
    }

    private func reloaded(_ controller: WMController, after edit: () throws -> Void) async throws {
        let completion = expectation(description: "Process init.luau")
        completion.assertForOverFulfill = false
        try edit()
        let script = try XCTUnwrap(controller.configScript)
        script.onReloadProcessed = { completion.fulfill() }
        defer { script.onReloadProcessed = nil }
        await fulfillment(of: [completion], timeout: failureBound)
    }

    private func makeDiagnosticsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsAggregator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
