// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

final class ConfigScriptHostTests: XCTestCase {
    private func evaluate(_ text: String, hyperMask: UInt32 = HyperKeyModifiers.default.carbonMask) async throws
        -> ConfigScriptEvaluation
    {
        try await ConfigScriptLoader().evaluate(Data(text.utf8), hyperMask: hyperMask)
    }

    private func rejection(_ text: String) async throws -> ConfigScriptError {
        var failure: ConfigScriptError?
        do {
            _ = try await evaluate(text)
        } catch let error as ConfigScriptError {
            failure = error
        }
        return try XCTUnwrap(failure, "Expected the complete configuration to be rejected")
    }

    func testConstructsTypedNativeActionsAndReportsDeclarationLines() async throws {
        let fine = 4
        let wide = 12
        let source = [
            "local wm = omniwm",
            "local fine = wm.cmd('set-container-primary-span', '+\(fine)%')",
            "wm.keymap.set('Control+Option+J', fine)",
            "wm.keymap.set('Control+Option+K', wm.cmd('set-container-primary-span', '+\(wide)%'))",
            "wm.keymap.set('Hyper+F', wm.cmd('focus', 'previous'))"
        ]
        let mask = UInt32(cmdKey | optionKey)
        let result = try await evaluate(source.joined(separator: "\n"), hyperMask: mask)
        XCTAssertEqual(result.bindings.map(\.command), [
            .sizing(.setContainerPrimarySpan(.adjustProportion(Double(fine)))),
            .sizing(.setContainerPrimarySpan(.adjustProportion(Double(wide)))),
            .focusNavigation(.previous)
        ])
        XCTAssertEqual(
            result.bindings.map(\.line),
            source.indices.filter { source[$0].hasPrefix("wm.keymap") }.map { $0 + 1 }
        )
        XCTAssertEqual(result.bindings.last?.chord, KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: mask))
        XCTAssertGreaterThan(result.peakBytes, 0)
        XCTAssertLessThanOrEqual(result.peakBytes, ConfigScriptLoader.heapLimit)
    }

    func testNativeParserAndBindingValidationReportTheFailingLineEvenWhenCaught() async throws {
        let prefix = ["local wm = omniwm", "local action = wm.cmd('open-command-palette')"]
        let cases = [
            ("wm.cmd('set-container-primary-spam', '+4%')", "Unknown command 'set-container-primary-spam'."),
            ("wm.cmd('set-container-primary-span', 'wide')", "Invalid arguments"),
            ("wm.cmd('switch-workspace', 'slot', '0')", "Invalid arguments"),
            ("wm.keymap.set('Unassigned', action)", "Invalid keyboard chord"),
            ("wm.keymap.set('Control+UnknownKey', action)", "Invalid keyboard chord"),
            ("wm.cmd(string.char(255))", "UTF-8")
        ]
        for (statement, expected) in cases {
            let failure = try await rejection((prefix + ["pcall(function() \(statement) end)"]).joined(separator: "\n"))
            XCTAssertEqual(failure.line, prefix.count + 1, statement)
            XCTAssertTrue(failure.message.contains(expected), failure.message)
        }
        let forged = try await rejection((prefix + ["pcall(wm.keymap.set, 'Option+J', {})"]).joined(separator: "\n"))
        XCTAssertEqual(forged.line, prefix.count + 1)
    }

    func testEveryManifestCommandCanBeConstructedInLuau() async throws {
        let source = IPCAutomationManifest.commandDescriptors.map { descriptor in
            let firstPositiveIndex = "1"
            let arguments = descriptor.arguments.map { $0.kind.literalValues?.first ?? firstPositiveIndex }
            let words = (descriptor.commandWords + arguments).map(\.debugDescription).joined(separator: ", ")
            return "assert(omniwm.cmd(\(words)))"
        }
        _ = try await evaluate(source.joined(separator: "\n"))
    }

    func testOverlappingSidedChordReportsTheOriginalDeclaration() async throws {
        let original = ["local wm = omniwm", "wm.keymap.set('Option+J', wm.cmd('open-command-palette'))"]
        let overlapping = "wm.keymap.set('Left Option+J', wm.cmd('focus', 'previous'))"
        let failure = try await rejection((original + [overlapping]).joined(separator: "\n"))
        XCTAssertEqual(failure.line, original.count + 1)
        XCTAssertTrue(failure.message.contains("init.luau:\(original.count)"), failure.message)
    }

    func testHostExposesOnlyConfigServicesAndFreezesItsTables() async throws {
        let result = try await evaluate("""
        assert(ui == nil and type(require) == "function" and io == nil and package == nil)
        assert(omniwm.run == nil and omniwm.data == nil and omniwm.dispatch == nil)
        assert(not pcall(function() omniwm.cmd = nil end))
        assert(not pcall(function() omniwm.keymap.set = nil end))
        local action = omniwm.cmd("open-command-palette")
        omniwm.keymap.set(string.upper("j"), action)
        """)
        XCTAssertEqual(result.bindings.map(\.command), [.openCommandPalette])
    }

    func testCompileAndRuntimeDiagnosticsKeepTheSourceLine() async throws {
        let prefix = ["local wm = omniwm"]
        for invalid in ["local broken = )", "error('runtime failure')"] {
            let failure = try await rejection((prefix + [invalid]).joined(separator: "\n"))
            XCTAssertEqual(failure.line, prefix.count + 1, failure.message)
        }
    }

    func testExecutionHeapAndAggregateStringBytesAreBounded() async throws {
        let timeout = try await rejection("pcall(function() while true do end end)")
        XCTAssertTrue(timeout.message.localizedCaseInsensitiveContains("budget"), timeout.message)
        let heap = try await rejection("return string.rep('a', \(ConfigScriptLoader.heapLimit))")
        XCTAssertTrue(heap.message.localizedCaseInsensitiveContains("memory"), heap.message)
        let bytes = try await rejection("""
        local action = omniwm.cmd("open-command-palette")
        omniwm.keymap.set(string.rep("a", \(ConfigScriptLoader.sourceLimit)), action)
        """)
        XCTAssertTrue(bytes.message.localizedCaseInsensitiveContains("byte limit"), bytes.message)
    }

    func testRulesValidateRawScalarFieldsAndRetainOnlyAcceptedNativeValues() async throws {
        let identifier = UUID()
        let fields = [
            "id = '\(identifier.uuidString)'", "bundleId = 'com.example.app'", "appNameSubstring = 'Sample'",
            "titleRegex = '^[Ee]ditor'", "axRole = 'AXWindow'", "axSubrole = 'AXStandardWindow'",
            "layout = 'float'", "assignToWorkspace = '2'", "assignToWorkspaceForAllWindows = true",
            "minWidth = 240", "minHeight = 120", "initialContainerPrimarySpan = 0.5"
        ]
        let declaration = "omniwm.rule { " + fields.joined(separator: ", ") + " }"
        let result = try await evaluate(declaration)
        let native = try XCTUnwrap(result.rules.first).rule
        XCTAssertEqual(native, AppRule(
            id: identifier, bundleId: "com.example.app", appNameSubstring: "Sample",
            titleRegex: "^[Ee]ditor", axRole: "AXWindow", axSubrole: "AXStandardWindow", layout: .float,
            assignToWorkspace: "2", assignToWorkspaceForAllWindows: true,
            initialContainerPrimarySpan: 0.5, minWidth: 240, minHeight: 120
        ))
        for (fields, reason) in [
            ("titleRegex = 'editor', titleSubstring = 'edit', layout = 'tile'", "either"),
            ("bundleId = 'app', titleRegex = '[', layout = 'tile'", ""),
            ("bundleId = 'app', scratchpad = 1.5", "type"),
            ("bundleId = 'app', scratchpad = 1, layout = 'tile'", "float"),
            ("bundleId = 'app', minWidth = '123'", "type"),
            ("bundleId = 'app', layout = 'unknown'", "layout"),
            ("bundleId = 'app', id = 'bad', layout = 'tile'", "UUID"),
            ("bundleID = 'app', layout = 'tile'", "Unknown rule field"),
            ("bundleId = 'app', effect = {}", "strings, numbers or booleans")
        ] {
            let failure = try await rejection("pcall(function() omniwm.rule { " + fields + " } end)")
            XCTAssertEqual(failure.line, 1, fields)
            XCTAssertFalse(failure.message.isEmpty)
            if !reason.isEmpty { XCTAssertTrue(failure.message.contains(reason), failure.message) }
        }
    }

    func testImplicitRuleIDsAreStableAcrossLineMovesAndDuplicateExplicitIDsFail() async throws {
        let declaration = "omniwm.rule { bundleId = 'app', layout = 'tile' }"
        let first = try await evaluate(declaration)
        let moved = try await evaluate("\n" + declaration)
        XCTAssertEqual(first.rules.first?.rule, moved.rules.first?.rule)
        XCTAssertNotEqual(first.rules.first?.line, moved.rules.first?.line)
        let id = UUID().uuidString
        let explicit = "omniwm.rule{ id='\(id)', bundleId='app', layout='float' }"
        let duplicate = try await rejection(explicit + "\n" + explicit)
        XCTAssertEqual(duplicate.line, 2)
        XCTAssertTrue(duplicate.message.contains("init.luau:1"), duplicate.message)
    }

    func testTruncatedMessagesEndOnScalars() async throws {
        let unexpected = String(repeating: "🧪", count: Int(OMNI_CONFIG_ERROR_CAPACITY))
        for code in ["omniwm.cmd('\(unexpected)')", "error('\(unexpected)')"] {
            let error = try await rejection(code)
            XCTAssertTrue(error.message.contains("🧪"))
            XCTAssertFalse(error.message.contains("�"))
        }
    }

    func testHostCapsBoundActionAndBindingCountsBeforeNativeStaging() {
        let limit = Int(OMNI_CONFIG_DECLARATION_LIMIT)
        let loops = [
            "omniwm.cmd('open-command-palette')",
            "omniwm.keymap.set('Option+J', action)"
        ]
        for statement in loops {
            for count in [limit, limit + 1] {
                let firstAction = statement.contains("keymap") ? "local action = omniwm.cmd('open-command-palette')" : ""
                let script = "\(firstAction)\nfor i = 1, \(count) do \(statement) end"
                var callbacks = omni_config_callbacks(
                    resolve: { _, _, _, _, actionID, _, _ in
                        actionID?.pointee = 0
                        return omni_config_live_vm_count() > 0
                    },
                    bind: { _, _, _, _, _, _, _ in true }, read_module: nil, rule: nil
                )
                var stats = omni_config_stats()
                var message = [CChar](repeating: 0, count: 256)
                let status = script.withCString { pointer in
                    omni_config_evaluate(
                        "@init.luau", omni_config_span(data: pointer, length: script.utf8.count),
                        ConfigScriptLoader.heapLimit, ConfigScriptLoader.cpuBudget, &callbacks, nil,
                        &stats, &message, message.count
                    )
                }
                XCTAssertEqual(status == OMNI_OK, count == limit, "\(statement), \(count)")
            }
        }
    }
}
