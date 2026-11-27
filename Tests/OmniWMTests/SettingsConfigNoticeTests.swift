// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SettingsConfigNoticeTests: XCTestCase {
    private let brokenScript = "omniwm.cmd.mistyped()"
    private let validScript = ""

    private var brokenScriptLine: Int {
        brokenScript.components(separatedBy: "\n").count
    }

    private func processed(_ fixture: Fixture, edit: () throws -> Void) async throws {
        let completion = expectation(description: "Process init.luau")
        completion.assertForOverFulfill = false
        fixture.script.onReloadProcessed = { completion.fulfill() }
        defer { fixture.script.onReloadProcessed = nil }
        try edit()
        await fulfillment(of: [completion], timeout: failureBound)
    }

    func testStartupRejectionShowsFileAndParserReasonWithoutTakingFocus() throws {
        let keyWindow = NSApp?.keyWindow
        let fixture = try Fixture(initialText: "return {\n    szie = 4,\n}")
        defer { fixture.close() }
        let panel = try fixture.panel()
        let issue = try XCTUnwrap(fixture.notices.issue)

        XCTAssertTrue(issue.message.contains(fixture.persistence.fileURL.path))
        XCTAssertTrue(issue.message.contains("settings.luau:2:"))
        XCTAssertTrue(issue.message.contains("szie: Unknown setting."))
        XCTAssertTrue(issue.message.contains("active settings were not changed"))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(NSApp?.keyWindow === keyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(fixture.registry.hasVisibleWindow)
        XCTAssertFalse(fixture.registry.isCaptureEligible(windowNumber: panel.windowNumber))
        XCTAssertTrue(fixture.registry.contains(window: panel))
    }

    func testDismissedErrorStaysDismissedUntilItChangesOrClears() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertNil(fixture.notices.issue)
        XCTAssertTrue(fixture.registry.visibleWindows().isEmpty)
        let originalSettings = fixture.settings.toExport()
        try fixture.edit("return {gaps = (}\n")
        let panel = try fixture.panel()
        let firstIssue = fixture.notices.issue
        fixture.notices.dismiss()

        fixture.notices.refresh()
        fixture.persistence.handlePossibleSettingsFileChange()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(fixture.settings.configNotice)
        XCTAssertEqual(fixture.settings.toExport(), originalSettings)

        try fixture.edit("return {bogus = true}\n")
        XCTAssertTrue(try fixture.panel() === panel)
        XCTAssertNotEqual(fixture.notices.issue, firstIssue)

        try fixture.edit(String(decoding: SettingsLuauDocument.initialSource(originalSettings), as: UTF8.self))
        XCTAssertNil(fixture.notices.issue)
        XCTAssertNil(fixture.settings.configNotice)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(fixture.registry.contains(window: panel))

        try fixture.edit("return {gaps = (}\n")
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertEqual(fixture.notices.issue, firstIssue)
    }

    func testOpeningRejectedFileReportsFailureAndKeepsNoticeVisible() throws {
        var openedURL: URL?
        let fixture = try Fixture(initialText: "return {gaps = (}\n", openFile: {
            openedURL = $0
            return false
        })
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.persistence.fileURL)
        fixture.notices.openIssueFile()

        XCTAssertEqual(openedURL, fixture.persistence.fileURL)
        guard case .error = fixture.notices.fileStatus else {
            return XCTFail("Expected opening failure to be visible")
        }
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), original)
    }

    func testOpeningRejectedFileKeepsTheDiagnosticAvailable() throws {
        let fixture = try Fixture(initialText: "return {gaps = (}\n", openFile: { _ in true })
        defer { fixture.close() }
        fixture.notices.openIssueFile()
        XCTAssertEqual(fixture.notices.fileStatus, .opened)
        XCTAssertTrue(try fixture.panel().isVisible)
    }

    func testInvalidTypeBlocksWritesAndClearsAfterCorrection() throws {
        let original = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let future = "return {gaps = {size = false}}"
        let fixture = try Fixture(initialText: future)
        defer { fixture.close() }
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertTrue(fixture.settings.settingsWritesBlocked)
        guard case .settingsInvalidRejected = fixture.notices.issue?.kind else {
            return XCTFail("Expected blocked settings notice")
        }

        try fixture.edit(original)
        XCTAssertNil(fixture.notices.issue)
        XCTAssertFalse(fixture.settings.settingsWritesBlocked)
        XCTAssertTrue(fixture.registry.visibleWindows().isEmpty)
    }

    func testClosingNoticeReleasesItsRegisteredSurface() throws {
        weak var panel: NSPanel?
        let registry = try autoreleasepool {
            let fixture = try Fixture(initialText: "return {gaps = (}\n")
            defer { fixture.close() }
            panel = try fixture.panel()
            fixture.notices.close()
            XCTAssertFalse(try XCTUnwrap(panel).isVisible)
            XCTAssertFalse(fixture.registry.contains(window: panel))
            return fixture.registry
        }
        XCTAssertNil(panel)
        XCTAssertTrue(registry.visibleWindows().isEmpty)
    }

    func testScriptLoadErrorShowsItsFileAndLineAndOpensInitLuau() async throws {
        var openedURL: URL?
        let fixture = try Fixture(openFile: {
            openedURL = $0
            return true
        })
        defer { fixture.close() }
        try await processed(fixture) {
            try fixture.writeScript(brokenScript)
            fixture.script.start()
        }
        let issue = try XCTUnwrap(fixture.notices.issue)
        guard case let .configScriptFailed(message) = issue.kind else {
            return XCTFail("Expected the init.luau load error")
        }

        XCTAssertTrue(message.contains("\(fixture.scriptURL.path):\(brokenScriptLine):"))
        XCTAssertEqual(issue.configFileURL, fixture.scriptURL)
        XCTAssertTrue(try fixture.panel().isVisible)
        fixture.notices.openIssueFile()
        XCTAssertEqual(openedURL, fixture.scriptURL)
        XCTAssertNil(fixture.notices.fileStatus)
    }

    func testSettingsNoticeComesFirstThenHandsOverToTheScriptError() async throws {
        let fixture = try Fixture(initialText: "return {gaps = (}\n")
        defer { fixture.close() }
        try await processed(fixture) {
            try fixture.writeScript(brokenScript)
            fixture.script.start()
        }
        XCTAssertNotNil(fixture.settings.configScriptLoadError)
        guard case .settingsInvalidRejected = fixture.notices.issue?.kind else {
            return XCTFail("Expected the settings.luau notice first")
        }
        let panel = try fixture.panel()
        fixture.notices.dismiss()
        XCTAssertFalse(panel.isVisible)

        try fixture.edit(String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self))
        XCTAssertNil(fixture.settings.configNotice)
        guard case .configScriptFailed = fixture.notices.issue?.kind else {
            return XCTFail("Expected the init.luau load error once settings.luau loads")
        }
        XCTAssertTrue(panel.isVisible)
    }

    func testScriptRecoveryClosesTheNotice() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await processed(fixture) {
            try fixture.writeScript(brokenScript)
            fixture.script.start()
        }
        let panel = try fixture.panel()

        try await processed(fixture) { try fixture.writeScript(validScript, atomic: true) }
        XCTAssertNil(fixture.settings.configScriptLoadError)
        XCTAssertNil(fixture.notices.issue)
        XCTAssertFalse(fixture.registry.contains(window: panel))
    }

    func testCallbackErrorShowsOnceAndClearsWhenTheScriptLoads() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await processed(fixture) {
            try fixture.writeScript(validScript)
            fixture.script.start()
        }
        let noticeChanges = fixture.configNoticeChanges
        var callbackChanges = fixture.callbackErrorChanges
        let failure = ConfigScriptError(line: brokenScriptLine, message: "callback failed")
        fixture.script.reportCallbackError(failure)
        callbackChanges += 1
        guard case let .configScriptFailed(message) = fixture.notices.issue?.kind else {
            return XCTFail("Expected the callback error in the notice")
        }
        XCTAssertEqual(message, "\(fixture.scriptURL.path):\(brokenScriptLine): \(failure.message)")
        XCTAssertEqual(fixture.notices.issue?.configFileURL, fixture.scriptURL)
        XCTAssertEqual(fixture.callbackErrorChanges, callbackChanges)
        let panel = try fixture.panel()

        fixture.notices.dismiss()
        fixture.script.reportCallbackError(failure)
        XCTAssertEqual(fixture.callbackErrorChanges, callbackChanges)
        XCTAssertFalse(panel.isVisible)

        let replacement = "\(fixture.scriptURL.path):\(brokenScriptLine): another failure"
        fixture.script.publishCallbackDiagnostic(replacement)
        callbackChanges += 1
        XCTAssertEqual(fixture.callbackErrorChanges, callbackChanges)
        XCTAssertEqual(fixture.notices.issue?.message, replacement)
        XCTAssertTrue(panel.isVisible)

        try await processed(fixture) { try fixture.writeScript(validScript + "\n", atomic: true) }
        callbackChanges += 1
        XCTAssertEqual(fixture.callbackErrorChanges, callbackChanges)
        XCTAssertEqual(fixture.configNoticeChanges, noticeChanges)
        XCTAssertNil(fixture.settings.configScriptCallbackError)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertNil(fixture.notices.issue)
        XCTAssertFalse(fixture.registry.contains(window: panel))
    }

    func testLoadErrorComesBeforeTheCallbackErrorAndOneLoadClearsBoth() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await processed(fixture) {
            try fixture.writeScript(validScript)
            fixture.script.start()
        }
        let callbackMessage = "\(fixture.scriptURL.path):\(brokenScriptLine): callback failed"
        fixture.script.publishCallbackDiagnostic(callbackMessage)
        try await processed(fixture) { try fixture.writeScript(brokenScript, atomic: true) }
        let loadError = try XCTUnwrap(fixture.settings.configScriptLoadError)
        XCTAssertEqual(fixture.settings.configScriptCallbackError, callbackMessage)
        XCTAssertEqual(fixture.notices.issue?.message, loadError)
        XCTAssertEqual(fixture.script.diagnostic, "\(loadError)\n\(callbackMessage)")

        let noticeChanges = fixture.configNoticeChanges
        let callbackChanges = fixture.callbackErrorChanges
        try await processed(fixture) { try fixture.writeScript(validScript, atomic: true) }
        XCTAssertEqual(fixture.configNoticeChanges, noticeChanges + 1)
        XCTAssertEqual(fixture.callbackErrorChanges, callbackChanges)
        XCTAssertNil(fixture.settings.configScriptCallbackError)
        XCTAssertNil(fixture.notices.issue)
    }

    func testShortcutConflictTracksSourceAndStaysBelowErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let keys = ["Control+Option+H", "Control+Option+J"]
        let saved = try keys.map { key in
            let binding = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(key))
            return HotkeyBinding(id: key, command: .focus(.right), binding: binding)
        }
        fixture.settings.hotkeyBindings = saved
        let bindings = keys.map { "omniwm.keymap.set('\($0)', omniwm.cmd.focus('left'))" }
        let source = bindings.joined(separator: "\n")
        try await processed(fixture) {
            try fixture.writeScript(source)
            fixture.script.start()
        }
        let original = try XCTUnwrap(fixture.notices.issue)
        XCTAssertTrue(original.isScriptConfigIssue)
        XCTAssertEqual(original.configFileURL, fixture.scriptURL)
        XCTAssertTrue(original.message.contains(saved[0].binding.humanReadableString))
        XCTAssertTrue(original.message.contains(saved[0].command.displayName))
        XCTAssertTrue(original.message.contains("\(ConfigScriptController.fileName):\(bindings.startIndex + 1)"))
        XCTAssertTrue(original.message.contains("\(saved.count) Settings assignments"))

        let previous = fixture.script.effectiveBindings
        fixture.notices.dismiss()
        let shifted = [""] + bindings
        try await processed(fixture) { try fixture.writeScript(shifted.joined(separator: "\n"), atomic: true) }
        XCTAssertEqual(fixture.script.effectiveBindings, previous)
        let relocated = try XCTUnwrap(fixture.notices.issue)
        XCTAssertNotEqual(relocated, original)
        XCTAssertTrue(relocated.message
            .contains("\(ConfigScriptController.fileName):\(shifted.count - bindings.count + 1)"))
        XCTAssertTrue(try fixture.panel().isVisible)

        let callback = "Callback failed"
        fixture.script.publishCallbackDiagnostic(callback)
        XCTAssertEqual(fixture.notices.issue?.message, callback)
        try await processed(fixture) { try fixture.writeScript(brokenScript, atomic: true) }
        XCTAssertEqual(fixture.notices.issue?.message, fixture.settings.configScriptLoadError)
        XCTAssertEqual(fixture.settings.configScriptCallbackError, callback)

        try await processed(fixture) { try fixture.writeScript(shifted.joined(separator: "\n"), atomic: true) }
        XCTAssertEqual(fixture.notices.issue, relocated)
        try await processed(fixture) { try fixture.writeScript(validScript, atomic: true) }
        XCTAssertNil(fixture.notices.issue)
        XCTAssertEqual(fixture.settings.hotkeyBindings, saved)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let persistence: SettingsFilePersistence
        let settings: SettingsStore
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let script: ConfigScriptController
        let notices: SettingsConfigNoticeController
        var configNoticeChanges = 0
        var callbackErrorChanges = 0

        var scriptURL: URL {
            directory.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false)
        }

        init(initialText: String? = nil, openFile: @escaping (URL) -> Bool = { _ in false }) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SettingsConfigNoticeTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let initialText {
                try Data(initialText.utf8).write(to: directory.appendingPathComponent(SettingsFilePersistence.fileName))
            }
            persistence = SettingsFilePersistence(
                directory: directory, startWatching: false, deferSaves: false, monitorProvider: { [] }
            )
            settings = SettingsStore(
                persistence: persistence,
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            script = ConfigScriptController(
                fileURL: directory.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false),
                settings: settings
            ) { _ in }
            notices = SettingsConfigNoticeController(
                settings: settings,
                ownedWindowRegistry: registry,
                openFile: openFile
            )
            settings.onConfigNoticeChanged = { [weak self] in
                guard let self else { return }
                configNoticeChanges += 1
                notices.refresh()
            }
            settings.onConfigScriptNoticeChanged = { [weak self] in
                guard let self else { return }
                callbackErrorChanges += 1
                notices.refresh()
            }
            notices.refresh()
        }

        func writeScript(_ source: String, atomic: Bool = false) throws {
            try Data(source.utf8).write(to: scriptURL, options: atomic ? .atomic : [])
        }

        func edit(_ text: String) throws {
            try Data(text.utf8).write(to: persistence.fileURL, options: .atomic)
            persistence.handlePossibleSettingsFileChange()
        }

        func panel() throws -> NSPanel {
            try XCTUnwrap(registry.visibleWindows(kind: .utility).first as? NSPanel)
        }

        func close() {
            script.stop()
            notices.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
