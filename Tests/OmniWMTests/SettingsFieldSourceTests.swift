// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsFieldSourceTests: XCTestCase {
    func testDefaultFileDeclaresItsTypeAndHasNoCodeMarks() throws {
        let data = try SettingsLuauDocument.initialSource(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(source.hasPrefix("--!strict\nlocal settings: OmniWMSettings = {"))
        XCTAssertTrue(source.hasSuffix("\nreturn settings\n"))
        let document = try SettingsLuauDocument(data)
        XCTAssertFalse(document.hasFormulas)
        let desiredGap = document.export.gaps.size + 1
        var desired = document.export
        desired.gaps.size = desiredGap
        let patch = try document.edit(from: document.export, to: desired)
        XCTAssertNil(patch.question)
        XCTAssertEqual(try SettingsLuauDocument(patch.source).export.gaps.size, desiredGap)
    }

    func testTypedLocalAndCompositeControlsOpenTheExactExpression() throws {
        let source = """
        --!strict
        local width = 8 -- é 🌓
        local settings: OmniWMSettings = {
            gaps = { size = 4, outer = { left = width / 2 } },
            niri = { containerPrimarySpanPresets = { 0.25, 1 / width } },
            workspaceBar = { iconOverrides = { ["com.sample.App"] = string.lower("X") } },
        }
        return settings
        """
        let sources = SettingsFieldSources()
        sources.document = try SettingsLuauDocument(Data(source.utf8))
        for (paths, expression) in [
            ([["gaps", "outer"], ["gaps", "outer", "left"]], "width / 2"),
            ([["niri", "containerPrimarySpanPresets"]], "1 / width"),
            ([["workspaceBar", "iconOverrides", "com.sample.App"]], #"string.lower("X")"#)
        ] {
            let sites = sources.sites(for: paths)
            XCTAssertEqual(sites.count, 1)
            let site = try XCTUnwrap(sites.first)
            let lines = source.components(separatedBy: "\n")
            XCTAssertEqual(site.line, try XCTUnwrap(lines.firstIndex { $0.contains(expression) }) + 1)
            XCTAssertEqual((source as NSString).substring(with: site.selection(in: Data(source.utf8))), expression)
        }
        XCTAssertTrue(sources.sites(for: [["gaps", "size"]]).isEmpty)
        XCTAssertTrue(sources.sites(for: [["workspaceBar", "iconOverrides", "com.other.App"]]).isEmpty)
        XCTAssertEqual(sources.sites(for: [.workspaceBarIconOverrides], member: .key("COM.SAMPLE.APP")).count, 1)
    }

    func testCodeGroupsAndConditionalReturnsMarkTheirDescendants() throws {
        let sources = SettingsFieldSources()
        let expr = "{ left = 1 }"
        let code = "local outer = \(expr)\nreturn { gaps = { outer = outer } }"
        sources.document = try SettingsLuauDocument(Data(code.utf8))
        let sites = sources.sites(for: [["gaps", "outer", "left"]])
        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)
        XCTAssertEqual((code as NSString).substring(with: site.selection(in: Data(code.utf8))), "outer")
        let conditional = "if true then return { gaps = {} } else return {} end"
        sources.document = try SettingsLuauDocument(Data(conditional.utf8))
        let expressions = sources.sites(for: [["gaps", "size"]]).map {
            (conditional as NSString).substring(with: $0.selection(in: Data(conditional.utf8)))
        }
        XCTAssertEqual(expressions, ["{ gaps = {} }", "{}"])
    }

    func testLiteralListRowsKeepDistinctMarksForTheirControls() throws {
        let source = """
        local function label(s) return s end
        return {
            launcher = { entries = {
                { name = "Plain" },
                { name = label("Computed"), path = "/Applications" },
            } },
            workspaceBar = { excludedBundleIDs = { "com.example.One", label("Com.Example.Two") } },
            niri = { containerPrimarySpanPresets = { 0.25, 1 / 2 } },
        }
        """
        let sources = SettingsFieldSources()
        let document = try SettingsLuauDocument(Data(source.utf8))
        sources.document = document
        let entries = document.export.launcher.entries
        let plain = try XCTUnwrap(entries.first { $0.name == "Plain" })
        let computed = try XCTUnwrap(entries.first { $0.name == "Computed" })
        XCTAssertTrue(sources.sites(for: [.launcherEntries], member: .row(plain.id.uuidString)).isEmpty)
        XCTAssertTrue(sources.sites(for: [.launcherEntries], member: .row(nil)).isEmpty)
        XCTAssertTrue(sources.sites(for: [.launcherEntries], member: .row(computed.id.uuidString), leaves: ["path"])
            .isEmpty)
        let name = try XCTUnwrap(sources.sites(
            for: [.launcherEntries],
            member: .row(computed.id.uuidString),
            leaves: ["name"]
        ).first)
        XCTAssertEqual((source as NSString).substring(with: name.selection(in: document.source)), #"label("Computed")"#)
        XCTAssertTrue(sources.sites(for: [.workspaceBarExcludedBundleIDs], member: .row("com.example.One")).isEmpty)
        XCTAssertEqual(sources.sites(for: [.workspaceBarExcludedBundleIDs], member: .row("com.example.two")).count, 1)
        let first = try XCTUnwrap(document.export.niri.containerPrimarySpanPresets?.indices.first)
        XCTAssertTrue(sources.sites(for: [.niriContainerPrimarySpanPresets], member: .index(first)).isEmpty)
        XCTAssertEqual(sources.sites(for: [.niriContainerPrimarySpanPresets], member: .index(first + 1)).count, 1)
    }

    func testComputedListMarksEvenAnAbsentRow() throws {
        let code = #"local rows = { { name = "Example" } }; return { launcher = { entries = rows } }"#
        let sources = SettingsFieldSources()
        sources.document = try SettingsLuauDocument(Data(code.utf8))
        let site = try XCTUnwrap(sources.sites(for: [.launcherEntries], member: .row(nil), leaves: ["name"]).first)
        XCTAssertEqual((code as NSString).substring(with: site.selection(in: Data(code.utf8))), "rows")
    }

    func testHostControlFindsOnlyItsOwnPermissionExpression() throws {
        let source = """
        return { shellPermissions = { widgets = {
            { role = "component", name = "Weather", source = "local",
              allowed = { "first.example", string.upper("other.example") }, denied = {} },
        } } }
        """
        let sources = SettingsFieldSources()
        let document = try SettingsLuauDocument(Data(source.utf8))
        sources.document = document
        let row = try XCTUnwrap(document.export.shellPermissions.widgets.indices.first)
        let leaves = ["allowed", "denied"]
        XCTAssertTrue(sources.sites(
            for: [.shellPermissionsWidgets],
            member: .index(row),
            leaves: leaves,
            element: "first.example"
        ).isEmpty)
        let site = try XCTUnwrap(sources.sites(
            for: [.shellPermissionsWidgets],
            member: .index(row),
            leaves: leaves,
            element: "other.example"
        ).first)
        XCTAssertEqual(
            (source as NSString).substring(with: site.selection(in: document.source)),
            #"string.upper("other.example")"#
        )
    }

    func testSameValueReloadUpdatesTheMarkAndItsLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let value = SettingsExport.defaults().gaps.size
        let literal = "return { gaps = { size = \(value) } }"
        try Data(literal.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: directory))
        let path = [["gaps", "size"]]
        let updated = expectation(description: "A source-only change invalidates the Settings mark")
        withObservationTracking { XCTAssertTrue(settings.fieldSources.sites(for: path).isEmpty) } onChange: {
            updated.fulfill()
        }
        let computed = "local value = \(value)\nreturn { gaps = { size = value } }"
        try Data(computed.utf8).write(to: storage.fileURL, options: .atomic)
        storage.handlePossibleSettingsFileChange()
        wait(for: [updated], timeout: failureBound)
        XCTAssertEqual(settings.fieldSources.sites(for: path).first?.line, computed.components(separatedBy: "\n").count)
        XCTAssertEqual(settings.gaps.size, value)
        try Data(literal.utf8).write(to: storage.fileURL, options: .atomic)
        storage.handlePossibleSettingsFileChange()
        XCTAssertTrue(settings.fieldSources.sites(for: path).isEmpty)
    }
}
