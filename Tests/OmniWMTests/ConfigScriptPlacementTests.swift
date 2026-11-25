// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptPlacementTests: XCTestCase {
    private static func display(_ id: UInt32, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: frame, visibleFrame: frame, hasNotch: false,
            name: "Placement \(id)"
        )
    }

    private let sideBySide = [
        display(1, CGRect(x: 0, y: 0, width: 1_200, height: 800)),
        display(2, CGRect(x: 1_200, y: 0, width: 1_200, height: 800))
    ]

    private let stacked = [
        display(1, CGRect(x: 0, y: 0, width: 800, height: 1_200)),
        display(2, CGRect(x: 0, y: 1_200, width: 800, height: 1_200))
    ]

    private static func recipe() throws -> String {
        try ConfigScriptWindowFixture.recipe("Move a window along the strip")
    }

    func testPlacementDescribesTheFocusedWindowsColumn() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [sideBySide[0]])
        let workspace = fixture.base.workspace("1")
        let display = sideBySide[0].id.scriptIdentifier
        fixture.base.add([1, 2, 3], to: workspace)
        fixture.base.stack(2, onto: 1, in: workspace)
        try await fixture.focus(2, on: "1")
        let grouped = [
            "local p = assert(ctx.placement)",
            "assert(table.isfrozen(p) and table.isfrozen(p.members) and ctx.truncated.placement == false)",
            "assert(ctx.windows == nil and ctx.workspaceWindows == nil and ctx.monitors == nil)",
            "assert(p.workspace == '1' and p.display == '\(display)' and p.vertical == false)",
            "assert(p.column == 1 and p.columns == 2 and #p.members == 2)",
            "assert(p.members[1] == '\(fixture.id(1))' and p.members[2] == '\(fixture.id(2))')"
        ]
        try await fixture.inspect(grouped)

        fixture.base.manager.withEngineMutationScope(in: workspace) {
            let column = fixture.base.node(1, in: workspace).flatMap(fixture.base.engine.column(of:))
            XCTAssertTrue(column.map {
                fixture.base.engine.toggleColumnTabbed($0, in: workspace, motion: .disabled, orientation: .horizontal)
            } == true)
        }
        try await fixture.inspect(grouped)

        XCTAssertTrue(fixture.base.manager.setWindowMinimized(true, token: fixture.base.token(1)))
        try await fixture.inspect([
            "local p = assert(ctx.placement)",
            "assert(p.column == 1 and p.columns == 2 and #p.members == 1 and p.members[1] == '\(fixture.id(2))')"
        ])

        try await fixture.focus(3, on: "1")
        try await fixture.inspect([
            "local p = assert(ctx.placement)",
            "assert(p.column == 2 and p.columns == 2 and #p.members == 1 and p.members[1] == '\(fixture.id(3))')"
        ])
        try await fixture.focus(2, on: "1")
        XCTAssertTrue(fixture.base.manager.setWindowMinimized(true, token: fixture.base.token(3)))
        try await fixture.inspect(["local p = assert(ctx.placement)", "assert(p.column == 1 and p.columns == 1)"])
    }

    func testTheSlotWalkMatchesTheProjectionWithHiddenAndHeldWindows() throws {
        let display = sideBySide[0]
        let base = try NiriGatherFixture(
            prefix: "slot", monitors: [display], workspaces: [.init(name: "1", monitor: display)]
        )
        let workspace = base.workspace("1")
        let engine = base.engine
        base.add([1, 2, 3, 4], to: workspace)
        base.stack(2, onto: 1, in: workspace)
        func check(_ label: String) {
            let projected = engine.projectedColumns(in: workspace)
            for (offset, column) in engine.columns(in: workspace).enumerated() {
                let expected = projected.firstIndex { $0.column === column }.map { [$0, projected.count] }
                let membership = engine.projectionMembership(in: workspace)
                let slot = engine.projectedSlot(of: column, in: workspace, membership: membership)
                    .map { [$0.index, $0.count] }
                XCTAssertEqual(slot, expected, "\(label), column \(offset)")
            }
        }
        check("plain")
        let window = try XCTUnwrap(base.node(1, in: workspace))
        let column = try XCTUnwrap(engine.column(of: window))
        let context = NiriInteractionContext(
            workspaceId: workspace, motion: .disabled, workingFrame: base.controller.niriWorkingFrame(for: display),
            gaps: base.controller.innerGap(for: display), orientation: .horizontal
        )
        base.manager.withEngineMutationScope(in: workspace) {
            column.displayMode = .tabbed
            base.manager.withNiriViewportState(for: workspace) { state in
                XCTAssertTrue(engine.liveColumnMoveBegin(
                    windowId: window.id, windowToken: base.token(1), context: context, state: &state
                ))
            }
            engine.liveColumnMove?.heldTabs = column.windowNodes.filter { $0 !== window }
        }
        XCTAssertTrue(engine.isLiveHeldTab(base.token(2), in: workspace))
        XCTAssertTrue(engine.projectionExclusions(in: workspace).isEmpty)
        check("held tab")
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: base.token(4)))
        check("held tab and minimized")
    }

    func testAVerticalStripSaysSo() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [stacked[0]])
        fixture.base.add([1, 2], to: fixture.base.workspace("1"))
        try await fixture.focus(2, on: "1")
        try await fixture.inspect([
            "local p = assert(ctx.placement)",
            "assert(p.vertical == true and p.column == 2 and p.columns == 2 and #p.members == 1)"
        ])
    }

    func testWindowsOutsideATiledNiriStripGetOnlyWorkspaceAndDisplay() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: sideBySide, layouts: [.niri, .dwindle])
        fixture.base.add([1, 2], to: fixture.base.workspace("1"))
        fixture.base.add([21], to: fixture.base.workspace("2"))
        XCTAssertTrue(fixture.base.manager.setWindowMode(.floating, for: fixture.base.token(1)))
        for (window, workspace, display) in [(1, "1", sideBySide[0]), (21, "2", sideBySide[1])] {
            try await fixture.focus(window, on: workspace)
            try await fixture.inspect([
                "local p = assert(ctx.placement)",
                "assert(p.workspace == '\(workspace)' and p.display == '\(display.id.scriptIdentifier)')",
                "assert(p.column == nil and p.columns == nil and p.members == nil and p.vertical == nil)"
            ])
        }
    }

    func testPlacementIsAbsentWithoutAFocusedWindow() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [sideBySide[0]])
        fixture.base.add([1], to: fixture.base.workspace("1"))
        try await fixture.inspect(["assert(ctx.placement == nil and ctx.truncated.placement == false)"])
    }

    func testRecipeMovesAlongASideBySideStripAndAcrossDisplays() async throws {
        try await checkRecipe(on: sideBySide)
    }

    func testRecipeMovesAlongAVerticalStripAndAcrossStackedDisplays() async throws {
        try await checkRecipe(on: stacked)
    }

    private func checkRecipe(on monitors: [Monitor]) async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: monitors)
        let (one, two) = (fixture.base.workspace("1"), fixture.base.workspace("2"))
        fixture.base.add([1, 2, 3], to: one)
        fixture.base.add([21], to: two)
        fixture.base.stack(2, onto: 1, in: one)
        try await fixture.load(try Self.recipe())
        let forward = "Control+Option+Shift+]"
        let back = "Control+Option+Shift+["
        let steps: [(chord: String, from: String, one: [[Int]], two: [[Int]])] = [
            (forward, "1", [[2], [1], [3]], [[21]]),
            (forward, "1", [[2], [3], [1]], [[21]]),
            (forward, "1", [[2], [3]], [[1], [21]]),
            (back, "2", [[2], [3], [1]], [[21]]),
            (back, "1", [[2], [1], [3]], [[21]])
        ]
        for (index, step) in steps.enumerated() {
            try await fixture.focus(1, on: step.from)
            try await fixture.press(step.chord)
            XCTAssertEqual(fixture.base.layout(one), step.one, "step \(index + 1)")
            XCTAssertEqual(fixture.base.layout(two), step.two, "step \(index + 1)")
        }
    }

    func testAColumnQueuedBeyondTheWindowFirstKeepsTheEdgeMoveFromCrossing() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: sideBySide)
        let (one, two) = (fixture.base.workspace("1"), fixture.base.workspace("2"))
        fixture.base.add([1, 2, 3], to: one)
        fixture.base.add([21], to: two)
        fixture.base.stack(2, onto: 1, in: one)
        try await fixture.load(try Self.recipe() + """

        local forward = alongStrip(true)
        omniwm.command("Queue a column, then move forward", function(ctx)
            local p = ctx.placement
            if p and p.column then
                omniwm.dispatch("window", "place-in-own-column", "\(fixture.id(2))", tostring(p.columns + 1))
            end
            forward(ctx)
        end, { reads = { "placement" } })
        """)
        try await fixture.focus(3, on: "1")
        try await fixture.run(named: "Queue a column, then move forward")
        XCTAssertEqual(fixture.base.layout(one), [[1], [3], [2]])
        XCTAssertEqual(fixture.base.layout(two), [[21]])
    }
}
