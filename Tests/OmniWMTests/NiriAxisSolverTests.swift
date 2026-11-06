// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriAxisSolverTests: XCTestCase {
    private func auto(weight: CGFloat = 1, min: CGFloat = 1, max: CGFloat = 0) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: weight,
            minConstraint: min,
            maxConstraint: max,
            hasMaxConstraint: max > 0,
            isConstraintFixed: false,
            hasFixedValue: false,
            fixedValue: nil
        )
    }

    private func fixed(value: CGFloat, min: CGFloat = 1) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: 1,
            minConstraint: min,
            maxConstraint: 0,
            hasMaxConstraint: false,
            isConstraintFixed: false,
            hasFixedValue: true,
            fixedValue: value
        )
    }

    func testFeasibleMinsArePinnedExactly() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 600), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 600)
        XCTAssertEqual(outputs[1].value, 400)
    }

    func testInfeasibleInputsPreserveMinimumRatiosAndBackstop() {
        let cases: [(String, [NiriAxisSolver.Input], CGFloat, [CGFloat])] = [
            ("equalMinima", [auto(min: 800), auto(min: 800)], 1000, [500, 500]),
            ("unequalMinima", [auto(min: 900), auto(min: 300)], 800, [600, 200]),
            ("fixedValue", [fixed(value: 900, min: 100), auto(min: 700)], 600, [75, 525]),
            ("zeroSpace", [auto(min: 500), auto(min: 500)], 0, [1, 1])
        ]
        for (label, inputs, space, expected) in cases {
            let outputs = NiriAxisSolver.solve(windows: inputs, availableSpace: space, gapSize: 0)
            XCTAssertEqual(outputs.count, 2, label)
            guard outputs.count == 2 else { continue }
            for (output, value) in zip(outputs, expected) {
                XCTAssertEqual(output.value, value, label)
                XCTAssertTrue(output.wasConstrained, label)
            }
        }
    }

    func testFeasibleFixedSurplusScalingKeepsEveryFixedTileAboveItsMin() {
        let outputs = NiriAxisSolver.solve(
            windows: [fixed(value: 900, min: 100), fixed(value: 300, min: 290)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertGreaterThanOrEqual(outputs[0].value, 100)
        XCTAssertGreaterThanOrEqual(outputs[1].value, 290)
        XCTAssertEqual(outputs[0].value + outputs[1].value, 1000)
    }

    func testTabbedOversizedMinOverflows() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 2000), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0,
            isTabbed: true
        )
        XCTAssertEqual(outputs[0].value, 2000)
        XCTAssertEqual(outputs[1].value, 2000)
    }

    func testLayoutCacheInvalidatesWhenWindowConstraintsChange() throws {
        let fixture = try makeStackedEngine()
        let initialFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(initialFrames[fixture.first.token]).height, 400)

        fixture.engine.updateWindowConstraints(
            for: fixture.first.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 600),
                maxSize: .zero,
                isFixed: false
            ),
            in: fixture.workspaceId,
            motion: .enabled
        )

        let constrainedFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(constrainedFrames[fixture.first.token]).height, 600)
        XCTAssertEqual(try XCTUnwrap(constrainedFrames[fixture.second.token]).height, 200)
    }

    func testLayoutCacheInvalidatesWhenSecondaryPresetsChange() throws {
        let fixture = try makeStackedEngine()
        fixture.first.height = .preset(0)
        fixture.engine.presetWindowSecondarySpans = [.proportion(0.25)]

        let proportionalFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(proportionalFrames[fixture.first.token]).height, 200)

        fixture.engine.presetWindowSecondarySpans = [.fixed(500)]

        let fixedFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(fixedFrames[fixture.first.token]).height, 500)
        XCTAssertEqual(try XCTUnwrap(fixedFrames[fixture.second.token]).height, 300)
    }

    func testLayoutCacheInvalidatesWhenProjectionMembershipChanges() throws {
        let fixture = try makeStackedEngine()
        _ = layout(fixture)

        let excludedFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal,
            excludedTokens: [fixture.first.token]
        )

        XCTAssertNil(excludedFrames[fixture.first.token])
        XCTAssertEqual(try XCTUnwrap(excludedFrames[fixture.second.token]).height, 800)
    }

    func testLayoutCacheSeparatesOrientations() throws {
        let fixture = try makeStackedEngine()
        fixture.first.height = .fixed(200)
        fixture.first.windowWidth = .fixed(500)

        let horizontalFrames = layout(fixture)
        let verticalFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )

        XCTAssertEqual(try XCTUnwrap(horizontalFrames[fixture.first.token]).height, 200)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[fixture.first.token]).width, 500)
    }

    func testLayoutCacheTracksAvailableSpaceAndGaps() throws {
        let fixture = try makeStackedEngine()
        _ = layout(fixture)

        let resizedFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 600),
            gaps: (horizontal: 20, vertical: 20),
            orientation: .horizontal
        )
        XCTAssertEqual(try XCTUnwrap(resizedFrames[fixture.first.token]).height, 270)
        XCTAssertEqual(try XCTUnwrap(resizedFrames[fixture.second.token]).height, 270)

        let restoredFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(restoredFrames[fixture.first.token]).height, 400)
        XCTAssertEqual(try XCTUnwrap(restoredFrames[fixture.second.token]).height, 400)
    }

    func testLayoutCacheInvalidatesWhenChildIsRemoved() throws {
        let fixture = try makeStackedEngine()
        let column = try XCTUnwrap(fixture.engine.column(of: fixture.first))
        let third = NiriWindow(token: WindowToken(pid: 71_003, windowId: 3))
        column.insertChild(third, at: column.children.count)
        let initialFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(initialFrames[fixture.first.token]).height, 266.5)

        third.detach()

        let remainingFrames = layout(fixture)
        XCTAssertNil(remainingFrames[third.token])
        XCTAssertEqual(try XCTUnwrap(remainingFrames[fixture.first.token]).height, 400)
        XCTAssertEqual(try XCTUnwrap(remainingFrames[fixture.second.token]).height, 400)
    }

    func testInvalidSecondaryPresetsKeepWeightedFallbackInBothOrientations() throws {
        let fixture = try makeStackedEngine()
        fixture.engine.presetWindowSecondarySpans = [.fixed(600)]
        fixture.first.height = .preset(-1)
        fixture.first.windowWidth = .preset(1)
        fixture.second.height = .auto(weight: 1)
        fixture.second.windowWidth = .auto(weight: 1)

        let horizontalFrames = layout(fixture)
        let verticalFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )

        XCTAssertEqual(try XCTUnwrap(horizontalFrames[fixture.first.token]).height, 400)
        XCTAssertEqual(try XCTUnwrap(horizontalFrames[fixture.second.token]).height, 400)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[fixture.first.token]).width, 500)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[fixture.second.token]).width, 500)
    }

    private func makeStackedEngine() throws -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        first: NiriWindow,
        second: NiriWindow
    ) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = engine.addWindow(
            token: WindowToken(pid: 71_001, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let second = engine.addWindow(
            token: WindowToken(pid: 71_002, windowId: 2),
            to: workspaceId,
            afterSelection: first.id
        )
        let column = try XCTUnwrap(engine.column(of: first))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                second,
                into: column,
                enteringFrom: .down,
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    gaps: 0,
                    orientation: .horizontal
                ),
                state: &state
            )
        )
        return (engine, workspaceId, state, first, second)
    }

    private func layout(
        _ fixture: (
            engine: NiriLayoutEngine,
            workspaceId: WorkspaceDescriptor.ID,
            state: ViewportState,
            first: NiriWindow,
            second: NiriWindow
        )
    ) -> [WindowToken: CGRect] {
        fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
    }
}
