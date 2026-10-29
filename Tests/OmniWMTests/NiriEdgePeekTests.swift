// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePeekTests: XCTestCase {
    private let peek: CGFloat = 76

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        var tokens: [WindowToken]
        var state: ViewportState

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: .disabled, workingFrame: frame, gaps: gap, orientation: .horizontal)
        }

        var cap: CGFloat {
            frame.width - 2 * (76 + gap)
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func span(of index: Int) -> ClosedRange<CGFloat> {
            engine.columnScreenSpan(column(index), context: context, state: state)!
        }

        func spans() -> [ClosedRange<CGFloat>] {
            tokens.indices.map(span(of:))
        }

        var leftPeek: CGFloat? {
            spans().last { $0.lowerBound < frame.minX - 0.5 }.map { max(0, $0.upperBound - frame.minX) }
        }

        var rightPeek: CGFloat? {
            spans().first { $0.upperBound > frame.maxX + 0.5 }.map { max(0, frame.maxX - $0.lowerBound) }
        }

        mutating func focus(_ index: Int, from previous: Int) {
            state.selectedNodeId = window(index).id
            engine.ensureSelectionVisible(
                node: window(index),
                context: context,
                state: &state,
                fromContainerIndex: previous
            )
        }
    }

    func testANearlyFullWidthColumnBetweenTwoOthersLeavesAPeekOnEachSide() {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5], centering: .always)

        fixture.focus(1, from: 0)

        XCTAssertEqual(fixture.span(of: 1).upperBound - fixture.span(of: 1).lowerBound, fixture.cap, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.rightPeek), peek - 0.5)
    }

    func testAFullWidthColumnIsCappedToLeaveBothPeeks() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.column(1).isFullWidth = true
        fixture.column(1).cachedWidth = 0

        fixture.focus(1, from: 0)

        let span = fixture.span(of: 1)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.cap, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(span.lowerBound, fixture.frame.minX + peek + fixture.gap - 0.5)
        XCTAssertLessThanOrEqual(span.upperBound, fixture.frame.maxX - peek - fixture.gap + 0.5)
    }

    func testTurningPeeksOffGivesTheColumnItsStoredWidthBack() {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5], centering: .always)
        fixture.focus(1, from: 0)
        let stored = fixture.column(1).width

        fixture.engine.edgePeekShare = nil
        fixture.focus(1, from: 1)

        XCTAssertEqual(fixture.column(1).width, stored)
        let span = fixture.span(of: 1)
        XCTAssertEqual(
            span.upperBound - span.lowerBound,
            (fixture.frame.width - fixture.gap) * 0.97 - fixture.gap,
            accuracy: 0.5
        )
    }

    func testTheFirstColumnGoesToTheLeftEdgeWithAPeekOnlyOnTheRight() {
        var fixture = makeFixture(widths: [1.0, 0.5, 0.5])

        fixture.focus(0, from: 1)

        XCTAssertEqual(fixture.span(of: 0).lowerBound, fixture.frame.minX + fixture.gap, accuracy: 0.5)
        XCTAssertNil(fixture.leftPeek)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: 0.5)
    }

    func testTheLastColumnGoesToTheRightEdgeWithAPeekOnlyOnTheLeft() {
        var fixture = makeFixture(widths: [0.5, 0.5, 1.0])

        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)

        XCTAssertEqual(fixture.span(of: 2).upperBound, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        XCTAssertNil(fixture.rightPeek)
        XCTAssertEqual(try XCTUnwrap(fixture.leftPeek), peek, accuracy: 0.5)
    }

    func testASingleColumnHasNoPeeksAndCanBeFullWidth() {
        var fixture = makeFixture(widths: [1.0])

        fixture.focus(0, from: 0)

        XCTAssertNil(fixture.column(0).edgePeekCap)
        let span = fixture.span(of: 0)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.frame.width - 2 * fixture.gap, accuracy: 0.5)
    }

    func testAddingASecondColumnCapsTheFirst() {
        var fixture = makeFixture(widths: [1.0])
        fixture.focus(0, from: 0)

        let token = WindowToken(pid: 951, windowId: 99)
        _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, afterSelection: fixture.window(0).id)
        fixture.tokens.append(token)
        fixture.focus(0, from: 0)

        let span = fixture.span(of: 0)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.cap + peek, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: 0.5)
    }

    func testTheEndColumnsGiveUpRoomForOnePeekOnly() {
        var fixture = makeFixture(widths: [1.0, 1.0, 1.0])

        fixture.focus(1, from: 0)

        XCTAssertEqual(fixture.column(0).cachedWidth, fixture.cap + peek, accuracy: 0.5)
        XCTAssertEqual(fixture.column(1).cachedWidth, fixture.cap, accuracy: 0.5)
        XCTAssertEqual(fixture.column(2).cachedWidth, fixture.cap + peek, accuracy: 0.5)
    }

    func testFocusingANeighbourKeepsAPeekOnBothSides() throws {
        for centering in [CenterFocusedColumn.never, .onOverflow, .always] {
            var fixture = makeFixture(widths: [0.6, 0.6, 0.6, 0.6, 0.6], centering: centering)
            for index in 1 ... 3 {
                fixture.focus(index, from: index - 1)

                XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - 0.5, "\(centering) \(index)")
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.rightPeek), peek - 0.5, "\(centering) \(index)")
            }
            for index in stride(from: 2, through: 1, by: -1) {
                fixture.focus(index, from: index + 1)

                XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - 0.5, "\(centering) \(index)")
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.rightPeek), peek - 0.5, "\(centering) \(index)")
            }
        }
    }

    func testANeighbourAlreadyShowingMoreThanAPeekIsLeftAsItIs() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        let offset = fixture.state.viewOffset
        let before = fixture.span(of: 2)

        fixture.focus(2, from: 1)

        XCTAssertEqual(fixture.span(of: 2).lowerBound, before.lowerBound, accuracy: 0.5)
        XCTAssertNotEqual(fixture.state.viewOffset, offset)
    }

    func testPeeksLeaveVerticalStripsAlone() {
        let fixture = makeFixture(widths: [0.97, 0.5])
        let columns = fixture.engine.columns(in: fixture.workspaceId)

        fixture.engine.applyEdgePeekCaps(
            to: columns,
            viewFrame: fixture.frame,
            workingFrame: fixture.frame,
            gap: fixture.gap,
            orientation: .vertical
        )

        XCTAssertTrue(columns.allSatisfy { $0.edgePeekCap == nil })
    }

    func testTheTitleBarPresetsAreCappedAtThePeek() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.focus(1, from: 0)
        let column = fixture.column(1)

        let full = column.resolvedWidthPixels(
            .proportion(1),
            availableSpan: fixture.frame.width,
            gaps: fixture.gap,
            contentInset: 0
        )
        let half = column.resolvedWidthPixels(
            .proportion(0.5),
            availableSpan: fixture.frame.width,
            gaps: fixture.gap,
            contentInset: 0
        )

        XCTAssertEqual(full, fixture.cap, accuracy: 0.5)
        XCTAssertEqual(half, (fixture.frame.width - fixture.gap) * 0.5 - fixture.gap, accuracy: 0.5)
    }

    func testASideEdgeDoubleClickStopsAtThePeek() throws {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        let span = fixture.span(of: 1)

        let stretch = try XCTUnwrap(fixture.engine.columnStretchToScreenEdge(
            fixture.column(1),
            rightSide: true,
            context: fixture.context,
            state: fixture.state
        ))

        XCTAssertEqual(span.lowerBound + stretch.width, fixture.frame.maxX - peek - fixture.gap, accuracy: 0.5)
    }

    func testOnASideWithNothingBeyondAResizeReachesTheScreenEdge() throws {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)
        let span = fixture.span(of: 2)

        let stretch = try XCTUnwrap(fixture.engine.columnStretchToScreenEdge(
            fixture.column(2),
            rightSide: true,
            context: fixture.context,
            state: fixture.state
        ))

        XCTAssertEqual(span.lowerBound + stretch.width, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
    }

    func testAnEdgeSharedWithAnotherDisplayHasNoPeek() throws {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5], centering: .always)
        let right = CGRect(x: fixture.frame.maxX, y: 0, width: 1_200, height: 900)
        let other = Monitor(
            id: Monitor.ID(displayId: 96), displayId: 96, frame: right, visibleFrame: right,
            hasNotch: false, name: "Right of edge peeks"
        )
        let otherWorkspace = WorkspaceDescriptor.ID()
        let monitor = try XCTUnwrap(fixture.engine.monitorForWorkspace(fixture.workspaceId))
        fixture.engine.syncWorkspaceAssignments(
            [
                (workspaceId: fixture.workspaceId, monitor: Monitor(
                    id: monitor.id, displayId: monitor.displayId, frame: fixture.frame, visibleFrame: fixture.frame,
                    hasNotch: false, name: "Edge peeks"
                )),
                (workspaceId: otherWorkspace, monitor: other)
            ],
            orientations: [monitor.id: .horizontal, other.id: .horizontal]
        )

        fixture.focus(1, from: 0)

        XCTAssertEqual(
            fixture.engine.edgePeekWidths(in: fixture.workspaceId),
            EdgePeekWidths(leading: peek, trailing: 0)
        )
        let span = fixture.span(of: 1)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.frame.width - peek - 2 * fixture.gap, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - 0.5)
    }

    func testAMaximisedColumnIsntCapped() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.focus(1, from: 0)
        let column = fixture.column(1)

        fixture.window(1).sizingMode = .maximized
        let area = ViewportFittingAreas(geometry: NiriViewportGeometry(
            gap: fixture.gap,
            viewportSpan: fixture.frame.width,
            orientation: .horizontal,
            workingArea: fixture.frame,
            viewFrame: fixture.frame,
            edgePeeks: EdgePeekWidths(leading: peek, trailing: peek)
        )).fittingArea(for: ViewportColumnTarget(
            index: 1,
            position: 0,
            span: column.cachedWidth,
            mode: column.effectiveSizingMode,
            columnCount: 3
        ))

        XCTAssertEqual(area.width, fixture.frame.width, accuracy: 0.5)
    }

    func testAScrollEndingWithTheEdgeInAGapSlidesToShowThePeek() {
        let viewStart = landing(at: 225, widths: Array(repeating: 400, count: 6))

        XCTAssertEqual(viewStart, 230 + peek, accuracy: 0.001)
    }

    func testAScrollEndingWithTooLittleOfTheNextColumnShowingSlidesToShowThePeek() {
        let viewStart = landing(at: 250, widths: Array(repeating: 400, count: 6))

        XCTAssertEqual(viewStart, 230 + peek, accuracy: 0.001)
    }

    func testAScrollEndingWithAPeekShowingDoesntMove() {
        let viewStart = landing(at: 310, widths: Array(repeating: 400, count: 6))

        XCTAssertEqual(viewStart, 310, accuracy: 0.001)
    }

    func testWhenOnePeekWouldHideTheOtherTheViewGoesToTheNearestPlaceWithBoth() throws {
        let widths: [CGFloat] = Array(repeating: 300, count: 6)

        let viewStart = landing(at: 280, widths: widths)

        let areas = ViewportFittingAreas(geometry: geometry(edgePeek: peek))
        let missing = areas.missingEdgePeeks(
            at: viewStart,
            spans: widths,
            gap: 10,
            peeks: EdgePeekWidths(leading: peek, trailing: peek)
        )
        XCTAssertEqual(missing.leading, 0, accuracy: 0.5)
        XCTAssertEqual(missing.trailing, 0, accuracy: 0.5)
        XCTAssertEqual(viewStart, 316, accuracy: 1)
    }

    func testAScrollEndingWithMomentumCorrectsOnlyOnceItLands() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        var state = ViewportState()
        state.endGesture(
            currentOffset: 100,
            projectedOffset: 225,
            columns: columns(widths),
            geometry: geometry(edgePeek: peek),
            motion: .enabled,
            snapToColumn: false,
            edges: .init(keepsStripEndsOnScreen: true)
        )

        let viewStart = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths),
            gap: 10,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
        XCTAssertEqual(viewStart, 230 + peek, accuracy: 0.001)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
    }

    func testAtTheStripsEndsTheScrollStillRestsAGapFromTheEdge() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)

        XCTAssertEqual(landing(at: -500, widths: widths), -10, accuracy: 0.001)
        XCTAssertEqual(landing(at: 5000, widths: widths), 2450 + 10 - 1000, accuracy: 0.001)
    }

    func testWithAllowOverscrollOnTheEndColumnStillShowsAtLeastAPeek() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 5000,
            columns: columns(widths),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 1000,
                orientation: .horizontal,
                edgeOverscroll: .enabled(visibleFraction: 0.05),
                edgePeeks: EdgePeekWidths(leading: peek, trailing: peek)
            ),
            motion: .disabled,
            snapToColumn: false,
            edges: .init(keepsStripEndsOnScreen: true)
        )

        let viewStart = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths),
            gap: 10,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
        XCTAssertEqual(viewStart, 2450 - peek, accuracy: 0.5)
    }

    func testWithoutPeeksAScrollEndsWhereItLands() {
        XCTAssertEqual(landing(at: 225, widths: Array(repeating: 400, count: 6), edgePeek: nil), 225, accuracy: 0.001)
    }

    private func landing(at viewStart: CGFloat, widths: [CGFloat], edgePeek: CGFloat? = 76) -> CGFloat {
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: Double(viewStart),
            columns: columns(widths),
            geometry: geometry(edgePeek: edgePeek),
            motion: .disabled,
            snapToColumn: false,
            edges: .init(keepsStripEndsOnScreen: true)
        )
        return state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths),
            gap: 10,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
    }

    private func geometry(edgePeek: CGFloat?) -> NiriViewportGeometry {
        NiriViewportGeometry(
            gap: 10,
            viewportSpan: 1000,
            orientation: .horizontal,
            edgePeeks: edgePeek.map { EdgePeekWidths(leading: $0, trailing: $0) }
        )
    }

    private func columns(_ widths: [CGFloat]) -> [NiriContainer] {
        widths.map { width in
            let column = NiriContainer()
            column.cachedWidth = width
            return column
        }
    }

    private func makeFixture(widths: [CGFloat], centering: CenterFocusedColumn = .onOverflow) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = centering
        engine.keepsStripEndsOnScreen = true
        engine.edgePeekShare = 76.0 / 1_500
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 95), displayId: 95, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Edge peeks"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 951, windowId: $0 + 1) }
        var previous: NiriWindow?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
            column.cachedWidth = 0
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[0], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = 0
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }
}
