// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptReadTriggerTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
        func testCoalescedEventsCaptureReadsOnlyAtDequeue() async throws {
            let fixture = try Fixture(test: self)
            defer { fixture.controller.stopConfigScript() }
            let kinds: [ConfigScriptEventKind] = [.workspaceActive, .windowTitle]
            fixture.apply(try await fixture.load(kinds.map {
                "omniwm.on('\($0.rawValue)', function(e) assert(e.monitors) end, { reads = {'monitors'} })"
            }))
            let observer = try XCTUnwrap(fixture.script.eventObservers)
            for kind in kinds {
                let before = ConfigScriptSnapshot.captures
                for value in ["first", "replacement", "last"] {
                    if kind == .workspaceActive {
                        ConfigScriptEventObservers.workspaceChanged(nil, name: value, controller: fixture.controller)
                    } else {
                        let session = fixture.controller.automationSession
                        observer.publishTitle(.init(
                            token: WindowToken(pid: getpid(), windowId: Int(getpid())),
                            session: session.identity,
                            epoch: session.epoch,
                            title: value,
                            bundle: nil
                        ), controller: fixture.controller)
                    }
                }
                XCTAssertEqual(ConfigScriptSnapshot.captures, before)
                let queue = try XCTUnwrap(fixture.script.callbackQueue)
                XCTAssertTrue(queue.hasPendingWork)
                await queue.waitUntilParked()
                XCTAssertEqual(ConfigScriptSnapshot.captures - before, 1)
                XCTAssertNil(fixture.script.diagnostic)
            }
        }
    #endif

    func testKeyReadsAtPressAndPaletteReadsAtInvocation() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let manager = fixture.controller.workspaceManager
        let workspace = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let opaque = IPCWindowOpaqueID.encode(token: token, sessionToken: fixture.controller.automationSessionToken)
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: fixture.controller)
        let expectedMonitors = manager.monitors.count
        let expectedWorkspaces = manager.workspaces.count
        let load = try await fixture.load([
            "local held",
            "omniwm.keymap.set('Control+Option+I', function(ctx)",
            "    held = ctx.workspaceWindows",
            "    assert(table.isfrozen(held) and table.isfrozen(held[1]))",
            "    assert(#held == 1 and held[1].id == '\(opaque)' and not held[1].floating)",
            "    assert(ctx.workspace == '\(fixture.origin)' and ctx.truncated.workspaceWindows == false)",
            "    assert(ctx.windows == nil and ctx.workspaces == nil and ctx.monitors == nil)",
            "end, {reads = {'workspaceWindows'}})",
            "omniwm.command('Inspect', function(ctx)",
            "    assert(#held == 1 and not held[1].floating)",
            "    assert(#ctx.windows == 1 and ctx.windows[1].id == '\(opaque)' and ctx.windows[1].floating)",
            "    assert(#ctx.monitors == \(expectedMonitors) and #ctx.workspaces == \(expectedWorkspaces))",
            "    assert(ctx.workspaceWindows == nil and ctx.truncated.workspaceWindows == nil)",
            "end, {reads = {'windows', 'workspaces', 'monitors'}})"
        ])
        fixture.apply(load)
        let before = omni_config_vm_entry_count()
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        XCTAssertTrue(manager.setWindowMode(.floating, for: token))
        await fixture.script.callbackQueue?.waitUntilParked()
        let name = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(name.function)), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        assertConfigVMEntries(2, since: before)
    }

    func testListenersSeeOnlyTheirOwnListsFromTheSameTrigger() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let workspace = try XCTUnwrap(fixture.controller.activeWorkspace())
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: fixture.controller)
        let load = try await fixture.load([
            "local order = 0",
            "omniwm.on('config.reloaded', function(e)",
            "    assert(e.workspaces and not e.workspaceWindows and not e.truncated.workspaceWindows)",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "    order += 1",
            "end, {reads = {'workspaces'}})",
            "omniwm.on('config.reloaded', function(e)",
            "    assert(order == 1 and #e.workspaceWindows == 1)",
            "    assert(e.workspaceWindows[1].workspace == '\(fixture.origin)' and e.workspaces == nil)",
            "    order += 1",
            "end, {reads = {'workspaceWindows'}})",
            "omniwm.on('config.reloaded', function(e)",
            "    assert(order == 2 and not e.truncated and not e.workspaceWindows and not e.workspaces)",
            "end)"
        ])
        let before = omni_config_vm_entry_count()
        fixture.apply(load)
        await fixture.script.callbackQueue?.waitUntilParked()
        assertConfigVMEntries(UInt64(try XCTUnwrap(load.result.get()).events.count), since: before)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testTimerReadsAtFiringAndReceivesFixedContext() async throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        let sleeper = ManualSleeper()
        let script = ConfigScriptController(
            fileURL: wm.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau"),
            settings: wm.settings, wmController: wm, timerSleep: { try await sleeper.sleep(for: $0) },
            didChangeBindings: { _ in }
        )
        wm.configScript = script
        defer { wm.stopConfigScript() }
        let load = try await fixture.load([
            "omniwm.timer({afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS)}, function(ctx)",
            "    assert(ctx.workspace == '\(fixture.destination)' and ctx.layout == 'niri')",
            "    assert(#ctx.workspaceWindows == 1 and ctx.workspaceWindows[1].workspace == ctx.workspace)",
            "    assert(ctx.truncated.workspaceWindows == false and not ctx.windows and not ctx.monitors)",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.origin)'))",
            "end, {reads = {'workspaceWindows'}})"
        ])
        XCTAssertTrue(script.apply(load, hyperMask: wm.settings.hyperKeyModifiers.carbonMask))
        let job = try XCTUnwrap(script.timerWorker)
        await sleeper.waitForPendingSleeps(1)
        let monitor = try XCTUnwrap(wm.workspaceManager.monitors.first)
        let destination = try XCTUnwrap(wm.workspaceManager.workspaceId(named: fixture.destination))
        XCTAssertTrue(wm.workspaceManager.setActiveWorkspace(destination, on: monitor.id))
        _ = WindowAdmissionTestSupport.track(
            WindowToken(pid: getpid(), windowId: Int(getpid())), in: destination, controller: wm
        )
        sleeper.resumeNext()
        await job.value
        XCTAssertEqual(wm.activeWorkspace()?.name, fixture.origin)
        XCTAssertNil(script.diagnostic)
    }
}
