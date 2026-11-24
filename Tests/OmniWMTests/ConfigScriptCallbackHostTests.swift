// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ConfigScriptCallbackHostTests: XCTestCase {
    private func load(_ lines: [String]) async throws -> ConfigScriptEvaluation {
        try await ConfigScriptLoader().evaluate(Data(lines.joined(separator: "\n").utf8), hyperMask: 0)
    }

    private func function(_ row: ConfigScriptBinding) throws -> Int {
        if case let .configFunction(id) = row.command { return id }
        throw ConfigScriptError(line: row.line, message: "Expected function binding", source: row.source)
    }

    func testEventListenersShareTheGenerationAndReceiveImmutableEventFields() async throws {
        let script = [
            "local wm = omniwm",
            "local describeWorkspace = function(e)",
            "    assert(table.isfrozen(e) and not pcall(function() e.name = 'other' end))",
            "    assert(e.workspace == nil and e.windowId == nil and e.layout == nil and e.bundleId == nil)",
            "    wm.notify((e.id or 'absent') .. '/' .. (e.name or 'absent'))",
            "end",
            "wm.on('workspace.active', describeWorkspace)",
            "wm.on('workspace.active', function(e) wm.notify('second') end)"
        ]
        let evaluated = try await load(script)
        let vm = try XCTUnwrap(evaluated.generation)
        XCTAssertEqual(evaluated.events.map(\.kind), [.workspaceActive, .workspaceActive])
        XCTAssertEqual(
            evaluated.events.map(\.line),
            script.indices.filter { script[$0].hasPrefix("wm.on") }.map { $0 + 1 }
        )
        XCTAssertEqual(Set(evaluated.events.map(\.function)).count, evaluated.events.count)
        let first = try XCTUnwrap(evaluated.events.first)
        let second = try XCTUnwrap(evaluated.events.last)
        let id = UUID().uuidString
        let name = "Design"
        let payload = ConfigScriptEventPayload(id: id, name: name)
        let before = omni_config_vm_entry_count()
        let workspace = try await vm.invoke(function: first.function, event: payload)
        let empty = try await vm.invoke(function: first.function, event: ConfigScriptEventPayload())
        let other = try await vm.invoke(function: second.function, event: payload)
        XCTAssertEqual(workspace.commands.map(\.operation), [.native(.showNotice("\(id)/\(name)"))])
        XCTAssertEqual(empty.commands.map(\.operation), [.native(.showNotice("absent/absent"))])
        XCTAssertEqual(other.commands.map(\.operation), [.native(.showNotice("second"))])
        assertConfigVMEntries(UInt64([workspace, empty, other].count), since: before)
    }

    func testUnknownEventsRejectTheConfigAtTheirSourceLineEvenInsidePcall() async throws {
        let kind = "workspace.notAnEvent"
        let source = [
            "local wm = omniwm",
            "wm.on('config.reloaded', function() end)",
            "pcall(function() wm.on('\(kind)', function() end) end)"
        ]
        do {
            _ = try await load(source)
            XCTFail("An unknown event must reject the whole configuration.")
        } catch let error as ConfigScriptError {
            XCTAssertEqual(error.source, "init.luau")
            XCTAssertEqual(error.line, source.count)
            XCTAssertTrue(error.message.contains(kind))
        }
    }

    func testNativeEffectsBuildAtLoadAndStageInOrderInsideCallbacks() async throws {
        let argv = ["/usr/bin/printf", "%s", "two words", ""]
        let bundle = "com.apple.TextEdit"
        let message = "Current workspace"
        let arguments = argv.map(\.debugDescription).joined(separator: ", ")
        let effects = ["open('\(bundle)')", "run({\(arguments)})", "notify('\(message)')"]
        let chords = ["Control+Option+O", "Control+Option+R", "Control+Option+N"]
        let bindings = zip(chords, effects).map { "wm.keymap.set('\($0)', wm.act.\($1))" }
        let prefix = ["local wm = omniwm"]
        let loaded = try await load(prefix + bindings)
        let expected: [HotkeyCommand] = [.openApp(bundle), .runProgram(argv), .showNotice(message)]
        XCTAssertNil(loaded.generation)
        XCTAssertEqual(loaded.bindings.map(\.command), expected)
        XCTAssertEqual(loaded.bindings.map(\.line), bindings.indices.map { $0 + prefix.count + 1 })
        let run = try XCTUnwrap(loaded.bindings.first { $0.command == .runProgram(argv) })
        XCTAssertEqual(run.commandText, "run [\(arguments)]")

        let function = ["local wm = omniwm", "wm.command('Apply', function(ctx)"]
        let callback = function + effects.map { "assert(wm.\($0) == nil)" } + ["end)"]
        let active = try await load(callback)
        let generation = try XCTUnwrap(active.generation)
        let id = try XCTUnwrap(active.namedCommands.first?.function)
        let staged = try await generation.invoke(function: id, context: ConfigScriptContext())
        XCTAssertEqual(staged.commands.map(\.operation), expected.map(ConfigScriptDispatch.Operation.native))
        XCTAssertEqual(staged.commands.map(\.line), effects.indices.map { function.count + $0 + 1 })
    }

    func testCallbackExtrasShareTheDispatchLimitAndDiscardOnFailure() async throws {
        let source = [
            "local wm = omniwm",
            "local saved = wm.act.open('com.apple.TextEdit')",
            "wm.command('Bounded', function(ctx)",
            "    if ctx.workspace then",
            "        for i = 1, \(OMNI_CONFIG_COMMAND_LIMIT) do wm.notify(ctx.workspace) end",
            "    end",
            "    wm.dispatch(saved)",
            "end)"
        ]
        let evaluation = try await load(source)
        let generation = try XCTUnwrap(evaluation.generation)
        let id = try XCTUnwrap(evaluation.namedCommands.first?.function)
        do {
            _ = try await generation.invoke(function: id, context: ConfigScriptContext(workspace: "work"))
            XCTFail("Expected a combined callback command overflow")
        } catch {
            XCTAssertTrue(error.message.contains("command limit"))
            XCTAssertEqual(error.line, try XCTUnwrap(source.firstIndex { $0.contains("wm.dispatch") }) + 1)
        }
        let next = try await generation.invoke(function: id, context: ConfigScriptContext())
        XCTAssertEqual(next.commands.map(\.operation), [.native(.openApp("com.apple.TextEdit"))])
    }

    func testNamedCommandKeepsItsFunctionAndDeclarationWithoutAChord() async throws {
        let name = "Resize TextEdit"
        let amount = 12
        let source = [
            "local wm = omniwm",
            "wm.command('\(name)', function(ctx)",
            "    assert(ctx.bundleId == 'com.apple.TextEdit')",
            "    wm.dispatch(wm.cmd('set-container-primary-span', '+\(amount)%'))",
            "end)"
        ]
        let evaluation = try await load(source)
        XCTAssertTrue(evaluation.bindings.isEmpty)
        let declaration = try XCTUnwrap(evaluation.namedCommands.first)
        XCTAssertEqual(declaration.name, name)
        XCTAssertEqual(declaration.source, "init.luau")
        XCTAssertEqual(declaration.line, try XCTUnwrap(source.firstIndex { $0.contains("wm.command") }) + 1)
        let generation = try XCTUnwrap(evaluation.generation)
        let invocation = try await generation.invoke(
            function: declaration.function, context: ConfigScriptContext(bundleId: "com.apple.TextEdit")
        )
        XCTAssertEqual(
            invocation.commands.map(\.operation),
            [.native(.sizing(.setContainerPrimarySpan(.adjustProportion(CGFloat(amount)))))]
        )
    }

    func testDuplicateAndInvalidPaletteCommandNamesRejectTheWholeLoad() async throws {
        let first = "omniwm.command('My command', function() end)"
        for (second, reason) in [
            (first, "init.luau:1"),
            ("omniwm.command(' ', function() end)", "name"),
            ("omniwm.command('Another', false)", "function")
        ] {
            let source = [first, second]
            do {
                _ = try await load(source)
                XCTFail("Expected the palette declaration to be rejected")
            } catch let error as ConfigScriptError {
                XCTAssertEqual(error.line, source.count)
                XCTAssertTrue(error.message.contains(reason), error.message)
            }
        }
    }

    func testContextCommandsAndGenerationIdentity() async throws {
        let source = [
            "local wm = omniwm",
            "local grow = wm.cmd('set-container-primary-span', '+12%')",
            "local saved = nil",
            "wm.keymap.set('Control+Option+I', function(ctx)",
            "    if ctx.windowId == nil then wm.dispatch(saved) return end",
            "    assert(ctx.windowId == 'opaque' and ctx.bundleId == 'com.apple.TextEdit')",
            "    assert(ctx.workspace == 'work' and ctx.layout == 'niri')",
            "    wm.log('window', ctx.windowId, true, nil)",
            "    wm.dispatch(grow)",
            "    saved = wm.cmd('focus', 'previous')",
            "    wm.dispatch(saved)",
            "end, { modeKey = 'I' })"
        ]
        let evaluation = try await load(source)
        let generation = try XCTUnwrap(evaluation.generation)
        let id = try function(XCTUnwrap(evaluation.bindings.first))
        let before = omni_config_vm_entry_count()
        let context = ConfigScriptContext(
            windowId: "opaque",
            bundleId: "com.apple.TextEdit",
            workspace: "work",
            layout: "niri"
        )
        let first = try await generation.invoke(function: id, context: context)
        XCTAssertEqual(first.commands.map(\.operation), [
            .native(.sizing(.setContainerPrimarySpan(.adjustProportion(12)))), .native(.focusNavigation(.previous))
        ])
        let dispatchLines = source.indices.filter { source[$0].hasPrefix("    wm.dispatch") }.map { $0 + 1 }
        XCTAssertEqual(first.commands.map(\.line), dispatchLines)
        let second = try await generation.invoke(function: id, context: ConfigScriptContext())
        XCTAssertEqual(second.commands.map(\.operation), [.native(.focusNavigation(.previous))])
        assertConfigVMEntries(2, since: before)
        print("Callback host allocator calls per invocation: \(first.allocations), \(second.allocations)")
        let replacement = try await load(source)
        let next = try XCTUnwrap(replacement.generation)
        let nextID = try function(XCTUnwrap(replacement.bindings.first))
        XCTAssertNotEqual(id, nextID)
        let beforeStale = omni_config_vm_entry_count()
        do {
            _ = try await next.invoke(function: id, context: context)
            XCTFail("The replacement accepted a retired function ID")
        } catch {
            XCTAssertTrue(error.message.contains("retired"))
        }
        XCTAssertEqual(omni_config_vm_entry_count(), beforeStale)
        let plain = try await load(["omniwm.keymap.set('Control+Option+I', omniwm.cmd('focus', 'previous'))"])
        XCTAssertNil(plain.generation)
    }

    func testErrorTimeoutAndCommandOverflowDiscardOnlyTheirCall() async throws {
        let overflowing = Int(OMNI_CONFIG_COMMAND_LIMIT) + 1
        let base = [
            "local wm = omniwm",
            "local act = wm.cmd('focus', 'previous')",
            "wm.keymap.set('I', function(ctx)",
            "    wm.dispatch(act)",
            "    if ctx.layout == 'overflow' then for i = 2, \(overflowing) do wm.dispatch(act) end end",
            "    if ctx.layout == 'error' then error('broken function') end",
            "    if ctx.layout == 'timeout' then while true do end end",
            "    if ctx.layout == 'nested' then wm.dispatch(wm.notify('staged notice')) end",
            "end)"
        ]
        let result = try await load(base)
        let generation = try XCTUnwrap(result.generation)
        let id = try function(XCTUnwrap(result.bindings.first))
        for trigger in ["error", "timeout", "overflow", "nested"] {
            do {
                _ = try await generation.invoke(function: id, context: ConfigScriptContext(layout: trigger))
                XCTFail("Expected \(trigger) to fail")
            } catch {
                XCTAssertEqual(error.source, "init.luau")
                XCTAssertEqual(
                    error.line,
                    try XCTUnwrap(base.firstIndex { $0.contains("== '\(trigger)'") }) + 1,
                    error.message
                )
            }
            let next = try await generation.invoke(function: id, context: ConfigScriptContext())
            XCTAssertEqual(next.commands.map(\.operation), [.native(.focusNavigation(.previous))])
        }
    }

    func testAlreadyCancelledInvocationNeverEntersLua() async throws {
        let result = try await load(["omniwm.keymap.set('I', function() error('called after cancellation') end)"])
        let generation = try XCTUnwrap(result.generation)
        let id = try function(XCTUnwrap(result.bindings.first))
        let before = omni_config_vm_entry_count()
        let rejected = await withTaskGroup(of: Bool.self) { group in
            group.cancelAll()
            group.addTask {
                do {
                    _ = try await generation.invoke(function: id, context: ConfigScriptContext())
                    return false
                } catch {
                    return Task.isCancelled
                }
            }
            return await group.next()
        }
        XCTAssertEqual(rejected, true)
        XCTAssertEqual(omni_config_vm_entry_count(), before)
    }

    func testImportedFunctionReportsModuleAndLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("init.luau")
        try Data("omniwm.keymap.set('I', require('./handler'))".utf8).write(to: file)
        let body = ["return function(ctx)", "    error('module failure')", "end"]
        let module = folder.appendingPathComponent("handler.luau")
        try Data(body.joined(separator: "\n").utf8).write(to: module)
        let load = await ConfigScriptLoader().load(fileURL: file, hyperMask: 0)
        let result = try XCTUnwrap(load.result.get())
        let generation = try XCTUnwrap(result.generation)
        let id = try function(XCTUnwrap(result.bindings.first))
        do {
            _ = try await generation.invoke(function: id, context: ConfigScriptContext())
            XCTFail("Expected module failure")
        } catch {
            XCTAssertEqual(error.source, module.lastPathComponent)
            XCTAssertEqual(error.line, try XCTUnwrap(body.firstIndex { $0.contains("error(") }) + 1)
            XCTAssertTrue(error.message.contains("module failure"))
        }
    }
}
