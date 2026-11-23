// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWindowDispatchTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    func testNativeWindowManifestStagesTypedRequestsWithOpaqueTargetsAtTheirSourceLines() async throws {
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let session = UUID().uuidString
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: session)
        let arguments = [
            "opaque-id": id, "workspace": "Work", "number": String(IPCScratchpadSlots.range.lowerBound),
            "direction": IPCDirection.right.rawValue, "cycle-direction": IPCCycleDirection.forward.rawValue,
            "size-change": "+12%"
        ]
        var source = ["omniwm.command('Window requests', function()"]
        var expected: [IPCWindowRequest] = []
        for descriptor in IPCAutomationManifest.windowActionDescriptors {
            let words = try [descriptor.name.rawValue] + descriptor.arguments.map { try XCTUnwrap(arguments[$0]) }
            expected.append(try XCTUnwrap(IPCWindowRequest(actionWords: words)))
            source.append("    omniwm.dispatch('window', " + words.map { "'\($0)'" }.joined(separator: ", ") + ")")
        }
        source.append("end)")
        let result = try await ConfigScriptLoader().evaluate(Data(source.joined(separator: "\n").utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let callback = try XCTUnwrap(result.namedCommands.first)
        let staged = try await vm.invoke(function: callback.function, context: ConfigScriptContext()).commands
        XCTAssertEqual(staged.count, expected.count)
        let lines = source.indices.filter { source[$0].contains("omniwm.dispatch") }.map { $0 + 1 }
        XCTAssertEqual(staged.map(\.line), lines)
        for (dispatch, native) in zip(staged, expected) {
            guard case let .window(window) = dispatch.operation else { return XCTFail("Expected a window request") }
            XCTAssertEqual(window.request, native)
            XCTAssertEqual(window.token, token)
            XCTAssertEqual(window.address.sessionToken, session)
            XCTAssertEqual(dispatch.source, "init.luau")
        }
    }

    func testInvalidWindowSelectorOrArgumentsPoisonEvenACaughtBatch() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: fixture.controller.automationSessionToken)
        for invalid in [
            "'window', 'focus', 'focused'", "'window', 'focus'", "'window', 'focus', nil",
            "'window', 'not-a-request', '\(id)'", "'window', 'move-column', '\(id)', 'sideways'",
            "'window', 'close', '\(id)', 'unexpected'", "'not-a-namespace', 'focus', '\(id)'"
        ] {
            let source = [
                "omniwm.keymap.set('I', function()",
                "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
                "    pcall(function() omniwm.dispatch(\(invalid)) end)",
                "end)"
            ]
            fixture.apply(try await fixture.load(source))
            XCTAssertEqual(fixture.press(try fixture.command), .executed)
            await fixture.script.callbackQueue?.worker?.value
            let line = try XCTUnwrap(source.firstIndex { $0.contains(invalid) }) + 1
            XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(line):"), invalid)
            XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        }
    }

    func testExplicitTargetSurvivesUnrelatedFocusAndClosedTargetStopsTheBatch() async throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        defer { wm.stopConfigScript() }
        let manager = wm.workspaceManager
        let source = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let destination = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let moving = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let other = WindowToken(pid: moving.pid, windowId: moving.windowId + 1)
        for token in [moving, other] {
            _ = WindowAdmissionTestSupport.track(token, in: source, controller: wm)
            XCTAssertTrue(manager.setWindowMode(.floating, for: token))
        }
        let id = IPCWindowOpaqueID.encode(token: moving, sessionToken: wm.automationSessionToken)
        let move = [
            "omniwm.keymap.set('I', function()",
            "    omniwm.dispatch('window', 'move-to-workspace', '\(id)', '\(fixture.destination)')",
            "end)"
        ]
        fixture.apply(try await fixture.load(move))
        _ = manager.setManagedFocus(moving, in: source)
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        _ = manager.setManagedFocus(other, in: source)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(manager.workspace(for: moving), destination)
        XCTAssertEqual(manager.workspace(for: other), source)
        XCTAssertEqual(manager.nativeManagedFocusToken, other)

        let focus = [
            "omniwm.keymap.set('I', function()",
            "    omniwm.dispatch('window', 'focus', '\(id)')",
            "    omniwm.dispatch(omniwm.cmd('switch-workspace', '\(fixture.destination)'))",
            "end)"
        ]
        fixture.apply(try await fixture.load(focus))
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        XCTAssertNotNil(manager.removeWindow(pid: moving.pid, windowId: moving.windowId))
        await fixture.script.callbackQueue?.worker?.value
        let line = try XCTUnwrap(focus.firstIndex { $0.contains("'focus'") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(line): window focus: notFound"))
        XCTAssertEqual(manager.nativeManagedFocusToken, other)
        XCTAssertEqual(wm.activeWorkspace()?.id, source)
    }

    func testSessionReplacementAndChangedSummonAnchorAreRejectedAtApply() throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        defer { wm.stopConfigScript() }
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let manager = wm.workspaceManager
        let workspace = try XCTUnwrap(wm.activeWorkspace()?.id)
        for token in [first, second] { _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: wm) }
        _ = manager.setManagedFocus(first, in: workspace)
        let id = IPCWindowOpaqueID.encode(token: second, sessionToken: wm.automationSessionToken)
        let target = wm.configScriptTarget()
        let summon = try ConfigScriptWindowRequest(words: ["summon-right", id])
        _ = manager.setManagedFocus(second, in: workspace)
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(summon), target: target), .staleWindowId)
        let request = try ConfigScriptWindowRequest(words: ["focus", id])
        _ = IPCServer(controller: wm)
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(request), target: target), .staleWindowId)
        XCTAssertEqual(
            wm.performConfigScriptDispatch(.window(request), target: wm.configScriptTarget()),
            .staleWindowId
        )
        XCTAssertEqual(manager.nativeManagedFocusToken, second)
    }
}
