// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptEventDeliveryTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    private func switchTo(_ name: String, in fixture: Fixture) throws {
        let manager = fixture.controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        let id = try XCTUnwrap(manager.workspaceId(named: name))
        XCTAssertTrue(manager.setActiveWorkspace(id, on: monitor.id))
    }

    private func runNamed(_ name: String, in fixture: Fixture) async throws {
        let command = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == name })
        XCTAssertEqual(fixture.script.enqueue(function: command.function, controller: fixture.controller), .executed)
        let worker = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await worker.value
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testWorkspaceChangesDuringACommandBatchDeliverOnlyTheNewestState() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let burst = "Switch three times"
        let check = "Check last workspace"
        let manager = fixture.controller.workspaceManager
        let finalID = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let targets = [fixture.destination, fixture.origin, fixture.destination]
        let body = [
            "local wm = omniwm",
            "local count = 0",
            "wm.on('workspace.active', function(e)",
            "    assert(e.name == '\(fixture.destination)' and e.id == '\(finalID.uuidString)')",
            "    count += 1",
            "end)",
            "wm.command('\(burst)', function()"
        ] + targets.map { "wm.dispatch(wm.cmd('switch-workspace', '\($0)'))" } + [
            "end)",
            "wm.command('\(check)', function() assert(count == 1) end)"
        ]
        fixture.apply(try await fixture.load(body))
        let before = omni_config_vm_entry_count()
        try await runNamed(burst, in: fixture)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, finalID)
        assertConfigVMEntries(2, since: before)
        try await runNamed(check, in: fixture)
    }

    func testWorkspaceListenerCannotRetriggerItselfAndOtherListenersSeeTheSwitch() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let check = "Check listeners"
        let body = [
            "local wm = omniwm",
            "local count = 0",
            "local visited = {}",
            "wm.on('workspace.active', function(e)",
            "    count += 1",
            "    assert(count == 1, 'workspace feedback')",
            "    wm.dispatch(wm.cmd('switch-workspace', '\(fixture.origin)'))",
            "end)",
            "wm.on('workspace.active', function(e) table.insert(visited, e.name) end)",
            "wm.command('\(check)', function()",
            "    assert(table.concat(visited, ',') == '\(fixture.destination),\(fixture.origin)' and count == 1)",
            "end)"
        ]
        fixture.apply(try await fixture.load(body))
        let before = omni_config_vm_entry_count()
        try switchTo(fixture.destination, in: fixture)
        let worker = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await worker.value
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        XCTAssertNil(fixture.script.diagnostic)
        assertConfigVMEntries(3, since: before)
        try await runNamed(check, in: fixture)
    }

    func testThreeSwitchesDuringDeliveryScheduleOneFollowupWithTheNewestWorkspace() async throws {
        let fixture = try Fixture(test: self)
        defer {
            fixture.script.onDiagnosticChanged = nil
            fixture.controller.stopConfigScript()
        }
        let manager = fixture.controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        let origin = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let destination = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let first = "first workspace delivery"
        fixture.apply(try await fixture.load([
            "local calls = 0",
            "omniwm.on('workspace.active', function(e)",
            "    calls += 1",
            "    if calls == 1 then error('\(first)') end",
            "    assert(calls == 2 and e.name == '\(fixture.origin)', 'wrong follow-up')",
            "end)"
        ]))
        var diagnostics: [String] = []
        fixture.script.onDiagnosticChanged = { diagnostic in
            guard let diagnostic else { return }
            diagnostics.append(diagnostic)
            if diagnostic.contains(first), diagnostics.count == 1 {
                for target in [origin, destination, origin] {
                    XCTAssertTrue(manager.setActiveWorkspace(target, on: monitor.id))
                }
            }
        }
        let before = omni_config_vm_entry_count()
        try switchTo(fixture.destination, in: fixture)
        let worker = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await worker.value
        XCTAssertEqual(diagnostics.count, 1, "\(diagnostics)")
        XCTAssertTrue(try XCTUnwrap(diagnostics.first).contains(first))
        assertConfigVMEntries(2, since: before)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, origin)
    }

    func testOnlySuccessfulReloadPublishesAndRetirementDropsPendingEvents() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let first = try await fixture.load([
            "omniwm.on('config.reloaded', function(e) assert(next(e) == nil) end)",
            "omniwm.on('workspace.active', function(e) error('old ' .. e.name) end)"
        ])
        let next = try await fixture.load(["omniwm.on('config.reloaded', function() end)"])
        let before = omni_config_vm_entry_count()
        fixture.apply(first)
        let initial = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await initial.value
        assertConfigVMEntries(1, since: before)
        XCTAssertNotNil(fixture.script.eventObservers)
        fixture.apply(ConfigScriptLoad(
            versions: [:],
            result: .failure(ConfigScriptError(line: 1, message: "bad save"))
        ))
        XCTAssertNotNil(fixture.script.diagnostic)
        XCTAssertNil(fixture.script.callbackQueue?.worker)
        try switchTo(fixture.destination, in: fixture)
        let kept = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await kept.value
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("old " + fixture.destination))
        try switchTo(fixture.origin, in: fixture)
        let retired = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        fixture.apply(next)
        let replacement = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await retired.value
        await replacement.value
        assertConfigVMEntries(3, since: before)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertNil(fixture.script.eventObservers)
        try switchTo(fixture.destination, in: fixture)
        XCTAssertNil(fixture.script.callbackQueue?.worker)
        fixture.apply(ConfigScriptLoad(versions: [:], result: .success(nil)))
        XCTAssertNil(fixture.script.callbackQueue)
    }

    func testEventCommandsUseOriginalTargetAndDiscardOnLuauError() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let body = [
            "local wm = omniwm",
            "wm.on('keybinds.submap', function()",
            "    wm.dispatch(wm.cmd('switch-workspace', '\(fixture.destination)'))",
            "end)",
            "wm.on('keybinds.submap', function(e)",
            "    wm.dispatch(wm.cmd('set-container-primary-span', '+12%'))",
            "    wm.dispatch(wm.cmd('switch-workspace', '\(fixture.origin)'))",
            "end)",
            "wm.on('workspace.active', function(e)",
            "    wm.dispatch(wm.cmd('switch-workspace', '\(fixture.origin)'))",
            "    error('drop staged switch')",
            "end)"
        ]
        fixture.apply(try await fixture.load(body))
        var errors: [String] = []
        fixture.script.onDiagnosticChanged = { if let diagnostic = $0 { errors.append(diagnostic) } }
        fixture.controller.scriptModeObserver?.modeChanged(.prefix)
        let worker = try XCTUnwrap(fixture.script.callbackQueue?.worker)
        await worker.value
        XCTAssertTrue(errors.contains { $0.contains("staleWindowId") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("drop staged switch") }, "\(errors)")
        XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.destination)
    }
}
