// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ConfigScriptModuleTests: XCTestCase {
    private struct Fixture {
        let folder: URL
        let entry: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
            entry = folder.appendingPathComponent("config/init.luau")
            try FileManager.default.createDirectory(
                at: entry.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        func write(_ relative: String, lines: [String]) throws {
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        }

        func evaluate() async -> ConfigScriptLoad {
            await ConfigScriptLoader().load(fileURL: entry, hyperMask: HyperKeyModifiers.default.carbonMask)
        }

        func close() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func testImporterRelativePathsCachedResultsAndExportedFunctionSource() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let declarations = [
            "local wm = omniwm",
            "return function()",
            "    wm.keymap.set('Control+Option+J', wm.cmd.openCommandPalette())",
            "end"
        ]
        try fixture.write("config/lib/declarations.luau", lines: declarations)
        try fixture.write("config/lib/setup.luau", lines: [
            "assert(outerGlobal == nil)",
            "innerGlobal = true",
            "assert(require('../false-value') == false)",
            "return require('./declarations')"
        ])
        try fixture.write("config/false-value.luau", lines: ["return false"])
        try fixture.write("config/init.luau", lines: [
            "outerGlobal = true",
            "local declare = require('./lib/setup')",
            "assert(innerGlobal == nil)",
            "assert(declare == require('./lib/declarations.luau'))",
            "assert(require('./false-value.luau') == false)",
            "declare()"
        ])
        let load = await fixture.evaluate()
        let result = try XCTUnwrap(load.result.get())
        let dependencies = ["config/lib/declarations.luau", "config/lib/setup.luau", "config/false-value.luau"]
        let observed = ([fixture.entry] + dependencies.map { fixture.folder.appendingPathComponent($0) })
            .map(\.standardizedFileURL)
        XCTAssertEqual(Set(load.versions.keys), Set(observed))
        XCTAssertEqual(result.moduleReads, dependencies.count)
        XCTAssertEqual(result.moduleExecutions, dependencies.count)
        let row = try XCTUnwrap(result.bindings.first)
        XCTAssertEqual(row.source, "lib/declarations.luau")
        XCTAssertEqual(row.line, try XCTUnwrap(declarations.firstIndex { $0.contains("wm.keymap.set") }) + 1)
        XCTAssertEqual(row.command, .openCommandPalette)
    }

    func testExternalSymlinkUsesItsLogicalImporterDirectoryAndTracksEveryAlias() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.write("outside/source.luau", lines: ["return require('./value')"])
        try fixture.write("config/value.luau", lines: ["return false"])
        let directory = fixture.entry.deletingLastPathComponent()
        let external = fixture.folder.appendingPathComponent("outside/source.luau")
        let linked = directory.appendingPathComponent("linked.luau")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        try fixture.write("config/init.luau", lines: [
            "assert(require('./linked') == false)",
            "assert(require('../outside/source') == false)"
        ])
        let load = await fixture.evaluate()
        let result = try XCTUnwrap(load.result.get())
        XCTAssertEqual(result.moduleExecutions, ["linked", "value"].count)
        XCTAssertEqual(result.moduleReads, result.moduleExecutions)
        XCTAssertNotNil(load.versions[linked.standardizedFileURL])
        XCTAssertNotNil(load.versions[external.standardizedFileURL])
    }

    func testCaughtNestedCycleAndCompileRuntimeAndHostFailuresReportTheirActualSite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.write("config/init.luau", lines: ["pcall(require, './outer')"])
        try fixture.write("config/outer.luau", lines: ["return require('./inner')"])
        let prefix = ["local a = 1"]
        for (statement, fragment) in [
            ("return require('./outer')", "init.luau -> outer.luau -> inner.luau -> outer.luau"),
            ("return require('./init')", "init.luau -> outer.luau -> inner.luau -> init.luau"),
            ("return )", "Expected"),
            ("error('module failed')", "module failed"),
            ("omniwm.cmd.notACommand()", "Unknown command"),
            ("return require('./absent')", "absent.luau")
        ] {
            try fixture.write("config/inner.luau", lines: prefix + [statement])
            let load = await fixture.evaluate()
            guard case let .failure(error) = load.result else { return XCTFail(statement) }
            XCTAssertEqual(error.source, "inner.luau", statement)
            XCTAssertEqual(error.line, prefix.count + 1, statement)
            XCTAssertTrue(error.message.localizedCaseInsensitiveContains(fragment), error.message)
            if statement.contains("absent") {
                let missing = fixture.entry.deletingLastPathComponent().appendingPathComponent("absent.luau")
                XCTAssertNotNil(load.versions[missing.standardizedFileURL])
            }
        }
    }

    func testOneCpuBudgetAlsoAppliesToModuleBodies() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.write("config/init.luau", lines: ["pcall(require, './busy')"])
        try fixture.write("config/busy.luau", lines: ["while true do end"])
        let load = await fixture.evaluate()
        guard case let .failure(error) = load.result else { return XCTFail("Expected a CPU-budget rejection") }
        XCTAssertTrue(error.message.localizedCaseInsensitiveContains("budget"), error.message)
    }

    func testDistinctModuleLimitAndSharedSourceByteLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let limit = Int(OMNI_CONFIG_MODULE_LIMIT)
        for index in 1 ... limit + 1 {
            try fixture.write("config/key\(index).luau", lines: ["return true"])
        }
        for count in [limit, limit + 1] {
            try fixture.write("config/init.luau", lines: ["for i = 1, \(count) do require('./key' .. i) end"])
            let load = await fixture.evaluate()
            if count == limit {
                XCTAssertEqual(try XCTUnwrap(load.result.get()).moduleExecutions, limit)
            } else if case let .failure(error) = load.result {
                XCTAssertTrue(error.message.contains("module limit"), error.message)
            } else {
                XCTFail("Expected module count limit")
            }
        }
        let entry = "require('./key1')"
        try fixture.write("config/init.luau", lines: [entry])
        let moduleSize = ConfigScriptLoader.sourceLimit - entry.utf8.count + 1
        try fixture.write("config/key1.luau", lines: [String(repeating: " ", count: moduleSize)])
        let load = await fixture.evaluate()
        guard case let .failure(error) = load.result else { return XCTFail("Expected combined source byte limit") }
        XCTAssertTrue(error.message.contains("1 MiB"), error.message)
    }
}
