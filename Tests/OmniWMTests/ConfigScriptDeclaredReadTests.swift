// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptDeclaredReadTests: XCTestCase {
    func testAllCallbackKindsRecordTheirDeclaredReads() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let statements = [
            "local wm = omniwm",
            "local function fn() end",
            "wm.keymap.set('Control+Option+F', fn, { reads = { 'workspaceWindows', 'windows' } })",
            "wm.command('Workspace list', fn, { reads = { 'workspaces' } })",
            "wm.on('window.active', fn, { reads = { 'monitors' } })",
            "wm.timer({ afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS) }, fn, { reads = { 'windows' } })",
            "wm.command('No reads', fn, { reads = {} })",
            "wm.on('window.active', fn, { reads = { 'frames', 'workspaces', 'monitors' } })",
            "wm.on('window.active', fn, { reads = { 'windows', 'placement', 'frames', 'workspaceWindows' } })",
            "wm.on('window.active', fn, { reads = { 'columns', 'monitors', 'windows', 'focusTarget', 'frames', " +
                "'workspaces', 'placement', 'workspaceWindows' } })"
        ]
        let load = try await fixture.load(statements)
        let result = try XCTUnwrap(load.result.get())
        XCTAssertEqual(result.bindings.map(\.reads), [[.workspaceWindows, .windows]])
        XCTAssertEqual(result.namedCommands.map(\.reads), [[.workspaces], []])
        XCTAssertEqual(result.events.map(\.reads), [
            [.monitors],
            [.workspaces, .monitors, .monitorFrames],
            [.windows, .placement, .workspaceWindows, .windowFrames, .workspaceWindowFrames],
            [
                .workspaceWindows, .windows, .workspaces, .monitors, .placement, .focusTarget,
                .workspaceWindowFrames, .windowFrames, .monitorFrames, .workspaceWindowColumns, .windowColumns
            ]
        ])
        XCTAssertEqual(result.timers.map(\.reads), [[.windows]])
    }

    func testInvalidReadOptionsRejectTheDeclarationAtItsLine() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let statements = [
            "wm.keymap.set('F', fn, { reads = 'windows' })",
            "wm.keymap.set('F', wm.cmd('open-command-palette'), { reads = { 'windows' } })",
            "wm.command('Wrong name', fn, { reads = { 'window' } })",
            "wm.command('Sparse', fn, { reads = { [2] = 'windows' } })",
            "wm.on('window.active', fn, { reads = { windows = true } })",
            "wm.on('workspace.active', fn, { reads = { 'workspaces', 'workspaces' } })",
            "wm.timer({ afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS) }, fn, { reads = { false } })",
            "wm.timer({ afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS) }, fn, { reads = {} })",
            "wm.timer({ afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS) }, fn, {})",
            "wm.command('Frames alone', fn, { reads = { 'frames' } })",
            "wm.command('Frames without a framed list', fn, { reads = { 'workspaces', 'placement', 'frames' } })",
            "wm.command('Frames twice', fn, { reads = { 'monitors', 'frames', 'frames' } })",
            "wm.command('Columns alone', fn, { reads = { 'columns' } })",
            "wm.command('Columns without a window list', fn, { reads = { 'monitors', 'frames', 'columns' } })",
            "wm.command('Columns twice', fn, { reads = { 'windows', 'columns', 'columns' } })"
        ]
        for statement in statements {
            let lines = ["local wm = omniwm", "local function fn() end", statement]
            do {
                _ = try await fixture.load(lines)
                XCTFail(statement)
            } catch let error as ConfigScriptError {
                XCTAssertEqual(error.line, lines.count, statement)
                XCTAssertEqual(error.source, "init.luau")
            }
        }
    }

    func testSharedSnapshotExposesOnlyEachListenerReadSetAndFreezesEachLevel() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let statements = [
            "local function check(e, mine, other)",
            "    assert(e.name == 'observed' and table.isfrozen(e))",
            "    assert(e[other] == nil and e.workspaceWindows == nil and e.windows == nil)",
            "    assert(table.isfrozen(e[mine]) and table.isfrozen(e[mine][1]))",
            "    assert(e[mine][1].id and e[mine][1].name)",
            "    assert(table.isfrozen(e.truncated) and e.truncated[mine] == false and e.truncated[other] == nil)",
            "end",
            "omniwm.on('workspace.active', function(e) check(e, 'workspaces', 'monitors') end, { reads = { 'workspaces' } })",
            "omniwm.on('workspace.active', function(e) check(e, 'monitors', 'workspaces') end, { reads = { 'monitors' } })",
            "omniwm.on('workspace.active', function(e) assert(e.truncated == nil and e.workspaces == nil and e.monitors == nil) end)"
        ]
        let load = try await fixture.load(statements)
        let result = try XCTUnwrap(load.result.get())
        let generation = try XCTUnwrap(result.generation)
        let target = fixture.controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        let snapshot = fixture.controller.configScriptSnapshot(
            reads: [.workspaces, .monitors],
            target: target,
            pool: &pool
        )
        let event = ConfigScriptEventPayload(name: "observed")
        let first = try XCTUnwrap(result.events.first)
        do {
            _ = try await generation.invoke(function: first.function, event: event)
            XCTFail("A requested projection was missing")
        } catch {
            XCTAssertEqual(error.line, first.line)
            XCTAssertTrue(error.message.contains("snapshot"))
        }
        for listener in result.events {
            _ = try await generation.invoke(function: listener.function, event: event, snapshot: snapshot)
        }
    }
}
