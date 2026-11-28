// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptFocusTargetTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: 1)
    private let windows = ["1": [1], "2": [2, 3], "3": [4, 5], "4": []]

    private func scene() async throws -> ConfigScriptWindowFixture {
        let base = try NiriGatherFixture(
            prefix: "focus-target",
            monitors: [display],
            workspaces: windows.keys.sorted().map { .init(name: $0, monitor: display) }
        )
        let fixture = ConfigScriptWindowFixture(base: base)
        let (one, two) = (base.workspace("1"), base.workspace("2"))
        for name in windows.keys.sorted() where windows[name]?.isEmpty == false {
            base.add(windows[name]!, to: base.workspace(name))
        }
        XCTAssertTrue(base.manager.setActiveWorkspace(two, on: display.id))
        try await fixture.focus(2, on: "2")
        XCTAssertTrue(base.manager.requestNativeFullscreenEnter(base.token(2), in: two))
        XCTAssertTrue(base.manager.markNativeFullscreenSuspended(base.token(2)))
        XCTAssertTrue(base.manager.setActiveWorkspace(one, on: display.id))
        try await fixture.focus(1, on: "1")
        XCTAssertTrue(base.manager.showsNativeFullscreenPlaceholder(for: base.token(2)))
        XCTAssertNotEqual(base.manager.externalFocusToken, base.token(2))
        return fixture
    }

    private func activation(of window: Int, in base: NiriGatherFixture) -> [String] {
        ["focusSpecificWindow \(base.token(window).windowId)", "raiseWindow"]
    }

    private func show(_ name: String, in fixture: ConfigScriptWindowFixture) {
        XCTAssertTrue(fixture.base.manager.setActiveWorkspace(fixture.base.workspace(name), on: display.id))
    }

    private func staged(_ window: Int, _ checks: String?, in fixture: ConfigScriptWindowFixture) async throws
        -> ConfigScriptWindowRequest
    {
        let table = checks.map { ", \($0)" } ?? ""
        let source = "omniwm.command('Stage', function() "
            + "omniwm.dispatch('window', 'focus', '\(fixture.id(window))'\(table)) end)"
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let stage = try XCTUnwrap(result.namedCommands.first)
        let commands = try await vm.invoke(function: stage.function, context: ConfigScriptContext()).commands
        let request: ConfigScriptWindowRequest? = if case let .window(request)? = commands.first?.operation {
            request
        } else {
            nil
        }
        return try XCTUnwrap(request)
    }

    private func perform(
        _ request: ConfigScriptWindowRequest, in fixture: ConfigScriptWindowFixture,
        capturedAs target: ConfigScriptTarget? = nil
    ) -> ExternalCommandResult {
        let controller = fixture.base.controller
        return controller.performConfigScriptDispatch(
            .window(request),
            target: target ?? controller.configScriptTarget()
        )
    }

    private func unmanagedWindow(in base: NiriGatherFixture) -> WindowToken {
        base.token(windows.values.flatMap(\.self).max()! + 1)
    }

    private func requestFocus(of window: Int, on name: String, in base: NiriGatherFixture) {
        let (token, workspace) = (base.token(window), base.workspace(name))
        let request = base.controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspace)
        XCTAssertTrue(base.manager.beginManagedFocusRequest(token, in: workspace, requestId: request.requestId))
        XCTAssertEqual(base.manager.pendingFocusedToken, token)
    }

    private func settleSwitch(in fixture: ConfigScriptWindowFixture) async throws {
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertTrue(queue.hasPendingWork)
        await queue.waitUntilParked()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.base.controller)
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testFocusTargetNamesTheWindowASwitchFocuses() async throws {
        let fixture = try await scene()
        let base = fixture.base
        try await fixture.inspect([
            "local t = assert(ctx.focusTarget)",
            "assert(table.isfrozen(t) and t.id == '\(fixture.id(1))' and t.nativeFullscreen == false)",
            "assert(ctx.truncated.focusTarget == false and ctx.placement == nil and ctx.windows == nil)"
        ], reads: ["focusTarget"])

        XCTAssertTrue(base.manager.setWindowMode(.floating, for: base.token(1)))
        try await fixture.inspect([
            "assert(ctx.focusTarget.id == '\(fixture.id(1))' and ctx.focusTarget.nativeFullscreen == false)"
        ], reads: ["focusTarget"])

        show("3", in: fixture)
        try await fixture.focus(5, on: "3")
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: base.token(5)))
        try await fixture.inspect(["assert(ctx.focusTarget.id == '\(fixture.id(4))')"], reads: ["focusTarget"])

        show("4", in: fixture)
        try await fixture.inspect(
            ["assert(ctx.focusTarget == nil and ctx.truncated.focusTarget == false)"], reads: ["focusTarget"]
        )
    }

    func testNativeFullscreenIsReadyOnlyWhileTheWindowHasItsOwnSpace() async throws {
        let fixture = try await scene()
        show("2", in: fixture)
        try await fixture.inspect([
            "assert(ctx.focusTarget.id == '\(fixture.id(2))' and ctx.focusTarget.nativeFullscreen == true)"
        ], reads: ["focusTarget"])

        XCTAssertTrue(fixture.base.manager.requestNativeFullscreenExit(fixture.base.token(2)))
        try await fixture.inspect([
            "assert(ctx.focusTarget.id == '\(fixture.id(2))' and ctx.focusTarget.nativeFullscreen == false)",
            "local row",
            "for _, w in ctx.workspaceWindows do if w.id == ctx.focusTarget.id then row = w end end",
            "assert(row and row.fullscreen == 'native')"
        ], reads: ["focusTarget", "workspaceWindows"])
    }

    func testFocusChecksRunWhenTheFocusRuns() async throws {
        let both: (String) -> String = { "{ targetOf = '\($0)', nativeFullscreen = true }" }
        let targetOf: (String) -> String = { "{ targetOf = '\($0)' }" }
        let ready: (String) -> String = { _ in "{ nativeFullscreen = true }" }
        let cases: [(String, Int, (String) -> String, (ConfigScriptWindowFixture) async throws -> Void, Bool)] = [
            ("still the target", 2, both, { _ in }, true),
            ("switched on to another workspace", 2, both, { self.show("3", in: $0) }, false),
            ("another window focused there", 2, targetOf, { try await $0.focus(3, on: "2") }, false),
            ("moved off the workspace", 3, targetOf, {
                $0.base.manager.setWorkspace(for: $0.base.token(3), to: $0.base.workspace("3"))
            }, false),
            ("an unmanaged window focused", 2, both, { fixture in
                let unmanaged = self.unmanagedWindow(in: fixture.base)
                XCTAssertNil(fixture.base.manager.entry(for: unmanaged))
                _ = fixture.base.manager.recordExternalFocus(pid: unmanaged.pid, windowId: unmanaged.windowId)
            }, false),
            ("OmniWM asked to focus a window elsewhere", 2, both, {
                self.requestFocus(of: 4, on: "3", in: $0.base)
            }, false),
            ("fullscreen exit requested", 2, ready, {
                XCTAssertTrue($0.base.manager.requestNativeFullscreenExit($0.base.token(2)))
            }, false)
        ]
        for (label, window, checks, change, runs) in cases {
            let fixture = try await scene()
            let base = fixture.base
            show("2", in: fixture)
            if window != 2 { try await fixture.focus(window, on: "2") }
            let request = try await staged(window, checks(base.workspace("2").uuidString), in: fixture)
            let capture = base.controller.configScriptTarget()
            try await change(fixture)
            let workspace = base.controller.activeWorkspace()?.id
            let focused = base.manager.focusSessionSnapshot.nativeFocusOwner
            let before = base.focusRecorder.operations.count
            XCTAssertEqual(perform(request, in: fixture, capturedAs: capture), runs ? .executed : .noChange, label)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(base.controller)
            let operations = Array(base.focusRecorder.operations[before...])
            if runs {
                XCTAssertEqual(operations, activation(of: window, in: base), label)
                XCTAssertEqual(base.manager.externalFocusToken, base.token(window), label)
            } else {
                XCTAssertEqual(operations, [], label)
                XCTAssertEqual(base.controller.activeWorkspace()?.id, workspace, label)
                XCTAssertEqual(base.manager.focusSessionSnapshot.nativeFocusOwner, focused, label)
            }
        }
    }

    func testACheckedFocusCapturedBeforeTheSwitchHandoffStillRunsAfterIt() async throws {
        for (name, window, fullscreen) in [("2", 2, true), ("3", 4, false)] {
            let fixture = try await scene()
            let base = fixture.base
            let controller = base.controller
            XCTAssertTrue(controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: name), name)
            let capture = controller.configScriptTarget()
            let checks = "{ targetOf = '\(base.workspace(name).uuidString)', nativeFullscreen = \(fullscreen) }"
            let request = try await staged(window, checks, in: fixture)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            XCTAssertEqual(base.manager.pendingFocusedToken, fullscreen ? nil : base.token(window), name)
            XCTAssertEqual(perform(request, in: fixture, capturedAs: capture), .executed, name)
            if fullscreen {
                await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
                XCTAssertEqual(base.manager.externalFocusToken, base.token(window), name)
            }
        }
    }

    func testPlainFocusStillReachesAWindowOnAnotherWorkspace() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let request = try await staged(2, nil, in: fixture)
        XCTAssertNil(request.check)
        let before = base.focusRecorder.operations.count
        XCTAssertEqual(perform(request, in: fixture), .executed)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(base.controller)
        XCTAssertEqual(Array(base.focusRecorder.operations[before...]), activation(of: 2, in: base))
        XCTAssertEqual(base.manager.externalFocusToken, base.token(2))
    }

    private func loadCountedRecipe(into fixture: ConfigScriptWindowFixture) async throws {
        let counter = [
            "local host = omniwm",
            "local dispatched = 0",
            "local omniwm = { on = host.on, dispatch = function(...) dispatched += 1; host.dispatch(...) end }",
            "for n = 0, 1 do",
            "    host.command('Dispatched ' .. n, function() assert(dispatched == n, 'dispatched ' .. dispatched) end)",
            "end"
        ]
        let recipe = try ConfigScriptWindowFixture.recipe("Land on a native fullscreen window")
        try await fixture.load((counter + [recipe]).joined(separator: "\n"))
    }

    func testTheRecipeLeavesAWindowYouFocusedWhileItWasQueued() async throws {
        let fixture = try await scene()
        let base = fixture.base
        try await loadCountedRecipe(into: fixture)
        XCTAssertTrue(base.controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "2"))
        let unmanaged = unmanagedWindow(in: base)
        _ = base.manager.recordExternalFocus(pid: unmanaged.pid, windowId: unmanaged.windowId)
        let before = base.focusRecorder.operations.count
        try await settleSwitch(in: fixture)
        XCTAssertEqual(Array(base.focusRecorder.operations[before...]), [])
        XCTAssertEqual(base.manager.externalFocusToken, unmanaged)
        try await fixture.run(named: "Dispatched 1")
    }

    func testTheRecipeLandsOnTheFullscreenWindowAndLeavesOtherSwitchesAlone() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let navigation = base.controller.workspaceNavigationHandler
        try await loadCountedRecipe(into: fixture)

        XCTAssertTrue(navigation.switchWorkspace(rawWorkspaceID: "2"))
        let before = base.focusRecorder.operations.count
        try await settleSwitch(in: fixture)
        XCTAssertEqual(Array(base.focusRecorder.operations[before...]), activation(of: 2, in: base))
        XCTAssertEqual(base.manager.externalFocusToken, base.token(2))
        XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace("2"))
        try await fixture.run(named: "Dispatched 1")

        XCTAssertNotNil(navigation.workspaceBackAndForth())
        try await settleSwitch(in: fixture)
        XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace("1"))
        try await fixture.run(named: "Dispatched 1")

        XCTAssertTrue(navigation.switchWorkspace(rawWorkspaceID: "3"))
        try await settleSwitch(in: fixture)
        XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace("3"))
        try await fixture.run(named: "Dispatched 1")
    }

    func testTheSwitchHandoffKeepsAFullscreenActivationInEitherOrder() async throws {
        for activationFirst in [true, false] {
            let base = try await scene().base
            let controller = base.controller
            let label = activationFirst ? "activation before the handoff" : "activation after the handoff"
            XCTAssertTrue(controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "2"), label)
            if !activationFirst {
                await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            }
            let before = base.focusRecorder.operations.count
            XCTAssertTrue(controller.windowActionHandler.focusWindowFromBar(token: base.token(2)), label)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            XCTAssertEqual(Array(base.focusRecorder.operations[before...]), activation(of: 2, in: base), label)
            XCTAssertEqual(base.manager.externalFocusToken, base.token(2), label)
            XCTAssertEqual(base.manager.selectedManagedToken, base.token(2), label)
            XCTAssertEqual(controller.activeWorkspace()?.id, base.workspace("2"), label)
        }
    }
}
