// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptGatherTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: 1)
    private static let recipeTitle = "Gather an app group into one column"

    private func scene() async throws -> ConfigScriptWindowFixture {
        let base = try NiriGatherFixture(
            prefix: "config-gather", monitors: [display],
            workspaces: [.init(name: "1", monitor: display), .init(name: "2", monitor: display)]
        )
        let fixture = ConfigScriptWindowFixture(base: base)
        let one = base.workspace("1")
        XCTAssertTrue(base.manager.setActiveWorkspace(one, on: display.id))
        base.add([1, 2, 3, 4], to: one)
        base.add([5], to: base.workspace("2"))
        base.stack(2, onto: 1, in: one)
        try await fixture.focus(4, on: "1")
        XCTAssertEqual(base.layout(one), [[1, 2], [3], [4]])
        return fixture
    }

    private func staged(_ body: String, in fixture: ConfigScriptWindowFixture) async throws -> [ConfigScriptDispatch] {
        let source = "omniwm.command('Stage', function() \(body) end)"
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let stage = try XCTUnwrap(result.namedCommands.first)
        return try await vm.invoke(function: stage.function, context: ConfigScriptContext()).commands
    }

    private func gather(_ ids: [String], from reach: String? = nil) -> String {
        let list = ids.map { "'\($0)'" }.joined(separator: ", ")
        return "omniwm.dispatch('window', 'gather', { \(list) }\(reach.map { ", '\($0)'" } ?? ""))"
    }

    private func perform(
        _ dispatch: ConfigScriptDispatch, in fixture: ConfigScriptWindowFixture, target: ConfigScriptTarget? = nil
    ) -> ExternalCommandResult {
        let controller = fixture.base.controller
        return controller.performConfigScriptDispatch(
            dispatch.operation,
            target: target ?? controller.configScriptTarget()
        )
    }

    func testAGatherJoinsWindowsFromTwoColumnsInListOrderWithoutMovingFocus() async throws {
        let fixture = try await scene()
        let twin = try await scene()
        let base = fixture.base
        let one = base.workspace("1")
        let commands = try await staged(gather([fixture.id(3), fixture.id(1), fixture.id(2)]), in: fixture)
        XCTAssertEqual(commands.count, 1)
        guard case let .gather(request)? = commands.first?.operation else { return XCTFail("Expected a gather") }
        XCTAssertEqual(request.tokens, [3, 1, 2].map(base.token))
        XCTAssertEqual(request.reach, .workspace)
        let focus = base.manager.focusSessionSnapshot
        XCTAssertEqual(perform(commands[0], in: fixture), .executed)
        guard case .gathered = try twin.base.gather([3, 1, 2], from: .workspace) else {
            return XCTFail("The handler gathers the same windows")
        }
        XCTAssertEqual(base.layout(one), twin.base.layout(twin.base.workspace("1")))
        XCTAssertTrue(base.layout(one).contains([3, 1, 2]))
        XCTAssertEqual(base.manager.focusSessionSnapshot.nativeFocusOwner, focus.nativeFocusOwner)
        XCTAssertEqual(base.manager.focusSessionSnapshot.selectedManagedToken, focus.selectedManagedToken)
        XCTAssertEqual(perform(commands[0], in: fixture), .noChange)
    }

    func testStaleRepeatedOutOfReachAndFloatingIDsRefuseTheWholeGather() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let one = base.workspace("1")
        let session = base.controller.scriptSession.identity
        let stale = ConfigScriptWindowID.string(base.token(3), session: ConfigScriptSession(id: session.id &+ 1))
        XCTAssertTrue(base.manager.setWindowMode(.floating, for: base.token(4)))
        let layout = base.layout(one)
        let cases: [(String, String, ExternalCommandResult)] = [
            ("stale", gather([fixture.id(1), stale]), .staleWindowId),
            ("repeated", gather([fixture.id(1), fixture.id(3), fixture.id(1)]), .invalidArguments),
            ("out of reach", gather([fixture.id(1), fixture.id(5)]), .windowActionFailed),
            ("floating", gather([fixture.id(1), fixture.id(4)]), .windowActionFailed)
        ]
        for (label, body, expected) in cases {
            let commands = try await staged(body, in: fixture)
            XCTAssertEqual(perform(commands[0], in: fixture), expected, label)
            XCTAssertEqual(base.layout(one), layout, label)
            XCTAssertEqual(base.layout(base.workspace("2")), [[5]], label)
        }
        let reached = try await staged(gather([fixture.id(1), fixture.id(5)], from: "monitor"), in: fixture)
        XCTAssertEqual(perform(reached[0], in: fixture), .executed)
        XCTAssertEqual(base.layout(base.workspace("2")), [])
    }

    func testASwitchedWorkspaceBeforeTheApplyRefusesAndStopsTheBatch() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let one = base.workspace("1")
        try await fixture.load("omniwm.command('Idle', function() end)")
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        let commands = try await staged(
            gather([fixture.id(3), fixture.id(1)]) +
                " omniwm.dispatch('window', 'move-column-to-first', '\(fixture.id(4))')",
            in: fixture
        )
        XCTAssertEqual(commands.count, 2)
        let target = base.controller.configScriptTarget()
        XCTAssertTrue(base.manager.setActiveWorkspace(base.workspace("2"), on: display.id))
        let layout = base.layout(one)
        do {
            try await queue.apply(
                commands, target: target, cause: nil, controller: base.controller, owner: fixture.script
            )
            XCTFail("A refused gather stops the batch")
        } catch {
            XCTAssertEqual(error.line, commands[0].line)
        }
        XCTAssertEqual(base.layout(one), layout)
    }

    func testDisabledCommandsOrAnOpenOverviewBeforeTheApplyRefuse() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let controller = base.controller
        let layout = base.layout(base.workspace("1"))
        let commands = try await staged(gather([fixture.id(3), fixture.id(1)]), in: fixture)
        let target = controller.configScriptTarget()
        controller.isEnabled = false
        XCTAssertEqual(perform(commands[0], in: fixture, target: target), .ignoredDisabled)
        controller.isEnabled = true
        controller.toggleOverview()
        defer { if controller.isOverviewOpen() { controller.toggleOverview() } }
        XCTAssertTrue(controller.isOverviewOpen())
        XCTAssertEqual(perform(commands[0], in: fixture, target: target), .ignoredOverview)
        XCTAssertEqual(base.layout(base.workspace("1")), layout)
    }

    func testTheRecipeGathersTheGroupAndLeavesATruncatedListAlone() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let manager = base.manager
        let one = base.workspace("1")
        let recipe = try ConfigScriptWindowFixture.recipe(Self.recipeTitle)
        let pattern = try NSRegularExpression(pattern: "\\[\"([^\"]+)\"\\] = true")
        let bundles = pattern.matches(in: recipe, range: NSRange(recipe.startIndex..., in: recipe)).compactMap {
            Range($0.range(at: 1), in: recipe).map { String(recipe[$0]) }
        }
        XCTAssertEqual(bundles.count, 2)
        func label(_ window: Int, bundle: String?, title: String) throws {
            let token = base.token(window)
            let workspace = try XCTUnwrap(manager.workspace(for: token))
            XCTAssertTrue(manager.setManagedReplacementMetadata(
                .init(bundleId: bundle, workspaceId: workspace, mode: .tiling, title: title), for: token
            ))
        }
        for (window, bundle) in [(3, bundles[0]), (1, bundles[1]), (5, bundles[0])] {
            try label(window, bundle: bundle, title: "member")
        }
        try label(4, bundle: nil, title: String(repeating: "x", count: ConfigScriptSnapshot.byteLimit))
        try await fixture.load(recipe)
        let layout = base.layout(one)
        try await fixture.press("Control+Option+Shift+G")
        XCTAssertEqual(base.layout(one), layout)
        XCTAssertEqual(base.layout(base.workspace("2")), [[5]])
        try label(4, bundle: nil, title: "short")
        try await fixture.press("Control+Option+Shift+G")
        XCTAssertTrue(base.layout(one).contains { Set($0) == [1, 3, 5] })
        XCTAssertEqual(base.layout(base.workspace("2")), [])
    }

    func testTheRecipeShortcutIsFreeInTheDefaultSettings() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display])
        fixture.base.controller.settings.hotkeyBindings = DefaultHotkeyBindings.all()
        try await fixture.load(ConfigScriptWindowFixture.recipe(Self.recipeTitle))
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testTheHostTakesAListOfIDsAndAnOptionalReach() async throws {
        let fixture = try await scene()
        let id = fixture.id(1)
        let defaulted = try await staged("omniwm.dispatch('window', 'gather', { '\(id)' }, nil)", in: fixture)
        guard case let .gather(request)? = defaulted.first?.operation else { return XCTFail("Expected a gather") }
        XCTAssertEqual(request.reach, .workspace)
        for body in [
            "omniwm.dispatch('window', 'gather', 'workspace', '\(id)')",
            "omniwm.dispatch('window', 'gather', '\(id)')",
            "omniwm.dispatch('window', 'focus', { '\(id)' })",
            "omniwm.dispatch('window', 'gather', {})",
            "omniwm.dispatch('window', 'gather', { '\(id)' }, 'workspace', 'extra')"
        ] {
            do {
                _ = try await staged(body, in: fixture)
                XCTFail("Expected the host to reject: \(body)")
            } catch {
                XCTAssertTrue(error is ConfigScriptError, body)
            }
        }
    }

    func testTheReachAndEveryIDAreCheckedWhenStaged() throws {
        let id = ConfigScriptWindowID.string(
            WindowToken(pid: getpid(), windowId: 1), session: ConfigScriptSession(id: 1)
        )
        for (reach, expected) in ConfigScriptGatherRequest.reaches {
            XCTAssertEqual(try ConfigScriptGatherRequest(testWords: ["gather", reach, id]).reach, expected)
        }
        XCTAssertThrowsError(try ConfigScriptGatherRequest(testWords: ["gather", "sideways", id]))
        XCTAssertThrowsError(try ConfigScriptGatherRequest(testWords: ["gather", "all", id, "not an id"]))
        let other = ConfigScriptWindowID.string(
            WindowToken(pid: getpid(), windowId: 2), session: ConfigScriptSession(id: 2)
        )
        XCTAssertNil(try ConfigScriptGatherRequest(testWords: ["gather", "all", id, other]).session)
        XCTAssertTrue(try ConfigScriptGatherRequest(testWords: ["gather", "all", id, id]).repeated)
    }
}

extension ConfigScriptGatherRequest {
    init(testWords words: [String]) throws {
        self = try withConfigSpans(words.map { Array($0.utf8) }) { try ConfigScriptGatherRequest(words: $0) }
    }
}
