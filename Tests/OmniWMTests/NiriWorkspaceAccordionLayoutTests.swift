// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriWorkspaceAccordionLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspace: WorkspaceDescriptor.ID

        var columns: [NiriContainer] {
            engine.columns(in: workspace)
        }
    }

    private func makeWorkspace(_ windowCounts: [Int], axis: AccordionAxis = .horizontal) throws -> Fixture {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        var nextId = 0
        for count in windowCounts {
            nextId += 1
            _ = engine.addWindow(
                token: WindowToken(pid: pid_t(nextId), windowId: nextId), to: workspace, afterSelection: nil
            )
            let column = try XCTUnwrap(engine.columns(in: workspace).last)
            for _ in 1 ..< count {
                nextId += 1
                let node = engine.addWindow(
                    token: WindowToken(pid: pid_t(nextId), windowId: nextId), to: workspace, afterSelection: nil
                )
                var state = ViewportState()
                XCTAssertTrue(engine.consumeWindow(
                    node,
                    into: column,
                    enteringFrom: .right,
                    context: .init(
                        workspaceId: workspace,
                        motion: .disabled,
                        workingFrame: screen,
                        gaps: 0,
                        orientation: .horizontal
                    ),
                    state: &state
                ))
            }
        }
        engine.updateAccordionStyle(padding: 30, axis: axis)
        engine.setAccordion(true, in: workspace)
        return Fixture(engine: engine, workspace: workspace)
    }

    private func layout(
        _ fixture: Fixture,
        active: Int,
        orientation: Monitor.Orientation = .horizontal,
        gaps: CGFloat = 0,
        viewOffset: CGFloat? = nil
    ) -> LayoutResult {
        var state = ViewportState()
        state.activeColumnIndex = active
        return fixture.engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: fixture.workspace,
            monitorFrame: screen,
            screenFrame: screen,
            gaps: (horizontal: gaps, vertical: gaps),
            orientation: orientation,
            viewOffsetOverride: viewOffset
        )
    }

    private func columnFrames(_ result: LayoutResult, _ fixture: Fixture) -> [CGRect] {
        fixture.columns.map { column in
            column.windowNodes.first.flatMap { result.frames[$0.token] } ?? .null
        }
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func testOneColumnFillsWorkingAreaAndIgnoresSingleWindowFit() throws {
        let fixture = try makeWorkspace([1])
        fixture.engine.updateConfiguration(singleWindowFit: SingleWindowFit(mode: .custom, width: 400, height: 300))

        XCTAssertEqual(columnFrames(layout(fixture, active: 0), fixture), [rect(0, 0, 1200, 800)])
    }

    func testOneColumnRespectsGaps() throws {
        let fixture = try makeWorkspace([1])

        XCTAssertEqual(columnFrames(layout(fixture, active: 0, gaps: 10), fixture), [rect(10, 10, 1180, 780)])
    }

    func testTwoColumnsHorizontal() throws {
        let fixture = try makeWorkspace([1, 1])
        let expected = [rect(0, 0, 1170, 800), rect(30, 0, 1170, 800)]

        XCTAssertEqual(columnFrames(layout(fixture, active: 0), fixture), expected)
        XCTAssertEqual(columnFrames(layout(fixture, active: 1), fixture), expected)
    }

    func testThreeColumnsHorizontalForEachActiveIndex() throws {
        let fixture = try makeWorkspace([1, 1, 1])
        let expected = [
            [rect(0, 0, 1170, 800), rect(60, 0, 1140, 800), rect(30, 0, 1170, 800)],
            [rect(0, 0, 1170, 800), rect(30, 0, 1140, 800), rect(30, 0, 1170, 800)],
            [rect(0, 0, 1170, 800), rect(0, 0, 1140, 800), rect(30, 0, 1170, 800)]
        ]

        for (active, frames) in expected.enumerated() {
            XCTAssertEqual(columnFrames(layout(fixture, active: active), fixture), frames, "active \(active)")
        }
    }

    func testTwoColumnsVertical() throws {
        let fixture = try makeWorkspace([1, 1], axis: .vertical)
        let expected = [rect(0, 0, 1200, 770), rect(0, 30, 1200, 770)]

        XCTAssertEqual(columnFrames(layout(fixture, active: 0), fixture), expected)
        XCTAssertEqual(columnFrames(layout(fixture, active: 1), fixture), expected)
    }

    func testThreeColumnsVerticalForEachActiveIndex() throws {
        let fixture = try makeWorkspace([1, 1, 1], axis: .vertical)
        let expected = [
            [rect(0, 0, 1200, 770), rect(0, 60, 1200, 740), rect(0, 30, 1200, 770)],
            [rect(0, 0, 1200, 770), rect(0, 30, 1200, 740), rect(0, 30, 1200, 770)],
            [rect(0, 0, 1200, 770), rect(0, 0, 1200, 740), rect(0, 30, 1200, 770)]
        ]

        for (active, frames) in expected.enumerated() {
            XCTAssertEqual(columnFrames(layout(fixture, active: active), fixture), frames, "active \(active)")
        }
    }

    func testAxisIgnoresMonitorOrientation() throws {
        let fixture = try makeWorkspace([1, 1])

        XCTAssertEqual(
            columnFrames(layout(fixture, active: 0, orientation: .vertical), fixture),
            [rect(0, 0, 1170, 800), rect(30, 0, 1170, 800)]
        )
    }

    func testStackedColumnStaysStackedInsideItsAccordionRect() throws {
        let fixture = try makeWorkspace([2, 1])
        let result = layout(fixture, active: 0)
        let stacked = fixture.columns[0].windowNodes
            .compactMap { result.frames[$0.token] }
            .sorted { $0.minY < $1.minY }

        XCTAssertEqual(stacked, [rect(0, 0, 1170, 400), rect(0, 400, 1170, 400)])
        XCTAssertEqual(columnFrames(result, fixture)[1], rect(30, 0, 1170, 800))
    }

    func testViewOffsetDoesNotMoveColumnsAndNothingIsHidden() throws {
        let fixture = try makeWorkspace([1, 1, 1])
        let settled = layout(fixture, active: 1)
        let scrolled = layout(fixture, active: 1, viewOffset: 5000)

        XCTAssertEqual(columnFrames(scrolled, fixture), columnFrames(settled, fixture))
        XCTAssertTrue(settled.hiddenHandles.isEmpty)
        XCTAssertTrue(scrolled.hiddenHandles.isEmpty)
    }

    func testTabbedColumnParksInactiveWindowInsideAccordion() throws {
        let fixture = try makeWorkspace([2, 1])
        let tabbed = fixture.columns[0]
        fixture.engine.setColumnDisplay(
            .tabbed, for: tabbed, in: fixture.workspace, motion: .disabled, orientation: .horizontal
        )
        let inactive = tabbed.windowNodes.filter { $0 !== tabbed.activeWindow }.map(\.token)

        let result = layout(fixture, active: 0)

        XCTAssertEqual(inactive.count, 1)
        XCTAssertEqual(Set(result.hiddenHandles.keys), Set(inactive))
    }

    func testOverlapPointHitsActiveColumn() throws {
        let fixture = try makeWorkspace([1, 1, 1])
        _ = layout(fixture, active: 1)
        let active = try XCTUnwrap(fixture.columns[1].windowNodes.first)
        let point = CGPoint(x: 600, y: 400)

        XCTAssertTrue(fixture.engine.hitTestTiled(point: point, in: fixture.workspace) === active)
        XCTAssertTrue(fixture.engine.hitTestFocusableWindow(point: point, in: fixture.workspace) === active)
        let target = fixture.engine.hitTestMoveTarget(
            point: point,
            excludingWindowId: NodeId(),
            orientation: .horizontal,
            in: fixture.workspace
        )
        guard case let .window(nodeId, _, _)? = target else {
            return XCTFail("expected a window target")
        }
        XCTAssertEqual(nodeId, active.id)
    }

    func testLeftStripHitsColumnBeforeActive() throws {
        let fixture = try makeWorkspace([1, 1, 1])
        _ = layout(fixture, active: 1)
        let previous = try XCTUnwrap(fixture.columns[0].windowNodes.first)

        XCTAssertTrue(fixture.engine.hitTestTiled(point: CGPoint(x: 15, y: 400), in: fixture.workspace) === previous)
    }

    func testHitTestColumnOrderStartsAtActiveAndBreaksTiesByLowerIndex() throws {
        let fixture = try makeWorkspace([1, 1, 1, 1, 1])
        _ = layout(fixture, active: 2)
        let ids = fixture.columns.map(\.id)

        XCTAssertEqual(
            fixture.engine.hitTestColumns(in: fixture.workspace).map(\.id),
            [ids[2], ids[1], ids[3], ids[0], ids[4]]
        )
    }

    func testHitTestColumnOrderIsPlainWhenAccordionIsOff() throws {
        let fixture = try makeWorkspace([1, 1, 1])
        _ = layout(fixture, active: 2)
        fixture.engine.setAccordion(false, in: fixture.workspace)

        XCTAssertEqual(fixture.engine.hitTestColumns(in: fixture.workspace).map(\.id), fixture.columns.map(\.id))
    }

    func testFocusRaiseOrderRaisesStackedSiblingsBeforeFocusedWindow() throws {
        let fixture = try makeWorkspace([3, 1])
        let tokens = fixture.columns[0].windowNodes.map(\.token)

        XCTAssertEqual(
            fixture.engine.accordionRaiseOrder(for: tokens[1], in: fixture.workspace),
            [tokens[0], tokens[2], tokens[1]]
        )

        fixture.engine.setAccordion(false, in: fixture.workspace)
        XCTAssertEqual(fixture.engine.accordionRaiseOrder(for: tokens[1], in: fixture.workspace), [])
    }
}
