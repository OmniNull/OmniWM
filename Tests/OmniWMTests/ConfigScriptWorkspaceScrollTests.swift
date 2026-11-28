// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptWorkspaceScrollTests: XCTestCase {
    private let callbackName = "Scroll workspace"

    func testScrollByNumberSurvivesTheScheduledRelayoutWithoutChangingFocus() async throws {
        let fixture = try NiriWorkspaceScrollFixture(center: .always, overscroll: true)
        defer { fixture.stop() }
        let script = installScript(in: fixture)
        defer { fixture.controller.stopConfigScript() }

        let workspace = try XCTUnwrap(fixture.manager.descriptor(for: fixture.workspace)?.name)
        let offset = fixture.noncenteredOffset
        fixture.controller.motionPolicy.systemReducesMotion = false
        fixture.controller.motionPolicy.animationsEnabled = true
        let call = scrollCall(target: workspace, arguments: ["\(offset)", "{ animate = false }"])
        let source = try await load(call, script: script, in: fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let before = fixture.state
        let focus = fixture.manager.focusSessionSnapshot
        let refresh = fixture.controller.layoutRefreshController
        let builds = refresh.layoutBuildMetricsCounts()
        XCTAssertNotEqual(offset, before.viewOffset)
        try await invoke(script, in: fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertNil(script.diagnostic)
        XCTAssertGreaterThan(refresh.layoutBuildMetricsCounts().totalBuilds, builds.totalBuilds, source)
        XCTAssertGreaterThan(refresh.layoutBuildMetricsCounts().completedRelayoutCycles, builds.completedRelayoutCycles)
        XCTAssertEqual(fixture.state.viewOffset, offset)
        XCTAssertEqual(fixture.state.activeColumnIndex, before.activeColumnIndex)
        XCTAssertEqual(fixture.state.selectedNodeId, before.selectedNodeId)
        XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspace))
    }

    func testPolicyRefusalReportsTheDispatchLineAndPreservesTheViewport() async throws {
        let fixture = try NiriWorkspaceScrollFixture(center: .always)
        defer { fixture.stop() }
        let script = installScript(in: fixture)
        defer { fixture.controller.stopConfigScript() }

        let target = "{ id = '\(fixture.workspace.uuidString)' }"
        let call = scrollCall(target: target, arguments: ["\(fixture.noncenteredOffset)"])
        let source = try await load(call, script: script, in: fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let before = fixture.state
        let focus = fixture.manager.focusSessionSnapshot
        let sequence = fixture.manager.worldSeq

        try await invoke(script, in: fixture)
        try assertDiagnostic(
            "workspace scroll: the Niri layout policy would move the scroll offset.",
            at: call, in: source, script: script
        )
        XCTAssertEqual(fixture.state, before)
        XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testMalformedScrollArgumentsFailAtTheDispatchCall() async throws {
        let fixture = try NiriWorkspaceScrollFixture(overscroll: true)
        defer { fixture.stop() }
        let script = installScript(in: fixture)
        defer { fixture.controller.stopConfigScript() }

        let workspace = try XCTUnwrap(fixture.manager.descriptor(for: fixture.workspace)?.name)
        let offset = String(describing: fixture.noncenteredOffset)
        let finite = "The scroll action needs a finite number of points."
        let animate = "The scroll options take only animate = true or false."
        let cases: [(arguments: [String], error: String)] = [
            ([], finite),
            (["'\(offset)'"], finite),
            (["math.huge"], finite),
            (["0 / 0"], finite),
            ([offset, "{ animate = 'yes' }"], animate),
            ([offset, "{ force = true }"], animate)
        ]
        for item in cases {
            let call = scrollCall(target: workspace, arguments: item.arguments)
            let source = try await load(call, script: script, in: fixture)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let before = fixture.state
            let sequence = fixture.manager.worldSeq
            try await invoke(script, in: fixture)
            try assertDiagnostic(item.error, at: call, in: source, script: script)
            XCTAssertEqual(fixture.state, before, call)
            XCTAssertEqual(fixture.manager.worldSeq, sequence, call)
        }
    }

    private func installScript(in fixture: NiriWorkspaceScrollFixture) -> ConfigScriptController {
        let controller = fixture.controller
        let directory = controller.settings.settingsFileURL.deletingLastPathComponent()
        let loader =
            ConfigScriptLoader(store: ConfigScriptStore(fileURL: directory.appendingPathComponent("script-store.json")))
        let script = ConfigScriptController(
            fileURL: directory.appendingPathComponent(ConfigScriptController.fileName),
            settings: controller.settings,
            loader: loader,
            wmController: controller
        ) { _ in }
        controller.configScript = script
        return script
    }

    private func scrollCall(target: String, arguments: [String]) -> String {
        let inputs = ["'workspace'", "'scroll'", target] + arguments
        return "omniwm.dispatch(\(inputs.joined(separator: ", ")))"
    }

    private func load(
        _ call: String, script: ConfigScriptController, in fixture: NiriWorkspaceScrollFixture
    ) async throws -> String {
        let source = """
        omniwm.command('\(callbackName)', function()
            \(call)
        end)
        """
        let mask = fixture.controller.settings.hyperKeyModifiers.carbonMask
        let evaluation = try await script.loader.evaluate(Data(source.utf8), hyperMask: mask)
        XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
        return source
    }

    private func invoke(_ script: ConfigScriptController, in fixture: NiriWorkspaceScrollFixture) async throws {
        let function = try XCTUnwrap(script.acceptedCommands.first { $0.name == callbackName }?.function)
        let result = fixture.controller.commandHandler.handleHotkeyInvocation(.init(command: .configFunction(function)))
        XCTAssertEqual(result, .executed)
        let queue = try XCTUnwrap(script.callbackQueue)
        await queue.waitUntilParked()
    }

    private func assertDiagnostic(
        _ message: String, at call: String, in source: String, script: ConfigScriptController
    ) throws {
        let line = try XCTUnwrap(source.split(separator: "\n").firstIndex { $0.contains(call) }) + 1
        let diagnostic = try XCTUnwrap(script.diagnostic, call)
        XCTAssertTrue(diagnostic.hasSuffix("init.luau:\(line): \(message)"), diagnostic)
    }
}
