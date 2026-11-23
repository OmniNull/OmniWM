// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import XCTest

@MainActor
final class ShellLuauConfirmationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPersonalBarMoveAsksOnceAndCancelOrReplaceKeepsOtherSource() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shell.luau")
        let initial = """
        local function lane() return { "clock" } end
        return { profiles = { default = {
            leading = lane(), -- keep my note
            trailing = {}, -- second lane
        } } }
        """
        try Data(initial.utf8).write(to: file)
        let presenter = SettingsFormulaConfirmation()
        presenter.canPresent = { true }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: directory)
        for replace in [false, true] {
            let shown = expectation(description: "Shell formula presented in Settings")
            withObservationTracking { _ = presenter.question } onChange: { shown.fulfill() }
            let task = Task {
                try await coordinator.editBar(confirm: presenter.confirm) { $0.move("clock", to: .trailing) }
            }
            await fulfillment(of: [shown], timeout: failureBound)
            let question = try XCTUnwrap(presenter.question)
            XCTAssertEqual(question.fileURL, file)
            XCTAssertTrue(question.message.contains("lane()"))
            XCTAssertTrue(question.message.contains("profiles.default.trailing"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), initial)
            presenter.answer(question.id, replace: replace)
            if replace {
                try await task.value
                XCTAssertEqual(coordinator.config.trailing, ["clock"])
                let document = try ShellLuauDocument.load(at: file)
                let profile = document.value["profiles"]?["default"]
                XCTAssertEqual(profile?["trailing"], .list([.string("clock")]))
                XCTAssertEqual(profile?["leading"], .record([:]))
                let source = String(decoding: document.source, as: UTF8.self)
                XCTAssertTrue(source.contains("leading = {}, -- keep my note"), source)
                XCTAssertTrue(source.contains("-- second lane"), source)
            } else {
                do { _ = try await task.value
                    XCTFail("Cancelled edit succeeded")
                } catch is CancellationError {}
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), initial)
            }
        }
    }

    func testChangingAHelperBeforeReplaceVoidsTheShellEdit() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shell.luau")
        let helper = directory.appendingPathComponent("palette.luau")
        let source = Data("return { profile = require('./palette') }".utf8)
        try source.write(to: file)
        try Data("return 'default'".utf8).write(to: helper)
        let writer = ShellIslandConfigWriter(shellDirectory: directory, confirm: { request in
            XCTAssertTrue(request.message.contains("require('./palette')"))
            try Data("return 'sakura'".utf8).write(to: helper, options: .atomic)
            return true
        }) {}
        do {
            _ = try await writer.perform { try ShellLuauDocument.write([(["profile"], .string("lake"))], in: $0) }
            XCTFail("A stale confirmation wrote to disk")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: file), source)
    }

    func testProfileHelpersAreScopedToTheirInstalledPackageAndPersonalRequiresAreCallerRelative() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let entry = profile.appendingPathComponent("shell.luau")
        let helper = profile.appendingPathComponent("colors.luau")
        let outside = directory.appendingPathComponent("colors.luau")
        let theme = "native"
        try Data("return '\(theme)'".utf8).write(to: outside)
        try Data("return require('../colors')".utf8).write(to: helper)
        try Data("return { theme = require('./colors') }".utf8).write(to: entry)
        XCTAssertThrowsError(try ShellLuauDocument.load(at: entry, packageRoot: profile)) { error in
            XCTAssertTrue(error.localizedDescription.contains("colors.luau:1"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("outside"), error.localizedDescription)
        }
        XCTAssertEqual(try ShellLuauDocument.load(at: entry).value["theme"], .string(theme))
        try Data("return '\(theme)'".utf8).write(to: helper)
        XCTAssertEqual(try ShellLuauDocument.load(at: entry, packageRoot: profile).value["theme"], .string(theme))
    }
}
