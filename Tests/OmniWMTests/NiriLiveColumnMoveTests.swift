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
            return engine.columns(in: workspaceId).compactMap { column in
                if column.isLiveDropSpace { return move.windowToken }
                let token = column.windowNodes.first?.token
                return token == move.windowToken ? nil : token
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
            let quarter = (maxX - minX) / 4
            return CGPoint(x: half == .before ? minX + quarter : maxX - quarter, y: midY)
        }

        func farHalf(of index: Int) -> CGPoint {
            let placed = stripColumn(holding: index)
            let columns = engine.columns(in: workspaceId)
            guard let move = engine.liveColumnMove,
                  let home = columns.firstIndex(where: { $0.windowNodes.contains { $0.id == move.windowId } }),
                  let target = columns.firstIndex(where: { $0 === placed.column }),
                  home != target
            else { return CGPoint(x: placed.midX, y: midY) }
            let clippedMinX = max(placed.minX, frame.minX)
            let clippedMaxX = min(placed.maxX, frame.maxX)
            let isVisible = clippedMaxX > clippedMinX
            let minX = isVisible ? clippedMinX : placed.minX
            let maxX = isVisible ? clippedMaxX : placed.maxX
            let quarter = (maxX - minX) / 4
            return CGPoint(x: target > home ? maxX - quarter : minX + quarter, y: midY)
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

        mutating func move(to cursor: CGPoint, at time: TimeInterval = 0) -> LiveColumnMove.Step {
            engine.liveColumnMoveUpdate(cursor: cursor, at: time, context: context, state: &state)
        }

        mutating func moveAndSettle(to cursor: CGPoint) -> LiveColumnMove.Step {
            let step = move(to: cursor)
            if step == .changed {
                engine.liveColumnMoveSettled()
                _ = move(to: cursor)
            }
            return step
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
        engine.moveConfiguration.liveHoverDelay = 0
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

    func testBeginRefusesStackedWindowsSingleColumnsAndVerticalStrips() {
        var stacked = makeFixture()
        stacked.engine.attachTransferredWindow(
            NiriWindow(token: WindowToken(pid: 931, windowId: 99)),
            stackedWith: stacked.window(1),
            after: true,
            in: stacked.workspaceId,
            state: &stacked.state
        )
        XCTAssertFalse(stacked.begin(1))

        var single = makeFixture(widths: [0.5], activeIndex: 0)
        XCTAssertFalse(single.begin(0))

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

    func testRestingOnANeighbourOpensADropSpaceOnItsFarSideWhenTheHomeSpotIsPartlyOffScreen() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        let homeSpan = fixture.stripColumn(holding: 2).maxX - fixture.stripColumn(holding: 2).minX
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        let right = fixture.farHalf(of: 3)
        let targetBefore = fixture.stripColumn(holding: 3)

        XCTAssertEqual(fixture.moveAndSettle(to: right), .changed)

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        let dropSpace = try? XCTUnwrap(fixture.dropSpace())
        XCTAssertEqual((dropSpace?.maxX ?? 0) - (dropSpace?.minX ?? 0), fixture.frame.width * 0.05, accuracy: 0.5)
        XCTAssertEqual(
            fixture.stripColumn(holding: 2).maxX - fixture.stripColumn(holding: 2).minX,
            homeSpan,
            accuracy: 0.5
        )
        assertTheDropSpaceIsFullyOnScreen(in: fixture)
        XCTAssertEqual(fixture.stripColumn(holding: 3).minX, targetBefore.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.move(to: right), .unchanged)
        let backOverTheTarget = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.moveAndSettle(to: backOverTheTarget), .unchanged)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
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
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
    }

    func testRestingOnTheHomeSpotClosesTheDropSpaceWithoutScrolling() {
        var fixture = makeFixture()
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        let home = fixture.farHalf(of: 2)
        let homeBefore = fixture.stripColumn(holding: 2)

        XCTAssertEqual(fixture.moveAndSettle(to: home), .changed)

        XCTAssertNil(fixture.dropSpace())
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, fixture.tokens.count)
        XCTAssertEqual(fixture.stripColumn(holding: 2).minX, homeBefore.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.move(to: home), .unchanged)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), fixture.tokens)
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

        XCTAssertEqual(fixture.moveAndSettle(to: CGPoint(x: top?.midX ?? 0, y: top?.midY ?? 0)), .changed)
        let afterFirst = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        let stackedNow = fixture.stripColumn(holding: 3)
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: stackedNow.midX, y: bottom?.midY ?? 0)),
            .unchanged
        )

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), afterFirst)
        XCTAssertEqual(stacked.windowNodes.map(\.token), [fixture.tokens[3], extra])
        XCTAssertEqual(stacked.windowNodes.map(\.height), heights)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
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
            XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1, edge)
        }
    }

    func testADropSpaceOpeningOffScreenScrollsUnderThePointer() {
        for edge in ["right", "left"] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 3)
            let (dragged, target) = edge == "right" ? (2, 3) : (3, 2)
            let span = fixture.stripColumn(holding: target).maxX - fixture.stripColumn(holding: target).minX
            fixture.scrollSoThat(
                target,
                startsAt: edge == "right" ? fixture.frame.maxX - span / 2 : fixture.frame.minX - span / 2
            )
            XCTAssertTrue(fixture.begin(dragged), edge)
            let cursor = fixture.farHalf(of: target)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, edge)

            XCTAssertEqual(fixture.dropSpace()?.midX ?? 0, cursor.x, accuracy: 0.5, edge)
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
                startsAt: edge == "right" ? fixture.frame.maxX - span / 2 : fixture.frame.minX - span / 2
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
            if fixture.moveAndSettle(to: CGPoint(x: cursorX, y: fixture.midY)) == .changed {
                changes += 1
                let index = fixture.landingOrder().firstIndex(of: fixture.tokens[0])!
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
        let stillOverTheTarget = CGPoint(x: fixture.stripColumn(holding: 0).midX - 20, y: cursor.y)
        XCTAssertEqual(fixture.move(to: stillOverTheTarget), .unchanged)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
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
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
    }

    func testAfterTheStripScrolledFarTheDropStaysWhereTheDropSpaceWas() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 9), activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + 2_000)
        let target = try? XCTUnwrap(fixture.strip().first { $0.column !== fixture.column(0) && $0.minX > 400 })
        XCTAssertEqual(
            fixture.moveAndSettle(to: CGPoint(x: target?.midX ?? 0, y: fixture.midY)),
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
        let homePosition = fixture.engine.primaryPositions(context: animated, state: fixture.state)[dragged.id] ?? 0
        let viewBefore = homePosition + fixture.state.viewOffset
        let releasedAt = fixture.stripColumn(holding: 3).maxX - 150

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAtScreenX: releasedAt,
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
            XCTAssertNil(fixture.dropSpace(), "\(half)")
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

            XCTAssertEqual(fixture.dropSpace() != nil, half == .after, "\(half)")
            XCTAssertEqual(fixture.landingOrder(), expected.map { fixture.tokens[$0] }, "\(half)")
        }
    }

    func testTheNearHalfOfANeighbourChangesNothing() {
        var fixture = makeFixture(widths: Array(repeating: 0.18, count: 5), activeIndex: 0)
        XCTAssertTrue(fixture.begin(1))
        let order = fixture.landingOrder()

        XCTAssertEqual(fixture.move(to: fixture.point(on: 2, half: .before)), .unchanged)
        XCTAssertEqual(fixture.move(to: fixture.point(on: 0, half: .after)), .unchanged)

        XCTAssertEqual(fixture.landingOrder(), order)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 0)
    }

    func testRestingOnTheHalfFacingTheHomeSpotClosesTheDropSpace() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .after)), .changed)
        XCTAssertNotNil(fixture.dropSpace())

        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .before)), .changed)

        XCTAssertNil(fixture.dropSpace())
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testAnOffScreenHomeSpotComesBackUnderThePointer() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0, 0.9, 1.0 / 3.0, 1.0 / 3.0])
        let span = fixture.stripColumn(holding: 3).maxX - fixture.stripColumn(holding: 3).minX
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.moveAndSettle(to: fixture.point(on: 3, half: .after)), .changed)
        XCTAssertNotNil(fixture.dropSpace())
        XCTAssertLessThan(fixture.stripColumn(holding: 2).minX, fixture.frame.minX)
        let cursor = fixture.point(on: 3, half: .before)

        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)

        XCTAssertNil(fixture.dropSpace())
        let home = fixture.stripColumn(holding: 2)
        let target = fixture.stripColumn(holding: 3)
        XCTAssertTrue(
            home.contains(x: cursor.x) || abs(home.minX - (fixture.frame.minX + fixture.gap)) < 0.5,
            "home spot \(home.minX)...\(home.maxX), pointer \(cursor.x)"
        )
        XCTAssertGreaterThanOrEqual(cursor.x, min(home.minX, target.minX))
        XCTAssertLessThanOrEqual(cursor.x, max(home.maxX, target.maxX))
        XCTAssertEqual(fixture.landingOrder(), fixture.tokens)
    }

    func testAStillPointerCausesNoSecondChangeAfterGoingBackToTheHomeSpot() {
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
        XCTAssertNil(fixture.dropSpace())
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 2)
    }

    func testMovingToTheOtherHalfMovesTheLandingPlaceAfterTheHoverDelay() {
        var fixture = makeFixture(widths: Array(repeating: 0.18, count: 5), activeIndex: 0)
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(0))
        let right = fixture.point(on: 2, half: .after)
        XCTAssertEqual(fixture.move(to: right, at: 0), .hovering(until: 0.12))
        XCTAssertEqual(fixture.move(to: right, at: 0.2), .changed)
        fixture.engine.liveColumnMoveSettled()
        XCTAssertEqual(fixture.landingOrder(), [1, 2, 0, 3, 4].map { fixture.tokens[$0] })

        let left = fixture.point(on: 2, half: .before)
        XCTAssertEqual(fixture.move(to: left, at: 0.3), .hovering(until: 0.42))
        XCTAssertEqual(fixture.landingOrder(), [1, 2, 0, 3, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.move(to: left, at: 0.5), .changed)

        XCTAssertEqual(fixture.landingOrder(), [1, 0, 2, 3, 4].map { fixture.tokens[$0] })
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
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
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
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7), activeIndex: 2)
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
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(2))
        let order = fixture.order()
        let neighbour = fixture.stripColumn(holding: 3)

        assertHovering(fixture.move(to: CGPoint(x: neighbour.midX, y: fixture.midY), at: 10), until: 10.12)
        assertHovering(fixture.move(to: CGPoint(x: neighbour.midX + 20, y: fixture.midY + 30), at: 10.1), until: 10.12)
        XCTAssertEqual(fixture.landingOrder(), order)

        XCTAssertEqual(fixture.move(to: CGPoint(x: neighbour.midX + 20, y: fixture.midY + 30), at: 10.12), .changed)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4].map { fixture.tokens[$0] })
        XCTAssertNil(fixture.engine.liveColumnMove?.hover)
    }

    func testMovingOntoAnotherColumnOrBackOverTheEmptySpaceRestartsTheHoverDelay() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(2))
        let order = fixture.order()
        let right = fixture.stripColumn(holding: 3)
        let farRight = fixture.stripColumn(holding: 4)
        let emptySpace = fixture.stripColumn(holding: 2)

        _ = fixture.move(to: CGPoint(x: right.midX, y: fixture.midY), at: 10)
        assertHovering(fixture.move(to: CGPoint(x: farRight.midX, y: fixture.midY), at: 10.1), until: 10.22)
        XCTAssertEqual(fixture.move(to: CGPoint(x: emptySpace.midX, y: fixture.midY), at: 10.15), .unchanged)
        XCTAssertNil(fixture.engine.liveColumnMove?.hover)
        assertHovering(fixture.move(to: CGPoint(x: right.midX, y: fixture.midY), at: 10.2), until: 10.32)
        XCTAssertEqual(fixture.landingOrder(), order)
    }

    func testCrossingSeveralColumnsQuicklyOpensOneDropSpaceBesideTheLastOne() {
        var fixture = makeFixture(activeIndex: 0)
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(0))
        let target = fixture.stripColumn(holding: 3)
        var time: TimeInterval = 10
        var cursorX = fixture.stripColumn(holding: 0).midX
        while cursorX < target.midX {
            cursorX += 40
            time += 0.01
            XCTAssertNotEqual(fixture.move(to: CGPoint(x: cursorX, y: fixture.midY), at: time), .changed)
        }
        XCTAssertEqual(fixture.landingOrder(), (0 ... 4).map { fixture.tokens[$0] })

        XCTAssertEqual(fixture.move(to: CGPoint(x: cursorX, y: fixture.midY), at: time + 0.12), .changed)

        XCTAssertEqual(fixture.landingOrder(), [1, 2, 3, 0, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
        fixture.engine.liveColumnMoveSettled()
        let underPointer = fixture.strip().first { $0.contains(x: cursorX) }
        XCTAssertTrue(underPointer?.column === fixture.column(3) || underPointer?.column.isLiveDropSpace == true)
    }

    func testAnImmediateUpdateSkipsTheHoverDelay() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
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

    func testWithBothOnScreenTheHomeSpotMovesPastTheTargetWithoutADropSpaceOrScroll() {
        for (dragged, target) in [(2, 3), (3, 2)] {
            var fixture = makeFixture()
            let slots = (0 ..< 5).map { fixture.stripColumn(holding: $0).minX }
            XCTAssertTrue(fixture.begin(dragged))
            let cursor = fixture.farHalf(of: target)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, "\(dragged)")

            XCTAssertNil(fixture.dropSpace(), "\(dragged)")
            XCTAssertEqual(fixture.order(), [0, 1, 3, 2, 4].map { fixture.tokens[$0] }, "\(dragged)")
            XCTAssertEqual(fixture.stripColumn(holding: target).minX, slots[dragged], accuracy: 0.5, "\(dragged)")
            XCTAssertEqual(fixture.stripColumn(holding: dragged).minX, slots[target], accuracy: 0.5, "\(dragged)")
            for index in [0, 1, 4] {
                XCTAssertEqual(fixture.stripColumn(holding: index).minX, slots[index], accuracy: 0.5, "\(dragged)")
            }
            for _ in 0 ..< 5 {
                XCTAssertEqual(fixture.move(to: cursor), .unchanged, "\(dragged)")
            }
            XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1, "\(dragged)")

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.order(), [0, 1, 3, 2, 4].map { fixture.tokens[$0] }, "\(dragged)")
            XCTAssertEqual(fixture.stripColumn(holding: target).minX, slots[dragged], accuracy: 0.5, "\(dragged)")
            XCTAssertEqual(fixture.stripColumn(holding: dragged).minX, slots[target], accuracy: 0.5, "\(dragged)")
        }
    }

    func testATargetPartlyOffScreenGetsTheDropSpaceAndTheHomeSpotStays() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        let span = fixture.stripColumn(holding: 3).maxX - fixture.stripColumn(holding: 3).minX
        fixture.scrollSoThat(3, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(2))

        XCTAssertEqual(
            fixture.moveAndSettle(to: CGPoint(x: fixture.frame.maxX - span / 4, y: fixture.midY)),
            .changed
        )

        XCTAssertNotNil(fixture.dropSpace())
        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
    }

    func testTheHomeSpotStopsAtAPartlyHiddenWindowAndMovesAgainOnAVisibleOne() {
        var fixture = makeFixture(widths: Array(repeating: 0.25, count: 7))
        fixture.scrollSoThat(2, startsAt: 420)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertGreaterThan(fixture.stripColumn(holding: 4).maxX, fixture.frame.maxX)

        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        XCTAssertNil(fixture.dropSpace())
        XCTAssertEqual(fixture.order(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })

        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 4)),
            .changed
        )
        XCTAssertNotNil(fixture.dropSpace())
        XCTAssertEqual(fixture.order(), [0, 1, 3, 2, 4, 5, 6].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 4, 2, 5, 6].map { fixture.tokens[$0] })

        let visible = fixture.stripColumn(holding: 3)
        XCTAssertGreaterThanOrEqual(visible.minX, fixture.frame.minX)
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        XCTAssertNil(fixture.dropSpace())
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
        XCTAssertEqual(fixture.order(), fixture.tokens)
    }

    func testARefusedHomeSpotMoveLeavesTheOpenDropSpaceInPlaceBeforeMovingIt() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
        fixture.pushHalfOffScreen(2, awayFrom: 3)
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(
            fixture.moveAndSettle(to: fixture.farHalf(of: 3)),
            .changed
        )
        fixture.scrollSoThat(2, startsAt: fixture.frame.minX + fixture.gap + 150)
        let partlyHidden = fixture.stripColumn(holding: 4)
        XCTAssertGreaterThan(partlyHidden.maxX, fixture.frame.maxX)

        XCTAssertEqual(
            fixture.moveAndSettle(to: CGPoint(x: (partlyHidden.minX + fixture.frame.maxX) / 2, y: fixture.midY)),
            .changed
        )

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.landingOrder(), [0, 1, 3, 4, 2, 5, 6].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).filter(\.isLiveDropSpace).count, 1)
    }

    func testMovingOffTheTargetAndBackMovesTheHomeSpotBack() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(2))
        let cursor = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed)
        XCTAssertTrue(fixture.stripColumn(holding: 2).contains(x: cursor.x))

        let backOnTheTarget = fixture.farHalf(of: 3)
        XCTAssertEqual(fixture.moveAndSettle(to: backOnTheTarget), .changed)

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertNil(fixture.dropSpace())
    }

    func testWithMixedWidthsThePointerEndsOverTheTargetOrTheHomeSpot() {
        for (dragged, target) in [(0, 1), (1, 0)] {
            var fixture = makeFixture(widths: [1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
            let ownWidth = fixture.column(dragged).width
            XCTAssertTrue(fixture.begin(dragged))
            let targetColumn = fixture.stripColumn(holding: target)
            let cursor = CGPoint(x: dragged < target ? targetColumn.maxX - 20 : targetColumn.minX + 20, y: fixture.midY)

            XCTAssertEqual(fixture.moveAndSettle(to: cursor), .changed, "\(dragged)")

            XCTAssertNil(fixture.dropSpace(), "\(dragged)")
            let underPointer = fixture.strip().first { $0.contains(x: cursor.x) }?.column
            XCTAssertTrue(
                underPointer == nil || underPointer === fixture.column(dragged) || underPointer === fixture
                    .column(target),
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
        XCTAssertNotEqual(fixture.order(), fixture.tokens)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.state.viewOffset, original.viewOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.state.activeColumnIndex, original.activeColumnIndex)
    }
}
