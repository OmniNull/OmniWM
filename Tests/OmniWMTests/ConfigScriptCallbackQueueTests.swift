// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptCallbackQueueTests: XCTestCase {
    @MainActor struct Fixture {
        let controller: WMController
        let script: ConfigScriptController
        let loader = ConfigScriptLoader()
        let origin = "1"
        let destination = "2"

        init(test: XCTestCase) throws {
            controller = InputControllerTestSupport.controller(for: test)
            let settings = controller.settings
            settings.hotkeyBindings = []
            let manager = controller.workspaceManager
            let monitor = try XCTUnwrap(manager.monitors.first)
            settings.workspaces.configurations = [origin, destination].map {
                WorkspaceConfiguration(
                    name: $0, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .niri
                )
            }
            manager.applyMonitorConfigurationChange([monitor])
            manager.applySettings()
            let active = try XCTUnwrap(manager.workspaceId(named: origin))
            XCTAssertTrue(manager.setActiveWorkspace(active, on: monitor.id))
            script = ConfigScriptController(
                fileURL: settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau"),
                settings: settings, wmController: controller
            ) { [weak controller] rows in
                guard let controller else { return }
                controller.updateHotkeyBindings(controller.settings.hotkeyBindings, scriptBindings: rows)
            }
            controller.configScript = script
        }

        func load(_ lines: [String]) async throws -> ConfigScriptLoad {
            let evaluation = try await loader.evaluate(
                Data(lines.joined(separator: "\n").utf8), hyperMask: controller.settings.hyperKeyModifiers.carbonMask
            )
            return ConfigScriptLoad(versions: [:], result: .success(evaluation))
        }

        func apply(_ load: ConfigScriptLoad) {
            XCTAssertTrue(script.apply(load, hyperMask: controller.settings.hyperKeyModifiers.carbonMask))
        }

        var command: HotkeyCommand {
            get throws { try XCTUnwrap(script.effectiveBindings.first?.command) }
        }

        func press(_ command: HotkeyCommand) -> ExternalCommandResult {
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: command))
        }
    }

    func testSuccessfulReturnAppliesInOrderAndStopsAtFirstMissingTarget() async throws {
        let fixture = try Fixture(test: self)
        let missing = WorkspaceIDPolicy.lowestUnusedRawID(in: [fixture.origin, fixture.destination])
        let body = [
            "omniwm.keymap.set('Control+Option+I', function()",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(missing)'))",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.origin)'))",
            "end)"
        ]
        fixture.apply(try await fixture.load(body))
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        let failedLine = try XCTUnwrap(body.firstIndex { $0.contains("'\(missing)'") }) + 1
        let diagnostic = try XCTUnwrap(fixture.script.diagnostic)
        XCTAssertTrue(diagnostic.contains("init.luau:\(failedLine):"), diagnostic)
        XCTAssertTrue(diagnostic.contains("notFound"), diagnostic)
    }

    func testNamedOnlyGenerationKeepsItsLastGoodCommandAndReportsOverflowAtItsDeclaration() async throws {
        let fixture = try Fixture(test: self)
        let name = "Switch workspace"
        let body = [
            "local destination = omniwm.cmd('switch-workspace', '\(fixture.destination)')",
            "omniwm.command('\(name)', function() omniwm.dispatch(destination) end)"
        ]
        var published: [[String]] = []
        fixture.script.onCommandsChanged = { published.append(fixture.script.acceptedCommands.map(\.name)) }
        defer { fixture.script.onCommandsChanged = nil }
        fixture.apply(try await fixture.load(body))
        XCTAssertEqual(published, [[name]])
        XCTAssertTrue(fixture.script.effectiveBindings.isEmpty)
        let named = try XCTUnwrap(fixture.script.acceptedCommands.first)
        let action = HotkeyCommand.configFunction(named.function)
        let broken = ConfigScriptError(line: 1, message: "bad replacement")
        fixture.apply(ConfigScriptLoad(versions: [:], result: .failure(broken)))
        XCTAssertEqual(fixture.script.acceptedCommands, [named])
        XCTAssertEqual(published, [[name]])
        for _ in 0 ..< ConfigScriptCallbackQueue.capacity {
            XCTAssertEqual(fixture.press(action), .executed)
        }
        XCTAssertEqual(fixture.press(action), .windowActionFailed)
        let declarationLine = try XCTUnwrap(body.firstIndex { $0.contains("omniwm.command") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic)
            .contains("init.luau:\(declarationLine): Callback queue is full"))
        await fixture.script.callbackQueue?.worker?.value
        fixture.apply(ConfigScriptLoad(versions: [:], result: .success(nil)))
        XCTAssertEqual(fixture.press(action), .notFound)
        XCTAssertNil(fixture.script.callbackQueue)
        XCTAssertEqual(published, [[name], []])
    }

    func testBoundedBurstDropsOverflowAndDiscardsEveryFailedCallsCommands() async throws {
        let fixture = try Fixture(test: self)
        let body = [
            "omniwm.keymap.set('Control+Option+I', function()",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "    error('broken callback')",
            "end)"
        ]
        fixture.apply(try await fixture.load(body))
        let command = try fixture.command
        let initialEntries = omni_config_vm_entry_count()
        for _ in 0 ..< ConfigScriptCallbackQueue.capacity {
            XCTAssertEqual(fixture.press(command), .executed)
        }
        XCTAssertEqual(fixture.press(command), .windowActionFailed)
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("queue is full"))
        XCTAssertEqual(omni_config_vm_entry_count(), initialEntries)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(omni_config_vm_entry_count() - initialEntries, UInt64(ConfigScriptCallbackQueue.capacity))
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        let errorLine = try XCTUnwrap(body.firstIndex { $0.contains("error(") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(errorLine):"))
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("broken callback"))
        let native = HotkeyCommand.workspace(.next)
        XCTAssertEqual(fixture.press(native), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
    }

    func testProgramSpawnFailureStopsLaterCommandsAndReportsTheRunLine() async throws {
        let fixture = try Fixture(test: self)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = [
            "omniwm.command('Start program', function()",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "    omniwm.run({'\(missing.path)'})",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.origin)'))",
            "end)"
        ]
        fixture.apply(try await fixture.load(source))
        let named = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(named.function)), .executed)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        let failedLine = try XCTUnwrap(source.firstIndex { $0.contains("omniwm.run") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(failedLine):"))
    }

    func testSlowCallbackDropsItsCommandsAndLaterPressStillRuns() async throws {
        let fixture = try Fixture(test: self)
        let lines = [
            "local destination = omniwm.cmd('switch-workspace', '\(fixture.destination)')",
            "omniwm.keymap.set('Control+Option+I', function()",
            "    omniwm.dispatch(destination)",
            "    while true do end",
            "end)",
            "omniwm.keymap.set('Control+Option+J', function() omniwm.dispatch(destination) end)"
        ]
        fixture.apply(try await fixture.load(lines))
        let slow = try XCTUnwrap(fixture.script.acceptedBindings.first?.command)
        let fast = try XCTUnwrap(fixture.script.acceptedBindings.last?.command)
        let before = omni_config_vm_entry_count()
        let sequence = [slow, slow, fast]
        for command in sequence { XCTAssertEqual(fixture.press(command), .executed) }
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(omni_config_vm_entry_count() - before, UInt64(sequence.count))
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        let slowLine = try XCTUnwrap(lines.firstIndex { $0.contains("while true") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(slowLine):"))
    }

    func testRejectedSaveKeepsAQueuedPressAndSuccessfulReplacementRetiresIt() async throws {
        let fixture = try Fixture(test: self)
        let callback = try await fixture.load([
            "omniwm.keymap.set('Control+Option+I', function()",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "end)"
        ])
        let missing = ConfigScriptLoad(versions: [:], result: .success(nil))
        let invalid = ConfigScriptLoad(
            versions: [:], result: .failure(ConfigScriptError(line: 1, message: "invalid edit"))
        )
        fixture.apply(callback)
        let oldCommand = try fixture.command
        let before = omni_config_vm_entry_count()
        XCTAssertEqual(fixture.press(oldCommand), .executed)
        fixture.apply(invalid)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("invalid edit"))
        XCTAssertEqual(omni_config_vm_entry_count() - before, 1)

        let newLoad = try await fixture
            .load(["omniwm.keymap.set('Control+Option+I', function() error('new handler') end)"])
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertEqual(fixture.press(oldCommand), .executed)
        let waiting = try XCTUnwrap(queue.worker)
        let beforeReplacement = omni_config_vm_entry_count()
        fixture.apply(newLoad)
        XCTAssertEqual(fixture.press(oldCommand), .notFound)
        await waiting.value
        XCTAssertEqual(omni_config_vm_entry_count(), beforeReplacement)
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("new handler"))
        fixture.apply(missing)
        XCTAssertNil(fixture.script.callbackQueue)
        XCTAssertNil(fixture.script.diagnostic)
    }
}
