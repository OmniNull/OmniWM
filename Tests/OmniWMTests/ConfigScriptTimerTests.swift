// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptTimerTests: XCTestCase {
    private var interval: Double {
        Double(OMNI_CONFIG_TIMER_MINIMUM_SECONDS)
    }

    private func controller(
        for fixture: ConfigScriptCallbackQueueTests.Fixture, sleeper: ManualSleeper
    ) -> ConfigScriptController {
        let native = fixture.controller
        let script = ConfigScriptController(
            fileURL: native.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau"),
            settings: native.settings, wmController: native, timerSleep: { try await sleeper.sleep(for: $0) }
        ) { _ in }
        native.configScript = script
        return script
    }

    func testStrictTimerDeclarationsAndFrozenHandles() async throws {
        let loader = ConfigScriptLoader()
        let function = "function() end"
        let active = "wm.timer({ afterSeconds = \(interval) }, \(function))"
        let limit = Int(OMNI_CONFIG_TIMER_LIMIT)
        let invalid = [
            "wm.timer({}, \(function))",
            "wm.timer({afterSeconds = 1, everySeconds = 1}, \(function))",
            "wm.timer({other = 1}, \(function))",
            "wm.timer({everySeconds = '1'}, \(function))",
            "wm.timer({everySeconds = \(interval / 2)}, \(function))",
            "wm.timer({everySeconds = math.huge}, \(function))",
            "wm.timer({afterSeconds = 0 / 0}, \(function))",
            "wm.timer({afterSeconds = \(interval)}, true)",
            "for i = 1, \(limit + 1) do \(active) end"
        ]
        for statement in invalid {
            let lines = ["local wm = omniwm", statement]
            do {
                _ = try await loader.evaluate(Data(lines.joined(separator: "\n").utf8), hyperMask: 0)
                XCTFail(statement)
            } catch let error as ConfigScriptError {
                XCTAssertEqual(error.line, lines.count, statement)
            }
        }
        let valid = """
        local wm = omniwm
        assert(os.date("!%H:%M:%S", 0) == "00:00:00" and os.execute == nil and os.getenv == nil)
        for i = 1, \(limit) do
            local handle = \(active)
            assert(not pcall(function() handle.cancel = nil end))
            handle.cancel()
            handle.cancel()
        end
        """
        let result = try await loader.evaluate(Data(valid.utf8), hyperMask: 0)
        XCTAssertTrue(result.timers.isEmpty)
        XCTAssertNil(result.generation)
    }

    func testOneShotWithNoCommandsMakesNoMainDelivery() async throws {
        let loader = ConfigScriptLoader()
        let source = "omniwm.timer({afterSeconds = \(interval)}, function() end)"
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(evaluation.generation)
        let sleeper = ManualSleeper()
        let before = omni_config_vm_entry_count()
        let worker = Task {
            await generation.runTimers(evaluation.timers, sleep: { try await sleeper.sleep(for: $0) }, capture: { _ in
                XCTFail("An undeclared read reached the main-actor snapshot builder")
                return nil
            }) { _, _ in
                XCTFail("An empty timer reached the main-actor receiver")
            }
        }
        await sleeper.waitForPendingSleeps(1)
        sleeper.resumeNext()
        await worker.value
        assertConfigVMEntries(1, since: before)
    }

    func testOneShotUsesNativeDispatchAndStopsAtFirstFailure() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let sleeper = ManualSleeper()
        let script = controller(for: fixture, sleeper: sleeper)
        let missing = WorkspaceIDPolicy.lowestUnusedRawID(in: [fixture.origin, fixture.destination])
        let lines = [
            "omniwm.timer({afterSeconds = \(interval)}, function(...)",
            "    assert(select('#', ...) == 0)",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.destination)'))",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(missing)'))",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.origin)'))",
            "end)"
        ]
        let liveBeforeLoad = omni_config_live_vm_count()
        let load = try await fixture.load(lines)
        XCTAssertTrue(script.apply(load, hyperMask: fixture.controller.settings.hyperKeyModifiers.carbonMask))
        let worker = try XCTUnwrap(script.timerWorker)
        let before = omni_config_vm_entry_count()
        await sleeper.waitForPendingSleeps(1)
        XCTAssertEqual(omni_config_live_vm_count(), liveBeforeLoad + 1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        sleeper.resumeNext()
        await worker.value
        XCTAssertEqual(omni_config_live_vm_count(), liveBeforeLoad)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        assertConfigVMEntries(1, since: before)
        XCTAssertEqual(sleeper.requestedDurations, [.seconds(interval)])
        XCTAssertEqual(sleeper.pendingCount, 0)
        let line = try XCTUnwrap(lines.firstIndex { $0.contains("'\(missing)'") }) + 1
        XCTAssertTrue(try XCTUnwrap(script.diagnostic).contains("init.luau:\(line):"))
    }

    func testRepeatingWaitStartsAfterDeliveryAndCancelPreservesFinalCommands() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let sleeper = ManualSleeper()
        let expected = ["first", "last"]
        let messages = expected.map(\.debugDescription).joined(separator: ", ")
        let load = try await fixture.load([
            "local messages = {\(messages)}", "local i = 0", "local handle",
            "handle = omniwm.timer({everySeconds = \(interval)}, function()",
            "    i += 1", "    if i == #messages then handle.cancel() end",
            "    omniwm.notify(messages[i])", "end)"
        ])
        let evaluation = try XCTUnwrap(load.result.get())
        let generation = try XCTUnwrap(evaluation.generation)
        let held = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var delivered: [ConfigScriptDispatch.Operation] = []
        let worker = Task {
            await generation.runTimers(evaluation.timers, sleep: { try await sleeper.sleep(for: $0) }) { result, _ in
                switch result {
                case let .success(invocation):
                    delivered.append(contentsOf: invocation.commands.map(\.operation))
                case let .failure(error):
                    XCTFail(error.localizedDescription)
                }
                if delivered.count == 1 {
                    held.continuation.finish()
                    for await _ in release.stream {}
                }
            }
        }
        await sleeper.waitForPendingSleeps(1)
        sleeper.resumeNext()
        for await _ in held.stream {}
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(sleeper.requestedDurations, [.seconds(interval)])
        release.continuation.finish()
        await sleeper.waitForPendingSleeps(1)
        sleeper.resumeNext()
        await worker.value
        XCTAssertEqual(delivered, expected.map { .native(.showNotice($0)) })
        XCTAssertEqual(sleeper.requestedDurations, expected.map { _ in .seconds(interval) })
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testFailedReloadKeepsTimersAndSuccessRemovalAndStopCancelThem() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let sleeper = ManualSleeper()
        let script = controller(for: fixture, sleeper: sleeper)
        let mask = fixture.controller.settings.hyperKeyModifiers.carbonMask
        let statements = [
            "omniwm.timer({everySeconds = \(interval)}, function()",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.destination)'))",
            "end)"
        ]
        let invalid = ConfigScriptLoad(versions: [:], result: .failure(.init(line: nil, message: "rejected edit")))
        let valid = try await fixture.load(statements)
        XCTAssertTrue(script.apply(valid, hyperMask: mask))
        let first = try XCTUnwrap(script.timerWorker)
        await sleeper.waitForPendingSleeps(1)
        XCTAssertTrue(script.apply(invalid, hyperMask: mask))
        sleeper.resumeNext()
        await sleeper.waitForPendingSleeps(1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        let replacement = try await fixture.load(["omniwm.command('Replacement', function() end)"])
        XCTAssertTrue(script.apply(replacement, hyperMask: mask))
        await first.value
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertNil(script.timerWorker)

        for removeFile in [true, false] {
            let next = try await fixture.load(statements)
            XCTAssertTrue(script.apply(next, hyperMask: mask))
            let worker = try XCTUnwrap(script.timerWorker)
            await sleeper.waitForPendingSleeps(1)
            let before = omni_config_vm_entry_count()
            if removeFile {
                XCTAssertTrue(script.apply(.init(versions: [:], result: .success(nil)), hyperMask: mask))
            } else {
                script.stop()
            }
            await worker.value
            XCTAssertEqual(sleeper.pendingCount, 0)
            XCTAssertEqual(omni_config_vm_entry_count(), before)
        }
    }

    func testNamedCallbackCanCancelSleepingTimerAndRejectedBatchHasNoEffects() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let sleeper = ManualSleeper()
        let script = controller(for: fixture, sleeper: sleeper)
        let statements = [
            "local handle = omniwm.timer({everySeconds = \(interval)}, function()",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.destination)'))",
            "    error('timer failed')", "end)",
            "omniwm.command('Cancel timer', function() handle.cancel() end)"
        ]
        let load = try await fixture.load(statements)
        XCTAssertTrue(script.apply(load, hyperMask: fixture.controller.settings.hyperKeyModifiers.carbonMask))
        let worker = try XCTUnwrap(script.timerWorker)
        await sleeper.waitForPendingSleeps(1)
        sleeper.resumeNext()
        await sleeper.waitForPendingSleeps(1)
        XCTAssertTrue(try XCTUnwrap(script.diagnostic).contains("timer failed"))
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        let id = try XCTUnwrap(script.acceptedCommands.first).function
        XCTAssertEqual(fixture.controller.enqueueConfigFunction(id), .executed)
        await script.callbackQueue?.waitUntilParked()
        await worker.value
        XCTAssertEqual(sleeper.pendingCount, 0)
        let before = omni_config_vm_entry_count()
        XCTAssertEqual(fixture.controller.enqueueConfigFunction(id), .executed)
        await script.callbackQueue?.waitUntilParked()
        assertConfigVMEntries(1, since: before)
    }
}
