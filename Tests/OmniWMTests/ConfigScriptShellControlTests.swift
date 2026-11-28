// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptShellControlTests: XCTestCase {
    private let callbackName = "Exercise Shell controls"
    private let key = "work.mode"
    private let widget = "quota"
    private let triggerName = "refresh"

    func testVarsShareCLIStorageAndCanBeChangedOrRemovedWithoutAHost() async throws {
        let fixture = try scene()
        let bar = fixture.base.controller.workspaceBarManager
        XCTAssertNil(bar.shellHost)
        let first = "writing"
        let second = "editing"

        _ = try await invoke([dispatch("set", literal(key), literal(first))], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(bar.shellVars, [key: first])

        let changed = await ipc(.set(key: key, value: second), in: fixture)
        XCTAssertEqual(changed.status, .executed)
        XCTAssertEqual(bar.shellVars, [key: second])

        _ = try await invoke([dispatch("unset", literal(key)), dispatch("unset", literal(key))], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertTrue(bar.shellVars.isEmpty)
        let missing = await ipc(.unset(key: key), in: fixture)
        XCTAssertEqual(missing.code, .noChange)
    }

    func testEqualSetAndMissingUnsetDoNotRepublishTheFeed() async throws {
        let fixture = try scene()
        let host = installHost(in: fixture)
        let value = "work"
        var delivered: [[String: String]] = []
        host.feed = ShellDataFeed(deliver: { delivered.append($0.vars) })

        _ = try await invoke([
            dispatch("set", literal(key), literal(value)),
            dispatch("set", literal(key), literal(value))
        ], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(delivered, [[key: value]])

        let equal = await ipc(.set(key: key, value: value), in: fixture)
        XCTAssertEqual(equal.status, .executed)
        _ = try await invoke([dispatch("unset", literal(key)), dispatch("unset", literal(key))], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(delivered, [[key: value], [:]])
    }

    func testCanonicallyEqualReplacementKeepsTheNewVariableBytes() async throws {
        let fixture = try scene()
        let first = "caf\u{e9}"
        let replacement = "cafe\u{301}"
        let initial = await ipc(.set(key: key, value: first), in: fixture)
        XCTAssertEqual(initial.status, .executed)

        _ = try await invoke([dispatch("set", literal(key), literal(replacement))], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        let stored = try XCTUnwrap(fixture.base.controller.workspaceBarManager.shellVars[key])
        XCTAssertEqual(Array(stored.utf8), Array(replacement.utf8))
    }

    func testByteLimitsAndReplacementAtVarCapacityAreShared() async throws {
        let fixture = try scene()
        let bar = fixture.base.controller.workspaceBarManager
        let maxKey = String(repeating: "k", count: ShellRuntimeLimits.keyLimit)
        let maxValue = utf8Value(bytes: ShellRuntimeLimits.valueLimit)
        let insert = dispatch("set", literal(maxKey), literal(maxValue))
        _ = try await invoke([insert], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)

        var expected = [maxKey: maxValue]
        for index in 1 ..< ShellRuntimeLimits.countLimit {
            let extra = "key.\(index)"
            let value = "value.\(index)"
            let response = await ipc(.set(key: extra, value: value), in: fixture)
            XCTAssertEqual(response.status, .executed)
            expected[extra] = value
        }
        XCTAssertEqual(bar.shellVars, expected)

        let excess = dispatch("set", literal(key), literal(""))
        let source = try await invoke([excess, dispatch("unset", literal(maxKey))], in: fixture)
        try assertDiagnostic("shell set: the runtime variable limit is full.", at: excess, in: source, fixture: fixture)
        let rejected = await ipc(.set(key: key, value: ""), in: fixture)
        XCTAssertEqual(rejected.code, .invalidArguments)
        XCTAssertEqual(bar.shellVars, expected)

        let replacement = dispatch("set", literal(maxKey), literal(""))
        _ = try await invoke([replacement], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        expected[maxKey] = ""
        XCTAssertEqual(bar.shellVars, expected)
    }

    func testMalformedCallsRefuseAtTheirSourceAndDiscardStagedWrites() async throws {
        let fixture = try scene()
        let bar = fixture.base.controller.workspaceBarManager
        let malformed = "Invalid shell action or arguments."
        let quotedKey = literal(key)
        let name = literal(triggerName)
        let value = literal("")
        let long = literal(utf8Value(bytes: ShellRuntimeLimits.valueLimit + 1))
        let cases = [
            (dispatch("set", quotedKey), malformed),
            (dispatch("set", quotedKey, "false"), "expected a string token"),
            (dispatch("set", quotedKey, long), malformed),
            (dispatch("unset", literal(String(repeating: "k", count: ShellRuntimeLimits.keyLimit + 1))), malformed),
            (dispatch("unset", literal("é")), malformed),
            (dispatch("toggle", literal("")), malformed),
            (dispatch("trigger", literal(".private"), name), malformed),
            (dispatch("trigger", literal("nested/\(widget)"), name), malformed),
            (dispatch("trigger", literal(widget), literal("two names")), malformed),
            (dispatch("trigger", literal(widget), name, long), malformed),
            (
                dispatch("trigger", literal(widget), name, value, value),
                "omniwm.dispatch expects 'shell', an action and its arguments"
            ),
            (dispatch("profile", literal("default")), malformed)
        ]
        let earlier = dispatch("set", quotedKey, value)
        for (call, message) in cases {
            let source = try await invoke([earlier, call], in: fixture)
            try assertDiagnostic(message, at: call, in: source, fixture: fixture)
            XCTAssertTrue(bar.shellVars.isEmpty, call)
        }
    }

    func testDisabledCommandsStillAllowVarsButBlockToggleAndTrigger() async throws {
        let fixture = try scene()
        let controller = fixture.base.controller
        let bar = controller.workspaceBarManager
        let initial = await ipc(.set(key: key, value: "initial"), in: fixture)
        XCTAssertEqual(initial.status, .executed)
        let new = "notes.mode"
        defer { controller.isEnabled = true }
        _ = try await invoke([
            dispatch("unset", literal(key)), dispatch("set", literal(new), literal(""))
        ], in: fixture) { controller.isEnabled = false }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(bar.shellVars, [new: ""])

        let host = installHost(in: fixture)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        _ = addReceiver(widget, to: host, mailbox: mailbox)
        for (action, call) in [
            ("toggle", dispatch("toggle", literal(widget))),
            ("trigger", dispatch("trigger", literal(widget), literal(triggerName)))
        ] {
            controller.isEnabled = true
            let source = try await invoke([call], in: fixture) { controller.isEnabled = false }
            try assertDiagnostic("shell \(action): OmniWM is disabled.", at: call, in: source, fixture: fixture)
        }
        mailbox.finish()
        let received = await triggers(in: messages)
        XCTAssertTrue(received.isEmpty)
    }

    func testOldSessionCannotPublishVarsOrSendATrigger() async throws {
        let fixture = try scene()
        let controller = fixture.base.controller
        let host = installHost(in: fixture)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        _ = addReceiver(widget, to: host, mailbox: mailbox)
        for call in [
            dispatch("set", literal(key), literal("")),
            dispatch("trigger", literal(widget), literal(triggerName))
        ] {
            let source = try await invoke([call], in: fixture) {
                controller.scriptSession = ConfigScriptSessionToken()
            }
            try assertDiagnostic("the callback belongs to an earlier session", at: call, in: source, fixture: fixture)
        }
        XCTAssertTrue(controller.workspaceBarManager.shellVars.isEmpty)
        mailbox.finish()
        let received = await triggers(in: messages)
        XCTAssertTrue(received.isEmpty)
    }

    func testTriggerDeliversOmittedNilAndEmptySeparatelyAndRefusesUnavailableMailboxes() async throws {
        let fixture = try scene()
        let call = dispatch("trigger", literal(widget), literal(triggerName))
        let toggle = dispatch("toggle", literal(widget))
        try await assertUnavailableTrigger(call, in: fixture)
        let absent = try await invoke([toggle], in: fixture)
        try assertDiagnostic(
            "shell toggle: no matching widget or drawer is available.", at: toggle, in: absent, fixture: fixture
        )

        let host = installHost(in: fixture)
        try await assertUnavailableTrigger(call, in: fixture)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        let receiver = addReceiver(widget, to: host, mailbox: mailbox)
        receiver.declaration.hasTrigger = false
        try await assertUnavailableTrigger(call, in: fixture)
        receiver.declaration.hasTrigger = true

        let values: [String?] = [nil, "", "refresh immediately"]
        let explicit = values
            .map { dispatch("trigger", literal(widget), literal(triggerName), $0.map(literal) ?? "nil") }
        _ = try await invoke([call] + explicit, in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        mailbox.finish()
        let delivered = await triggers(in: messages)
        XCTAssertEqual(delivered, ([nil] + values).map { Trigger(name: triggerName, value: $0) })

        try await assertUnavailableTrigger(call, in: fixture)
        receiver.mailbox = nil
        try await assertUnavailableTrigger(call, in: fixture)
    }

    func testNativeToggleChoosesTheInteractionDisplayAndPrefersSameNamedIslandDrawer() async throws {
        let left = NiriGatherFixture.monitor(displayId: .max - 1)
        let right = NiriGatherFixture.monitor(displayId: left.displayId - 1, x: left.frame.maxX)
        let fixture = try scene(monitors: [left, right])
        let controller = fixture.base.controller
        let manager = controller.workspaceManager
        controller.workspaceBarManager.controller = controller
        controller.surfaceReconciler.controller = nil
        controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen = true
        let host = installHost(in: fixture)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        let receiver = addReceiver(widget, to: host, mailbox: mailbox)
        host.config.island = ShellIslandConfig(root: widget)
        host.config.island?.displays = .all
        let desired = [left, right].map { DesiredIslandSurface(monitor: $0, fullscreen: false) }
        func prepareIslands() {
            _ = manager.setInteractionMonitor(right.id)
            XCTAssertEqual(manager.interactionMonitorID(), right.id)
            host.desiredIslands = desired
            host.refreshIslandData()
            XCTAssertEqual(host.config.island?.root, widget)
            XCTAssertEqual(host.islandData[ShellBarKey(monitor: right.id, placement: .island)]?.surface?.visible, true)
            XCTAssertTrue(host.widgets[widget] === receiver)
            XCTAssertNotNil(receiver.package)
            XCTAssertNotNil(receiver.mailbox)
            XCTAssertTrue(receiver.declaration.hasTrigger)
            XCTAssertFalse(receiver.declaration.hasPopout)
        }

        let toggle = dispatch("toggle", literal(widget))
        _ = try await invoke([toggle], in: fixture, beforeApply: prepareIslands)
        XCTAssertNil(fixture.script.diagnostic)
        host.config.drawers = [ShellDrawerConfig(
            id: widget,
            edge: .right,
            widgets: [widget],
            hover: false,
            island: true
        )]
        _ = try await invoke([toggle], in: fixture, beforeApply: prepareIslands)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(host.islandDrawer?.id, widget)
        XCTAssertEqual(host.islandDrawer?.monitor, right.id)
        XCTAssertNil(host.drawer)
        XCTAssertTrue(host.islandWindows.isEmpty)
        mailbox.finish()
        let delivered = await triggers(in: messages)
        XCTAssertEqual(delivered, [Trigger(name: "toggle", value: "display:\(right.displayId)")])
    }
}

extension ConfigScriptShellControlTests {
    private struct Trigger: Equatable {
        let name: String
        let value: String?
    }

    private func scene(monitors: [Monitor] = [NiriGatherFixture.monitor(displayId: .max - 1)]) throws
        -> ConfigScriptWindowFixture
    {
        let fixture = try ConfigScriptWindowFixture(monitors: monitors)
        let controller = fixture.base.controller
        addTeardownBlock { @MainActor in
            controller.stopConfigScript()
            controller.layoutRefreshController.resetState()
            controller.workspaceBarManager.shellHost = nil
        }
        return fixture
    }

    private func installHost(in fixture: ConfigScriptWindowFixture) -> ShellWidgetHost {
        let controller = fixture.base.controller
        let bar = controller.workspaceBarManager
        let directory = controller.settings.settingsFileURL.deletingLastPathComponent()
        let host = ShellWidgetHost(
            configDirectory: directory, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("shell-resources")),
            world: { ShellWorldData() }, vars: { [weak bar] in bar?.shellVars ?? [:] }, bars: { [:] },
            onLayoutChange: {}, onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        bar.shellHost = host
        return host
    }

    private func addReceiver(
        _ name: String, to host: ShellWidgetHost, mailbox: AsyncStream<ShellWidgetMessage>.Continuation
    ) -> ShellWidgetHost.WidgetState {
        let receiver = ShellWidgetHost.WidgetState(
            name: name,
            sourceURL: host.widgetsDirectory.appendingPathComponent(name)
        )
        receiver.package = ShellWidgetPackage(name: name, generation: 1, outbox: ShellWidgetOutbox { _ in })
        receiver.declaration.hasTrigger = true
        receiver.mailbox = mailbox
        host.widgets[name] = receiver
        return receiver
    }

    private func triggers(in messages: AsyncStream<ShellWidgetMessage>) async -> [Trigger] {
        var result: [Trigger] = []
        for await message in messages {
            if case let .trigger(name, value) = message { result.append(Trigger(name: name, value: value)) }
        }
        return result
    }

    private func dispatch(_ action: String, _ arguments: String...) -> String {
        "omniwm.dispatch(" + ([literal("shell"), literal(action)] + arguments).joined(separator: ", ") + ")"
    }

    private func literal(_ text: String) -> String {
        String(reflecting: text)
    }

    private func utf8Value(bytes: Int) -> String {
        let symbol = "é"
        return String(repeating: symbol, count: bytes / symbol.utf8.count)
            + String(repeating: "x", count: bytes % symbol.utf8.count)
    }

    private func invoke(
        _ statements: [String], in fixture: ConfigScriptWindowFixture, beforeApply: () -> Void = {}
    ) async throws -> [String] {
        let lines = ["omniwm.command('\(callbackName)', function()"] + statements.map { "    \($0)" } + ["end)"]
        try await fixture.load(lines.joined(separator: "\n"))
        let function = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == callbackName }?.function)
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertEqual(
            fixture.base.controller.commandHandler.handleHotkeyInvocation(.init(command: .configFunction(function))),
            .executed
        )
        beforeApply()
        await queue.waitUntilParked()
        return lines
    }

    private func ipc(_ request: IPCShellRequest, in fixture: ConfigScriptWindowFixture) async -> IPCResponse {
        await IPCApplicationBridge.shellResponse(
            for: request,
            id: request.name.rawValue,
            controller: fixture.base.controller
        )
    }

    private func assertUnavailableTrigger(_ call: String, in fixture: ConfigScriptWindowFixture) async throws {
        let source = try await invoke([call], in: fixture)
        try assertDiagnostic(
            "shell trigger: the widget has no available trigger.", at: call, in: source, fixture: fixture
        )
    }

    private func assertDiagnostic(
        _ message: String, at call: String, in source: [String], fixture: ConfigScriptWindowFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let sourceLine = try XCTUnwrap(source.firstIndex { $0.contains(call) }, file: file, line: line) + 1
        let diagnostic = try XCTUnwrap(fixture.script.diagnostic, file: file, line: line)
        XCTAssertTrue(diagnostic.contains("init.luau:\(sourceLine):"), diagnostic, file: file, line: line)
        XCTAssertTrue(diagnostic.contains(message), diagnostic, file: file, line: line)
    }
}
