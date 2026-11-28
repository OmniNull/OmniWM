// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ConfigScriptActionBuilderTests: XCTestCase {
    private func load(_ script: String) async throws -> ConfigScriptEvaluation {
        try await ConfigScriptLoader().evaluate(Data(script.utf8), hyperMask: 0)
    }

    func testLoadTimeEffectsPointToTheirBuilders() async throws {
        for (name, argument) in [("notify", "'ready'"), ("openApp", "'com.apple.TextEdit'"), ("launch", "{'echo'}")] {
            do {
                _ = try await load("omniwm.\(name)(\(argument))")
                XCTFail("A direct effect needs a callback")
            } catch let error as ConfigScriptError {
                XCTAssertTrue(error.message.contains("omniwm.act.\(name)"), error.message)
                XCTAssertEqual(error.source, "init.luau")
            }
        }
    }

    func testCallbackCanBuildAnActionForALaterCall() async throws {
        let message = "Saved notice"
        let evaluation = try await load("""
        local saved
        omniwm.command("Store", function(ctx) saved = omniwm.act.notify(ctx.workspace) end)
        omniwm.command("Send", function() omniwm.dispatch(saved) end)
        omniwm.command("Now", function(ctx) omniwm.dispatch(omniwm.act.notify(ctx.workspace)) end)
        """)
        let generation = try XCTUnwrap(evaluation.generation)
        let named = Dictionary(uniqueKeysWithValues: evaluation.namedCommands.map { ($0.name, $0.function) })
        let context = ConfigScriptContext(workspace: message)
        let stored = try await generation.invoke(function: XCTUnwrap(named["Store"]), context: context)
        XCTAssertTrue(stored.commands.isEmpty)
        for name in ["Send", "Now"] {
            let result = try await generation.invoke(function: XCTUnwrap(named[name]), context: context)
            XCTAssertEqual(result.commands.map(\.operation), [.native(.showNotice(message))])
        }
    }

    func testCommandBindingsKeepTheirDeclaredSpelling() async throws {
        let command = "set-container-primary-span"
        let bindings = [("J", "+4%"), ("K", "+4.0%")]
        let script = bindings.map { chord, step in
            "omniwm.keymap.set('\(chord)', omniwm.cmd.setContainerPrimarySpan('\(step)'))"
        }.joined(separator: "\n")
        let evaluation = try await load(script)
        XCTAssertEqual(evaluation.bindings.map(\.commandText), bindings.map { "\(command) \($0.1)" })
    }

    func testRunActionsPreserveDistinctArgumentBytes() async throws {
        let spellings = ["caf\u{E9}", "cafe\u{301}"]
        let evaluation = try await load("""
        local wm = omniwm
        local first = wm.act.launch({"echo", "\(spellings[0])"})
        wm.command("Send", function(ctx)
            wm.dispatch(first)
            wm.dispatch(wm.act.launch({"echo", ctx.workspace}))
        end)
        """)
        let generation = try XCTUnwrap(evaluation.generation)
        let id = try XCTUnwrap(evaluation.namedCommands.first?.function)
        let result = try await generation.invoke(function: id, context: ConfigScriptContext(workspace: spellings[1]))
        let arguments = try result.commands.map { dispatch in
            guard case let .native(.runProgram(argv)) = dispatch.operation else {
                XCTFail("Expected an argument vector")
                return [UInt8]()
            }
            return try Array(XCTUnwrap(argv.last).utf8)
        }
        XCTAssertEqual(arguments, spellings.map { Array($0.utf8) })
    }

    func testCountAndByteExhaustionKeepInternedActionsUsable() async throws {
        let countLimit = Int(OMNI_CONFIG_DECLARATION_LIMIT)
        let argumentLimit = Int(OMNI_CONFIG_ARG_BYTE_LIMIT)
        let countAction = "omniwm.act.notify(ctx.workspace)"
        let byteAction = "omniwm.act.launch({ctx.workspace .. string.rep('x', \(argumentLimit) - #ctx.workspace)})"
        let encodedLaunchBytes = ConfigScriptStage.launchText([""]).utf8.count + argumentLimit
        for (build, capacity) in [
            (countAction, countLimit), (byteAction, ConfigScriptLoader.sourceLimit / encodedLaunchBytes)
        ] {
            let evaluation = try await load("""
            local saved
            omniwm.command("Build", function(ctx)
                local action = \(build)
                if not saved then saved = action end
            end)
            omniwm.command("Send", function() omniwm.dispatch(saved) end)
            """)
            let generation = try XCTUnwrap(evaluation.generation)
            let buildID = try XCTUnwrap(evaluation.namedCommands.first { $0.name == "Build" }?.function)
            let sendID = try XCTUnwrap(evaluation.namedCommands.first { $0.name == "Send" }?.function)
            let inputs = 1 ... capacity
            let first = String(inputs.lowerBound)
            for index in inputs {
                _ = try await generation.invoke(
                    function: buildID,
                    context: ConfigScriptContext(workspace: String(index))
                )
            }
            do {
                _ = try await generation.invoke(function: buildID, context: ConfigScriptContext(workspace: "extra"))
                XCTFail("Expected the action storage limit")
            } catch {
                XCTAssertTrue(error.message.contains("storage limit"), error.message)
            }
            _ = try await generation.invoke(function: buildID, context: ConfigScriptContext(workspace: first))
            let result = try await generation.invoke(function: sendID, context: ConfigScriptContext())
            let expected: HotkeyCommand = build == countAction ? .showNotice(first) :
                .runProgram([first + String(repeating: "x", count: argumentLimit - first.utf8.count)])
            XCTAssertEqual(result.commands.map(\.operation), [.native(expected)])
        }
    }
}
