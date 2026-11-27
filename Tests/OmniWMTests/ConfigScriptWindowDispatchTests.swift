// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptWindowDispatchTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    func testNativeWindowManifestStagesTheCLIActionsWithLuauTargetsAtTheirSourceLines() async throws {
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let session = ConfigScriptSession.random()
        let id = ConfigScriptWindowID.string(token, session: session)
        let arguments = [
            "opaque-id": id, "workspace": "Work", "number": String(IPCScratchpadSlots.range.lowerBound),
            "direction": IPCDirection.right.rawValue, "cycle-direction": IPCCycleDirection.forward.rawValue,
            "size-change": "+12%"
        ]
        var source = ["omniwm.command('Window requests', function()"]
        var expected: [(IPCWindowActionName, WindowAction)] = []
        for descriptor in IPCAutomationManifest.windowActionDescriptors {
            let words = try [descriptor.name.rawValue] + descriptor.arguments.map { try XCTUnwrap(arguments[$0]) }
            let cli = try XCTUnwrap(IPCWindowRequest(actionWords: words))
            expected.append((descriptor.name, try XCTUnwrap(WindowAction(cli))))
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
        for (dispatch, (name, action)) in zip(staged, expected) {
            guard case let .window(window) = dispatch.operation else { return XCTFail("Expected a window request") }
            XCTAssertEqual(window.name, .shared(name))
            XCTAssertEqual(window.action, action)
            XCTAssertEqual(window.token, token)
            XCTAssertEqual(window.session, session)
            XCTAssertEqual(dispatch.source, "init.luau")
        }
    }

    func testInvalidWindowSelectorOrArgumentsPoisonEvenACaughtBatch() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let id = ConfigScriptWindowID.string(token, session: fixture.controller.scriptSession.identity)
        let pastScratchpads = IPCScratchpadSlots.range.upperBound + 1
        let pastSafeInteger = OMNI_CONFIG_MAX_SAFE_INTEGER + 1
        for invalid in [
            "'window', 'focus', 'focused'", "'window', 'focus'", "'window', 'focus', nil",
            "'window', 'not-a-request', '\(id)'", "'window', 'move-column', '\(id)', 'sideways'",
            "'window', 'close', '\(id)', 'unexpected'", "'not-a-namespace', 'focus', '\(id)'",
            "'window', 'move-to-workspace', 1, 2", "'window', 'move-to-workspace', '\(id)', 1 / 2",
            "'window', 'move-column-to-index', '\(id)', 0", "'window', 'place-in-own-column', '\(id)', math.huge",
            "'window', 'assign-to-scratchpad', '\(id)', \(pastScratchpads)",
            "'window', 'move-to-workspace', '\(id)', \(pastSafeInteger)",
            "'window', 'move-column', '\(id)', 1", "'window', 'set-window-primary-span', '\(id)', 1",
            "'window', 'focus', '\(IPCWindowOpaqueID.encode(token: token, sessionToken: UUID().uuidString))'"
        ] {
            let source = [
                "omniwm.keymap.set('I', function()",
                "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.destination)'))",
                "    pcall(function() omniwm.dispatch(\(invalid)) end)",
                "end)"
            ]
            fixture.apply(try await fixture.load(source))
            XCTAssertEqual(fixture.press(try fixture.command), .executed)
            await fixture.script.callbackQueue?.waitUntilParked()
            let line = try XCTUnwrap(source.firstIndex { $0.contains(invalid) }) + 1
            XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(line):"), invalid)
            XCTAssertEqual(fixture.controller.activeWorkspace()?.name, fixture.origin)
        }
    }

    func testWindowSelectorsAcceptNumbersAndKeepWorkspaceNamesDistinct() async throws {
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let id = ConfigScriptWindowID.string(token, session: ConfigScriptSession.random())
        let index = IPCScratchpadSlots.range.upperBound
        let cases: [(String, String, WindowAction)] = [
            ("move-to-workspace", "\(index)", .moveToWorkspace(.rawID(String(index)))),
            ("move-to-workspace", "'0\(index)'", .moveToWorkspace(.displayName("0\(index)"))),
            ("move-column-to-index", "\(index)", .moveColumn(.index(index))),
            ("place-in-own-column", "\(index)", .placeInOwnColumn(index)),
            ("assign-to-scratchpad", "\(index)", .assignToScratchpad(try XCTUnwrap(ScratchpadIndex(index))))
        ]
        let calls = cases
            .map { action, argument, _ in "  omniwm.dispatch('window', '\(action)', '\(id)', \(argument))" }
        let prefix = ["omniwm.command('Window selectors', function()"]
        let source = (prefix + calls + ["end)"]).joined(separator: "\n")
        let evaluation = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(evaluation.generation)
        let command = try XCTUnwrap(evaluation.namedCommands.first)
        let staged = try await vm.invoke(function: command.function, context: ConfigScriptContext()).commands
        XCTAssertEqual(staged.map(\.line), calls.indices.map { prefix.count + $0 + 1 })
        let actions = staged.map { dispatch -> WindowAction? in
            if case let .window(window) = dispatch.operation { return window.action }
            return nil
        }
        XCTAssertEqual(actions, cases.map { Optional($0.2) })
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
        let id = ConfigScriptWindowID.string(moving, session: wm.scriptSession.identity)
        let move = [
            "omniwm.keymap.set('I', function()",
            "    omniwm.dispatch('window', 'move-to-workspace', '\(id)', '\(fixture.destination)')",
            "end)"
        ]
        fixture.apply(try await fixture.load(move))
        _ = manager.setManagedFocus(moving, in: source)
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        _ = manager.setManagedFocus(other, in: source)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(manager.workspace(for: moving), destination)
        XCTAssertEqual(manager.workspace(for: other), source)
        XCTAssertEqual(manager.nativeManagedFocusToken, other)

        let focus = [
            "omniwm.keymap.set('I', function()",
            "    omniwm.dispatch('window', 'focus', '\(id)')",
            "    omniwm.dispatch(omniwm.cmd.switchWorkspace('\(fixture.destination)'))",
            "end)"
        ]
        fixture.apply(try await fixture.load(focus))
        XCTAssertEqual(fixture.press(try fixture.command), .executed)
        XCTAssertNotNil(manager.removeWindow(pid: moving.pid, windowId: moving.windowId))
        await fixture.script.callbackQueue?.waitUntilParked()
        let line = try XCTUnwrap(focus.firstIndex { $0.contains("'focus'") }) + 1
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:\(line): window focus: notFound"))
        XCTAssertEqual(manager.nativeManagedFocusToken, other)
        XCTAssertEqual(wm.activeWorkspace()?.id, source)
    }

    func testChangedSummonAnchorIsRejectedAtApply() throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        defer { wm.stopConfigScript() }
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let manager = wm.workspaceManager
        let workspace = try XCTUnwrap(wm.activeWorkspace()?.id)
        for token in [first, second] { _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: wm) }
        _ = manager.setManagedFocus(first, in: workspace)
        let id = ConfigScriptWindowID.string(second, session: wm.scriptSession.identity)
        let target = wm.configScriptTarget()
        let summon = try ConfigScriptWindowRequest(testWords: ["summon-right", id])
        _ = manager.setManagedFocus(second, in: workspace)
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(summon), target: target), .staleWindowId)
        XCTAssertEqual(manager.nativeManagedFocusToken, second)
    }

    func testOnlyThisSessionsIDForTheSameProcessMovesAWindowAndIPCStartKeepsIt() throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        defer { wm.stopConfigScript() }
        let manager = wm.workspaceManager
        let source = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let destination = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let window = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(window, in: source, controller: wm)
        XCTAssertTrue(manager.setWindowMode(.floating, for: window))
        let session = wm.scriptSession.identity
        let otherProcess = WindowToken(pid: window.pid + 1, windowId: window.windowId)
        let refused: [(String, ExternalCommandResult)] = [
            (ConfigScriptWindowID.string(window, session: ConfigScriptSession(id: session.id &+ 1)), .staleWindowId),
            (ConfigScriptWindowID.string(otherProcess, session: session), .notFound)
        ]
        for (id, result) in refused {
            let move = try ConfigScriptWindowRequest(testWords: ["move-to-workspace", id, fixture.destination])
            XCTAssertEqual(wm.performConfigScriptDispatch(.window(move), target: wm.configScriptTarget()), result)
            XCTAssertEqual(manager.workspace(for: window), source)
        }
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let first = IPCServer(controller: wm, socketPath: socket)
        try first.start()
        first.stop()
        let restarted = IPCServer(controller: wm, socketPath: socket)
        try restarted.start()
        defer { restarted.stop() }
        XCTAssertEqual(wm.scriptSession.identity, session)
        let id = ConfigScriptWindowID.string(window, session: session)
        let move = try ConfigScriptWindowRequest(testWords: ["move-to-workspace", id, fixture.destination])
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(move), target: wm.configScriptTarget()), .executed)
        XCTAssertEqual(manager.workspace(for: window), destination)
    }

    func testControllerRefusalComesBeforeTheSuppliedIDSession() throws {
        let fixture = try Fixture(test: self)
        let wm = fixture.controller
        defer { wm.stopConfigScript() }
        let manager = wm.workspaceManager
        let source = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let window = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(window, in: source, controller: wm)
        let session = wm.scriptSession.identity
        let other = ConfigScriptWindowID.string(window, session: ConfigScriptSession(id: session.id &+ 1))
        let move = try ConfigScriptWindowRequest(testWords: ["move-to-workspace", other, fixture.destination])
        wm.isEnabled = false
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(move), target: wm.configScriptTarget()), .ignoredDisabled)
        wm.isEnabled = true
        XCTAssertEqual(wm.performConfigScriptDispatch(.window(move), target: wm.configScriptTarget()), .staleWindowId)
        XCTAssertEqual(manager.workspace(for: window), source)
    }
}

extension ConfigScriptWindowRequest {
    init(testWords words: [String]) throws {
        self = try withConfigSpans(words.map { Array($0.utf8) }) { try ConfigScriptWindowRequest(words: $0) }
    }
}

func withConfigSpans<Result>(
    _ words: [[UInt8]],
    _ body: (UnsafeBufferPointer<omni_config_span>) throws -> Result
) rethrows -> Result {
    var bytes: [CChar] = []
    var ranges: [Range<Int>] = []
    for word in words {
        let start = bytes.count
        bytes.append(contentsOf: word.map { CChar(bitPattern: $0) })
        ranges.append(start ..< bytes.count)
    }
    return try bytes.withUnsafeBufferPointer { base in
        let spans = ranges.map { range in
            omni_config_span(data: base.baseAddress.map { $0 + range.lowerBound }, length: range.count)
        }
        return try spans.withUnsafeBufferPointer(body)
    }
}
