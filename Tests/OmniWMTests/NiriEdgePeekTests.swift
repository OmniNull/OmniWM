// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePeekTests: XCTestCase {
    func testAnEngineThatNeverHadPeeksNeverSetsACap() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 99), displayId: 99, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "No peeks yet"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        var previous: NiriWindow?
        for index in 0 ..< 4 {
            previous = engine.addWindow(
                token: WindowToken(pid: 991, windowId: index + 1),
                to: workspaceId,
                afterSelection: previous?.id
            )
        }

        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)

        XCTAssertFalse(engine.hasSetEdgePeekCaps)
        XCTAssertTrue(engine.columns(in: workspaceId).allSatisfy { $0.edgePeekCap == nil })

        engine.edgePeekShare = 0.05
        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)
        XCTAssertTrue(engine.hasSetEdgePeekCaps)
        XCTAssertTrue(engine.columns(in: workspaceId).contains { $0.edgePeekCap != nil })

        engine.edgePeekShare = nil
        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)
        XCTAssertTrue(engine.columns(in: workspaceId).allSatisfy { $0.edgePeekCap == nil })
    }

    private let peek: CGFloat = 76
    private let landingGap: CGFloat = 10
    private let landingViewport: CGFloat = 1000

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let peek: CGFloat
        let orientation: Monitor.Orientation
        let scale: CGFloat
        var tokens: [WindowToken]
        var state: ViewportState

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: .disabled, workingFrame: frame, gaps: gap, orientation: orientation)
        }

        var cap: CGFloat {
            primarySpan - 2 * (peek + gap)
        }

        var primarySpan: CGFloat {
            orientation == .horizontal ? frame.width : frame.height
        }

        var primaryStart: CGFloat {
            orientation == .horizontal ? frame.minX : frame.minY
        }

        var primaryEnd: CGFloat {
            primaryStart + primarySpan
        }

        var tolerance: CGFloat {
            1 / scale / 2
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func span(of index: Int) -> ClosedRange<CGFloat> {
            if orientation == .horizontal {
                return engine.columnScreenSpan(column(index), context: context, state: state)!
            }
            var result = LayoutResult(frames: [:], hiddenHandles: [:])
            engine.calculateLayoutInto(
                result: &result, state: state, workspaceId: workspaceId,
                geometry: NiriLayoutGeometry(
                    workingArea: WorkingAreaContext(workingFrame: frame, viewFrame: frame, scale: scale),
                    gaps: LayoutGaps(horizontal: gap, vertical: gap), orientation: orientation
                ),
                animationTime: 0, hiddenPlacementMonitor: nil, hiddenPlacementMonitors: [],
                isSettled: true, recordsPresentationGeometry: true
            )
            let viewPosition = state.containerPosition(
                at: state.activeColumnIndex, containers: engine.columns(in: workspaceId), gap: gap,
                sizeKeyPath: orientation.settledSpanKeyPath
            ) + state.viewOffset
            let rect = WorkingAreaContext(workingFrame: frame, viewFrame: frame, scale: scale)
                .visibleRenderedContainerRect(
                    canonicalRect: column(index).frame!,
                    viewPosition: viewPosition,
                    workspaceOffset: 0,
                    renderOffset: .zero,
                    orientation: orientation
                )
            return rect.minY ... rect.maxY
        }

        func spans() -> [ClosedRange<CGFloat>] {
            tokens.indices.map(span(of:))
        }

        var leftPeek: CGFloat? {
            spans().last { $0.lowerBound < primaryStart - tolerance }.map { max(0, $0.upperBound - primaryStart) }
        }

        var rightPeek: CGFloat? {
            spans().first { $0.upperBound > primaryEnd + tolerance }.map { max(0, primaryEnd - $0.lowerBound) }
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

        XCTAssertEqual(
            fixture.span(of: 1).upperBound - fixture.span(of: 1).lowerBound,
            fixture.cap,
            accuracy: fixture.tolerance
        )
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - fixture.tolerance)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.rightPeek), peek - fixture.tolerance)
    }

    func testAFullWidthColumnIsCappedToLeaveBothPeeks() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.column(1).isFullWidth = true
        fixture.column(1).cachedWidth = 0

        fixture.focus(1, from: 0)

        let span = fixture.span(of: 1)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.cap, accuracy: fixture.tolerance)
        XCTAssertGreaterThanOrEqual(span.lowerBound, fixture.frame.minX + peek + fixture.gap - fixture.tolerance)
        XCTAssertLessThanOrEqual(span.upperBound, fixture.frame.maxX - peek - fixture.gap + fixture.tolerance)
    }

    func testACappedColumnStopsAtTheWidthItsWindowIsKnownToSettleAt() {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5], centering: .always)
        let hint = ObservedAxisHint(requested: fixture.cap, observed: fixture.cap + 40)
        fixture.window(1).packingHints = ObservedPackingHints(width: hint)
        fixture.column(1).cachedWidth = 0
        fixture.focus(1, from: 0)
        let column = fixture.column(1)
        XCTAssertEqual(column.edgePeekCap, fixture.cap)

        let packed = column.resolvedPrimarySpan(
            column.width, orientation: .horizontal, availableSpace: fixture.frame.width, gaps: fixture.gap
        )
        let unpacked = column.resolvedPrimarySpan(
            column.width,
            orientation: .horizontal,
            availableSpace: fixture.frame.width,
            gaps: fixture.gap,
            applyingPackingHints: false
        )

        XCTAssertEqual(packed, hint.packed(fixture.cap, limit: fixture.frame.width - 2 * fixture.gap))
        XCTAssertGreaterThan(packed, fixture.cap)
        XCTAssertEqual(unpacked, fixture.cap)
    }

    func testACappedColumnsMaximumWidthStillWinsOverItsPackedWidth() {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5], centering: .always)
        let maximum = fixture.cap + 20
        fixture.window(1).packingHints = ObservedPackingHints(
            width: ObservedAxisHint(requested: fixture.cap, observed: fixture.cap + 40)
        )
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: maximum, height: 0),
            isFixed: false
        )
        fixture.column(1).cachedWidth = 0
        fixture.focus(1, from: 0)
        let column = fixture.column(1)

        XCTAssertEqual(
            column.resolvedPrimarySpan(
                column.width, orientation: .horizontal, availableSpace: fixture.frame.width, gaps: fixture.gap
            ),
            maximum
        )
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
            accuracy: fixture.tolerance
        )
    }

    func testTheFirstColumnGoesToTheLeftEdgeWithAPeekOnlyOnTheRight() {
        var fixture = makeFixture(widths: [1.0, 0.5, 0.5])

        fixture.focus(0, from: 1)

        XCTAssertEqual(fixture.span(of: 0).lowerBound, fixture.frame.minX + fixture.gap, accuracy: fixture.tolerance)
        XCTAssertNil(fixture.leftPeek)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: fixture.tolerance)
    }

    func testTheLastColumnGoesToTheRightEdgeWithAPeekOnlyOnTheLeft() {
        var fixture = makeFixture(widths: [0.5, 0.5, 1.0])

        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)

        XCTAssertEqual(fixture.span(of: 2).upperBound, fixture.frame.maxX - fixture.gap, accuracy: fixture.tolerance)
        XCTAssertNil(fixture.rightPeek)
        XCTAssertEqual(try XCTUnwrap(fixture.leftPeek), peek, accuracy: fixture.tolerance)
    }

    func testASingleColumnHasNoPeeksAndCanBeFullWidth() {
        var fixture = makeFixture(widths: [1.0])

        fixture.focus(0, from: 0)

        XCTAssertNil(fixture.column(0).edgePeekCap)
        let span = fixture.span(of: 0)
        XCTAssertEqual(
            span.upperBound - span.lowerBound,
            fixture.frame.width - 2 * fixture.gap,
            accuracy: fixture.tolerance
        )
    }

    func testAddingASecondColumnCapsTheFirst() {
        var fixture = makeFixture(widths: [1.0])
        fixture.focus(0, from: 0)

        let token = WindowToken(pid: 951, windowId: 99)
        _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, afterSelection: fixture.window(0).id)
        fixture.tokens.append(token)
        fixture.focus(0, from: 0)

        let span = fixture.span(of: 0)
        XCTAssertEqual(span.upperBound - span.lowerBound, fixture.cap + peek, accuracy: fixture.tolerance)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: fixture.tolerance)
    }

    func testWithoutPeeksASecondColumnLeavesTheFirstAsItWas() {
        var fixture = makeFixture(widths: [1.0])
        fixture.engine.edgePeekShare = nil
        fixture.focus(0, from: 0)
        let before = fixture.span(of: 0)

        let token = WindowToken(pid: 951, windowId: 99)
        _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, afterSelection: fixture.window(0).id)
        fixture.tokens.append(token)
        fixture.focus(0, from: 0)

        let after = fixture.span(of: 0)
        XCTAssertNil(fixture.column(0).edgePeekCap)
        XCTAssertEqual(
            after.upperBound - after.lowerBound,
            before.upperBound - before.lowerBound,
            accuracy: fixture.tolerance
        )
    }

    func testTheEndColumnsGiveUpRoomForOnePeekOnly() {
        var fixture = makeFixture(widths: [1.0, 1.0, 1.0])

        fixture.focus(1, from: 0)

        XCTAssertEqual(fixture.column(0).cachedWidth, fixture.cap + peek, accuracy: fixture.tolerance)
        XCTAssertEqual(fixture.column(1).cachedWidth, fixture.cap, accuracy: fixture.tolerance)
        XCTAssertEqual(fixture.column(2).cachedWidth, fixture.cap + peek, accuracy: fixture.tolerance)
    }

    func testTheDragsPlaceholdersDontCountForTheCaps() {
        let fixture = makeFixture(widths: [1.0])
        let dropSpace = NiriContainer()
        dropSpace.isLiveDropSpace = true
        fixture.engine.root(for: fixture.workspaceId)!.insertChild(dropSpace, at: 0)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)

        XCTAssertNil(fixture.column(0).edgePeekCap)
    }

    func testTwoHalfColumnsAtTheStripStartLeaveRoomForThePeekBeyondThem() throws {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])

        fixture.focus(0, from: 1)

        XCTAssertEqual(fixture.span(of: 0).lowerBound, fixture.frame.minX + fixture.gap, accuracy: fixture.tolerance)
        XCTAssertNil(fixture.leftPeek)
        XCTAssertLessThanOrEqual(fixture.span(of: 1).upperBound, fixture.frame.maxX + fixture.tolerance)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: fixture.tolerance)
        XCTAssertEqual(fixture.column(0).width, .proportion(0.5))
    }

    func testTwoHalfColumnsAtTheStripEndLeaveRoomForThePeekBeforeThem() throws {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])

        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)

        XCTAssertEqual(fixture.span(of: 2).upperBound, fixture.frame.maxX - fixture.gap, accuracy: fixture.tolerance)
        XCTAssertNil(fixture.rightPeek)
        XCTAssertGreaterThanOrEqual(fixture.span(of: 1).lowerBound, fixture.frame.minX - fixture.tolerance)
        XCTAssertEqual(try XCTUnwrap(fixture.leftPeek), peek, accuracy: fixture.tolerance)
        XCTAssertEqual(fixture.column(2).width, .proportion(0.5))
    }

    func testStretchingAnEndColumnNarrowedForThePeekReachesThePeek() throws {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.focus(0, from: 1)
        let before = fixture.span(of: 0)

        let stretch = try XCTUnwrap(fixture.engine.columnStretchToScreenEdge(
            fixture.column(0),
            towardTrailingEdge: true,
            context: fixture.context,
            state: fixture.state
        ))
        fixture.engine.stretchColumn(
            fixture.column(0),
            to: stretch,
            towardTrailingEdge: true,
            context: fixture.context,
            state: &fixture.state
        )
        fixture.focus(0, from: 0)

        let after = fixture.span(of: 0)
        XCTAssertGreaterThan(after.upperBound - after.lowerBound, before.upperBound - before.lowerBound)
        XCTAssertEqual(after.upperBound, fixture.frame.maxX - peek - fixture.gap, accuracy: fixture.tolerance)
        XCTAssertEqual(after.lowerBound, before.lowerBound, accuracy: fixture.tolerance)
        XCTAssertEqual(try XCTUnwrap(fixture.rightPeek), peek, accuracy: fixture.tolerance)
    }

    func testAWidthChangeThatGivesAnEndColumnRoomForThePeekAnimates() throws {
        var fixture = makeFixture(widths: [0.5, 0.5, 1.0 / 3.0])
        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)
        let last = fixture.column(2)
        let context = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .enabled,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        fixture.engine.presetContainerPrimarySpans = [.proportion(1.0 / 3.0), .proportion(0.5)]
        last.presetWidthIdx = 0

        fixture.engine.toggleContainerPrimarySpan(last, forwards: true, context: context, state: &fixture.state)
        XCTAssertEqual(last.width, .proportion(0.5))
        fixture.engine.ensureSelectionVisible(
            node: fixture.window(2),
            context: context,
            state: &fixture.state,
            fromContainerIndex: 2
        )

        XCTAssertTrue(last.hasWidthAnimationRunning)
        XCTAssertNotNil(last.stripEndPeekRoom)
    }

    func testAParkedColumnTakesAWidthChangeInOneStep() {
        let fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        let parked = fixture.column(0)
        let shown = fixture.column(1)
        let start = parked.cachedWidth
        parked.isParked = true
        let target = start + 100
        let startTime: TimeInterval = 0
        for column in [parked, shown] {
            column.widthAnimation = SpringAnimation(
                from: Double(start), to: Double(target), startTime: startTime, config: .default
            )
            column.targetWidth = target
        }

        _ = fixture.engine.tickAllColumnAnimations(in: fixture.workspaceId, at: startTime)

        XCTAssertEqual(parked.cachedWidth, target)
        XCTAssertFalse(parked.hasWidthAnimationRunning)
        XCTAssertEqual(shown.cachedWidth, start)
        XCTAssertTrue(shown.hasWidthAnimationRunning)
    }

    func testOnlyAColumnHiddenOffScreenIsParked() {
        let fixture = makeFixture(widths: [0.5, 0.5, 0.5, 0.5])
        fixture.engine.edgePeekShare = nil
        var result = LayoutResult(frames: [:], hiddenHandles: [:])
        let monitor = HiddenPlacementMonitorContext(
            id: .init(displayId: 95), frame: fixture.frame, visibleFrame: fixture.frame
        )
        fixture.engine.calculateLayoutInto(
            result: &result, state: fixture.state, workspaceId: fixture.workspaceId,
            geometry: NiriLayoutGeometry(
                workingArea: WorkingAreaContext(workingFrame: fixture.frame, viewFrame: fixture.frame, scale: 1),
                gaps: LayoutGaps(horizontal: fixture.gap, vertical: fixture.gap), orientation: .horizontal
            ),
            animationTime: 0, hiddenPlacementMonitor: monitor, hiddenPlacementMonitors: [monitor],
            isSettled: true, recordsPresentationGeometry: true
        )

        XCTAssertFalse(fixture.column(0).isParked)
        XCTAssertTrue(fixture.column(3).isParked)
    }

    func testCyclingSizesNeverCoversAPeek() {
        for target in [0, 1, 3] {
            for forwards in [true, false] {
                var fixture = makeFixture(widths: [0.5, 0.5, 0.5, 0.5])
                if target > 0 {
                    for index in 1 ... target {
                        fixture.focus(index, from: index - 1)
                    }
                }
                let presets = NiriLayoutEngine.defaultPresetContainerPrimarySpans
                fixture.engine.presetContainerPrimarySpans = presets
                for press in 1 ... (presets.count * 2) {
                    fixture.engine.toggleContainerPrimarySpan(
                        fixture.column(target),
                        forwards: forwards,
                        context: fixture.context,
                        state: &fixture.state
                    )
                    fixture.engine.resolvePrimaryContainerSpans(
                        in: fixture.workspaceId,
                        workingFrame: fixture.frame,
                        gaps: fixture.gap,
                        orientation: .horizontal
                    )
                    let label = "column \(target) \(forwards ? "forward" : "backward") press \(press)"
                    let spans = fixture.spans()
                    if spans.contains(where: { $0.lowerBound < fixture.frame.minX - fixture.tolerance }) {
                        XCTAssertGreaterThanOrEqual(fixture.leftPeek ?? 0, peek - fixture.tolerance, label)
                    }
                    if spans.contains(where: { $0.upperBound > fixture.frame.maxX + fixture.tolerance }) {
                        XCTAssertGreaterThanOrEqual(fixture.rightPeek ?? 0, peek - fixture.tolerance, label)
                    }
                }
            }
        }
    }

    func testFocusingANeighbourKeepsAPeekOnBothSides() throws {
        for centering in [CenterFocusedColumn.never, .onOverflow, .always] {
            var fixture = makeFixture(widths: [0.6, 0.6, 0.6, 0.6, 0.6], centering: centering)
            for index in 1 ... 3 {
                fixture.focus(index, from: index - 1)

                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(fixture.leftPeek),
                    peek - fixture.tolerance,
                    "\(centering) \(index)"
                )
                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(fixture.rightPeek),
                    peek - fixture.tolerance,
                    "\(centering) \(index)"
                )
            }
            for index in stride(from: 2, through: 1, by: -1) {
                fixture.focus(index, from: index + 1)

                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(fixture.leftPeek),
                    peek - fixture.tolerance,
                    "\(centering) \(index)"
                )
                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(fixture.rightPeek),
                    peek - fixture.tolerance,
                    "\(centering) \(index)"
                )
            }
        }
    }

    func testANeighbourAlreadyShowingMoreThanAPeekIsLeftAsItIs() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        let offset = fixture.state.viewOffset
        let before = fixture.span(of: 2)

        fixture.focus(2, from: 1)

        XCTAssertEqual(fixture.span(of: 2).lowerBound, before.lowerBound, accuracy: fixture.tolerance)
        XCTAssertNotEqual(fixture.state.viewOffset, offset)
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

        XCTAssertEqual(full, fixture.cap, accuracy: fixture.tolerance)
        XCTAssertEqual(half, (fixture.frame.width - fixture.gap) * 0.5 - fixture.gap, accuracy: fixture.tolerance)
    }

    func testATitleBarPresetCycledAroundTheCentreStopsAtThePeek() {
        var fixture = makeFixture(widths: [0.1, 0.5, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        let before = fixture.span(of: 1)

        let nextPreset: CGFloat = 1
        fixture.engine.presetContainerPrimarySpans = [.proportion(0.5), .proportion(nextPreset)]
        fixture.column(1).presetWidthIdx = 0
        fixture.engine.cycleColumnSpanAroundCentre(fixture.column(1), context: fixture.context, state: &fixture.state)

        let after = fixture.span(of: 1)
        XCTAssertGreaterThan(after.upperBound - after.lowerBound, before.upperBound - before.lowerBound)
        XCTAssertEqual(
            after.upperBound - after.lowerBound,
            min((fixture.primarySpan - fixture.gap) * nextPreset - fixture.gap, fixture.cap),
            accuracy: fixture.tolerance
        )
        XCTAssertGreaterThanOrEqual(after.lowerBound, fixture.frame.minX + peek + fixture.gap - fixture.tolerance)
        XCTAssertLessThanOrEqual(after.upperBound, fixture.frame.maxX - peek - fixture.gap + fixture.tolerance)
    }

    func testCapsStayPutDuringALiveDragAndFollowTheDrop() {
        var fixture = makeFixture(widths: [0.5, 0.97, 0.5])
        let column = fixture.column(1)
        let middleCap = column.edgePeekCap
        XCTAssertNotNil(middleCap)
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: fixture.window(1).id,
            windowToken: fixture.tokens[1],
            context: fixture.context,
            state: &fixture.state
        ))
        let root = fixture.engine.root(for: fixture.workspaceId)!
        root.insertChild(column, at: root.children.count - 1)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)
        XCTAssertEqual(column.edgePeekCap, middleCap)

        fixture.engine.liveColumnMove = nil
        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)
        XCTAssertEqual(
            column.edgePeekCap ?? 0,
            fixture.frame.width - peek - 2 * fixture.gap,
            accuracy: fixture.tolerance
        )
    }

    func testASideEdgeDoubleClickStopsAtThePeek() throws {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        let span = fixture.span(of: 1)

        let stretch = try XCTUnwrap(fixture.engine.columnStretchToScreenEdge(
            fixture.column(1),
            towardTrailingEdge: true,
            context: fixture.context,
            state: fixture.state
        ))

        XCTAssertEqual(
            span.lowerBound + stretch.span,
            fixture.frame.maxX - peek - fixture.gap,
            accuracy: fixture.tolerance
        )
    }

    func testOnASideWithNothingBeyondAResizeReachesTheScreenEdge() throws {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3], centering: .never)
        fixture.focus(1, from: 0)
        fixture.focus(2, from: 1)
        let span = fixture.span(of: 2)

        let stretch = try XCTUnwrap(fixture.engine.columnStretchToScreenEdge(
            fixture.column(2),
            towardTrailingEdge: true,
            context: fixture.context,
            state: fixture.state
        ))

        XCTAssertEqual(span.lowerBound + stretch.span, fixture.frame.maxX - fixture.gap, accuracy: fixture.tolerance)
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
            fixture.engine.edgePeekSpans(in: fixture.workspaceId),
            EdgePeekSpans(leading: peek, trailing: 0)
        )
        let span = fixture.span(of: 1)
        XCTAssertEqual(
            span.upperBound - span.lowerBound,
            fixture.frame.width - peek - 2 * fixture.gap,
            accuracy: fixture.tolerance
        )
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.leftPeek), peek - fixture.tolerance)
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
            edgePeeks: EdgePeekSpans(leading: peek, trailing: peek)
        )).fittingArea(for: ViewportColumnTarget(
            index: 1,
            position: 0,
            span: column.cachedWidth,
            mode: column.effectiveSizingMode,
            columnCount: 3
        ))

        XCTAssertEqual(area.width, fixture.frame.width, accuracy: fixture.tolerance)
    }

    func testAScrollEndingOnAFullscreenOrMaximisedColumnLeavesItCoveringTheScreen() {
        for mode in [SizingMode.fullscreen, .maximized] {
            for snaps in [true, false] {
                let widths: [CGFloat] = [600, landingViewport, 600]
                let strip = columns(widths)
                let secondStart = widths[0] + landingGap
                let window = NiriWindow(token: WindowToken(pid: 945, windowId: 1))
                window.sizingMode = mode
                strip[1].appendChild(window)
                var state = ViewportState()
                state.endGesture(
                    currentOffset: 0,
                    projectedOffset: Double(secondStart),
                    columns: strip,
                    geometry: geometry(edgePeek: 100),
                    motion: .disabled,
                    snapToColumn: snaps
                )
                let viewStart = state.containerPosition(
                    at: state.activeColumnIndex, containers: strip, gap: landingGap, sizeKeyPath: \.cachedWidth
                ) + state.viewOffset

                XCTAssertEqual(state.activeColumnIndex, 1, "\(mode), snaps \(snaps)")
                XCTAssertEqual(viewStart, secondStart, "\(mode), snaps \(snaps)")
            }
        }
    }

    func testAScrollEndingWithTheEdgeInAGapSlidesToShowThePeek() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        let viewStart = landing(at: 225, widths: widths)

        XCTAssertEqual(viewStart, widths.prefix(3).reduce(0, +) + 3 * landingGap - landingViewport + peek)
    }

    func testAScrollEndingWithTooLittleOfTheNextColumnShowingSlidesToShowThePeek() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        let viewStart = landing(at: 250, widths: widths)

        XCTAssertEqual(viewStart, widths.prefix(3).reduce(0, +) + 3 * landingGap - landingViewport + peek)
    }

    func testAScrollEndingWithAPeekShowingDoesntMove() {
        let requestedLanding: CGFloat = 310
        let viewStart = landing(at: requestedLanding, widths: Array(repeating: 400, count: 6))

        XCTAssertEqual(viewStart, requestedLanding)
    }

    func testWhenOnePeekWouldHideTheOtherTheViewGoesToTheNearestPlaceWithBoth() throws {
        let widths: [CGFloat] = Array(repeating: 300, count: 6)

        let viewStart = landing(at: 280, widths: widths)

        let areas = ViewportFittingAreas(geometry: geometry(edgePeek: peek))
        let missing = areas.missingEdgePeeks(
            at: viewStart,
            spans: widths,
            gap: landingGap,
            peeks: EdgePeekSpans(leading: peek, trailing: peek)
        )
        XCTAssertEqual(missing.leading, 0)
        XCTAssertEqual(missing.trailing, 0)
        XCTAssertEqual(viewStart, widths.prefix(4).reduce(0, +) + 4 * landingGap - landingViewport + peek)
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
            snapToColumn: false
        )

        let viewStart = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths),
            gap: landingGap,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
        XCTAssertEqual(viewStart, widths.prefix(3).reduce(0, +) + 3 * landingGap - landingViewport + peek)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
    }

    func testAtTheStripsEndsTheScrollStillRestsAGapFromTheEdge() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)

        let stripSpan = widths.reduce(0, +) + CGFloat(widths.count - 1) * landingGap
        XCTAssertEqual(landing(at: -500, widths: widths), -landingGap)
        XCTAssertEqual(landing(at: 5000, widths: widths), stripSpan + landingGap - landingViewport)
    }

    func testWithAllowOverscrollOnTheEndColumnStillShowsAtLeastAPeek() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 5000,
            columns: columns(widths),
            geometry: NiriViewportGeometry(
                gap: landingGap,
                viewportSpan: landingViewport,
                orientation: .horizontal,
                edgeOverscroll: .enabled(visibleFraction: 0.05),
                edgePeeks: EdgePeekSpans(leading: peek, trailing: peek)
            ),
            motion: .disabled,
            snapToColumn: false
        )

        let viewStart = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths),
            gap: landingGap,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
        XCTAssertEqual(viewStart, widths.reduce(0, +) + CGFloat(widths.count - 1) * landingGap - peek)
    }

    func testWithoutPeeksAnOffsetComesBackExactlyAsItWas() {
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let areas = ViewportFittingAreas(working: frame, parent: frame, orientation: .horizontal, scale: 2)
        let target = ViewportColumnTarget(index: 1, position: 0.1, span: 400, mode: .normal)

        XCTAssertEqual(areas.offsetShowingEdgePeeks(0.2, target: target, containers: [], gap: 12), 0.2)
    }

    func testWithoutPeeksAScrollEndsWhereItLands() {
        let requestedLanding: CGFloat = 225
        XCTAssertEqual(
            landing(at: requestedLanding, widths: Array(repeating: 400, count: 6), edgePeek: nil), requestedLanding
        )
    }

    func testPrimaryAxisPeeksCoverFocusEndpointsAndFullSizeCommands() throws {
        let scenarios: [[CGFloat]] = [[0.5, 0.97, 0.5], [1.0, 0.5, 0.5], [0.5, 0.5, 1.0], [0.5, 0.5, 0.5], [1.0]]
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for widths in scenarios {
                var fixture = makeFixture(widths: widths, orientation: orientation, origin: CGPoint(x: 231, y: -347))
                for index in widths.indices {
                    fixture.focus(index, from: max(0, index - 1))
                    let expectedCap = fixture.primarySpan - 2 * fixture.gap
                        - (index > 0 ? peek : 0) - (index < widths.count - 1 ? peek : 0)
                    if widths.count == 1 {
                        XCTAssertNil(fixture.column(index).edgePeekCap)
                    } else {
                        XCTAssertEqual(fixture.column(index).edgePeekCap, expectedCap)
                    }
                    let neighbors = [index - 1, index + 1].filter { widths.indices.contains($0) }
                    for neighbor in neighbors {
                        let span = fixture.span(of: neighbor)
                        let visible = min(span.upperBound, fixture.primaryEnd) - max(
                            span.lowerBound,
                            fixture.primaryStart
                        )
                        XCTAssertGreaterThanOrEqual(
                            visible, peek - fixture.tolerance,
                            "\(orientation), \(widths), focus \(index), neighbor \(neighbor)"
                        )
                    }
                }
                let target = widths.count / 2
                fixture.focus(target, from: widths.count - 1)
                fixture.engine.toggleContainerFullPrimarySpan(
                    fixture.column(target), context: fixture.context, state: &fixture.state
                )
                fixture.focus(target, from: target)
                let span = fixture.span(of: target)
                let expected = fixture.primarySpan - 2 * fixture.gap
                    - (target > 0 ? peek : 0) - (target < widths.count - 1 ? peek : 0)
                XCTAssertEqual(span.upperBound - span.lowerBound, expected, accuracy: fixture.tolerance)
                fixture.engine.edgePeekShare = nil
                fixture.focus(target, from: target)
                XCTAssertNil(fixture.column(target).edgePeekCap)
                let uncapped = fixture.span(of: target)
                XCTAssertEqual(uncapped.upperBound - uncapped.lowerBound, fixture.primarySpan - 2 * fixture.gap)
            }
        }
    }

    func testPrimaryAxisConstraintsAndObservedSizesTakePriorityOverPeeks() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = makeFixture(widths: [0.5, 0.97, 0.5], orientation: orientation)
            let hint = ObservedAxisHint(requested: fixture.cap, observed: fixture.cap + 40)
            fixture.window(1).packingHints = orientation == .horizontal
                ? ObservedPackingHints(width: hint) : ObservedPackingHints(height: hint)
            fixture.column(1).invalidateCachedPrimarySpan(orientation: orientation)
            fixture.focus(1, from: 0)
            let column = fixture.column(1)
            let spec: ProportionalSize = .proportion(0.97)
            XCTAssertEqual(
                column.resolvedPrimarySpan(
                    spec,
                    orientation: orientation,
                    availableSpace: fixture.primarySpan,
                    gaps: fixture.gap
                ),
                hint.packed(fixture.cap, limit: fixture.primarySpan - 2 * fixture.gap)
            )
            let maximum = fixture.cap + 20
            fixture.window(1).constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 1),
                maxSize: orientation == .horizontal ? CGSize(width: maximum, height: 0) : CGSize(
                    width: 0,
                    height: maximum
                ),
                isFixed: false
            )
            XCTAssertEqual(
                column.resolvedPrimarySpan(
                    spec,
                    orientation: orientation,
                    availableSpace: fixture.primarySpan,
                    gaps: fixture.gap
                ),
                maximum
            )
            fixture.window(1).packingHints = ObservedPackingHints()
            let minimum = fixture.cap + 30
            fixture.window(1).constraints = WindowSizeConstraints(
                minSize: orientation == .horizontal ? CGSize(width: minimum, height: 1) : CGSize(
                    width: 1,
                    height: minimum
                ),
                maxSize: .zero, isFixed: false
            )
            XCTAssertEqual(
                column.resolvedPrimarySpan(
                    spec,
                    orientation: orientation,
                    availableSpace: fixture.primarySpan,
                    gaps: fixture.gap
                ),
                minimum
            )
        }
    }

    func testPrimaryAxisResizeStopsAtThePeekAndReturnsToItsStartingSpan() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = makeFixture(widths: [0.5, 0.5, 0.5], orientation: orientation)
            fixture.focus(1, from: 0)
            let startSpan = (fixture.primarySpan - fixture.gap) * 0.5 - fixture.gap
            XCTAssertTrue(fixture.engine.interactiveResizeBegin(
                windowId: fixture.window(1).id, edges: orientation == .horizontal ? .right : .top,
                startLocation: .zero, in: fixture.workspaceId, orientation: orientation
            ))
            let growth = orientation == .horizontal
                ? CGPoint(x: fixture.primarySpan, y: 0) : CGPoint(x: 0, y: fixture.primarySpan)
            let gaps = LayoutGaps(horizontal: fixture.gap, vertical: fixture.gap)
            XCTAssertTrue(fixture.engine.interactiveResizeUpdate(
                currentLocation: growth,
                monitorFrame: fixture.frame,
                gaps: gaps
            ))
            XCTAssertEqual(fixture.column(1)[keyPath: orientation.settledSpanKeyPath], fixture.cap)
            XCTAssertTrue(fixture.engine.interactiveResizeUpdate(
                currentLocation: .zero,
                monitorFrame: fixture.frame,
                gaps: gaps
            ))
            XCTAssertEqual(fixture.column(1)[keyPath: orientation.settledSpanKeyPath], startSpan)
            fixture.engine.interactiveResizeEnd(
                motion: .disabled, state: &fixture.state, workingFrame: fixture.frame, gaps: fixture.gap
            )
            XCTAssertNil(fixture.engine.interactiveResize)
        }
    }

    func testPrimaryAxisLandingAndMomentumPreserveThePeeks() {
        let widths: [CGFloat] = Array(repeating: 400, count: 6)
        let expected = widths.prefix(3).reduce(0, +) + 3 * landingGap - landingViewport + peek
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            XCTAssertEqual(landing(at: 225, widths: widths, orientation: orientation), expected)
            let strip = columns(widths, orientation: orientation)
            var state = ViewportState()
            state.endGesture(
                currentOffset: 100, projectedOffset: 225, columns: strip,
                geometry: geometry(edgePeek: peek, orientation: orientation), motion: .enabled, snapToColumn: false
            )
            let viewStart = state.containerPosition(
                at: state.activeColumnIndex, containers: strip, gap: landingGap,
                sizeKeyPath: orientation.settledSpanKeyPath
            ) + state.viewOffset
            XCTAssertEqual(viewStart, expected)
            XCTAssertEqual(state.offsetTransition.kind, .deceleration)
        }
    }

    func testPrimaryAxisFittingAreaUsesTranslatedAsymmetricDisplayInsets() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let view = CGRect(x: 137, y: -219, width: 1500, height: 1700)
            let working = CGRect(x: view.minX + 23, y: view.minY + 41, width: view.width - 52, height: view.height - 98)
            let horizontal = orientation == .horizontal
            let areas = ViewportFittingAreas(geometry: NiriViewportGeometry(
                gap: landingGap, viewportSpan: horizontal ? working.width : working.height,
                orientation: orientation, workingArea: working, viewFrame: view,
                edgePeeks: EdgePeekSpans(leading: peek, trailing: peek)
            ))
            let target = ViewportColumnTarget(index: 1, position: 0, span: 400, mode: .normal, columnCount: 3)
            let fitted = areas.fittingArea(for: target)
            let leadingInset = horizontal ? working.minX - view.minX : working.minY - view.minY
            XCTAssertEqual(areas.origin(of: fitted), peek - leadingInset)
            XCTAssertEqual(areas.span(of: fitted), (horizontal ? view.width : view.height) - 2 * peek)
            for mode in [SizingMode.maximized, .fullscreen] {
                let full = areas.fittingArea(for: ViewportColumnTarget(
                    index: 1,
                    position: 0,
                    span: 400,
                    mode: mode,
                    columnCount: 3
                ))
                XCTAssertEqual(full, areas.area(for: mode))
            }
        }
    }

    func testRotationRecomputesCapsAndTurningPeeksOffRestoresStoredSpans() throws {
        let fixture = makeFixture(widths: [0.5, 0.97, 0.5])
        let monitor = try XCTUnwrap(fixture.engine.monitorForWorkspace(fixture.workspaceId))
        let display = Monitor(
            id: monitor.id, displayId: monitor.displayId, frame: fixture.frame, visibleFrame: fixture.frame,
            hasNotch: false, name: "Rotated peeks"
        )
        let column = fixture.column(1)
        let height: CGFloat = 0.97
        column.height = .proportion(height)
        for orientation in [Monitor.Orientation.vertical, .horizontal, .vertical] {
            fixture.engine.syncWorkspaceAssignments(
                [(workspaceId: fixture.workspaceId, monitor: display)], orientations: [display.id: orientation]
            )
            fixture.engine.resolvePrimaryContainerSpans(
                in: fixture.workspaceId, workingFrame: fixture.frame, gaps: fixture.gap, orientation: orientation
            )
            let primarySpan = orientation == .horizontal ? fixture.frame.width : fixture.frame.height
            let axisPeek = (primarySpan * peek / fixture.frame.width).rounded()
            XCTAssertEqual(column.edgePeekCap, primarySpan - 2 * (axisPeek + fixture.gap))
        }
        fixture.engine.edgePeekShare = nil
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId, workingFrame: fixture.frame, gaps: fixture.gap, orientation: .vertical
        )
        XCTAssertNil(column.edgePeekCap)
        XCTAssertEqual(column.height, .proportion(height))
        XCTAssertEqual(column.cachedHeight, (fixture.frame.height - fixture.gap) * height - fixture.gap)
    }

    func testAColumnLeftOutOfTheProjectionLosesItsCapAndTheOthersKeepTheirs() {
        let fixture = makeFixture(widths: [0.5, 0.97, 0.5])
        let endCap = fixture.frame.width - peek - 2 * fixture.gap
        XCTAssertNotNil(fixture.column(1).edgePeekCap)
        XCTAssertGreaterThan(fixture.column(1).cachedWidth, 0)
        fixture.engine.setProjectionExclusions([fixture.tokens[1]], in: fixture.workspaceId)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)

        XCTAssertNil(fixture.column(1).edgePeekCap)
        XCTAssertEqual(fixture.column(1).cachedWidth, 0)
        XCTAssertEqual(fixture.column(0).edgePeekCap, endCap)
        XCTAssertEqual(fixture.column(2).edgePeekCap, endCap)
    }

    func testAnEndColumnResolvesItsWidthAgainWhenTheColumnsBeyondItChange() throws {
        let fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        let first = fixture.column(0)
        let last = fixture.column(2)
        let firstRoom = try XCTUnwrap(first.stripEndPeekRoom)
        let lastRoom = try XCTUnwrap(last.stripEndPeekRoom)
        let firstCap = first.edgePeekCap
        let lastCap = last.edgePeekCap
        fixture.column(1).width = .proportion(1.0 / 3.0)
        XCTAssertGreaterThan(first.cachedWidth, 0)
        XCTAssertGreaterThan(last.cachedWidth, 0)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)

        XCTAssertNotEqual(try XCTUnwrap(first.stripEndPeekRoom), firstRoom)
        XCTAssertNotEqual(try XCTUnwrap(last.stripEndPeekRoom), lastRoom)
        XCTAssertEqual(first.edgePeekCap, firstCap)
        XCTAssertEqual(last.edgePeekCap, lastCap)
        XCTAssertEqual(first.cachedWidth, 0)
        XCTAssertEqual(last.cachedWidth, 0)
    }

    func testASecondPassWithNothingChangedKeepsTheEndColumnsResolvedWidths() {
        let fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        let first = fixture.column(0)
        let last = fixture.column(2)
        let firstWidth = first.cachedWidth
        let lastWidth = last.cachedWidth
        XCTAssertGreaterThan(firstWidth, 0)
        XCTAssertGreaterThan(lastWidth, 0)
        XCTAssertNotNil(first.stripEndPeekRoom)
        XCTAssertNotNil(last.stripEndPeekRoom)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)

        XCTAssertEqual(first.cachedWidth, firstWidth)
        XCTAssertEqual(last.cachedWidth, lastWidth)
    }

    func testAMiddleColumnStillHoldingAnEndRoomGivesItUpAndResolvesItsWidthAgain() {
        let fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        let middle = fixture.column(1)
        let middleCap = middle.edgePeekCap
        XCTAssertNil(middle.stripEndPeekRoom)
        XCTAssertGreaterThan(middle.cachedWidth, 0)
        middle.stripEndPeekRoom = fixture.column(0).stripEndPeekRoom
        XCTAssertNotNil(middle.stripEndPeekRoom)

        fixture.engine.applyEdgePeekCaps(in: fixture.workspaceId, workingFrame: fixture.frame, gap: fixture.gap)

        XCTAssertNil(middle.stripEndPeekRoom)
        XCTAssertEqual(middle.edgePeekCap, middleCap)
        XCTAssertEqual(middle.cachedWidth, 0)
    }

    private func landing(
        at viewStart: CGFloat, widths: [CGFloat], edgePeek: CGFloat? = 76,
        orientation: Monitor.Orientation = .horizontal
    ) -> CGFloat {
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: Double(viewStart),
            columns: columns(widths, orientation: orientation),
            geometry: geometry(edgePeek: edgePeek, orientation: orientation),
            motion: .disabled,
            snapToColumn: false
        )
        return state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns(widths, orientation: orientation),
            gap: landingGap,
            sizeKeyPath: orientation.settledSpanKeyPath
        ) + state.viewOffset
    }

    private func geometry(edgePeek: CGFloat?, orientation: Monitor.Orientation = .horizontal) -> NiriViewportGeometry {
        NiriViewportGeometry(
            gap: landingGap,
            viewportSpan: landingViewport,
            orientation: orientation,
            edgePeeks: edgePeek.map { EdgePeekSpans(leading: $0, trailing: $0) }
        )
    }

    private func columns(_ widths: [CGFloat], orientation: Monitor.Orientation = .horizontal) -> [NiriContainer] {
        widths.map { width in
            let column = NiriContainer()
            if orientation == .horizontal { column.cachedWidth = width } else { column.cachedHeight = width }
            return column
        }
    }

    private func makeFixture(
        widths: [CGFloat], centering: CenterFocusedColumn = .onOverflow,
        orientation: Monitor.Orientation = .horizontal, origin: CGPoint = .zero
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = centering
        engine.policies.keepsStripEndsOnScreen = true
        let primarySpan: CGFloat = 1_500
        engine.edgePeekShare = peek / primarySpan
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(
            origin: origin,
            size: orientation == .horizontal
                ? CGSize(width: primarySpan, height: 900) : CGSize(width: 900, height: primarySpan)
        )
        let scale: CGFloat = 1
        let monitor = Monitor(
            id: Monitor.ID(displayId: 95), displayId: 95, frame: frame, visibleFrame: frame,
            hasNotch: false, backingScale: scale, name: "Edge peeks"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: orientation]
        )
        let tokens = widths.indices.map { WindowToken(pid: 951, windowId: $0 + 1) }
        var previous: NiriWindow?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            if orientation == .horizontal {
                column.width = .proportion(width)
            } else {
                column.height = .proportion(width)
            }
            column.invalidateCachedPrimarySpan(orientation: orientation)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: orientation)
        let active = engine.findNode(for: tokens[0], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = 0
        state.jumpOffset(to: -gap)
        return Fixture(
            engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, peek: peek,
            orientation: orientation, scale: scale, tokens: tokens, state: state
        )
    }
}
