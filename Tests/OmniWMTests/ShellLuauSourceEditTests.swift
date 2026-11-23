// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellLuauSourceEditTests: XCTestCase {
    private func edit(
        _ changes: [([String], SettingsLuauValue?)], in original: String
    ) throws -> (text: String, value: SettingsLuauValue) {
        let document = try ShellLuauDocument(Data(original.utf8))
        let patch = try document.editing(changes)
        XCTAssertNil(patch.question)
        return try (String(decoding: patch.source, as: UTF8.self), ShellLuauDocument(patch.source).value)
    }

    func testEditingNestedSettingsPreservesUnrelatedSourceAndValues() throws {
        let original = """
        return {
            profile = 'look',
            profiles = {
                default = { leading = { "clock" } },
                look = { workspaceBar = { height = 60 } },
            },
            name = "x][", -- keep this
            when = "1979-05-27 07:32:00Z",
            trailing = { "a]", 'b[' },
            weather = { city = "Toronto" },
        }
        """
        let updated = try edit([
            (["profiles", "look", "workspaceBar", "height"], .integer(80)),
            (["profiles", "default", "leading"], .list([.string("battery")]))
        ], in: original)
        let expected = try ShellLuauDocument(Data(original.utf8)).value
        let bar = updated.value["profiles"]?["look"]?["workspaceBar"]
        XCTAssertEqual(bar?["height"], .integer(80))
        XCTAssertNil(bar?["position"])
        XCTAssertEqual(updated.value["profiles"]?["default"]?["leading"], .list([.string("battery")]))
        for key in ["profile", "name", "when", "trailing", "weather"] {
            XCTAssertEqual(updated.value[key], expected[key])
        }
        let unrelated = try XCTUnwrap(original.range(of: "    name = "))
        XCTAssertTrue(updated.text.hasSuffix(String(original[unrelated.lowerBound...])))
    }

    func testQuotedKeysAndEscapedValuesRoundTrip() throws {
        let value = "quote \" line\nslash \\ tab\t"
        let updated = try edit(
            [(["profiles", "my look", "theme"], .string(value))],
            in: "return { ['profile'] = 'default' }"
        )
        XCTAssertEqual(updated.value, .record([
            "profile": .string("default"),
            "profiles": .record(["my look": .record(["theme": .string(value)])])
        ]))
    }

    func testRemovingOneProfileTableLeavesOtherProfilesAndSettings() throws {
        let updated = try edit([(["profiles", "look", "workspaceBar"], nil)], in: """
        return {
            profile = 'look',
            profiles = {
                look = { leading = {'clock'}, workspaceBar = {height = 60} },
                default = { workspaceBar = {height = 24} },
            },
        }
        """)
        XCTAssertEqual(updated.value, .record([
            "profile": .string("look"),
            "profiles": .record([
                "look": .record(["leading": .list([.string("clock")])]),
                "default": .record(["workspaceBar": .record(["height": .integer(24)])])
            ])
        ]))
    }

    func testNoOpPreservesTheOriginalText() throws {
        let original = "-- keep formatting\nreturn {profile = 'default' }\n"
        XCTAssertEqual(try edit([(["profile"], .string("default"))], in: original).text, original)
        XCTAssertEqual(try edit([(["missing"], nil)], in: original).text, original)
    }

    func testInvalidInputCannotOverwriteExistingValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shell.luau")
        let invalidSource = Data("return { trailing = {".utf8)
        try invalidSource.write(to: file)
        XCTAssertThrowsError(try ShellLuauDocument.write([(["profile"], .string("look"))], in: directory))
        XCTAssertEqual(try Data(contentsOf: file), invalidSource)

        let scalarGroup = Data("return {profiles = {look = 42}}".utf8)
        try scalarGroup.write(to: file)
        XCTAssertThrowsError(try ShellLuauDocument.write(
            [(["profiles", "look", "height"], .integer(60))],
            in: directory
        ))
        XCTAssertThrowsError(try ShellLuauDocument.write([(["trailing"], .encoding(Double.infinity))], in: directory))
        XCTAssertEqual(try Data(contentsOf: file), scalarGroup)
    }

    func testSpecialNumbersRetainTheirValueAcrossEditsWithoutCollidingWithUserTables() throws {
        let source = """
        return {
            calculated = 0 / 0,
            positive = math.huge,
            negative = -math.huge,
            names = { "inf", "-inf", "nan" },
            lookalike = { "null", "nan" },
        }
        """
        let original = try ShellLuauDocument(Data(source.utf8))
        let value = original.value
        let nan = try XCTUnwrap(value["calculated"])
        XCTAssertEqual(nan, .number(.nan))
        XCTAssertEqual(value["positive"], .number(.infinity))
        XCTAssertEqual(value["negative"], .number(-.infinity))
        XCTAssertEqual(value["names"], .list([.string("inf"), .string("-inf"), .string("nan")]))
        XCTAssertEqual(value["lookalike"], .list([.string("null"), .string("nan")]))
        let materialized = try ShellLuauDocument(Data(("return " + value.literal()).utf8))
        XCTAssertEqual(materialized.value, value)
        XCTAssertEqual(Set([materialized.value, value]), Set([value]))
        XCTAssertThrowsError(try SettingsLuauDocument(Data("return { gaps = { size = math.huge } }".utf8)))
    }

    @MainActor
    func testWidgetIslandEditCannotConfirmItsOwnFormulaAndAnInteractiveRetryKeepsTheInstanceID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shell.luau")
        let source = Data("""
        local function components() return {} end
        return { profiles = { lake = { island = {components = components()} } } }
        """.utf8)
        try source.write(to: file)
        var questions: [String] = []
        let writer = ShellIslandConfigWriter(shellDirectory: directory, confirm: { question in
            questions.append(question.message)
            return true
        }) {}
        let instance = ShellComponentInstance(id: UUID().uuidString, widget: "clock")
        let request = ShellIslandConfigWriter.Write(
            id: .init(owner: .init(generation: .zero, owner: .zero, epoch: .zero), request: .zero),
            profile: "lake", root: "lake", change: .components([instance])
        )
        let refused = await withCheckedContinuation { continuation in
            writer.submit(request) { continuation.resume(returning: $0) }
        }
        let reason = try XCTUnwrap(refused.error)
        XCTAssertTrue(reason.contains("components()"), reason)
        XCTAssertEqual(refused.id, request.id)
        XCTAssertEqual(questions, [])
        XCTAssertEqual(try Data(contentsOf: file), source)
        let revision = try await writer.persist(request.change, profile: request.profile, root: request.root)
        XCTAssertGreaterThan(revision, refused.revision)
        XCTAssertEqual(questions, [reason])
        let saved = try ShellLuauDocument.load(at: file).value
        let components = saved["profiles"]?[request.profile]?["island"]?["components"]
        XCTAssertEqual(try ShellComponentCatalog.instances(in: components), [instance])
    }

    func testTypedMonitorSettingsAndColorsRoundTrip() throws {
        let monitor = MonitorBarSettings(monitorName: "Main", monitorDisplayId: 7, position: .right, height: 60)
        let color = SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        let updated = try edit([
            (["profiles", "look", "monitorBarOverrides"], try .encoding([monitor])),
            (["profiles", "look", "workspaceBar", "accentColor"], try .encoding(color))
        ], in: "return {}")
        let profile = updated.value["profiles"]?["look"]
        let monitors = try XCTUnwrap(profile?["monitorBarOverrides"])
        let accent = try XCTUnwrap(profile?["workspaceBar"]?["accentColor"])
        XCTAssertEqual(try monitors.decode([MonitorBarSettings].self), [monitor])
        XCTAssertEqual(try accent.decode(SettingsColor.self), color)
    }
}
