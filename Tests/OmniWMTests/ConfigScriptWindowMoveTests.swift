// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

enum ConfigFieldValue {
    case text(String)
    case number(Double)
    case flag(Bool)
}

func withConfigFields<Result>(
    _ fields: [(String, ConfigFieldValue)],
    _ body: (UnsafeBufferPointer<omni_config_field>) throws -> Result
) rethrows -> Result {
    var bytes: [CChar] = []
    var ranges: [(name: Range<Int>, text: Range<Int>?)] = []
    func append(_ text: String) -> Range<Int> {
        let start = bytes.count
        bytes.append(contentsOf: text.utf8.map { CChar(bitPattern: $0) })
        return start ..< bytes.count
    }
    for (name, value) in fields {
        let nameRange = append(name)
        let textRange: Range<Int>? = if case let .text(text) = value { append(text) } else { nil }
        ranges.append((nameRange, textRange))
    }
    return try bytes.withUnsafeBufferPointer { base in
        func span(_ range: Range<Int>) -> omni_config_span {
            omni_config_span(data: base.baseAddress.map { $0 + range.lowerBound }, length: range.count)
        }
        let built = zip(fields, ranges).map { field, range in
            var result = omni_config_field()
            result.name = span(range.name)
            switch field.1 {
            case .text:
                result.kind = OMNI_CONFIG_STRING
                result.string_value = span(range.text ?? range.name.upperBound ..< range.name.upperBound)
            case let .number(value):
                result.kind = OMNI_CONFIG_NUMBER
                result.number_value = value
            case let .flag(value):
                result.kind = OMNI_CONFIG_BOOLEAN
                result.bool_value = value
            }
            return result
        }
        return try built.withUnsafeBufferPointer(body)
    }
}

@MainActor
final class ConfigScriptWindowMoveTests: XCTestCase {
    private let displays = [1, 2, 3].map { index in
        NiriGatherFixture.monitor(displayId: UInt32(index), x: CGFloat(index - 1) * 1_200)
    }

    private func fixture(
        layouts: [LayoutType] = [.niri, .niri, .niri],
        spare: Bool = false
    ) throws -> NiriGatherFixture {
        var specs = zip(displays, layouts).enumerated().map { index, pair in
            NiriGatherFixture.WorkspaceSpec(name: String(index + 1), layoutType: pair.1, monitor: pair.0)
        }
        if spare { specs.append(.init(name: spareWorkspace, layoutType: .niri, monitor: displays[1])) }
        let fixture = try NiriGatherFixture(prefix: "window-move", monitors: displays, workspaces: specs)
        for (index, display) in displays.enumerated() {
            XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace(String(index + 1)), on: display.id))
        }
        return fixture
    }

    private var spareWorkspace: String {
        String(displays.count + 1)
    }

    private func move(
        _ fixture: NiriGatherFixture,
        _ id: Int,
        _ target: WindowDisplayTarget,
        column: Int? = nil,
        edgeOf anchor: WorkspaceDescriptor.ID? = nil
    ) -> ExternalCommandResult {
        fixture.controller.performWindowAction(
            .moveToDisplay(target, column: column),
            on: fixture.token(id),
            edgeOf: anchor
        )
    }

    private func stack(
        _ id: Int,
        onto target: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        _ fixture: NiriGatherFixture
    ) {
        fixture.manager.withEngineMutationScope(in: workspaceId) {
            let engine = fixture.engine
            guard let node = fixture.node(id, in: workspaceId),
                  let source = engine.findColumn(containing: node, in: workspaceId),
                  let targetNode = fixture.node(target, in: workspaceId),
                  let column = engine.findColumn(containing: targetNode, in: workspaceId)
            else { return XCTFail("missing fixture columns") }
            engine.moveWindowToColumn(node, from: source, to: column, in: workspaceId)
            source.remove()
        }
    }

    func testDisplayDestinationsCycleThroughThreeDisplaysEachWay() throws {
        let fixture = try fixture()
        fixture.add([1], to: fixture.workspace("1"))
        for order in [[1, 2, 0], [2, 1, 0]] {
            for index in order {
                XCTAssertEqual(move(fixture, 1, .display(displays[index].id)), .executed)
                XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace(String(index + 1)))
            }
        }
    }

    func testNeighborFollowsDisplayOrderAnchorsOnOfAndStopsWithoutANeighbor() throws {
        let fixture = try fixture()
        fixture.add([1], to: fixture.workspace("1"))
        XCTAssertEqual(move(fixture, 1, .neighbor(.right, of: nil)), .executed)
        XCTAssertEqual(move(fixture, 1, .neighbor(.right, of: nil)), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace("3"))
        XCTAssertEqual(move(fixture, 1, .neighbor(.right, of: nil)), .noChange)
        XCTAssertEqual(move(fixture, 1, .neighbor(.right, of: displays[0].id)), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace("2"))
    }

    func testDisplayDestinationResolvesTheActiveWorkspaceWhenTheMoveRuns() throws {
        let fixture = try fixture(spare: true)
        fixture.add([1], to: fixture.workspace("1"))
        let action = WindowAction.moveToDisplay(.display(displays[1].id), column: nil)
        XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace(spareWorkspace), on: displays[1].id))
        XCTAssertEqual(fixture.controller.performWindowAction(action, on: fixture.token(1)), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace(spareWorkspace))
    }

    func testANonEmptyNiriDestinationGetsItsOwnColumnAndKeepsItsGroup() throws {
        let fixture = try fixture()
        let destination = fixture.workspace("2")
        fixture.add([1], to: fixture.workspace("1"))
        fixture.add([21, 22], to: destination)
        stack(22, onto: 21, in: destination, fixture)
        XCTAssertEqual(move(fixture, 1, .neighbor(.right, of: nil)), .executed)
        XCTAssertEqual(fixture.layout(destination), [[21, 22], [1]])
    }

    func testColumnInsertsAtTheVisiblePositionPastHiddenColumnsAndAppendsPastTheEnd() throws {
        let fixture = try fixture()
        let destination = fixture.workspace("2")
        fixture.add([1, 2], to: fixture.workspace("1"))
        fixture.add([29, 21, 22], to: destination)
        fixture.manager.withEngineMutationScope(in: destination) {
            fixture.engine.setProjectionExclusions([fixture.token(29)], in: destination)
        }
        XCTAssertEqual(move(fixture, 1, .display(displays[1].id), column: 1), .executed)
        XCTAssertEqual(fixture.layout(destination), [[29], [1], [21], [22]])
        let pastTheEnd = fixture.engine.projectedColumns(in: destination).count + 2
        XCTAssertEqual(move(fixture, 2, .display(displays[1].id), column: pastTheEnd), .executed)
        XCTAssertEqual(fixture.layout(destination), [[29], [1], [21], [22], [2]])
    }

    func testDwindleDestinationIgnoresTheColumnHint() throws {
        let fixture = try fixture(layouts: [.niri, .dwindle, .niri])
        fixture.add([1], to: fixture.workspace("1"))
        fixture.add([21], to: fixture.workspace("2"))
        XCTAssertEqual(move(fixture, 1, .display(displays[1].id), column: 1), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace("2"))
        XCTAssertNotNil(fixture.controller.dwindleEngine?.findNode(for: fixture.token(1), in: fixture.workspace("2")))
    }

    func testQueuedEdgePressesMoveOnceEvenWhenTheDestinationWorkspaceChanges() throws {
        let fixture = try fixture(spare: true)
        let source = fixture.workspace("1")
        fixture.add([11, 1], to: source)
        let edge = WindowDisplayTarget.neighbor(.right, of: displays[0].id)
        XCTAssertEqual(move(fixture, 1, edge, edgeOf: source), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace("2"))
        XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace(spareWorkspace), on: displays[1].id))
        XCTAssertEqual(move(fixture, 1, edge, edgeOf: source), .noChange)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), fixture.workspace("2"))
    }

    func testEdgeMovesNeedTheOutermostColumnAllowGroupMembersAndSkipFloatingWindows() throws {
        let fixture = try fixture()
        let source = fixture.workspace("1")
        let edge = WindowDisplayTarget.neighbor(.right, of: displays[0].id)
        fixture.add([1, 11, 12, 13], to: source)
        XCTAssertEqual(move(fixture, 1, edge, edgeOf: source), .noChange)
        stack(13, onto: 12, in: source, fixture)
        XCTAssertEqual(move(fixture, 13, edge, edgeOf: source), .executed)
        XCTAssertEqual(fixture.layout(fixture.workspace("2")), [[13]])
        XCTAssertEqual(fixture.layout(source), [[1], [11], [12]])
        XCTAssertTrue(fixture.manager.setWindowMode(.floating, for: fixture.token(12)))
        XCTAssertEqual(move(fixture, 12, edge, edgeOf: source), .noChange)
    }

    func testAnEdgeMoveOfAMinimizedMemberDoesNothingInsteadOfFailing() throws {
        let fixture = try fixture()
        let source = fixture.workspace("1")
        fixture.add([11, 1, 2], to: source)
        stack(2, onto: 1, in: source, fixture)
        XCTAssertTrue(fixture.manager.setWindowMinimized(true, token: fixture.token(2)))
        let edge = WindowDisplayTarget.neighbor(.right, of: displays[0].id)
        XCTAssertEqual(move(fixture, 2, edge, edgeOf: source), .noChange)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(2)), source)
    }

    func testFromEdgeOnlyAnchorsTheCallbackWindow() throws {
        let fixture = try fixture()
        let source = fixture.workspace("1")
        fixture.add([11, 1], to: source)
        XCTAssertTrue(fixture.manager.setManagedFocus(fixture.token(11), in: source))
        let controller = fixture.controller
        let session = controller.scriptSession.identity
        let fields: [(String, ConfigFieldValue)] = [
            ("neighbor", .text("right")), ("of", .text(String(displays[0].displayId))), ("fromEdge", .flag(true))
        ]
        let request = try ConfigScriptWindowRequest(
            testWords: ["move-to-workspace", ConfigScriptWindowID.string(fixture.token(1), session: session)],
            destination: fields
        )
        XCTAssertTrue(request.fromEdge)
        let target = controller.configScriptTarget()
        XCTAssertEqual(controller.performConfigScriptDispatch(.window(request), target: target), .invalidArguments)
        XCTAssertEqual(fixture.manager.workspace(for: fixture.token(1)), source)
    }

    func testDestinationTablesAreValidatedBeforeAnythingMoves() throws {
        let id = ConfigScriptWindowID.string(WindowToken(pid: getpid(), windowId: 1), session: .random())
        let display = ("display", ConfigFieldValue.text("2"))
        let cases: [([String], [(String, ConfigFieldValue)], String)] = [
            (["move-to-workspace", id], [], "either display or neighbor"),
            (["move-to-workspace", id], [display, ("neighbor", .text("left"))], "either display or neighbor"),
            (["move-to-workspace", id], [display, ("of", .text("1"))], "need neighbor"),
            (["move-to-workspace", id], [display, ("fromEdge", .flag(false))], "need neighbor"),
            (["move-to-workspace", id], [("neighbor", .text("left")), ("fromEdge", .flag(true))], "fromEdge needs of"),
            (["move-to-workspace", id], [("neighbor", .text("sideways"))], "neighbor must be"),
            (["move-to-workspace", id], [("display", .text("display:2"))], "display ID"),
            (["move-to-workspace", id], [("display", .text("02"))], "display ID"),
            (["move-to-workspace", id], [("display", .number(2))], "wrong type"),
            (["move-to-workspace", id], [display, ("column", .number(0))], "at least 1"),
            (["move-to-workspace", id], [display, ("column", .number(1.5))], "at least 1"),
            (["move-to-workspace", id], [display, ("slot", .number(1))], "Unknown window destination field"),
            (["focus", id], [display], "Only move-to-workspace"),
            (["move-to-workspace", id, "2"], [display], "Only move-to-workspace")
        ]
        for (words, fields, expected) in cases {
            XCTAssertThrowsError(try ConfigScriptWindowRequest(testWords: words, destination: fields)) { error in
                let message = (error as? ConfigScriptError)?.message ?? ""
                XCTAssertTrue(message.contains(expected), "\(words) \(fields.map(\.0)): \(message)")
            }
        }
    }

    func testLuauStagesDestinationTablesOnlyInTheDestinationPosition() async throws {
        let id = ConfigScriptWindowID.string(WindowToken(pid: getpid(), windowId: 1), session: .random())
        let source = """
        omniwm.command('Move', function()
            omniwm.dispatch('window', 'move-to-workspace', '\(id)', { neighbor = 'right', of = '2', fromEdge = true, column = 1 })
        end)
        omniwm.command('Bad', function() omniwm.dispatch('window', 'focus', '\(id)', {}) end)
        """
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let commands = result.namedCommands
        let move = try XCTUnwrap(commands.first { $0.name == "Move" })
        let staged = try await vm.invoke(function: move.function, context: ConfigScriptContext()).commands
        guard case let .window(window)? = staged.first?.operation else { return XCTFail("Expected a window request") }
        XCTAssertEqual(window.action, .moveToDisplay(.neighbor(.right, of: Monitor.ID(displayId: 2)), column: 1))
        XCTAssertTrue(window.fromEdge)
        let bad = try XCTUnwrap(commands.first { $0.name == "Bad" })
        do {
            _ = try await vm.invoke(function: bad.function, context: ConfigScriptContext())
            XCTFail("A destination table on focus must be refused")
        } catch {
            XCTAssertTrue(error.message.contains("Only move-to-workspace"), error.message)
        }
    }
}

extension ConfigScriptWindowRequest {
    init(testWords words: [String], destination: [(String, ConfigFieldValue)]) throws {
        self = try withConfigSpans(words.map { Array($0.utf8) }) { spans in
            try withConfigFields(destination) { fields in
                try ConfigScriptWindowRequest(words: spans, destination: fields)
            }
        }
    }
}
