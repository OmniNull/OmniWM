// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class SettingsLuauDocumentTests: XCTestCase {
    func testNewFileContainsEverySavedValueAndLeavesTOMLAlone() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("settings.toml")
        let old = Data("[gaps]\nsize = 29\n".utf8)
        try old.write(to: oldURL)
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let outcome = storage.loadOutcome()
        XCTAssertNil(outcome.notice)
        let actual = try XCTUnwrap(outcome.export)
        XCTAssertEqual(storage.fileURL.lastPathComponent, "settings.luau")
        XCTAssertEqual(try SettingsLuauValue.fields(of: actual), try SettingsLuauValue.fields(of: .defaults()))
        let bytes = try Data(contentsOf: storage.fileURL)
        XCTAssertEqual(bytes, try SettingsLuauDocument.initialSource(.defaults()))
        XCTAssertEqual(try Data(contentsOf: oldURL), old)
        XCTAssertEqual(try SettingsLuauDocument(bytes).export, actual)
    }

    func testLiteralEditPreservesEveryOtherByteWithCRLFUnicodeAndOrder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false)
        let original = "-- höjd\r\nreturn { gaps = { size = 7 -- keep 🚲\r\n}, general = { language = 'sv' } }\r\n"
        try Data(original.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        let committed = expectation(description: "Settings finished saving the slider value")
        storage.setSaveNoticeHandler { notice in
            XCTAssertNil(notice)
            committed.fulfill()
        }
        let radius = 13.0
        settings.gaps.size = radius
        await fulfillment(of: [committed], timeout: failureBound)
        let saved = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertEqual(saved, original.replacingOccurrences(of: "size = 7", with: "size = \(Int(radius))"))
        let identity = try SettingsFileAccess.fileFingerprint(at: storage.fileURL)
        settings.flushNow()
        XCTAssertEqual(try SettingsFileAccess.fileFingerprint(at: storage.fileURL), identity)
    }

    func testMissingGroupsUseDefaultsAndWrongFieldOrTypeReportsItsOwnLine() throws {
        let value = SettingsExport.defaults().gaps.size + 1
        let source = "return {\n    gaps = {\n        size = \(value),\n    },\n}\n"
        let parsed = try SettingsLuauDocument(Data(source.utf8))
        XCTAssertEqual(parsed.export.gaps.size, value)
        XCTAssertEqual(parsed.export.niri, SettingsExport.defaults().niri)
        for (field, change) in [("gaps.szie", "szie = \(value)"), ("gaps.size", "size = 'large'")] {
            let broken = source.replacingOccurrences(of: "size = \(value)", with: change)
            XCTAssertThrowsError(try SettingsLuauDocument(Data(broken.utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("settings.luau:3:"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
            }
        }
    }

    func testConversionPastTheCPUBudgetReportsTheBudget() {
        let source = "return { value = string.rep('x', \(OMNI_NATIVE_BUDGET_INTERVAL)) }"
        omni_native_budget_expire_next_check()
        XCTAssertThrowsError(try SettingsLuauDocument(Data(source.utf8))) { error in
            XCTAssertTrue(
                error.localizedDescription.hasSuffix("settings exceeded the CPU budget"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(omni_native_budget_cancel_expiry())
    }

    func testRunningOutOfMemoryStillReportsMemory() {
        let source = "return { value = string.rep('x', \(ConfigScriptLoader.heapLimit)) }"
        XCTAssertThrowsError(try SettingsLuauDocument(Data(source.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.hasSuffix("not enough memory"), error.localizedDescription)
        }
    }

    func testNoninteractiveEditRefusesFormulaAndSavesLiteralList() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let input = Data("return { gaps = { size = 2 * 3 }, workspaces = {} }".utf8)
        try input.write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        let accepted = settings.toExport()
        settings.gaps.size = accepted.gaps.size + 1
        XCTAssertEqual(settings.gaps.size, accepted.gaps.size)
        XCTAssertTrue(String(describing: settings.configNotice).contains("formula"))
        var list = accepted
        list.workspaceConfigurations.append(WorkspaceConfiguration(name: "Another workspace", layoutType: .niri))
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), input)
        try storage.saveImmediately(list)
        let saved = try Data(contentsOf: storage.fileURL)
        let evaluated = try SettingsLuauDocument(saved)
        XCTAssertEqual(evaluated.export.workspaceConfigurations, list.workspaceConfigurations)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("size = 2 * 3"))
    }

    func testExternalTypoKeepsLastGoodValuesAndCanBeCorrected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let good = "return { gaps = { size = 7 } }\n"
        try Data(good.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        let lastGood = settings.gaps.size
        let invalid = Data(good.replacingOccurrences(of: "size", with: "szie").utf8)
        try invalid.write(to: storage.fileURL, options: .atomic)
        storage.handlePossibleSettingsFileChange()
        XCTAssertEqual(settings.gaps.size, lastGood)
        XCTAssertTrue(String(describing: settings.configNotice).contains("gaps.szie"))
        settings.gaps.size = lastGood + 1
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), invalid)
        XCTAssertEqual(settings.gaps.size, lastGood)
        guard case let .invalidRejected(reason) = settings.configNotice else {
            return XCTFail("Expected the file error when Settings refuses an edit")
        }
        XCTAssertTrue(reason.contains("settings.luau:1:"), reason)
        XCTAssertTrue(reason.contains("gaps.szie"), reason)
        let changed = lastGood + 2
        try Data("return { gaps = { size = \(changed) } }".utf8).write(to: storage.fileURL, options: .atomic)
        storage.handlePossibleSettingsFileChange()
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(settings.gaps.size, changed)
    }

    func testFailedIPCStartPreservesItsFormulaWhenAnotherFieldIsSaved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let source = "return { general = { ipcEnabled = not false }, gaps = { size = 5 } }"
        try Data(source.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        XCTAssertTrue(settings.ipcEnabled)
        settings.recordFailedIPCStart()
        XCTAssertFalse(settings.ipcEnabled)
        let changed = settings.gaps.size + 1
        settings.gaps.size = changed
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(
            try String(contentsOf: storage.fileURL, encoding: .utf8),
            source.replacingOccurrences(of: "size = 5", with: "size = \(Int(changed))")
        )
        XCTAssertFalse(settings.ipcEnabled)
    }

    func testExternalRevisionWinsOverAnUnflushedGUIEdit() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        settings.gaps.size += 1
        let external = settings.gaps.size + 1
        let content = Data("return { gaps = { size = \(external) } }".utf8)
        try content.write(to: storage.fileURL, options: .atomic)
        settings.flushNow()
        XCTAssertNotNil(settings.configNotice)
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), content)
        storage.handlePossibleSettingsFileChange()
        XCTAssertEqual(settings.gaps.size, external)
        XCTAssertNil(settings.configNotice)
    }

    func testSettingsHaveNoAutomationShellOrSystemServices() throws {
        let source = "assert(omniwm == nil and ui == nil and os == nil and io == nil and require == nil)\nreturn {gaps = {size = math.max(2, 3)}}"
        XCTAssertEqual(try SettingsLuauDocument(Data(source.utf8)).export.gaps.size, 3)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
