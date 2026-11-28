// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptOwnColumnTests: XCTestCase {
    private func fixture(_ layout: LayoutType = .niri) throws -> NiriGatherFixture {
        let monitor = NiriGatherFixture.monitor(displayId: 1)
        let fixture = try NiriGatherFixture(
            prefix: "own-column",
            monitors: [monitor],
            workspaces: [.init(name: "1", layoutType: layout, monitor: monitor)]
        )
        XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace("1"), on: monitor.id))
        return fixture
    }

    private func place(_ fixture: NiriGatherFixture, _ id: Int, at slot: Int) -> ExternalCommandResult {
        fixture.controller.performWindowAction(.placeInOwnColumn(slot), on: fixture.token(id))
    }

    func testAGroupMemberLeavesForAColumnOfItsOwnAtTheSlot() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2, 3, 4], to: workspace)
        fixture.stack(2, onto: 1, in: workspace)
        fixture.stack(3, onto: 1, in: workspace)
        fixture.select(1, in: workspace)
        let selection = fixture.manager.niriViewportState(for: workspace).selectedNodeId
        XCTAssertEqual(fixture.layout(workspace), [[1, 2, 3], [4]])

        XCTAssertEqual(place(fixture, 2, at: 1), .executed)
        XCTAssertEqual(fixture.layout(workspace), [[2], [1, 3], [4]])
        XCTAssertEqual(place(fixture, 3, at: 3), .executed)
        XCTAssertEqual(fixture.layout(workspace), [[2], [1], [3], [4]])
        XCTAssertEqual(fixture.manager.niriViewportState(for: workspace).selectedNodeId, selection)
    }

    func testAWindowAloneInItsColumnMovesWithItAndStaysWhenAlreadyThere() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2, 3], to: workspace)
        let last = fixture.layout(workspace).count

        XCTAssertEqual(place(fixture, 1, at: last), .executed)
        XCTAssertEqual(fixture.layout(workspace), [[2], [3], [1]])
        XCTAssertEqual(place(fixture, 1, at: last), .noChange)
        XCTAssertEqual(place(fixture, 1, at: last + 1), .noChange)
    }

    func testASlotPastTheEndPutsTheWindowLast() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2, 3], to: workspace)
        fixture.stack(2, onto: 1, in: workspace)

        XCTAssertEqual(place(fixture, 2, at: fixture.layout(workspace).count + 2), .executed)
        XCTAssertEqual(fixture.layout(workspace), [[1], [3], [2]])
    }

    func testOnlyThatWindowLeavesWhenItsSiblingIsMinimized() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2, 3], to: workspace)
        fixture.stack(2, onto: 1, in: workspace)
        XCTAssertTrue(fixture.manager.setWindowMinimized(true, token: fixture.token(2)))
        XCTAssertTrue(fixture.engine.isExcludedFromProjection(fixture.token(2), in: workspace))

        XCTAssertEqual(place(fixture, 1, at: 2), .executed)
        XCTAssertEqual(fixture.layout(workspace), [[2], [3], [1]])
        XCTAssertEqual(fixture.engine.projectedColumns(in: workspace).map { $0.windows.map(\.token) }, [
            [fixture.token(3)], [fixture.token(1)]
        ])
    }

    func testWindowsOutsideATiledNiriStripAreLeftAlone() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2], to: workspace)
        fixture.stack(2, onto: 1, in: workspace)
        XCTAssertTrue(fixture.manager.setWindowMode(.floating, for: fixture.token(2)))
        XCTAssertEqual(place(fixture, 2, at: 2), .noChange)
        let unknown = WindowToken(pid: fixture.token(1).pid, windowId: fixture.token(2).windowId + 1)
        XCTAssertEqual(fixture.controller.performWindowAction(.placeInOwnColumn(1), on: unknown), .notFound)

        let dwindle = try self.fixture(.dwindle)
        dwindle.add([1], to: dwindle.workspace("1"))
        XCTAssertEqual(place(dwindle, 1, at: 1), .ignoredLayoutMismatch)
    }

    func testEachPlacementIsOneLayoutOperationAndOneRelayoutRequest() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        fixture.add([1, 2, 3], to: workspace)
        fixture.stack(2, onto: 1, in: workspace)
        let refresh = fixture.controller.layoutRefreshController
        for (id, slot) in [(2, 3), (1, 3)] {
            let sequence = fixture.lastTraceSequence()
            refresh.performanceCounters = .init()
            XCTAssertEqual(place(fixture, id, at: slot), .executed)
            let lines = fixture.traceLines(after: sequence)
            XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
            XCTAssertEqual(lines.filter { $0.contains("event=layout_operation") }.count, 1, lines.joined())
            XCTAssertEqual(lines.filter { $0.contains("label=viewport_mutation") }.count, 1, lines.joined())
            XCTAssertEqual(refresh.performanceCounters?.refreshesEnqueued, 1)
        }
        XCTAssertEqual(fixture.layout(workspace), [[3], [2], [1]])
    }

    func testLuauStagesTheSlotAndRefusesAnythingElse() throws {
        let fixture = try fixture()
        let controller = fixture.controller
        let id = ConfigScriptWindowID.string(fixture.token(1), session: controller.scriptSession.identity)
        let request = try ConfigScriptWindowRequest(testWords: ["place-in-own-column", id, "2"])
        XCTAssertEqual(request.name, .placeInOwnColumn)
        XCTAssertEqual(request.action, .placeInOwnColumn(2))
        for words in [
            ["place-in-own-column", id], ["place-in-own-column", id, "0"], ["place-in-own-column", id, "-1"],
            ["place-in-own-column", id, "1.5"], ["place-in-own-column", id, "x"], ["place-in-own-column", id, ""]
        ] {
            XCTAssertThrowsError(try ConfigScriptWindowRequest(testWords: words), words.joined(separator: " ")) {
                XCTAssertEqual(($0 as? ConfigScriptError)?.message, "Invalid window action or arguments.")
            }
        }
        XCTAssertThrowsError(try ConfigScriptWindowRequest(
            testWords: ["place-in-own-column", id], destination: [("display", .text("1"))]
        )) {
            XCTAssertEqual(
                ($0 as? ConfigScriptError)?.message,
                "Only move-to-workspace, focus and set-floating-frame take a table."
            )
        }
        let stale = ConfigScriptWindowID.string(fixture.token(1), session: .random())
        let staleRequest = try ConfigScriptWindowRequest(testWords: ["place-in-own-column", stale, "1"])
        XCTAssertEqual(
            controller.performConfigScriptDispatch(.window(staleRequest), target: controller.configScriptTarget()),
            .staleWindowId
        )
    }
}
