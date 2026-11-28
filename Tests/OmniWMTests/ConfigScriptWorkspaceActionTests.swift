// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import XCTest

@MainActor
final class ConfigScriptWorkspaceActionTests: XCTestCase {
    private let left = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
    private let callbackName = "Exercise workspace actions"
    private let work = "Work"
    private let renamed = "Mail"

    private var right: Monitor {
        NiriGatherFixture.monitor(displayId: left.displayId + 1, x: left.frame.maxX)
    }

    func testFocusNameAddressesAWorkspaceByDisplayNameNumberAndID() async throws {
        let fixture = try scene()
        let base = fixture.base
        let workID = base.workspace("2")
        _ = try await invoke([dispatch("focus-name", quoted(work))], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.manager.activeWorkspace(on: left.id)?.id, workID)

        _ = try await invoke([dispatch("focus-name", "1")], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.manager.activeWorkspace(on: left.id)?.id, base.workspace("1"))

        let byID = dispatch("focus-name", idTable(workID))
        _ = try await invoke([byID, byID], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.manager.activeWorkspace(on: left.id)?.id, workID)
    }

    func testMoveToMonitorThenRenameByID() async throws {
        let fixture = try scene()
        let base = fixture.base
        let workID = base.workspace("2")
        let move = dispatch("move-to-monitor", quoted(work), quoted("right"), "{ force = true }")
        let rename = dispatch("rename", idTable(workID), quoted(renamed))
        _ = try await invoke([move, rename], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(base.manager.monitorForWorkspace(workID)?.id, right.id)
        XCTAssertEqual(configuration("2", in: base)?.displayName, renamed)

        _ = try await invoke([rename], in: fixture)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(configuration("2", in: base)?.displayName, renamed)
    }

    func testApplyRefusalsNameTheNativeReasonAndChangeNothing() async throws {
        let fixture = try scene()
        let base = fixture.base
        let configuredNumbers = base.controller.settings.workspaces.configurations
            .compactMap { WorkspaceIDPolicy.workspaceNumber(from: $0.name) }
        let numericLabel = try String(XCTUnwrap(configuredNumbers.max()) + 1)
        setDisplayName(numericLabel, of: "3", in: base)
        let unknownID = UUID()
        let cases: [(call: String, action: String, reason: String)] = [
            (dispatch("focus-name", quoted(numericLabel)), "focus-name", "no workspace has that name or number"),
            (dispatch("focus-name", numericLabel), "focus-name", "no workspace has that name or number"),
            (dispatch("focus-name", idTable(unknownID)), "focus-name", "no workspace has that ID"),
            (
                dispatch("move-to-monitor", "1", quoted("right")), "move-to-monitor",
                "the workspace is assigned to another display; pass { force = true } to move it anyway"
            ),
            (
                dispatch("move-to-monitor", "1", quoted("up")),
                "move-to-monitor",
                "there's no display up of the workspace"
            )
        ]
        for item in cases {
            let lines = try await invoke([item.call], in: fixture)
            try assertRefusal(item.action, item.reason, at: item.call, in: lines, fixture: fixture)
        }
        setDisplayName(work, of: "3", in: base)
        let ambiguous = dispatch("focus-name", quoted(work))
        let lines = try await invoke([ambiguous], in: fixture)
        try assertRefusal(
            "focus-name",
            "more than one workspace has that name",
            at: ambiguous,
            in: lines,
            fixture: fixture
        )
        XCTAssertEqual(base.manager.monitorForWorkspace(base.workspace("1"))?.id, left.id)
        XCTAssertEqual(base.manager.activeWorkspace(on: left.id)?.id, base.workspace("1"))
    }

    func testMalformedArgumentsFailAtTheDispatchCall() async throws {
        let fixture = try scene()
        let cases: [(call: String, message: String)] = [
            (dispatch("focus-name", "0"), "expected a positive safe integer selector"),
            (dispatch("focus-name", "{ name = 'x' }"), "a workspace target table takes only id, a workspace ID string"),
            (dispatch("focus-name", "1", quoted("extra")), "The focus-name action takes only a workspace."),
            (dispatch("jump", "1"), "Unknown workspace action; use focus-name, move-to-monitor or rename."),
            (
                dispatch("move-to-monitor", "1", quoted("sideways")),
                "The move-to-monitor action needs a direction: left, right, up or down."
            ),
            (
                dispatch("move-to-monitor", "1", quoted("right"), "{ force = 'yes' }"),
                "The move-to-monitor options take only force = true or false."
            ),
            (dispatch("rename", "1", quoted("Two\\nLines")), "A workspace display name can't contain a line break.")
        ]
        for item in cases {
            let lines = try await invoke([item.call], in: fixture)
            let sourceLine = try XCTUnwrap(lines.firstIndex { $0.contains(item.call) }) + 1
            let diagnostic = try XCTUnwrap(fixture.script.diagnostic, item.call)
            XCTAssertTrue(diagnostic.contains("init.luau:\(sourceLine):"), diagnostic)
            XCTAssertTrue(diagnostic.contains(item.message), diagnostic)
        }
    }

    private func scene() throws -> ConfigScriptWindowFixture {
        let right = right
        let base = try NiriGatherFixture(
            prefix: "config-workspace-actions", monitors: [left, right],
            workspaces: [
                .init(name: "1", monitor: left),
                .init(name: "2", monitor: left),
                .init(name: "3", monitor: right)
            ]
        )
        base.controller.settings.animationsEnabled = false
        _ = base.manager.setActiveWorkspace(base.workspace("3"), on: right.id)
        _ = base.manager.setActiveWorkspace(base.workspace("1"), on: left.id)
        setDisplayName(work, of: "2", in: base)
        addTeardownBlock { @MainActor in
            base.controller.stopConfigScript()
            base.controller.layoutRefreshController.resetState()
        }
        return ConfigScriptWindowFixture(base: base)
    }

    private func configuration(_ rawName: String, in base: NiriGatherFixture) -> WorkspaceConfiguration? {
        base.controller.settings.workspaces.configurations.first { $0.name == rawName }
    }

    private func setDisplayName(_ displayName: String, of rawName: String, in base: NiriGatherFixture) {
        var configurations = base.controller.settings.workspaces.configurations
        guard let index = configurations.firstIndex(where: { $0.name == rawName }) else {
            return XCTFail("Missing workspace \(rawName)")
        }
        configurations[index].displayName = displayName
        base.controller.settings.workspaces.configurations = configurations
    }

    private func quoted(_ text: String) -> String {
        "'\(text)'"
    }

    private func idTable(_ id: WorkspaceDescriptor.ID) -> String {
        "{ id = '\(id.uuidString)' }"
    }

    private func dispatch(_ action: String, _ arguments: String...) -> String {
        "omniwm.dispatch('workspace', '\(action)', \(arguments.joined(separator: ", ")))"
    }

    private func load(_ statements: [String], in fixture: ConfigScriptWindowFixture) async throws -> [String] {
        let lines = ["omniwm.command('\(callbackName)', function()"] + statements.map { "    \($0)" } + ["end)"]
        try await fixture.load(lines.joined(separator: "\n"))
        return lines
    }

    private func invoke(_ statements: [String], in fixture: ConfigScriptWindowFixture) async throws -> [String] {
        let source = try await load(statements, in: fixture)
        let function = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == callbackName }?.function)
        XCTAssertEqual(
            fixture.base.controller.commandHandler.handleHotkeyInvocation(.init(command: .configFunction(function))),
            .executed
        )
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        await queue.waitUntilParked()
        return source
    }

    private func assertRefusal(
        _ action: String, _ reason: String, at call: String, in source: [String], fixture: ConfigScriptWindowFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let sourceLine = try XCTUnwrap(source.firstIndex { $0.contains(call) }, file: file, line: line) + 1
        let diagnostic = try XCTUnwrap(fixture.script.diagnostic, call, file: file, line: line)
        XCTAssertTrue(
            diagnostic.contains("init.luau:\(sourceLine): workspace \(action): \(reason)."),
            diagnostic,
            file: file,
            line: line
        )
    }
}
