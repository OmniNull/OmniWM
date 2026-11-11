// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriLiveColumnMoveTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let tokens: [WindowToken]
        var state: ViewportState
        var changes = 0

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: .disabled, workingFrame: frame, gaps: gap, orientation: .horizontal)
        }

        var midY: CGFloat {
            frame.midY
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func order() -> [WindowToken] {
            engine.columns(in: workspaceId).compactMap { $0.windowNodes.first?.token }
        }

        func strip() -> [LiveColumnMove.StripColumn] {
            engine.liveColumnStrip(context: context, state: state)
        }

        func dropSpace() -> LiveColumnMove.StripColumn? {
            strip().first { $0.column.isLiveDropSpace }
        }

        func landingOrder() -> [WindowToken] {
            guard let move = engine.liveColumnMove, engine.liveDropSpace(for: move) != nil else { return order() }
            let columns = engine.columns(in: workspaceId)
            let dragged = columns.first { $0.windowNodes.contains { $0.token == move.windowToken } }
            return columns.compactMap { column in
                if column.isLiveDropSpace { return dragged?.windowNodes.first?.token }
                return column === dragged ? nil : column.windowNodes.first?.token
            }
        }

        func stripColumn(holding index: Int) -> LiveColumnMove.StripColumn {
            let column = column(index)
            return strip().first { $0.column === column }!
        }

        func point(on index: Int, half: LiveColumnMove.Side) -> CGPoint {
            let placed = stripColumn(holding: index)
            let minX = max(placed.minX, frame.minX)
            let maxX = min(placed.maxX, frame.maxX)
            let middle = (minX + maxX) / 2
            let quarter = (maxX - minX) / 4
            return half == .before
                ? pointOutsideTheCentre(of: placed, preferring: minX + quarter, within: minX ... middle)
                : pointOutsideTheCentre(of: placed, preferring: maxX - quarter, within: middle ... maxX)
        }

        func pointOutsideTheCentre(
            of placed: LiveColumnMove.StripColumn,
            preferring x: CGFloat,
            within range: ClosedRange<CGFloat>
        ) -> CGPoint {
            let third = placed.width / 3
            let centre = placed.minX + third ..< placed.maxX - third
            guard placed.width >= MoveConfiguration.liveCentreMinimumWidth - 0.5, centre.contains(x) else {
                return CGPoint(x: x, y: midY)
            }
            let pieces = [
                (range.lowerBound, min(range.upperBound, centre.lowerBound)),
                (max(range.lowerBound, centre.upperBound), range.upperBound)
            ].filter { $0.1 - $0.0 > 1 }
            let widest = pieces.max { $0.1 - $0.0 < $1.1 - $1.0 }
            return CGPoint(x: widest.map { ($0.0 + $0.1) / 2 } ?? x, y: midY)
        }

        func farHalf(of index: Int) -> CGPoint {
            let placed = stripColumn(holding: index)
            let columns = engine.columns(in: workspaceId)
            guard let move = engine.liveColumnMove,
                  let home = columns.firstIndex(where: { $0.id == move.homeColumnId }),
                  let target = columns.firstIndex(where: { $0 === placed.column }),
                  home != target
            else { return CGPoint(x: placed.midX, y: midY) }
            let clippedMinX = max(placed.minX, frame.minX)
            let clippedMaxX = min(placed.maxX, frame.maxX)
            let isVisible = clippedMaxX > clippedMinX
            let minX = isVisible ? clippedMinX : placed.minX
            let maxX = isVisible ? clippedMaxX : placed.maxX
            let middle = (minX + maxX) / 2
            let quarter = (maxX - minX) / 4
            return target > home
                ? pointOutsideTheCentre(of: placed, preferring: maxX - quarter, within: middle ... maxX)
                : pointOutsideTheCentre(of: placed, preferring: minX + quarter, within: minX ... middle)
        }

        func frames() -> [WindowToken: CGRect] {
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: .horizontal
            )
        }

        mutating func begin(_ index: Int) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window(index).id,
                windowToken: tokens[index],
                context: context,
                state: &state
            )
        }

        mutating func beginActiveTab(_ index: Int) -> Bool {
            guard let shown = column(index).activeWindow else { return false }
            return engine.liveColumnMoveBegin(
                windowId: shown.id,
                windowToken: shown.token,
                context: context,
                state: &state
            )
        }

        mutating func move(to cursor: CGPoint, at time: TimeInterval = 0) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveUpdate(cursor: cursor, at: time, context: context, state: &state)
            if step.changesLayout {
                changes += 1
            }
            return step
        }

        mutating func moveAndSettle(to cursor: CGPoint) -> LiveColumnMove.Step {
            let step = move(to: cursor)
            if step.changesLayout {
                engine.liveColumnMoveSettled()
                _ = move(to: cursor)
            }
            return step
        }

        mutating func makeTabbed(_ index: Int, tabCount: Int = 3, activeTab: Int = 1) -> NiriContainer {
            var last = window(index)
            for tab in 1 ..< tabCount {
                let tabWindow = NiriWindow(token: WindowToken(pid: 932, windowId: index * 10 + tab))
                engine.attachTransferredWindow(
                    tabWindow,
                    stackedWith: last,
                    after: true,
                    in: workspaceId,
                    state: &state
                )
                last = tabWindow
            }
            let column = column(index)
            column.displayMode = .tabbed
            column.setActiveTileIdx(activeTab)
            engine.updateTabbedColumnVisibility(column: column)
            engine.renderStyle.tabIndicatorWidth = 24
            column.cachedWidth = 0
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            )
            return column
        }

        mutating func scrollSoThat(_ index: Int, startsAt x: CGFloat) {
            let current = stripColumn(holding: index).minX
            state.jumpOffset(to: state.viewOffset + current - x)
        }

        mutating func pushHalfOffScreen(_ index: Int, awayFrom target: Int) {
            let span = stripColumn(holding: index).maxX - stripColumn(holding: index).minX
            scrollSoThat(index, startsAt: target > index ? frame.minX - span / 2 : frame.maxX - span / 2)
        }
    }

    private func makeFixture(
        widths: [CGFloat] = Array(repeating: 1.0 / 3.0, count: 5),
        activeIndex: Int = 2,
        screenWidth: CGFloat = 1_500
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.liveHoverDelay = 0
        engine.applyMacOSFusion(.init(enabled: true, edgePeekShare: nil))
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: screenWidth, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 93), displayId: 93, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Live column move"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 931, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[activeIndex], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = activeIndex
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }

    private func assertTheDropSpaceIsFullyOnScreen(
        in fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let dropSpace = fixture.dropSpace() else {
            XCTFail("No drop space", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(dropSpace.minX, fixture.frame.minX + fixture.gap - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(dropSpace.maxX, fixture.frame.maxX - fixture.gap + 0.5, file: file, line: line)
    }

    func testTheHomeSlotOfALoneTabbedWindowClosesAndThenSettles() {
        var fixture = makeFixture()
        fixture.column(2).displayMode = .tabbed
        XCTAssertTrue(fixture.begin(2))
        let home = fixture.stripColumn(holding: 2)
        let pickup = CGPoint(x: home.midX, y: fixture.midY)
        XCTAssertEqual(fixture.move(to: pickup), .unchanged)
        let cursor = CGPoint(x: pickup.x + 120, y: fixture.midY)

        XCTAssertEqual(fixture.move(to: cursor), .changed)
        fixture.engine.liveColumnMoveSettled()

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        let narrowed = fixture.stripColumn(holding: 2)
        XCTAssertLessThan(narrowed.maxX - narrowed.minX, home.maxX - home.minX - 100)
    }

    func testStripMatchesTheLayoutFramesOfVisibleColumns() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.5])
        fixture.state.jumpOffset(to: -137)
        let frames = fixture.frames()
        var compared = 0
        for index in fixture.tokens.indices {
            let column = fixture.stripColumn(holding: index)
            guard column.minX >= fixture.frame.minX, column.maxX <= fixture.frame.maxX else { continue }
            let frame = frames[fixture.tokens[index]]
            XCTAssertEqual(column.minX, frame?.minX ?? .nan, accuracy: 1, "column \(index)")
            XCTAssertEqual(column.maxX, frame?.maxX ?? .nan, accuracy: 1, "column \(index)")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 2)
    }

    func testBeginKeepsEveryColumnWhereItIs() {
        var fixture = makeFixture(activeIndex: 4)
        let before = fixture.strip().map(\.minX)

        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.strip().map(\.minX), before)
        XCTAssertEqual(fixture.state.selectedNodeId, fixture.window(1).id)
        XCTAssertEqual(fixture.state.activeColumnIndex, 1)
    }

    func testBeginRefusesSingleColumnsThatCantBeCarriedAndVerticalStrips() {
        var single = makeFixture(widths: [0.5], activeIndex: 0)
        XCTAssertFalse(single.begin(0))
        XCTAssertTrue(single.engine.liveColumnMoveBegin(
            windowId: single.window(0).id,
            windowToken: single.tokens[0],
            canCarry: true,
            context: single.context,
            state: &single.state
        ))

        var vertical = makeFixture()
        let context = vertical.context.oriented(.vertical)
        XCTAssertFalse(vertical.engine.liveColumnMoveBegin(
            windowId: vertical.window(1).id,
            windowToken: vertical.tokens[1],
            context: context,
            state: &vertical.state
        ))
        XCTAssertNil(vertical.engine.liveColumnMove)
    }

    func testRestingOnTheFarThirdOfANeighbourOpensADropSpaceOnItsFarSide() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        let right = fixture.farHalf(of: 3)
        let targetBefore = fixture.stripColumn(holding: 3)

        XCTAssertEqual(fixture.moveAndSettle(to: right), .changed)

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        let dropSpace = try? XCTUnwrap(fixture.dropSpace())
        XCTAssertEqual((dropSpace?.maxX ?? 0) - (dropSpace?.minX ?? 0), fixture.frame.width * 0.05, accuracy: 0.5)
        XCTAssertLessThanOrEqual(fixture.stripColumn(holding: 2).maxX - fixture.stripColumn(holding: 2).minX, 0.5)
        assertTheDropSpaceIsFullyOnScreen(in: fixture)
        XCTAssertEqual(fixture.stripColumn(holding: 3).minX, targetBefore.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.move(to: right), .unchanged)
        let backOverTheTarget = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.moveAndSettle(to: backOverTheTarget), .unchanged)
        XCTAssertEqual(fixture.changes, 1)
    }

    func testALeftTargetGetsTheDropSpaceOnItsLeft() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        fixture.pushHalfOffScreen(3, awayFrom: 2)
        XCTAssertTrue(fixture.begin(3))
        let left = fixture.farHalf(of: 2)

        XCTAssertEqual(fixture.moveAndSettle(to: left), .changed)

        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        assertTheDropSpaceIsFullyOnScreen(in: fixture)
        XCTAssertTrue(fixture.stripColumn(holding: 2).contains(x: left.x))
    }

    func testTheKeepVisibleScrollNeverSlidesTheTargetFromUnderThePointer() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let target = fixture.stripColumn(holding: 1)
        let offScreenTarget = CGPoint(x: target.minX + (target.maxX - target.minX) / 4, y: fixture.midY)
        XCTAssertLessThan(offScreenTarget.x, fixture.frame.minX)

        XCTAssertEqual(fixture.moveAndSettle(to: offScreenTarget), .changed)

        let underPointer = fixture.strip().first { $0.contains(x: offScreenTarget.x) }
        XCTAssertTrue(underPointer?.column === fixture.column(1) || underPointer?.column.isLiveDropSpace == true)
        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.changes, 1)
    }

    func testTheKeepVisibleScrollStopsShortOfAPartlyHiddenTargetsMiddleThird() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        let span = fixture.stripColumn(holding: 3).width
        XCTAssertGreaterThanOrEqual(span, MoveConfiguration.liveCentreMinimumWidth)
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))
        let cursor = CGPoint(x: fixture.frame.maxX - span / 5, y: fixture.midY)
        let targetBefore = fixture.stripColumn(holding: 3)
        XCTAssertLessThan(cursor.x, targetBefore.minX + span / 3)

        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        let target = fixture.stripColumn(holding: 3)
        XCTAssertLessThan(target.minX, targetBefore.minX - 0.5)
        XCTAssertLessThan(cursor.x, target.minX + span / 3)
        XCTAssertGreaterThan(cursor.x, target.minX + span / 3 - 2)
        let dropSpace = try? XCTUnwrap(fixture.dropSpace())
        XCTAssertGreaterThanOrEqual(dropSpace?.minX ?? 0, fixture.frame.maxX)

        for time in [0.1, fixture.engine.liveCentreStackDelay + 0.1, 2] {
            XCTAssertEqual(fixture.move(to: cursor, at: time), .unchanged, "\(time)")
        }
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        XCTAssertEqual(fixture.engine.liveColumnMove?.landingIsHint, false)
        XCTAssertEqual(fixture.stripColumn(holding: 3).minX, target.minX, accuracy: 0.5)
        XCTAssertNotNil(fixture.dropSpace())
    }

    func testTheDropSpaceIsFivePercentOfTheScreenAndAtMostTwoHundredPoints() {
        for (screenWidth, expected) in [(1_512.0, 75.6), (2_560.0, 128.0), (4_500.0, 200.0)] as [(CGFloat, CGFloat)] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), screenWidth: screenWidth)
            fixture.pushHalfOffScreen(2, awayFrom: 3)
            XCTAssertTrue(fixture.begin(2))

            XCTAssertEqual(
                fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
                .changed
            )

            let dropSpace = fixture.dropSpace()
            XCTAssertEqual((dropSpace?.maxX ?? 0) - (dropSpace?.minX ?? 0), expected, accuracy: 0.5, "\(screenWidth)")
        }
    }

    func testTheDropSpaceStaysInTheStripWhenTheWorkspaceHasHiddenWindows() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        fixture.engine.setProjectionExclusions([fixture.tokens[6]], in: fixture.workspaceId)
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))

        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )

        let dropSpace = try? XCTUnwrap(fixture.dropSpace())
        XCTAssertEqual((dropSpace?.maxX ?? 0) - (dropSpace?.minX ?? 0), fixture.frame.width * 0.05, accuracy: 0.5)
        XCTAssertEqual(fixture.strip().count, 7)
    }

    func testTheHomeSlotOfATabbedColumnWithAHiddenTabClosesAndThenSettles() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        fixture.engine.setProjectionExclusions([tabbed.windowNodes[2].token], in: fixture.workspaceId)
        XCTAssertTrue(fixture.beginActiveTab(2))
        let home = fixture.stripColumn(holding: 2)
        let pickup = CGPoint(x: home.midX, y: fixture.midY)
        XCTAssertEqual(fixture.move(to: pickup), .unchanged)
        let cursor = CGPoint(x: pickup.x + 120, y: fixture.midY)

        XCTAssertEqual(fixture.move(to: cursor), .changed)
        fixture.engine.liveColumnMoveSettled()

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        let narrowed = fixture.stripColumn(holding: 2)
        XCTAssertLessThan(narrowed.maxX - narrowed.minX, home.maxX - home.minX - 100)
    }

    func testStackedTargetGetsOneDropSpaceBesideTheWholeColumn() {
        var fixture = makeFixture()
        let extra = WindowToken(pid: 931, windowId: 98)
        fixture.engine.attachTransferredWindow(
            NiriWindow(token: extra),
            stackedWith: fixture.window(3),
            after: true,
            in: fixture.workspaceId,
            state: &fixture.state
        )
        let stacked = fixture.column(3)
        let heights = stacked.windowNodes.map(\.height)
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        let frames = fixture.frames()
        let top = try? XCTUnwrap(frames[fixture.tokens[3]])
        let bottom = try? XCTUnwrap(frames[extra])

        XCTAssertEqual(fixture.moveAndSettle(to: CGPoint(x: fixture.farHalf(of: 3).x, y: top?.midY ?? 0)), .changed)
        let afterFirst = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.farHalf(of: 3).x, y: bottom?.midY ?? 0)),
            .unchanged
        )

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), afterFirst)
        XCTAssertEqual(stacked.windowNodes.map(\.token), [fixture.tokens[3], extra])
        XCTAssertEqual(stacked.windowNodes.map(\.height), heights)
        XCTAssertEqual(fixture.changes, 1)
    }

    func testWindowMostlyOffEitherEdgeChangesExactlyOnce() {
        for edge in ["right", "left"] {
            var fixture = makeFixture()
            let (dragged, target) = edge == "right" ? (2, 3) : (2, 1)
            let span = fixture.stripColumn(holding: target).maxX - fixture.stripColumn(holding: target).minX
            if edge == "right" {
                fixture.scrollSoThat(target, startsAt: fixture.frame.maxX - span / 3)
            } else {
                fixture.scrollSoThat(target, startsAt: fixture.frame.minX - span * 2 / 3)
            }
            XCTAssertTrue(fixture.begin(dragged), edge)
            let cursor = fixture.farHalf(of: target)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, edge)
            XCTAssertNotNil(fixture.dropSpace(), edge)
            for _ in 0 ..< 5 {
                XCTAssertEqual(fixture.move(to: cursor), .unchanged, edge)
            }
            var swapped = fixture.tokens
            swapped.swapAt(dragged, target)
            XCTAssertEqual(fixture.landingOrder(), swapped, edge)
        }
    }

    func testADropSpaceOpeningEntirelyOffScreenComesInToTheScreenEdge() {
        for edge in ["right", "left"] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 3)
            let (dragged, target) = edge == "right" ? (2, 3) : (3, 2)
            let span = fixture.stripColumn(holding: target).maxX - fixture.stripColumn(holding: target).minX
            fixture.scrollSoThat(
                target,
                startsAt: edge == "right" ? fixture.frame.maxX - span + 20 : fixture.frame.minX - 20
            )
            XCTAssertTrue(fixture.begin(dragged), edge)
            let cursor = fixture.farHalf(of: target)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, edge)

            let dropSpace = fixture.dropSpace()
            if edge == "right" {
                XCTAssertEqual(dropSpace?.maxX ?? 0, fixture.frame.maxX - fixture.gap, accuracy: 0.5, edge)
            } else {
                XCTAssertEqual(dropSpace?.minX ?? 0, fixture.frame.minX + fixture.gap, accuracy: 0.5, edge)
            }
            assertTheDropSpaceIsFullyOnScreen(in: fixture)
            XCTAssertEqual(fixture.move(to: cursor), .unchanged, edge)
        }
    }

    func testWithThePointerAtTheScreenEdgeTheDropSpaceStopsFlushWithIt() {
        for edge in ["right", "left"] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 3)
            let (dragged, target) = edge == "right" ? (2, 3) : (3, 2)
            let span = fixture.stripColumn(holding: target).maxX - fixture.stripColumn(holding: target).minX
            fixture.scrollSoThat(
                target,
                startsAt: edge == "right" ? fixture.frame.maxX - span + 20 : fixture.frame.minX - 20
            )
            XCTAssertTrue(fixture.begin(dragged), edge)
            let cursor = CGPoint(
                x: edge == "right" ? fixture.frame.maxX - 20 : fixture.frame.minX + 20,
                y: fixture.midY
            )

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, edge)

            let dropSpace = fixture.dropSpace()
            if edge == "right" {
                XCTAssertEqual(dropSpace?.maxX ?? 0, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
            } else {
                XCTAssertEqual(dropSpace?.minX ?? 0, fixture.frame.minX + fixture.gap, accuracy: 0.5)
            }
            XCTAssertEqual(fixture.move(to: cursor), .unchanged, edge)
        }
    }

    func testTheDropSpaceWidthDependsOnlyOnTheScreenAndTheWindowKeepsItsOwn() {
        for (dragged, target) in [(1, 2), (2, 1)] {
            var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0], activeIndex: 1)
            if dragged == 2 {
                fixture.engine.columns(in: fixture.workspaceId)[1].width = .proportion(2.0 / 3.0)
                fixture.engine.columns(in: fixture.workspaceId)[2].width = .proportion(1.0 / 3.0)
                fixture.engine.columns(in: fixture.workspaceId).forEach { $0.cachedWidth = 0 }
            }
            let ownWidth = fixture.column(dragged).width
            fixture.pushHalfOffScreen(dragged, awayFrom: target)
            XCTAssertTrue(fixture.begin(dragged))
            let cursor = fixture.farHalf(of: target)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

            let dropSpace = try? XCTUnwrap(fixture.dropSpace())
            XCTAssertEqual((dropSpace?.maxX ?? 0) - (dropSpace?.minX ?? 0), fixture.frame.width * 0.05, accuracy: 0.5)
            assertTheDropSpaceIsFullyOnScreen(in: fixture)
            let landing = fixture.landingOrder()

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.order(), landing)
            XCTAssertEqual(fixture.column(dragged).width, ownWidth)
            XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, fixture.tokens.count)
        }
    }

    func testWalkingAcrossTheStripMovesTheLandingPlaceOncePerColumnAndNeverBack() {
        var fixture = makeFixture(activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        var cursorX = fixture.stripColumn(holding: 0).midX
        var landingIndex = 0
        var changes = 0
        while cursorX < fixture.frame.maxX - 1 {
            cursorX += 8
            _ = fixture.moveAndSettle(to: CGPoint(x: cursorX, y: fixture.midY))
            let index = fixture.landingOrder().firstIndex(of: fixture.tokens[0])!
            if index != landingIndex {
                changes += 1
                XCTAssertEqual(index, landingIndex + 1)
                landingIndex = index
            }
        }
        XCTAssertGreaterThanOrEqual(changes, 2)
        let landing = fixture.landingOrder()
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), landing)
    }

    func testStripStartShowsAsMuchOfTheDropSpaceAsItCanWithoutALock() {
        var fixture = makeFixture(widths: [2.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0], activeIndex: 1)
        fixture.scrollSoThat(0, startsAt: fixture.frame.minX + fixture.gap)
        XCTAssertTrue(fixture.begin(1))
        let cursor = fixture.farHalf(of: 0)

        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        XCTAssertTrue(fixture.strip().first?.column.isLiveDropSpace == true)
        XCTAssertEqual(fixture.strip().first?.minX ?? 0, fixture.frame.minX + fixture.gap, accuracy: 0.5)
        let stillOverTheTarget = fixture.point(on: 0, half: .before)
        XCTAssertEqual(fixture.move(to: stillOverTheTarget), .unchanged)
        XCTAssertEqual(fixture.changes, 1)
    }

    func testStripEndStopsTheScrollWithTheDropSpaceLast() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0], activeIndex: 3)
        let lastSpan = fixture.stripColumn(holding: 3).maxX - fixture.stripColumn(holding: 3).minX
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - fixture.gap - lastSpan)
        XCTAssertTrue(fixture.begin(2))
        let cursor = CGPoint(x: fixture.stripColumn(holding: 3).maxX - 10, y: fixture.midY)

        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        XCTAssertTrue(fixture.strip().last?.column.isLiveDropSpace == true)
        XCTAssertEqual(fixture.strip().last?.maxX ?? 0, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        for _ in 0 ..< 5 {
            XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        }
        XCTAssertEqual(fixture.changes, 1)
    }

    func testAfterTheStripScrolledFarTheDropStaysWhereTheDropSpaceWas() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 9), activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + 2_000)
        let target = try? XCTUnwrap(fixture.strip().first { $0.column !== fixture.column(0) && $0.minX > 400 })
        XCTAssertEqual(
            fixture.moveAndSettle(to: CGPoint(x: (target?.maxX ?? 0) - (target?.width ?? 0) / 4, y: fixture.midY)),
            .changed
        )
        let dropSpace = try? XCTUnwrap(fixture.dropSpace())

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        let landed = fixture.stripColumn(holding: 0)
        XCTAssertEqual(landed.minX, dropSpace?.minX ?? 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(landed.minX, fixture.frame.minX)
        XCTAssertLessThan(landed.minX, fixture.frame.maxX)
    }

    func testTheDroppedWindowGlidesFromWhereItWasReleasedNotFromItsHomeSpot() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        let animated = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .enabled,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        let dragged = fixture.column(2)
        let positions = fixture.engine.primaryPositions(context: animated, state: fixture.state)
        let homePosition = positions[dragged.id] ?? 0
        let viewBefore = fixture.engine
            .liveViewPosition(positions: positions, context: animated, state: fixture.state) ?? 0
        let releasedAt = fixture.stripColumn(holding: 3).maxX - 150

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: CGRect(x: releasedAt, y: 0, width: 0, height: 0),
            context: animated,
            state: &fixture.state
        ))

        let landedPosition = fixture.engine.primaryPositions(context: animated, state: fixture.state)[dragged.id] ?? 0
        let releasePosition = releasedAt - fixture.frame.minX + viewBefore
        XCTAssertEqual(dragged.moveAnimation?.fromOffset ?? 0, releasePosition - landedPosition, accuracy: 0.5)
        XCTAssertNotEqual(releasePosition, homePosition, accuracy: 1)
    }

    func testTwoVisibleNeighboursStayVisibleAfterTheDropInEitherDirection() {
        for (dragged, target) in [(0, 1), (1, 0)] {
            var fixture = makeFixture(widths: [0.5, 0.5, 0.5], activeIndex: 0)
            let visible = { (fixture: Fixture, index: Int) -> Bool in
                let column = fixture.stripColumn(holding: index)
                return column.minX >= fixture.frame.minX - 0.5 && column.maxX <= fixture.frame.maxX + 0.5
            }
            XCTAssertTrue(visible(fixture, 0) && visible(fixture, 1))
            let firstSlot = fixture.stripColumn(holding: 0).minX
            XCTAssertTrue(fixture.begin(dragged))

            XCTAssertEqual(
                fixture.moveAndSettle(to: fixture.farHalf(of: target)),
                .changed
            )
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

            XCTAssertEqual(fixture.order(), [1, 0, 2].map { fixture.tokens[$0] }, "\(dragged)")
            XCTAssertTrue(visible(fixture, 0), "\(dragged)")
            XCTAssertTrue(visible(fixture, 1), "\(dragged)")
            XCTAssertEqual(fixture.stripColumn(holding: 1).minX, firstSlot, accuracy: 0.5, "\(dragged)")
        }
    }

    func testTheLeftHalfLandsBeforeTheTargetAndTheRightHalfAfter() {
        for (half, expected) in [(LiveColumnMove.Side.before, [1, 2, 0, 3, 4]), (.after, [1, 2, 3, 0, 4])] {
            var fixture = makeFixture(widths: Array(repeating: 0.18, count: 5), activeIndex: 0)
            XCTAssertTrue(fixture.begin(0))

            XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: half)), .changed, "\(half)")
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

            XCTAssertEqual(fixture.order(), expected.map { fixture.tokens[$0] }, "\(half)")
        }
    }

    func testAPartlyHiddenTargetLandsOnTheSideOfTheHalfOfItsVisiblePart() {
        for (half, expected) in [(LiveColumnMove.Side.before, [0, 1, 3, 2, 4, 5, 6]), (.after, [0, 1, 3, 4, 2, 5, 6])] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
            let span = fixture.stripColumn(holding: 4).maxX - fixture.stripColumn(holding: 4).minX
            fixture.scrollSoThat(4, startsAt: fixture.frame.maxX - span / 2)
            XCTAssertTrue(fixture.begin(2))

            XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 4, half: half)), .changed, "\(half)")

            XCTAssertEqual(fixture.landingOrder(), expected.map { fixture.tokens[$0] }, "\(half)")
        }
    }

    func testRestingOnTheHalfOfANeighbourFacingTheWindowsPlaceChangesNothing() {
        var fixture = makeFixture(widths: Array(repeating: 0.18, count: 5), activeIndex: 0)
        XCTAssertTrue(fixture.begin(1))
        let order = fixture.landingOrder()

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(holding: 2).minX + 10, y: fixture.midY))
        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(holding: 0).maxX - 10, y: fixture.midY))

        XCTAssertEqual(fixture.landingOrder(), order)
        XCTAssertNil(fixture.engine.liveColumnMove?.lockedTarget)
    }

    func testRestingOnTheHalfFacingTheWindowsPlaceLandsItBackThere() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .after)), .changed)
        XCTAssertNotNil(fixture.dropSpace())

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .before)), .changed)

        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testComingBackKeepsAPartlyHiddenTargetStill() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.9, 1.0 / 3.0, 1.0 / 3.0])
        let span = fixture.stripColumn(holding: 3).maxX - fixture.stripColumn(holding: 3).minX
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .after)), .changed)
        XCTAssertNotNil(fixture.dropSpace())
        let cursor = fixture.point(on: 3, half: .before)
        let targetBefore = fixture.stripColumn(holding: 3)

        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        let target = fixture.stripColumn(holding: 3)
        XCTAssertEqual(target.minX, targetBefore.minX, accuracy: 0.5)
        XCTAssertTrue(target.contains(x: cursor.x))
        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
    }

    func testAStillPointerCausesNoSecondChangeAfterComingBack() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.9, 1.0 / 3.0, 1.0 / 3.0])
        let span = fixture.stripColumn(holding: 3).maxX - fixture.stripColumn(holding: 3).minX
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .after)), .changed)
        let cursor = fixture.point(on: 3, half: .before)
        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        for offset in [0.0, 4.0, -4.0, 0.0] {
            XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + offset, y: cursor.y)), .unchanged, "\(offset)")
        }
        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertEqual(fixture.changes, 2)
    }

    func testAStillPointerCausesNoSecondChangeAfterAHalfChange() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        let span = fixture.stripColumn(holding: 4).maxX - fixture.stripColumn(holding: 4).minX
        fixture.scrollSoThat(4, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))
        let cursor = fixture.point(on: 4, half: .before)
        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        for offset in [0.0, 4.0, -4.0] {
            XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + offset, y: cursor.y)), .unchanged, "\(offset)")
        }
        XCTAssertEqual(fixture.changes, 1)
    }

    func testAMoveDuringSettlingStillChangesTheTarget() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let right = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.move(to: right), .changed)
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .settling)
        let far = fixture.farHalf(of: 0)

        XCTAssertEqual(fixture.move(to: far), .changed)
    }

    func testAStillPointerCausesNoSecondChangeWhileSettling() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let right = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.move(to: right), .changed)
        let order = fixture.order()

        XCTAssertEqual(fixture.move(to: CGPoint(x: right.x + 4, y: right.y + 4)), .unchanged)
        XCTAssertEqual(fixture.move(to: right), .unchanged)
        XCTAssertEqual(fixture.order(), order)
    }

    func testAChangeMidTransitionStartsFromTheWindowsOnScreen() {
        var fixture = makeFixture(widths: Array(repeating: 0.2, count: 7), activeIndex: 2)
        let clock = AnimationClock(time: 100)
        fixture.engine.animationClock = clock
        let animated = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .enabled,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: fixture.window(2).id,
            windowToken: fixture.tokens[2],
            context: animated,
            state: &fixture.state
        ))
        let first = fixture.farHalf(of: 3)
        XCTAssertEqual(
            fixture.engine.liveColumnMoveUpdate(cursor: first, at: 0, context: animated, state: &fixture.state),
            .changed
        )
        let second = fixture.farHalf(of: 4)
        let moment = clock.now()
        let before = renderedFrames(fixture, at: moment)

        XCTAssertEqual(
            fixture.engine.liveColumnMoveUpdate(cursor: second, at: 0, context: animated, state: &fixture.state),
            .changed
        )

        let after = renderedFrames(fixture, at: moment)
        for token in fixture.tokens where token != fixture.tokens[2] {
            XCTAssertEqual(after[token]?.minX ?? .nan, before[token]?.minX ?? .nan, accuracy: 2, "\(token)")
        }
    }

    func testTheDropSpaceFollowsAFastDragAcrossSeveralColumns() {
        let targets = [3, 4, 5]
        var slow = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        XCTAssertTrue(slow.begin(2))
        for target in targets {
            _ = slow.moveAndSettle(to: slow.farHalf(of: target))
        }
        XCTAssertTrue(slow.engine.liveColumnMoveEnd(context: slow.context, state: &slow.state))

        var fast = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        XCTAssertTrue(fast.begin(2))
        for target in targets {
            XCTAssertEqual(fast.move(to: fast.farHalf(of: target)), .changed, "\(target) \(fast.landingOrder())")
        }
        XCTAssertTrue(fast.engine.liveColumnMoveEnd(context: fast.context, state: &fast.state))

        XCTAssertEqual(fast.order(), slow.order())
    }

    private func renderedFrames(_ fixture: Fixture, at time: TimeInterval) -> [WindowToken: CGRect] {
        fixture.engine.calculateLayoutWithVisibility(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.frame,
            gaps: (fixture.gap, fixture.gap),
            orientation: .horizontal,
            animationTime: time
        ).frames
    }

    func testCancelRestoresOrderWidthsAndViewport() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0, 0.5, 1.0 / 3.0], activeIndex: 4)
        fixture.state.jumpOffset(to: 40)
        let original = fixture.state
        let order = fixture.order()
        let widths = fixture.engine.columns(in: fixture.workspaceId)
            .map { fixture.engine.containerSizingState(for: $0) }
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 4)),
            .changed
        )

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), order)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).map { fixture.engine.containerSizingState(for: $0) },
            widths
        )
        XCTAssertEqual(fixture.state.viewOffset, original.viewOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.state.activeColumnIndex, original.activeColumnIndex)
        XCTAssertEqual(fixture.state.selectedNodeId, original.selectedNodeId)
    }

    func testAWidthAnimationRunningWhenTheDragStartsKeepsRunningAfterTheDropOrACancel() {
        for cancels in [false, true] {
            var fixture = makeFixture()
            let column = fixture.column(2)
            let target = column.cachedWidth + 100
            let animation = SpringAnimation(
                from: Double(column.cachedWidth),
                to: Double(target),
                startTime: 0,
                config: .niriWindowMovement,
                displayRefreshRate: 60
            )
            column.widthAnimation = animation
            column.targetWidth = target
            XCTAssertTrue(fixture.begin(2))
            XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 3)), .changed)

            if cancels {
                XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
            } else {
                XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            }

            XCTAssertTrue(column.widthAnimation === animation, "cancels: \(cancels)")
            XCTAssertEqual(column.targetWidth, target, "cancels: \(cancels)")
        }
    }

    func testCancelRestoresTheActiveColumnEvenIfAColumnClosedDuringTheDrag() {
        var fixture = makeFixture(activeIndex: 3)
        let originalActive = fixture.column(3)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 2)),
            .changed
        )

        fixture.engine.removeWindow(token: fixture.tokens[0], in: fixture.workspaceId)
        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        XCTAssertTrue(columns.indices.contains(fixture.state.activeColumnIndex))
        XCTAssertTrue(columns[fixture.state.activeColumnIndex] === originalActive)
    }

    func testRemovingTheDraggedWindowEndsTheSessionWithoutRestoring() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        let order = fixture.order()

        fixture.engine.cancelInteractions(for: [fixture.window(2).id], in: fixture.workspaceId)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), order)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
    }

    func testKeepVisibleScrollIsOffDuringTheDrag() {
        var fixture = makeFixture(activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        let offScreen = fixture.window(4)
        let viewport = fixture.state

        fixture.engine.ensureSelectionVisible(node: offScreen, context: fixture.context, state: &fixture.state)

        XCTAssertEqual(fixture.state, viewport)
    }

    func testFocusingAnOffScreenColumnScrollsAsUsualAfterTheDrop() {
        var fixture = makeFixture(activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 1)),
            .changed
        )
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        let offScreen = fixture.window(4)
        XCTAssertGreaterThan(fixture.stripColumn(holding: 4).maxX, fixture.frame.maxX)
        let offset = fixture.state.viewOffset

        fixture.state.selectedNodeId = offScreen.id
        fixture.engine.ensureSelectionVisible(node: offScreen, context: fixture.context, state: &fixture.state)

        XCTAssertNotEqual(fixture.state.viewOffset, offset)
        XCTAssertLessThanOrEqual(fixture.stripColumn(holding: 4).maxX, fixture.frame.maxX + 0.5)
    }

    private func assertHovering(
        _ step: LiveColumnMove.Step,
        until expected: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .hovering(until) = step else {
            XCTFail("Expected hovering, got \(step)", file: file, line: line)
            return
        }
        XCTAssertEqual(until, expected, accuracy: 0.000_001, file: file, line: line)
    }

    func testAColumnMovesOnlyAfterThePointerRestsOnItForTheHoverDelay() {
        var fixture = makeFixture()
        fixture.engine.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(2))
        let order = fixture.order()
        let farThird = fixture.point(on: 3, half: .after)
        XCTAssertEqual(
            fixture.move(to: farThird, at: 10),
            .changedWhileHovering(until: 10.12)
        )
        fixture.engine.liveColumnMoveSettled()

        assertHovering(fixture.move(to: CGPoint(x: farThird.x, y: fixture.midY + 30), at: 10.1), until: 10.12)
        XCTAssertEqual(fixture.landingOrder(), order)

        XCTAssertEqual(fixture.move(to: CGPoint(x: farThird.x, y: fixture.midY + 30), at: 10.12), .changed)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4].map { fixture.tokens[$0] })
        XCTAssertNil(fixture.engine.liveColumnMove?.hover)
    }

    func testMovingOntoAnotherColumnOrBackOverTheEmptySpaceRestartsTheHoverDelay() {
        var fixture = makeFixture()
        fixture.engine.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(2))
        let order = fixture.order()
        let right = fixture.stripColumn(holding: 3)
        let farRight = fixture.stripColumn(holding: 4)
        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(holding: 2).midX, y: fixture.midY), at: 9.9)

        _ = fixture.move(to: CGPoint(x: right.maxX - right.width / 4, y: fixture.midY), at: 10)
        let emptySpace = fixture.stripColumn(holding: 2)
        assertHovering(
            fixture.move(to: CGPoint(x: farRight.maxX - farRight.width / 4, y: fixture.midY), at: 10.1),
            until: 10.22
        )
        XCTAssertEqual(fixture.move(to: CGPoint(x: emptySpace.midX, y: fixture.midY), at: 10.15), .unchanged)
        XCTAssertNil(fixture.engine.liveColumnMove?.hover)
        assertHovering(
            fixture.move(to: CGPoint(x: right.maxX - right.width / 4, y: fixture.midY), at: 10.2),
            until: 10.32
        )
        XCTAssertEqual(fixture.landingOrder(), order)
    }

    func testCrossingSeveralColumnsQuicklyOpensOneDropSpaceBesideTheLastOne() {
        var fixture = makeFixture(activeIndex: 0)
        fixture.engine.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(0))
        let target = fixture.stripColumn(holding: 3)
        var time: TimeInterval = 10
        var cursorX = fixture.stripColumn(holding: 0).midX
        while cursorX < target.maxX - target.width / 4 {
            cursorX += 40
            time += 0.01
            _ = fixture.move(to: CGPoint(x: cursorX, y: fixture.midY), at: time)
        }
        XCTAssertEqual(fixture.landingOrder(), (0 ... 4).map { fixture.tokens[$0] })
        XCTAssertNil(fixture.engine.liveColumnMove?.lockedTarget)

        XCTAssertEqual(fixture.move(to: CGPoint(x: cursorX, y: fixture.midY), at: time + 0.12), .changed)

        XCTAssertEqual(fixture.landingOrder(), [1, 2, 3, 0, 4].map { fixture.tokens[$0] })
        fixture.engine.liveColumnMoveSettled()
        let underPointer = fixture.strip().first { $0.contains(x: cursorX) }
        XCTAssertTrue(underPointer?.column === fixture.column(3) || underPointer?.column.isLiveDropSpace == true)
    }

    func testAnImmediateUpdateSkipsTheHoverDelay() {
        var fixture = makeFixture()
        fixture.engine.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(2))
        let neighbour = fixture.stripColumn(holding: 3)

        let step = fixture.engine.liveColumnMoveUpdate(
            cursor: CGPoint(x: neighbour.midX, y: fixture.midY),
            at: 10,
            immediate: true,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertEqual(step, .changed)
        XCTAssertNotNil(fixture.dropSpace())
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testTheFarDropSpaceMovesOnToAPartlyHiddenWindowAndBack() {
        var fixture = makeFixture(widths: Array(repeating: 0.25, count: 7))
        fixture.scrollSoThat(2, startsAt: 420)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertGreaterThan(fixture.stripColumn(holding: 4).maxX, fixture.frame.maxX)

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 3)), .changed)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 4)), .changed)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 4, 2, 5, 6].map { fixture.tokens[$0] })

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 3)), .changed)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).filter(\.isLiveDropSpace).count, 1)
    }

    func testComingBackWhereTheWindowStartedLandsItInItsPlace() {
        var fixture = makeFixture()
        let start = CGPoint(x: fixture.stripColumn(holding: 2).midX, y: fixture.midY)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 3)), .changed)
        XCTAssertNotEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertTrue(fixture.stripColumn(holding: 1).contains(x: start.x))
        let sideFacingThePlace = fixture.point(on: 1, half: .after)

        XCTAssertEqual(fixture.moveAndSettle(to: sideFacingThePlace), .changed)

        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testWithTwoWindowsTheRightOneIsPulledLeftForItsDropSpace() throws {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        let before = fixture.stripColumn(holding: 1)
        let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 1)), .changed)

        let dropSpace = try XCTUnwrap(fixture.dropSpace())
        let target = fixture.stripColumn(holding: 1)
        XCTAssertEqual(target.minX, before.minX - shift, accuracy: 0.5)
        XCTAssertEqual(dropSpace.maxX, before.maxX, accuracy: 0.5)
        XCTAssertEqual(fixture.landingOrder(), [1, 0].map { fixture.tokens[$0] })
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), [1, 0].map { fixture.tokens[$0] })
    }

    func testWithTwoWindowsTheLeftOneIsPulledRightForItsDropSpace() throws {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        XCTAssertTrue(fixture.begin(1))
        let before = fixture.stripColumn(holding: 0)
        let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 0)), .changed)

        let dropSpace = try XCTUnwrap(fixture.dropSpace())
        XCTAssertEqual(fixture.stripColumn(holding: 0).minX, before.minX + shift, accuracy: 0.5)
        XCTAssertEqual(dropSpace.minX, before.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.landingOrder(), [1, 0].map { fixture.tokens[$0] })
    }

    func testWithTwoWindowsComingBackLandsTheWindowInItsPlace() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        let start = CGPoint(x: fixture.stripColumn(holding: 0).midX, y: fixture.midY)
        XCTAssertTrue(fixture.begin(0))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 1)), .changed)
        XCTAssertNotNil(fixture.dropSpace())

        XCTAssertEqual(fixture.moveAndSettle(to: start), .changed)

        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertTrue(fixture.stripColumn(holding: 1).isFullyVisible(in: fixture.frame))
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testWithTwoWindowsAStillPointerCausesNoSecondChange() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        let cursor = fixture.farHalf(of: 1)
        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)
        let target = fixture.stripColumn(holding: 1)

        for _ in 0 ..< 5 {
            XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        }

        XCTAssertEqual(fixture.stripColumn(holding: 1).minX, target.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.changes, 1)
    }

    func testWithThreeWindowsTheWindowPastTheDropSpaceStillMakesRoom() {
        var fixture = makeFixture(widths: [0.25, 0.25, 0.25], activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        let target = fixture.stripColumn(holding: 1)
        let beyond = fixture.stripColumn(holding: 2)
        let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.farHalf(of: 1)), .changed)

        XCTAssertNotNil(fixture.dropSpace())
        XCTAssertEqual(fixture.stripColumn(holding: 1).minX, target.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.stripColumn(holding: 2).minX, beyond.minX + shift, accuracy: 0.5)
    }

    func testWithMixedWidthsThePointerEndsOverTheTargetOrItsDropSpace() {
        for (dragged, target) in [(0, 1), (1, 0)] {
            var fixture = makeFixture(widths: [1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
            let ownWidth = fixture.column(dragged).width
            XCTAssertTrue(fixture.begin(dragged))
            let targetColumn = fixture.stripColumn(holding: target)
            let cursor = CGPoint(x: dragged < target ? targetColumn.maxX - 20 : targetColumn.minX + 20, y: fixture.midY)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, "\(dragged)")

            XCTAssertNotNil(fixture.dropSpace(), "\(dragged)")
            let underPointer = fixture.strip().first { $0.contains(x: cursor.x) }?.column
            XCTAssertTrue(
                underPointer === fixture.column(target) || underPointer?.isLiveDropSpace == true,
                "\(dragged)"
            )
            XCTAssertEqual(fixture.move(to: cursor), .unchanged, "\(dragged)")
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.order(), [1, 0, 2].map { fixture.tokens[$0] }, "\(dragged)")
            XCTAssertEqual(fixture.column(dragged).width, ownWidth, "\(dragged)")
        }
    }

    func testCancelAfterTheHomeSpotMovedRestoresTheOriginalLayout() {
        var fixture = makeFixture()
        let original = fixture.state
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 4)),
            .changed
        )
        XCTAssertNotEqual(fixture.landingOrder(), fixture.tokens)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.state.viewOffset, original.viewOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.state.activeColumnIndex, original.activeColumnIndex)
    }

    func testANarrowedPlaceGetsItsFullWidthBackOnDropAndOnCancel() {
        for cancels in [false, true] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 3)
            let fullWidth = fixture.column(3).cachedWidth
            XCTAssertTrue(fixture.begin(3))
            let home = fixture.stripColumn(holding: 3)
            XCTAssertEqual(fixture.move(to: CGPoint(x: home.midX + 100, y: fixture.midY)), .changed)
            XCTAssertNotNil(fixture.column(3).liveSlotWidth)

            if cancels {
                XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
            } else {
                XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            }

            XCTAssertEqual(fixture.column(3).cachedWidth, fullWidth, accuracy: 0.001, "cancel: \(cancels)")
            XCTAssertNil(fixture.column(3).liveSlotWidth)
            XCTAssertEqual(fixture.order(), fixture.tokens)
            fixture.column(3).cachedWidth = 0
            fixture.engine.resolvePrimaryContainerSpans(
                in: fixture.workspaceId,
                workingFrame: fixture.frame,
                gaps: fixture.gap,
                orientation: .horizontal
            )
            XCTAssertEqual(fixture.column(3).cachedWidth, fullWidth, accuracy: 0.001)
        }
    }

    func testDraggingAFullyVisibleWindowKeepsTheWindowsAheadStillAndTheOthersFollowItsTrailingEdge() {
        for headingRight in [true, false] {
            var fixture = makeFixture(widths: Array(repeating: 0.3, count: 7), activeIndex: 3)
            fixture.scrollSoThat(3, startsAt: fixture.frame.midX - 200)
            XCTAssertTrue(fixture.begin(3))
            let home = fixture.stripColumn(holding: 3)
            let ahead = fixture.stripColumn(holding: headingRight ? 4 : 2)
            let direction: CGFloat = headingRight ? 1 : -1
            XCTAssertEqual(fixture.move(to: CGPoint(x: home.midX, y: fixture.midY)), .unchanged)

            for distance: CGFloat in [40, 120] {
                XCTAssertEqual(
                    fixture.move(to: CGPoint(x: home.midX + direction * distance, y: fixture.midY)),
                    .changed
                )
                let slot = fixture.stripColumn(holding: 3)
                if headingRight {
                    XCTAssertEqual(slot.minX, home.minX + distance, accuracy: 0.5)
                    XCTAssertEqual(fixture.stripColumn(holding: 2).maxX, slot.minX - fixture.gap, accuracy: 0.5)
                } else {
                    XCTAssertEqual(slot.maxX, home.maxX - distance, accuracy: 0.5)
                    XCTAssertEqual(fixture.stripColumn(holding: 4).minX, slot.maxX + fixture.gap, accuracy: 0.5)
                }
                XCTAssertEqual(fixture.stripColumn(holding: headingRight ? 4 : 2).minX, ahead.minX, accuracy: 0.5)
            }

            let aheadEdge = headingRight ? ahead.minX : ahead.maxX
            _ = fixture.move(to: CGPoint(x: aheadEdge + direction * 10, y: fixture.midY))
            XCTAssertEqual(fixture.stripColumn(holding: headingRight ? 4 : 2).minX, ahead.minX, accuracy: 0.5)
            XCTAssertEqual(fixture.landingOrder(), fixture.tokens)

            let aheadFarEdge = headingRight ? ahead.maxX : ahead.minX
            _ = fixture.moveAndSettle(to: CGPoint(x: aheadFarEdge - direction * 30, y: fixture.midY))
            let order = headingRight ? [0, 1, 2, 4, 3, 5, 6] : [0, 1, 3, 2, 4, 5, 6]
            XCTAssertEqual(fixture.landingOrder(), order.map { fixture.tokens[$0] })
        }
    }

    func testComingBackToTheHalfOfANeighbourFacingTheWindowsPlaceLandsItHome() {
        for towardLeading in [true, false] {
            var fixture = makeFixture(widths: Array(repeating: 0.2, count: 7), activeIndex: 3)
            fixture.scrollSoThat(3, startsAt: fixture.frame.midX - 150)
            XCTAssertTrue(fixture.begin(3))
            let neighbour = towardLeading ? 2 : 4
            let away = towardLeading ? 1 : 5
            _ = fixture.move(to: CGPoint(x: fixture.stripColumn(holding: 3).midX, y: fixture.midY))
            let farColumn = fixture.stripColumn(holding: away)
            _ = fixture.move(to: CGPoint(
                x: towardLeading ? farColumn.minX + 20 : farColumn.maxX - 20,
                y: fixture.midY
            ))

            let back = fixture.stripColumn(holding: neighbour)
            _ = fixture.move(to: CGPoint(x: towardLeading ? back.maxX - 20 : back.minX + 20, y: fixture.midY))

            XCTAssertEqual(fixture.landingOrder(), fixture.tokens, "\(towardLeading)")
            let expected = [0, 1, 2, 3, 4, 5, 6]
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.order(), expected.map { fixture.tokens[$0] }, "\(towardLeading)")
        }
    }

    func testAQuickReleaseFollowsTheHalfUnderThePointerEvenOverANeighbour() {
        let cases: [(pointer: Int, nearHalf: Bool, expected: [Int])] = [
            (2, true, [0, 1, 2, 3, 4, 5, 6]),
            (2, false, [0, 1, 3, 2, 4, 5, 6]),
            (5, true, [0, 1, 2, 4, 3, 5, 6]),
            (5, false, [0, 1, 2, 4, 5, 3, 6]),
            (1, true, [0, 1, 3, 2, 4, 5, 6]),
            (1, false, [0, 3, 1, 2, 4, 5, 6])
        ]
        for (pointer, nearHalf, expected) in cases {
            var fixture = makeFixture(widths: Array(repeating: 0.2, count: 7), activeIndex: 3)
            fixture.engine.liveHoverDelay = 0.12
            fixture.scrollSoThat(3, startsAt: fixture.frame.midX - 150)
            XCTAssertTrue(fixture.begin(3))
            _ = fixture.move(to: CGPoint(x: fixture.stripColumn(holding: 3).midX, y: fixture.midY), at: 10)
            let target = fixture.stripColumn(holding: pointer)
            let towardHome = pointer < 3 ? target.maxX - 10 : target.minX + 10
            let awayFromHome = pointer < 3 ? target.minX + 10 : target.maxX - 10
            let release = CGPoint(x: nearHalf ? towardHome : awayFromHome, y: fixture.midY)
            _ = fixture.move(to: release, at: 10.01)

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
                releasedAt: release,
                context: fixture.context,
                state: &fixture.state
            ))

            XCTAssertEqual(fixture.order(), expected.map { fixture.tokens[$0] }, "\(pointer) \(nearHalf)")
        }
    }

    func testEdgeScrollStopsAtTheSameStripEndsAsTheAnchoredScroll() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))

        let trailing = fixture.engine.liveEdgeScrollLimit(
            towardTrailingEdge: true, context: fixture.context, state: fixture.state
        )
        let leading = fixture.engine.liveEdgeScrollLimit(
            towardTrailingEdge: false, context: fixture.context, state: fixture.state
        )

        fixture.state.jumpOffset(to: trailing ?? fixture.state.viewOffset)
        XCTAssertEqual(fixture.strip().last?.maxX ?? 0, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        XCTAssertNil(fixture.engine.liveEdgeScrollLimit(
            towardTrailingEdge: true, context: fixture.context, state: fixture.state
        ))

        fixture.state.jumpOffset(to: leading ?? fixture.state.viewOffset)
        XCTAssertEqual(fixture.strip().first?.minX ?? 0, fixture.frame.minX + fixture.gap, accuracy: 0.5)
        XCTAssertNil(fixture.engine.liveEdgeScrollLimit(
            towardTrailingEdge: false, context: fixture.context, state: fixture.state
        ))
    }

    func testEdgeScrollNeverPullsAnOverScrolledStripBack() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let last = fixture.stripColumn(holding: 4)
        fixture.scrollSoThat(4, startsAt: fixture.frame.maxX - (last.maxX - last.minX) - 200)

        XCTAssertNil(fixture.engine.liveEdgeScrollLimit(
            towardTrailingEdge: true, context: fixture.context, state: fixture.state
        ))
    }

    func testWouldSwapAnswersLikeTheHitTestWithoutChangingTheLayout() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let order = fixture.order()
        let neighbour = fixture.stripColumn(holding: 3)
        let emptySpace = fixture.stripColumn(holding: 2)

        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: CGPoint(x: neighbour.midX, y: fixture.midY), strip: fixture.strip(), context: fixture.context
        ))
        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: CGPoint(x: emptySpace.midX, y: fixture.midY), strip: fixture.strip(), context: fixture.context
        ))
        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .dragging)
    }

    func testWouldSwapIsFalseOverTheCurrentTargetAndTrueOverAnotherColumn() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )

        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.farHalf(of: 3),
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: CGPoint(x: fixture.dropSpace()?.midX ?? 0, y: fixture.midY),
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.farHalf(of: 4),
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.point(on: 1, half: .before),
            strip: fixture.strip(),
            context: fixture.context
        ))
    }

    private struct TabbedSnapshot: Equatable {
        let windows: [WindowToken]
        let activeTab: Int
        let displayMode: ColumnDisplay
        let sizing: NiriContainerSizingState
    }

    private func tabbedSnapshot(_ column: NiriContainer, in fixture: Fixture) -> TabbedSnapshot {
        TabbedSnapshot(
            windows: column.windowNodes.map(\.token),
            activeTab: column.activeTileIdx,
            displayMode: column.displayMode,
            sizing: fixture.engine.containerSizingState(for: column)
        )
    }

    func testBeginTakesATabbedColumnWholeAndAStackedWindowOnItsOwn() {
        var tabbed = makeFixture()
        let column = tabbed.makeTabbed(1)
        XCTAssertEqual(column.windowNodes.count, 3)
        XCTAssertTrue(tabbed.beginActiveTab(1))
        XCTAssertEqual(tabbed.state.activeColumnIndex, 1)

        var stacked = makeFixture()
        stacked.engine.attachTransferredWindow(
            NiriWindow(token: WindowToken(pid: 931, windowId: 99)),
            stackedWith: stacked.window(1),
            after: true,
            in: stacked.workspaceId,
            state: &stacked.state
        )
        XCTAssertFalse(stacked.column(1).isTabbed)
        XCTAssertTrue(stacked.begin(1))
        XCTAssertEqual(stacked.engine.liveColumnMove?.isWholeColumn, false)
        XCTAssertEqual(stacked.engine.liveColumnMove?.inStack, true)
    }

    func testATabbedColumnLandsPastAVisibleNeighbourAndKeepsItsTabsOnRelease() {
        for (dragged, target) in [(2, 3), (3, 2)] {
            var fixture = makeFixture()
            let column = fixture.makeTabbed(dragged)
            let tabs = tabbedSnapshot(column, in: fixture)
            XCTAssertTrue(fixture.beginActiveTab(dragged))

            XCTAssertEqual(
                fixture.moveAndSettle(to: fixture.farHalf(of: target)),
                .changed,
                "\(dragged)"
            )
            XCTAssertEqual(
                fixture.engine.columns(in: fixture.workspaceId).firstIndex { $0.isLiveDropSpace },
                dragged < target ? 4 : 2,
                "\(dragged)"
            )

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

            XCTAssertEqual(fixture.order(), [0, 1, 3, 2, 4].map { fixture.tokens[$0] }, "\(dragged)")
            XCTAssertEqual(fixture.engine.columnIndex(of: column, in: fixture.workspaceId), target, "\(dragged)")
            XCTAssertEqual(tabbedSnapshot(column, in: fixture), tabs, "\(dragged)")
            XCTAssertEqual(fixture.state.selectedNodeId, column.activeWindow?.id, "\(dragged)")
            XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
        }
    }

    func testADroppedTabbedColumnGlidesFromTheReleasedWindowLessTheTabRail() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
        let dragged = fixture.makeTabbed(2)
        let railWidth = fixture.engine.renderStyle.tabIndicatorWidth
        XCTAssertGreaterThan(railWidth, 0)
        XCTAssertTrue(fixture.beginActiveTab(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        let animated = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .enabled,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        let positions = fixture.engine.primaryPositions(context: animated, state: fixture.state)
        let viewBefore = fixture.engine
            .liveViewPosition(positions: positions, context: animated, state: fixture.state) ?? 0
        let releasedWindowX = fixture.stripColumn(holding: 3).maxX - 150

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: CGRect(x: releasedWindowX, y: 0, width: 0, height: 0),
            context: animated,
            state: &fixture.state
        ))

        let landedPosition = fixture.engine.primaryPositions(context: animated, state: fixture.state)[dragged.id] ?? 0
        let releasedColumnPosition = releasedWindowX - railWidth - fixture.frame.minX + viewBefore
        XCTAssertEqual(
            dragged.moveAnimation?.fromOffset ?? 0,
            releasedColumnPosition - landedPosition,
            accuracy: 0.5
        )
    }

    func testCancellingATabbedColumnDragRestoresTheLayoutAndLeavesTheTabsAlone() {
        var fixture = makeFixture(activeIndex: 4)
        let column = fixture.makeTabbed(2)
        fixture.state.jumpOffset(to: 40)
        let original = fixture.state
        let order = fixture.order()
        let tabs = tabbedSnapshot(column, in: fixture)
        let widths = fixture.engine.columns(in: fixture.workspaceId)
            .map { fixture.engine.containerSizingState(for: $0) }
        XCTAssertTrue(fixture.beginActiveTab(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).map { fixture.engine.containerSizingState(for: $0) },
            widths
        )
        XCTAssertEqual(fixture.state.viewOffset, original.viewOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.state.activeColumnIndex, original.activeColumnIndex)
        XCTAssertEqual(fixture.state.selectedNodeId, original.selectedNodeId)
        XCTAssertEqual(tabbedSnapshot(column, in: fixture), tabs)
    }

    func testIsLiveDraggedColumnNamesOnlyTheDraggedColumnWhileTheDragLasts() {
        var fixture = makeFixture()
        let dragged = fixture.makeTabbed(2)
        let other = fixture.makeTabbed(4, tabCount: 2, activeTab: 0)
        XCTAssertFalse(fixture.engine.isLiveDraggedColumn(dragged))

        XCTAssertTrue(fixture.beginActiveTab(2))
        XCTAssertTrue(fixture.engine.isLiveDraggedColumn(dragged))
        XCTAssertFalse(fixture.engine.isLiveDraggedColumn(other))

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertFalse(fixture.engine.isLiveDraggedColumn(dragged))
    }

    func testRestingOnFreeScreenPastTheLastColumnMovesTheWindowToTheEnd() {
        var fixture = makeFixture(widths: [0.25, 0.25, 0.25], activeIndex: 0)
        let freeScreen = CGPoint(x: fixture.stripColumn(holding: 2).maxX + 100, y: fixture.midY)
        XCTAssertLessThan(freeScreen.x, fixture.frame.maxX)
        XCTAssertTrue(fixture.begin(0))

        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: freeScreen,
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertEqual(fixture.moveAndSettle(to: freeScreen), .changed)
        XCTAssertEqual(fixture.landingOrder(), [fixture.tokens[1], fixture.tokens[2], fixture.tokens[0]])
        XCTAssertEqual(fixture.move(to: CGPoint(x: freeScreen.x + 20, y: freeScreen.y)), .unchanged)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: freeScreen,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertEqual(fixture.order(), [fixture.tokens[1], fixture.tokens[2], fixture.tokens[0]])
    }

    func testRestingOnFreeScreenBeforeTheFirstColumnMovesTheWindowToTheStart() {
        var fixture = makeFixture(widths: [0.25, 0.25], activeIndex: 0)
        fixture.scrollSoThat(0, startsAt: 600)
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.moveAndSettle(to: CGPoint(x: 300, y: fixture.midY)), .changed)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), [fixture.tokens[1], fixture.tokens[0]])
    }

    func testAWindowDraggedOutOfAStackOntoFreeScreenBecomesTheLastColumn() {
        var fixture = makeFixture(widths: [0.25, 0.25], activeIndex: 0)
        let extra = WindowToken(pid: 931, windowId: 98)
        let window = NiriWindow(token: extra)
        fixture.engine.attachTransferredWindow(
            window,
            stackedWith: fixture.window(0),
            after: true,
            in: fixture.workspaceId,
            state: &fixture.state
        )
        let freeScreen = CGPoint(x: fixture.stripColumn(holding: 1).maxX + 200, y: fixture.midY)
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: window.id,
            windowToken: extra,
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertEqual(fixture.move(to: freeScreen), .changed)
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)
        XCTAssertEqual(fixture.order(), [fixture.tokens[0], extra, fixture.tokens[1]])
        fixture.engine.liveColumnMoveSettled()
        XCTAssertEqual(fixture.move(to: CGPoint(x: freeScreen.x + 10, y: freeScreen.y)), .changed)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), [fixture.tokens[0], fixture.tokens[1], extra])
        XCTAssertEqual(fixture.column(0).windowNodes.map(\.token), [fixture.tokens[0]])
    }

    func testReleasingWithTheStackModifierOverFreeScreenMovesTheWindowToTheEnd() {
        var fixture = makeFixture(widths: [0.25, 0.25, 0.25], activeIndex: 0)
        let freeScreen = CGPoint(x: fixture.stripColumn(holding: 2).maxX + 100, y: fixture.midY)
        XCTAssertTrue(fixture.begin(0))
        _ = fixture.engine.liveColumnMoveStackModeChanged(
            held: true,
            cursor: fixture.point(on: 0, half: .before),
            context: fixture.context,
            state: &fixture.state
        )
        _ = fixture.move(to: freeScreen)
        XCTAssertNil(fixture.dropSpace())
        XCTAssertEqual(fixture.order(), [fixture.tokens[0], fixture.tokens[1], fixture.tokens[2]])

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: freeScreen,
            stacking: true,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertEqual(fixture.order(), [fixture.tokens[1], fixture.tokens[2], fixture.tokens[0]])
    }

    func testAPointerOffTheStripsDisplayIsNotFreeScreen() {
        var fixture = makeFixture(widths: [0.25, 0.25, 0.25], activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))

        _ = fixture.move(to: CGPoint(x: fixture.frame.maxX + 50, y: fixture.midY))
        XCTAssertNil(fixture.dropSpace())

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), [fixture.tokens[0], fixture.tokens[1], fixture.tokens[2]])
    }

    func testTheMiddleThirdLimitNeverPushesTheStripTheWrongWay() {
        let fixture = makeFixture()
        let landing = fixture.column(0)
        let target = fixture.column(1)
        let towardStart = (
            pointerX: CGFloat(400.5),
            strip: [
                LiveColumnMove.StripColumn(column: landing, minX: -700, maxX: -100),
                LiveColumnMove.StripColumn(column: target, minX: 0, maxX: 600)
            ]
        )
        let towardEnd = (
            pointerX: CGFloat(199.5),
            strip: [
                LiveColumnMove.StripColumn(column: target, minX: 0, maxX: 600),
                LiveColumnMove.StripColumn(column: landing, minX: 1_600, maxX: 2_200)
            ]
        )
        for (pointerX, strip) in [towardStart, towardEnd] {
            let reveal = fixture.engine.liveLandingReveal(
                showing: landing,
                besideTargetUnder: (target: target, cursor: CGPoint(x: pointerX, y: fixture.midY)),
                strip: strip,
                pulledEnd: nil,
                context: fixture.context
            )
            if strip.first?.column === landing {
                XCTAssertLessThanOrEqual(reveal.shift, 0)
            } else {
                XCTAssertGreaterThanOrEqual(reveal.shift, 0)
            }
        }
    }
}
