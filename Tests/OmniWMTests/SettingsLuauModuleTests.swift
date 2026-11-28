// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class SettingsLuauModuleTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let directory: URL
        let storage: SettingsFilePersistence
        var entry: URL {
            storage.fileURL
        }

        init(_ source: String, watch: Bool = false, deferSaves: Bool = false) throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            root = try SettingsFileAccess.canonicalURL(for: temporary)
            directory = root.appendingPathComponent("config", isDirectory: true)
            storage = SettingsFilePersistence(directory: directory, startWatching: watch, deferSaves: deferSaves)
            try write(SettingsFilePersistence.fileName, source)
        }

        func url(_ path: String) -> URL {
            directory.appendingPathComponent(path).standardizedFileURL
        }

        func write(_ path: String, _ source: String) throws {
            let path = url(path)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(source.utf8).write(to: path, options: .atomic)
        }

        func store() -> SettingsStore {
            SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        }

        func close() {
            storage.observation.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testReturnedFunctionUsesItsOwnImporterAndTheSettingsSandbox() throws {
        let source = """
        local make = require('./lib/settings')
        assert(make == require('./lib/settings.luau'))
        return { gaps = make() }
        """
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let gap = SettingsExport.defaults().gaps.size + 1
        try fixture.write("lib/settings.luau", """
        assert(omniwm == nil and ui == nil and io == nil and os == nil and getfenv == nil)
        return function() return { size = require('../value') } end
        """)
        try fixture.write("value.luau", "return \(gap)")
        let result = fixture.storage.loadOutcome()
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.export?.gaps.size, gap)
    }

    func testStartupLanguageUsesModulesAndAChangedHelperInvalidatesTheLaunchCache() throws {
        let fixture = try Fixture("return { general = { language = require('./language') } }")
        defer { fixture.close() }
        let languages = AppLanguagePreference.availableLanguages
        let first = try XCTUnwrap(languages.first)
        let second = try XCTUnwrap(languages.first { $0 != first })
        try fixture.write("language.luau", "return '\(first)'")
        let configured = AppLanguagePreference.configuredLanguage(in: fixture.entry)
        XCTAssertEqual(configured, first)
        XCTAssertNil(AppLanguagePreference.launchArguments(["AppleLanguages": [second]], selecting: configured))
        try fixture.write("language.luau", "return '\(second)'")
        XCTAssertEqual(fixture.store().language, second)
    }

    func testErrorsCarryTheActualModuleAndLineEvenWhenRequireIsCaught() throws {
        let fixture = try Fixture("pcall(require, './outer')\nreturn {}")
        defer { fixture.close() }
        try fixture.write("outer.luau", "return require('./lib/inner')")
        let prefix = ["local okay = true", "assert(okay)"]
        for (body, expected) in [
            ("return )", "Expected"),
            ("error('broken helper')", "broken helper"),
            ("return require('../outer')", "settings.luau -> outer.luau -> lib/inner.luau -> outer.luau"),
            ("return require('../missing')", "missing.luau")
        ] {
            try fixture.write("lib/inner.luau", (prefix + [body]).joined(separator: "\n"))
            guard case let .invalidRejected(reason) = fixture.storage.loadOutcome().notice else { return XCTFail(body) }
            XCTAssertTrue(reason.contains("lib/inner.luau:\(prefix.count + 1):"), reason)
            XCTAssertTrue(reason.contains(expected), reason)
        }
        try fixture.write("lib/inner.luau", "return function()\nerror('inside exported function')\nend")
        try fixture.write(SettingsFilePersistence.fileName, "require('./outer')()\nreturn {}")
        guard case let .invalidRejected(reason) = fixture.storage.loadOutcome().notice
        else { return XCTFail("Expected the exported function error") }
        XCTAssertTrue(reason.contains("lib/inner.luau:2: inside exported function"), reason)
    }

    func testOneSharedBudgetAndSourceLimitsIncludeTheSettingsEntry() throws {
        let entry = "return { gaps = { size = require('./piece') } }"
        let fixture = try Fixture(entry)
        defer { fixture.close() }
        try fixture.write("piece.luau", "while true do end")
        guard case let .invalidRejected(timeout) = fixture.storage.loadOutcome().notice
        else { return XCTFail("Expected the shared CPU limit") }
        XCTAssertTrue(timeout.contains("CPU budget"), timeout)
        let remaining = ConfigScriptLoader.sourceLimit - entry.utf8.count
        try fixture.write("piece.luau", String(repeating: " ", count: remaining + 1))
        guard case let .invalidRejected(bytes) = fixture.storage.loadOutcome().notice
        else { return XCTFail("Expected the total source byte limit") }
        XCTAssertTrue(bytes.contains("1 MiB"), bytes)
        let limit = Int(OMNI_CONFIG_MODULE_LIMIT)
        for index in 0 ... limit { try fixture.write("part\(index).luau", "return true") }
        for count in [limit, limit + 1] {
            let calls = (0 ..< count).map { "require('./part\($0)')" }
            try fixture.write(SettingsFilePersistence.fileName, (calls + ["return {}"]).joined(separator: "\n"))
            let result = fixture.storage.loadOutcome()
            if count == limit {
                XCTAssertNil(result.notice)
            } else {
                guard case let .invalidRejected(reason) = result.notice
                else { return XCTFail("Expected the module count limit") }
                XCTAssertTrue(reason.contains("module limit"), reason)
            }
        }
    }

    func testBrokenHelperRefusesAWindowEditWithTheDiagnosticBeforeOrAfterObservation() throws {
        let entry = "local size = require('./gaps')\nreturn { gaps = { size = size } }"
        let good = SettingsExport.defaults().gaps.size + 1
        let prefix = ["local gap = 1"]
        for observed in [true, false] {
            let fixture = try Fixture(entry)
            defer { fixture.close() }
            try fixture.write("gaps.luau", "return \(good)")
            let settings = fixture.store()
            fixture.storage.confirmation.canPresent = { true }
            try fixture.write("gaps.luau", (prefix + ["error('repair this gap')"]).joined(separator: "\n"))
            if observed { fixture.storage.handlePossibleSettingsFileChange() }
            settings.gaps.size = good + 1
            guard case let .invalidRejected(reason) = settings.configNotice
            else { return XCTFail("Expected the broken helper diagnostic") }
            XCTAssertTrue(reason.contains("gaps.luau:\(prefix.count + 1): repair this gap"), reason)
            XCTAssertEqual(settings.gaps.size, good)
            XCTAssertEqual(try Data(contentsOf: fixture.entry), Data(entry.utf8))
            XCTAssertNil(fixture.storage.confirmation.question)
            try fixture.write("gaps.luau", "return \(good + 1)")
            fixture.storage.handlePossibleSettingsFileChange()
            XCTAssertNil(settings.configNotice)
            XCTAssertEqual(settings.gaps.size, good + 1)
        }
    }

    func testCallSiteConfirmationCannotReplaceCodeFromAnOlderHelperRevision() throws {
        let source = "return { gaps = { size = require('./gaps'), -- intact\n} }"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let value = SettingsExport.defaults().gaps.size + 1
        try fixture.write("gaps.luau", "return \(value)")
        let settings = fixture.store()
        fixture.storage.confirmation.canPresent = { true }
        settings.gaps.size = value + 1
        let stale = try XCTUnwrap(fixture.storage.confirmation.question)
        XCTAssertTrue(stale.message.contains("Line 1 calculates gaps.size. Replace require('./gaps')"))
        let newer = "return \(value + 2)"
        try fixture.write("gaps.luau", newer)
        fixture.storage.confirmation.answer(stale.id, replace: true)
        XCTAssertEqual(try Data(contentsOf: fixture.entry), Data(source.utf8))
        XCTAssertEqual(settings.gaps.size, value + 2)
        settings.gaps.size = value
        let current = try XCTUnwrap(fixture.storage.confirmation.question)
        fixture.storage.confirmation.answer(current.id, replace: true)
        XCTAssertEqual(settings.gaps.size, value)
        XCTAssertEqual(try Data(contentsOf: fixture.url("gaps.luau")), Data(newer.utf8))
        let literal = source.replacingOccurrences(of: "require('./gaps')", with: String(Int(value)))
        XCTAssertEqual(try Data(contentsOf: fixture.entry), Data(literal.utf8))
        try fixture.write("gaps.luau", "error('no longer needed')")
        fixture.storage.handlePossibleSettingsFileChange()
        XCTAssertNil(settings.configNotice)
    }

    func testDeferredWindowEditRacingABrokenHelperReportsItsLine() async throws {
        let entry = "return { gaps = { size = require('./gaps') } }"
        let fixture = try Fixture(entry, watch: true, deferSaves: true)
        defer { fixture.close() }
        let gap = SettingsExport.defaults().gaps.size + 1
        try fixture.write("gaps.luau", "return \(gap)")
        let settings = fixture.store()
        fixture.storage.confirmation.canPresent = { true }
        let broken = ["local value = 1", "return )"]
        try await observe(settings, until: {
            guard case let .invalidRejected(reason) = settings.configNotice else { return false }
            return reason.contains("gaps.luau:\(broken.count):") && settings.settingsWritesBlocked
        }, edit: {
            try fixture.write("gaps.luau", broken.joined(separator: "\n"))
            settings.gaps.size = gap + 1
        })
        XCTAssertEqual(settings.gaps.size, gap)
        XCTAssertNil(fixture.storage.confirmation.question)
        XCTAssertEqual(try Data(contentsOf: fixture.entry), Data(entry.utf8))
    }

    func testLiveWatchesFollowAtomicTargetEditsRetargetedLinksAndMissingImports() async throws {
        let entry = "return { gaps = { size = require('./gaps') } }"
        let fixture = try Fixture(entry, watch: true)
        defer { fixture.close() }
        let first = SettingsExport.defaults().gaps.size + 1
        try fixture.write("../external/first.luau", "return \(first)")
        let link = fixture.url("gaps.luau")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url("../external/first.luau"))
        let settings = fixture.store()
        XCTAssertEqual(settings.gaps.size, first)
        try await observe(settings, until: { settings.gaps.size == first + 1 }, edit: {
            try fixture.write("../external/first.luau", "return \(first + 1)")
        })
        try await observe(settings, until: { settings.gaps.size == first + 2 }, edit: {
            try fixture.write("../other/second.luau", "return \(first + 2)")
            let replacement = fixture.url("replacement")
            try FileManager.default.createSymbolicLink(
                at: replacement,
                withDestinationURL: fixture.url("../other/second.luau")
            )
            XCTAssertEqual(rename(replacement.path, link.path), 0)
        })
        let missing = "./later/nested/value"
        try await observe(settings, until: {
            guard case let .invalidRejected(reason) = settings.configNotice else { return false }
            return reason.contains("gaps.luau:1:") && reason.contains("value.luau")
        }, edit: {
            try fixture.write("../other/second.luau", "return require('\(missing)')")
        })
        XCTAssertEqual(settings.gaps.size, first + 2)
        try await observe(settings, until: { settings.configNotice == nil && settings.gaps.size == first + 3 }, edit: {
            try fixture.write("later/nested/value.luau", "return \(first + 3)")
        })
        XCTAssertEqual(try Data(contentsOf: fixture.entry), Data(entry.utf8))
    }

    func testDeletingEntryKeepsItsWorkingValuesAndBlocksEditsUntilRestored() async throws {
        let entry = "return { gaps = { size = require('./gaps') } }"
        let fixture = try Fixture(entry, watch: true)
        defer { fixture.close() }
        let gap = SettingsExport.defaults().gaps.size + 1
        try fixture.write("gaps.luau", "return \(gap)")
        let settings = fixture.store()
        try await observe(settings, until: {
            guard case let .invalidRejected(reason) = settings.configNotice else { return false }
            return reason.contains("missing") && reason.contains("Restore")
        }, edit: {
            try FileManager.default.removeItem(at: fixture.entry)
        })
        settings.gaps.size = gap + 1
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entry.path))
        XCTAssertEqual(settings.gaps.size, gap)
        XCTAssertTrue(settings.settingsWritesBlocked)
        try await observe(settings, until: { settings.configNotice == nil && !settings.settingsWritesBlocked }, edit: {
            try fixture.write(SettingsFilePersistence.fileName, entry)
        })
        XCTAssertEqual(settings.gaps.size, gap)
    }

    private func observe(
        _ settings: SettingsStore, until ready: @escaping @MainActor () -> Bool, edit: () throws -> Void
    ) async throws {
        let done = expectation(description: "Native file observation applied the expected settings or diagnostic")
        var delivered = false
        let stateChanged: @MainActor () -> Void = {
            if !delivered, ready() {
                delivered = true
                done.fulfill()
            }
        }
        settings.onExternalSettingsReloaded = stateChanged
        settings.onConfigNoticeChanged = stateChanged
        defer {
            settings.onExternalSettingsReloaded = nil
            settings.onConfigNoticeChanged = nil
        }
        try edit()
        await fulfillment(of: [done], timeout: failureBound)
    }
}
