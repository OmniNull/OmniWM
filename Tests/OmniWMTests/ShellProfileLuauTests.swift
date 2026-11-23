// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellProfileLuauTests: XCTestCase {
    func testNestedRecordsMergeAndEmptyPersonalListsReplaceInheritedLists() throws {
        let directory = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory
        try write("""
        return {
            center = { 'base-lane' },
            widgets = { example = {
                palette = { base = 'base-color', style = 'old-color' },
                names = { 'base-item' },
            } },
        }
        """, at: shell.appendingPathComponent("default/shell.luau"))
        try write("""
        return { palette = { style = 'style-color' }, names = { 'style-item' } }
        """, at: shell.appendingPathComponent("look/data.luau"))
        try write("""
        return { widgets = { example = require('./data') } }
        """, at: shell.appendingPathComponent("look/shell.luau"))
        try write("""
        return { profile = 'look', profiles = { look = {
            center = {},
            widgets = { example = { palette = { own = 'own-color' }, names = {} } },
        } } }
        """, at: shell.appendingPathComponent("shell.luau"))

        let loaded = try ShellConfigurationInputs.load(in: shell)
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.config.center, [])
        let fields = ShellWidgetSettingsModel.fields(widget: "example", config: loaded.config)
        XCTAssertEqual(fields["palette"], .object([
            "base": .text("base-color"), "style": .text("style-color"), "own": .text("own-color")
        ]))
        XCTAssertEqual(fields["names"], .array([]))
    }

    func testBrokenInstalledHelperNamesItsFileAndKeepsOtherLayersInLenientMode() throws {
        let directory = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory
        let helper = shell.appendingPathComponent("look/layout.luau")
        try write("return { leading = { 'from-default' } }", at: shell.appendingPathComponent("default/shell.luau"))
        try write("return require('./layout')", at: shell.appendingPathComponent("look/shell.luau"))
        try write(
            "return { profile = 'look', profiles = { look = { trailing = { 'from-user' } } } }",
            at: shell.appendingPathComponent("shell.luau")
        )

        XCTAssertThrowsError(try ShellConfigurationInputs.load(in: shell)) { error in
            guard let failure = error as? ShellBarLayout.Unreadable else { return XCTFail(error.localizedDescription) }
            XCTAssertTrue(failure.problem.contains(helper.lastPathComponent), failure.problem)
            XCTAssertTrue(failure.helperFiles.contains(helper.standardizedFileURL))
        }
        var problems: [String] = []
        let fallback = ShellConfig.resolve(shellDirectory: shell, problems: &problems)
        XCTAssertTrue(problems.contains { $0.contains(helper.lastPathComponent) })
        XCTAssertEqual(fallback.leading, ["from-default"])
        XCTAssertEqual(fallback.trailing, ["from-user"])

        try write("return { leading = { 'from-style' } }", at: helper)
        let recovered = try ShellConfigurationInputs.load(in: shell)
        XCTAssertEqual(recovered.problems, [])
        XCTAssertEqual(recovered.config.leading, ["from-style"])
        XCTAssertEqual(recovered.config.trailing, fallback.trailing)
    }

    func testAtomicSaveToExternalSymlinkedHelperReloadsTheActiveConfiguration() async throws {
        let directory = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        let target = directory.appendingPathComponent("dotfiles/bar.luau")
        let alias = directory.appendingPathComponent("links/lanes.luau")
        try write("return { 'clock' }", at: target)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        try write("""
        return { profiles = { default = { trailing = require('../links/lanes') } } }
        """, at: shell.appendingPathComponent("shell.luau"))

        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        XCTAssertEqual(coordinator.config.trailing, ["clock"])
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()
        let updated = expectation(description: "The active bar received the new helper value")
        let next = "volume"
        coordinator.onSave = { config in
            if config.trailing == [next] { updated.fulfill() }
        }
        try write("return { '\(next)' }", at: target)
        await fulfillment(of: [updated], timeout: failureBound)
        await coordinator.flush()
        XCTAssertEqual(coordinator.config.trailing, [next])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
