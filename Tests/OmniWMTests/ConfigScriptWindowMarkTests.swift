// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWindowMarkTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
    private let origin = "1"
    private let destination = "2"
    private let anchorWindow = 1
    private let markedWindow = 2
    private let markName = "editor"
    private let callbackName = "Exercise shared marks"

    func testFlexMarkCanBeListedFocusedAndRemovedByTheCLI() async throws {
        let fixture = try scene()
        let base = fixture.base
        try await focus(markedWindow, on: destination, in: fixture)
        let set = dispatch("set", " \(markName) ")
        _ = try await invoke([set], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)

        let mark = try XCTUnwrap(list(in: fixture).first)
        XCTAssertEqual(mark.name, markName)
        XCTAssertEqual(mark.id, IPCWindowOpaqueID.encode(token: base.token(markedWindow), sessionToken: ""))
        try await focus(anchorWindow, on: origin, in: fixture)
        XCTAssertEqual(reply(.focus(name: markName), in: fixture).status, .executed)
        XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace(destination))
        XCTAssertEqual(reply(.remove(name: markName), in: fixture).status, .executed)
        XCTAssertTrue(try list(in: fixture).isEmpty)
    }

    func testCLIMarkCanBeFocusedAndRemovedByFlex() async throws {
        let fixture = try scene()
        let base = fixture.base
        try await focus(markedWindow, on: destination, in: fixture)
        XCTAssertEqual(reply(.set(name: markName), in: fixture).status, .executed)
        try await focus(anchorWindow, on: origin, in: fixture)

        _ = try await invoke([dispatch("focus", markName), dispatch("remove", markName)], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace(destination))
        XCTAssertTrue(try list(in: fixture).isEmpty)
    }

    func testNoOpAndByteDistinctNamesUseTheSharedRegistry() async throws {
        let fixture = try scene()
        let base = fixture.base
        let first = "caf\u{00E9}"
        let second = "cafe\u{0301}"
        try await focus(anchorWindow, on: origin, in: fixture)
        let set = dispatch("set", first)
        _ = try await invoke([set, set, dispatch("set", markName)], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(markName), .found(base.token(anchorWindow)))

        try await focus(markedWindow, on: destination, in: fixture)
        XCTAssertEqual(reply(.set(name: second), in: fixture).status, .executed)
        let lines = try await invoke([set], in: fixture)
        try assertRefusal("set", "mark is already assigned to another window", at: set, in: lines, fixture: fixture)
        let entries = try list(in: fixture)
        let expectedNames = [first, second, markName].map { Array($0.utf8) }
        XCTAssertEqual(entries.map { Array($0.name.utf8) }, expectedNames.sorted { $0.lexicographicallyPrecedes($1) })
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(first), .found(base.token(anchorWindow)))
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(second), .found(base.token(markedWindow)))
    }

    func testMissingAndChangedCapturedFocusRefuseSet() async throws {
        let fixture = try scene()
        let base = fixture.base
        let originId = base.workspace(origin)
        let anchor = base.token(anchorWindow)
        let set = dispatch("set", markName)
        let missing = try await load([set], in: fixture)
        _ = base.manager.clearNativeFocusOwner()
        XCTAssertNil(base.manager.nativeManagedFocusToken)
        try enqueue(in: fixture)
        base.select(anchorWindow, in: originId)
        _ = base.manager.setManagedFocus(anchor, in: originId)
        XCTAssertEqual(base.manager.nativeManagedFocusToken, anchor)
        try await drain(fixture)
        try assertRefusal("set", "no focused managed window", at: set, in: missing, fixture: fixture)
        XCTAssertTrue(try list(in: fixture).isEmpty)

        let replacementWindow = markedWindow + 1
        let replacement = base.token(replacementWindow)
        base.add([replacementWindow], to: originId)
        let changed = try await invoke([set], in: fixture) {
            base.select(replacementWindow, in: originId)
            _ = base.manager.setManagedFocus(replacement, in: originId)
            XCTAssertEqual(base.manager.nativeManagedFocusToken, replacement)
        }
        try assertRefusal("set", "captured focus changed", at: set, in: changed, fixture: fixture)
        XCTAssertTrue(try list(in: fixture).isEmpty)
    }

    func testSummonRequiresTheCapturedAnchorAndPreservesNativeRefusals() async throws {
        let fixture = try scene()
        let base = fixture.base
        let target = base.token(markedWindow)
        let summon = dispatch("summon", markName)
        try await focus(markedWindow, on: destination, in: fixture)
        XCTAssertEqual(reply(.set(name: markName), in: fixture).status, .executed)
        try await focus(anchorWindow, on: origin, in: fixture)
        let originId = base.workspace(origin)
        let destinationId = base.workspace(destination)
        let refused = try await invoke([summon], in: fixture) {
            _ = base.manager.setActiveWorkspace(destinationId, on: display.id)
            base.select(markedWindow, in: destinationId)
            _ = base.manager.setManagedFocus(target, in: destinationId)
            XCTAssertEqual(base.manager.nativeManagedFocusToken, target)
        }
        try assertRefusal("summon", "captured focus changed", at: summon, in: refused, fixture: fixture)
        let selfSummon = try await invoke([summon], in: fixture)
        try assertRefusal("summon", "cannot summon the anchor window", at: summon, in: selfSummon, fixture: fixture)

        try await focus(anchorWindow, on: origin, in: fixture)
        _ = base.manager.setAppHidden(true, pid: target.pid, source: .service)
        let hidden = try await invoke([summon], in: fixture)
        try assertRefusal("summon", "marked window is hidden", at: summon, in: hidden, fixture: fixture)
        XCTAssertEqual(base.manager.workspace(for: target), destinationId)
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(markName), .found(target))

        _ = base.manager.setAppHidden(false, pid: target.pid, source: .service)
        _ = try await invoke([summon], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.manager.workspace(for: target), originId)
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(markName), .found(target))
    }

    func testSummonRefusesAnIncompatiblePendingFocusWithTheSameNativeOwner() async throws {
        let fixture = try scene()
        let base = fixture.base
        let target = base.token(markedWindow)
        let destinationId = base.workspace(destination)
        try await focus(markedWindow, on: destination, in: fixture)
        XCTAssertEqual(reply(.set(name: markName), in: fixture).status, .executed)
        try await focus(anchorWindow, on: origin, in: fixture)

        let summon = dispatch("summon", markName)
        let source = try await invoke([summon], in: fixture) {
            let request = base.controller.intentLedger.beginManagedRequest(token: target, workspaceId: destinationId)
            XCTAssertTrue(base.manager.beginManagedFocusRequest(
                target,
                in: destinationId,
                requestId: request.requestId
            ))
            XCTAssertEqual(base.manager.pendingFocusedToken, target)
            XCTAssertEqual(base.manager.nativeManagedFocusToken, base.token(anchorWindow))
        }
        try assertRefusal("summon", "captured focus changed", at: summon, in: source, fixture: fixture)
        XCTAssertEqual(base.manager.workspace(for: target), destinationId)
    }

    func testRefusedRemoveStopsLaterEffectsAndKeepsEarlierMarks() async throws {
        let fixture = try scene()
        try await focus(anchorWindow, on: origin, in: fixture)
        let missing = "unassigned"
        let later = "never set"
        let remove = dispatch("remove", missing)
        let lines = try await invoke([dispatch("set", markName), remove, dispatch("set", later)], in: fixture)
        try assertRefusal("remove", "unknown mark", at: remove, in: lines, fixture: fixture)
        XCTAssertEqual(try list(in: fixture).map(\.name), [markName])
    }

    func testMarksSurviveReloadAndRekeyUntilWindowRetirement() async throws {
        let fixture = try scene()
        let base = fixture.base
        let controller = base.controller
        try await focus(markedWindow, on: destination, in: fixture)
        _ = try await invoke([dispatch("set", markName)], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        let focus = dispatch("focus", markName)
        let source = try await load([focus], in: fixture)
        let previous = base.token(markedWindow)
        XCTAssertEqual(try list(in: fixture).map(\.name), [markName])

        let replacement = WindowToken(pid: previous.pid, windowId: previous.windowId + 1)
        let rekeyed = try XCTUnwrap(controller.axEventHandler.commitManagedWindowIdentityRebind(
            from: previous, to: replacement, axRef: WindowAdmissionTestSupport.axRef(for: replacement),
            managedReplacementMetadata: nil
        ))
        XCTAssertEqual(rekeyed.token, replacement)
        XCTAssertEqual(base.controller.windowMarkRegistry.lookup(markName), .found(replacement))
        let entry = try XCTUnwrap(list(in: fixture).first)
        XCTAssertEqual(entry.id, IPCWindowOpaqueID.encode(token: replacement, sessionToken: ""))

        controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(rekeyed)
        XCTAssertEqual(controller.windowMarkRegistry.lookup(markName), .unknown)
        XCTAssertTrue(try list(in: fixture).isEmpty)
        try enqueue(in: fixture)
        try await drain(fixture)
        try assertRefusal("focus", "unknown mark", at: focus, in: source, fixture: fixture)
    }

    func testWhitespaceOnlyMarkGetsTheSameNativeRefusalAsTheCLI() async throws {
        let fixture = try scene()
        try await focus(anchorWindow, on: origin, in: fixture)
        let whitespace = " "
        XCTAssertEqual(reply(.set(name: whitespace), in: fixture).code, .invalidMark)
        let set = dispatch("set", whitespace)
        let source = try await invoke([set], in: fixture)
        try assertRefusal("set", "invalid mark name", at: set, in: source, fixture: fixture)
        XCTAssertTrue(try list(in: fixture).isEmpty)
    }

    func testMalformedMarkDispatchCannotBeCaughtToKeepEarlierEffects() async throws {
        let fixture = try scene()
        try await focus(anchorWindow, on: origin, in: fixture)
        let calls = [
            "'mark', 'set'",
            "'mark', 'set', true",
            "'mark', 'set', '\(markName)', 'extra'",
            "'mark', 'list', '\(markName)'",
            "'mark', 'set', string.char(\(UInt8.max))"
        ]
        for arguments in calls {
            let malformed = "pcall(function() omniwm.dispatch(\(arguments)) end)"
            let source = try await invoke([dispatch("set", markName), malformed], in: fixture)
            let line = try XCTUnwrap(source.firstIndex { $0.contains(malformed) }) + 1
            let diagnostic = try XCTUnwrap(fixture.script.diagnostic, arguments)
            XCTAssertTrue(diagnostic.contains("init.luau:\(line):"), diagnostic)
            XCTAssertTrue(try list(in: fixture).isEmpty)
        }
    }

    func testMarksRefuseDisabledAutomationAndOpenOverviewAtApply() async throws {
        let fixture = try scene()
        let controller = fixture.base.controller
        try await focus(anchorWindow, on: origin, in: fixture)
        XCTAssertEqual(reply(.set(name: markName), in: fixture).status, .executed)
        let remove = dispatch("remove", markName)
        let disabled = try await invoke([remove], in: fixture) { controller.isEnabled = false }
        try assertRefusal("remove", "automation is disabled", at: remove, in: disabled, fixture: fixture)
        controller.isEnabled = true
        defer { if controller.isOverviewOpen() { controller.toggleOverview() } }
        let overview = try await invoke([remove], in: fixture) { controller.toggleOverview() }
        XCTAssertTrue(controller.isOverviewOpen())
        try assertRefusal("remove", "Overview is open", at: remove, in: overview, fixture: fixture)
        XCTAssertEqual(try list(in: fixture).map(\.name), [markName])
    }

    private func scene() throws -> ConfigScriptWindowFixture {
        let base = try NiriGatherFixture(
            prefix: "config-marks", monitors: [display],
            workspaces: [origin, destination].map { .init(name: $0, monitor: display) }
        )
        base.controller.settings.animationsEnabled = false
        _ = base.manager.setActiveWorkspace(base.workspace(origin), on: display.id)
        base.add([anchorWindow], to: base.workspace(origin))
        base.add([markedWindow], to: base.workspace(destination))
        addTeardownBlock { @MainActor in
            base.controller.stopConfigScript()
            base.controller.layoutRefreshController.resetState()
        }
        return ConfigScriptWindowFixture(base: base)
    }

    private func focus(_ window: Int, on workspace: String, in fixture: ConfigScriptWindowFixture) async throws {
        let base = fixture.base
        _ = base.manager.setActiveWorkspace(base.workspace(workspace), on: display.id)
        try await fixture.focus(window, on: workspace)
    }

    private func dispatch(_ action: String, _ name: String) -> String {
        "omniwm.dispatch('mark', '\(action)', '\(name)')"
    }

    private func load(_ statements: [String], in fixture: ConfigScriptWindowFixture) async throws -> [String] {
        let lines = ["omniwm.command('\(callbackName)', function()"] + statements.map { "    \($0)" } + ["end)"]
        try await fixture.load(lines.joined(separator: "\n"))
        return lines
    }

    private func enqueue(in fixture: ConfigScriptWindowFixture) throws {
        let function = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == callbackName }?.function)
        let command = HotkeyCommand.configFunction(function)
        XCTAssertEqual(
            fixture.base.controller.commandHandler.handleHotkeyInvocation(.init(command: command)),
            .executed
        )
    }

    private func drain(_ fixture: ConfigScriptWindowFixture) async throws {
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        await queue.waitUntilParked()
    }

    private func invoke(
        _ statements: [String], in fixture: ConfigScriptWindowFixture, beforeApply: () -> Void = {}
    ) async throws -> [String] {
        let source = try await load(statements, in: fixture)
        try enqueue(in: fixture)
        beforeApply()
        try await drain(fixture)
        return source
    }

    private func assertRefusal(
        _ action: String, _ reason: String, at call: String, in source: [String], fixture: ConfigScriptWindowFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let sourceLine = try XCTUnwrap(source.firstIndex { $0.contains(call) }, file: file, line: line) + 1
        let diagnostic = try XCTUnwrap(fixture.script.diagnostic, file: file, line: line)
        XCTAssertTrue(
            diagnostic.contains("init.luau:\(sourceLine): mark \(action): \(reason)."),
            diagnostic,
            file: file,
            line: line
        )
    }

    private func list(in fixture: ConfigScriptWindowFixture) throws -> [IPCWindowMarkEntry] {
        let response = reply(.list, in: fixture)
        XCTAssertTrue(response.ok)
        guard case let .windowMarks(entries)? = response.result?.payload else {
            XCTFail("Expected the CLI to return the shared marks")
            return []
        }
        return entries.marks
    }

    private func reply(_ request: IPCWindowMarkRequest, in fixture: ConfigScriptWindowFixture) -> IPCResponse {
        IPCWindowMarkRequestExecutor(controller: fixture.base.controller).response(for: request, id: callbackName)
    }
}
