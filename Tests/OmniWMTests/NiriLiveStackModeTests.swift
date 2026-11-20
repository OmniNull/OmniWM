// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriLiveStackModeTests: XCTestCase {
    private let axisFrames: [(Monitor.Orientation, CGRect)] = [
        (.horizontal, CGRect(x: 137, y: -241, width: 1_512, height: 912)),
        (.vertical, CGRect(x: -317, y: 89, width: 912, height: 1_512))
    ]

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let tokens: [WindowToken]
        let orientation: Monitor.Orientation
        var state: ViewportState
        var motion = MotionSnapshot.disabled

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: motion, workingFrame: frame, gaps: gap, orientation: orientation)
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func columnOrder() -> [[WindowToken]] {
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        }

        func strip() -> [LiveColumnMove.StripColumn] {
            engine.liveColumnStrip(context: context, state: state)
        }

        func stripColumn(_ column: NiriContainer) -> LiveColumnMove.StripColumn {
            strip().first { $0.column === column }!
        }

        func spans(_ column: NiriContainer) -> [LiveColumnMove.WindowSpan] {
            engine.liveWindowSpans(in: column, context: context)
        }

        func span(of index: Int) -> LiveColumnMove.WindowSpan {
            spans(column(index)).first { $0.window === window(index) }!
        }

        func point(inColumnOf index: Int, y: CGFloat) -> CGPoint {
            context.point(primary: stripColumn(column(index)).midX, secondary: y)
        }

        func point(inTrailingThirdOf index: Int, y: CGFloat) -> CGPoint {
            let placed = stripColumn(column(index))
            return context.point(primary: placed.maxX - placed.width / 6, secondary: y)
        }

        func frames() -> [WindowToken: CGRect] {
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: orientation
            )
        }

        func frames(at time: TimeInterval) -> [WindowToken: CGRect] {
            engine.calculateLayoutWithVisibility(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: orientation,
                animationTime: time
            ).frames
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
            let step = engine.liveColumnMoveUpdate(cursor: cursor, at: time, context: context, state: &state)
            if step.changesLayout {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func stack(_ index: Int, onto target: Int, after: Bool = true) {
            let moved = window(index)
            let column = column(index)
            moved.detach()
            column.remove()
            engine.attachTransferredWindow(
                moved,
                stackedWith: window(target),
                after: after,
                in: workspaceId,
                state: &state
            )
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: orientation
            )
        }

        mutating func makeTabbed(_ index: Int, tabCount: Int = 3, activeTab: Int = 1) -> NiriContainer {
            var last = window(index)
            for tab in 1 ..< tabCount {
                let tabWindow = NiriWindow(token: WindowToken(pid: 942, windowId: index * 10 + tab))
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
            if orientation == .horizontal {
                column.cachedWidth = 0
            } else {
                column.cachedHeight = 0
            }
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: orientation
            )
            return column
        }

        mutating func scrollSoThat(_ column: NiriContainer, startsAt x: CGFloat) {
            state.jumpOffset(to: state.viewOffset + stripColumn(column).minX - x)
        }

        mutating func beginPull(_ window: NiriWindow) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: window.token,
                pullsTab: true,
                context: context,
                state: &state
            )
        }

        func storage(_ column: NiriContainer) -> [WindowToken] {
            column.windowNodes.map(\.token)
        }

        func middle(of index: Int) -> CGPoint {
            let span = span(of: index)
            return point(inColumnOf: index, y: (span.minY + span.maxY) / 2)
        }
    }

    private func makeFixture(
        widths: [CGFloat] = Array(repeating: 1.0 / 3.0, count: 5),
        activeIndex: Int = 1,
        orientation: Monitor.Orientation = .horizontal,
        frame: CGRect? = nil
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.liveHoverDelay = 0
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = frame ?? CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 94), displayId: 94, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Live stack mode"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: orientation]
        )
        let tokens = widths.indices.map { WindowToken(pid: 941, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            if orientation == .horizontal {
                column.width = .proportion(width)
            } else {
                column.height = .proportion(width)
            }
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: orientation)
        let active = engine.findNode(for: tokens[activeIndex], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = activeIndex
        state.jumpOffset(to: -gap)
        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            frame: frame,
            gap: gap,
            tokens: tokens,
            orientation: orientation,
            state: state
        )
    }

    func testAWindowLeftAloneInAStackKeepsTheHeightItWasGiven() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let left = fixture.window(2)
        let chosenHeight: CGFloat = 300
        left.height = .fixed(chosenHeight)
        let before = fixture.span(of: 2)
        XCTAssertEqual(before.maxY - before.minY, chosenHeight, accuracy: 0.5)
        XCTAssertTrue(fixture.begin(3))

        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)), .changed)

        let after = fixture.span(of: 2)
        XCTAssertEqual(after.maxY - after.minY, chosenHeight, accuracy: 0.5)
        XCTAssertNil(left.heightAnimation)
    }

    func testAWindowPulledOutOfAStackPassesItsNeighbourWhichStaysStillWhileTheStackClosesIn() {
        for towardTrailingSide in [true, false] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 7))
            let pulled = towardTrailingSide ? 4 : 2
            fixture.stack(pulled, onto: 3)
            let stack = fixture.column(3)
            let neighbour = fixture.column(towardTrailingSide ? 5 : 1)
            fixture.scrollSoThat(stack, startsAt: towardTrailingSide ? 400 : 600)
            XCTAssertTrue(fixture.stripColumn(neighbour).isFullyVisible(in: fixture.context), "\(towardTrailingSide)")
            XCTAssertTrue(fixture.begin(pulled), "\(towardTrailingSide)")
            let leave = towardTrailingSide
                ? CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)
                : CGPoint(x: fixture.stripColumn(stack).minX - 20, y: 450)
            let neighbourX = fixture.stripColumn(neighbour).minX
            XCTAssertEqual(fixture.move(to: leave), .changed, "\(towardTrailingSide)")
            XCTAssertEqual(fixture.stripColumn(neighbour).minX, neighbourX, accuracy: 0.5, "\(towardTrailingSide)")
            let home = fixture.column(pulled)
            let stackX = fixture.stripColumn(stack).minX
            let placed = fixture.stripColumn(neighbour)
            let overNeighbour = CGPoint(x: towardTrailingSide ? placed.maxX - 60 : placed.minX + 60, y: 450)

            _ = fixture.move(to: overNeighbour)
            _ = fixture.move(to: overNeighbour)

            let order = fixture.engine.columns(in: fixture.workspaceId)
            let dropSpaceIndex = order.firstIndex { $0.id == fixture.engine.liveColumnMove?.dropSpaceId } ?? -1
            let neighbourIndex = order.firstIndex { $0 === neighbour } ?? -1
            XCTAssertEqual(
                dropSpaceIndex,
                towardTrailingSide ? neighbourIndex + 1 : neighbourIndex - 1,
                "\(towardTrailingSide)"
            )
            let stackIndex = order.firstIndex { $0 === stack } ?? -1
            XCTAssertEqual(
                order.firstIndex { $0 === home },
                towardTrailingSide ? stackIndex + 1 : stackIndex - 1,
                "\(towardTrailingSide)"
            )
            let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap
            XCTAssertEqual(fixture.stripColumn(neighbour).minX, placed.minX, accuracy: 0.5, "\(towardTrailingSide)")
            XCTAssertEqual(
                fixture.stripColumn(stack).minX,
                towardTrailingSide ? stackX + shift : stackX - shift,
                accuracy: 0.5,
                "\(towardTrailingSide)"
            )
        }
    }

    func testAfterLeavingAStackAReleaseOverTheNeighbourFollowsTheHalfUnderTheCursor() {
        for towardTrailingSide in [true, false] {
            for nearHalf in [true, false] {
                var fixture = makeFixture()
                let pulled = towardTrailingSide ? 3 : 1
                fixture.stack(pulled, onto: 2)
                let stack = fixture.column(2)
                let neighbour = fixture.column(towardTrailingSide ? 4 : 0)
                fixture.scrollSoThat(stack, startsAt: towardTrailingSide ? 300 : 600)
                XCTAssertTrue(fixture.begin(pulled))
                let leave = towardTrailingSide
                    ? CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)
                    : CGPoint(x: fixture.stripColumn(stack).minX - 20, y: 450)
                XCTAssertEqual(fixture.move(to: leave), .changed)
                let placed = fixture.stripColumn(neighbour)
                XCTAssertTrue(placed.isFullyVisible(in: fixture.context), "\(towardTrailingSide) \(nearHalf)")
                let near = towardTrailingSide ? placed.minX + 40 : placed.maxX - 40
                let far = towardTrailingSide ? placed.maxX - 40 : placed.minX + 40
                let release = CGPoint(x: nearHalf ? near : far, y: 450)

                XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
                    releasedAt: release,
                    context: fixture.context,
                    state: &fixture.state
                ))

                let order = fixture.engine.columns(in: fixture.workspaceId)
                let windowIndex = order.firstIndex { $0.windowNodes.contains { $0 === fixture.window(pulled) } } ?? -1
                let neighbourIndex = order.firstIndex { $0 === neighbour } ?? -1
                let landsBefore = towardTrailingSide == nearHalf
                XCTAssertEqual(
                    windowIndex,
                    landsBefore ? neighbourIndex - 1 : neighbourIndex + 1,
                    "\(towardTrailingSide) \(nearHalf)"
                )
            }
        }
    }

    func testWindowSpansMatchTheLayoutFrames() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let frames = fixture.frames()
        for index in [2, 3] {
            let span = fixture.span(of: index)
            XCTAssertEqual(span.minY, frames[fixture.tokens[index]]?.minY ?? .nan, accuracy: 1, "\(index)")
            XCTAssertEqual(span.maxY, frames[fixture.tokens[index]]?.maxY ?? .nan, accuracy: 1, "\(index)")
        }
        XCTAssertLessThan(fixture.span(of: 2).maxY, fixture.span(of: 3).minY)
    }

    func testATabbedColumnTakesTheFullHeight() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)

        let frames = fixture.frames()

        for window in column.windowNodes {
            XCTAssertEqual(frames[window.token]?.height ?? .nan, fullTabHeight(fixture), accuracy: 1)
        }
    }

    func testATabbedColumnTurnedNormalGetsItsResizedHeightBack() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)
        XCTAssertEqual(fixture.frames()[fixture.tokens[2]]?.height ?? .nan, fullTabHeight(fixture), accuracy: 1)

        column.displayMode = .normal
        fixture.engine.updateTabbedColumnVisibility(column: column)

        XCTAssertEqual(fixture.frames()[fixture.tokens[2]]?.height ?? .nan, 400, accuracy: 1)
    }

    private func makeTabbedColumnWithAResizedTab(_ fixture: inout Fixture) -> NiriContainer {
        fixture.window(2).height = .fixed(400)
        fixture.stack(3, onto: 2)
        let column = fixture.column(2)
        column.displayMode = .tabbed
        column.setActiveTileIdx(0)
        fixture.engine.updateTabbedColumnVisibility(column: column)
        return column
    }

    private func fullTabHeight(_ fixture: Fixture) -> CGFloat {
        fixture.frame.height - 2 * fixture.gap
    }

    func testAColumnWhoseOnlyMateIsHiddenMovesAsAWholeColumn() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.engine.setProjectionExclusions([fixture.tokens[3]], in: fixture.workspaceId)
        let column = fixture.column(2)
        XCTAssertEqual(column.windowNodes.count, 2)

        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.engine.liveColumnMove.map { $0.home != .stackSlot }, true)
        let target = fixture.stripColumn(fixture.column(1))
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: target.minX + target.width / 6, y: 450), at: 1),
            .changed
        )
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        XCTAssertTrue(fixture.column(2) === column)
        XCTAssertEqual(fixture.engine.columnIndex(of: column, in: fixture.workspaceId), 1)
        XCTAssertEqual(fixture.columnOrder(), [
            [fixture.tokens[0]],
            [fixture.tokens[2], fixture.tokens[3]],
            [fixture.tokens[1]],
            [fixture.tokens[4]]
        ])
    }

    func testAStackedWindowMovesWithinItsStackAsThePointerReachesItsMates() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.stack(4, onto: 3)
        let stack = fixture.column(2)
        let stripBefore = fixture.strip().map(\.minX)
        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)

        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.storage(stack), [3, 2, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 2)), .unchanged)
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 4)), .changed)
        XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.strip().map(\.minX), stripBefore)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 3)
        XCTAssertEqual(fixture.state.selectedNodeId, fixture.window(2).id)
    }

    func testAnEdgeHopAfterLeavingAStackMovesTheDropSpaceAndOpensNoSecondGap() throws {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: fixture.middle(of: 3).y)),
            .changed
        )
        let home = fixture.column(3)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.dropSpaceId)

        let passed = fixture.engine.liveColumnMoveHop(
            towardTrailingEdge: true,
            context: fixture.context,
            state: &fixture.state
        )

        let beside = try XCTUnwrap(passed)
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        XCTAssertEqual(columns.filter(\.isLiveDropSpace).count, 1)
        let index = try XCTUnwrap(columns.firstIndex { $0 === beside })
        XCTAssertTrue(columns.indices.contains(index + 1) && columns[index + 1].isLiveDropSpace)
        XCTAssertTrue(fixture.window(3).parent === home)
    }

    func testLeavingAStackSidewaysClosesTheWindowsPlaceAndOpensADropSpaceBesideItOnThatSide() {
        for towardTrailing in [false, true] {
            var fixture = makeFixture()
            fixture.stack(3, onto: 2)
            let stack = fixture.column(2)
            let stackX = fixture.stripColumn(stack).minX
            let stackSpan = fixture.stripColumn(stack).maxX - fixture.stripColumn(stack).minX
            XCTAssertTrue(fixture.begin(3))
            let inset = stackSpan * 0.05
            let edge = towardTrailing ? fixture.stripColumn(stack).maxX - inset : stackX + inset

            XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: fixture.middle(of: 3).y)), .changed)

            let during: [[Int]] = towardTrailing ? [[0], [1], [2], [3], [], [4]] : [[0], [1], [], [3], [2], [4]]
            XCTAssertEqual(fixture.columnOrder(), during.map { $0.map { fixture.tokens[$0] } }, "\(towardTrailing)")
            XCTAssertEqual(fixture.stripColumn(stack).minX, stackX, accuracy: 0.5, "\(towardTrailing)")
            let home = fixture.column(3)
            XCTAssertEqual(
                fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX,
                -fixture.gap,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
            let move = fixture.engine.liveColumnMove
            XCTAssertEqual(move?.home, .origin)
            XCTAssertEqual(move?.originClosedToward, towardTrailing ? .after : .before)
            XCTAssertEqual(move?.homeColumnId, home.id)
            let dropSpace = fixture.strip().first { $0.column.isLiveDropSpace }
            XCTAssertEqual(dropSpace.map { $0.maxX - $0.minX } ?? 0, fixture.frame.width * 0.05, accuracy: 0.5)
            let stackNow = fixture.stripColumn(stack)
            XCTAssertEqual(
                dropSpace.map { towardTrailing ? $0.minX - stackNow.maxX : stackNow.minX - $0.maxX } ?? 0,
                fixture.gap,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
            let remaining = fixture.span(of: 2)
            XCTAssertEqual(remaining.maxY - remaining.minY, fixture.frame.height - 2 * fixture.gap, accuracy: 0.5)

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            let expected = towardTrailing ? [[0], [1], [2], [3], [4]] : [[0], [1], [3], [2], [4]]
            XCTAssertEqual(fixture.columnOrder(), expected.map { $0.map { fixture.tokens[$0] } }, "\(towardTrailing)")
            XCTAssertFalse(home.isLiveHomeSpot)
            XCTAssertEqual(
                fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX,
                stackSpan,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
        }
    }

    func testCancelAfterMovingWithinOrLeavingAStackRestoresIt() {
        for leaves in [false, true] {
            var fixture = makeFixture()
            fixture.stack(3, onto: 2)
            fixture.window(2).height = .auto(weight: 2)
            let order = fixture.columnOrder()
            let offset = fixture.state.viewOffset
            let stack = fixture.column(2)
            XCTAssertTrue(fixture.begin(2))
            XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
            if leaves {
                XCTAssertEqual(
                    fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)),
                    .changed
                )
            }

            XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

            XCTAssertEqual(fixture.columnOrder(), order, "\(leaves)")
            XCTAssertEqual(fixture.window(2).height, .auto(weight: 2), "\(leaves)")
            XCTAssertEqual(fixture.state.viewOffset, offset, accuracy: 0.5, "\(leaves)")
            XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        }
    }

    func testAWorkspaceWithASingleStackedColumnCanBeDragged() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        fixture.stack(1, onto: 0)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)

        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)
    }

    func testPullingATabOutShowsTheNextTabAndOpensADropSpaceBeside() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        let next = tabbed.windowNodes[2]
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)
        XCTAssertFalse(fixture.engine.isLiveDraggedColumn(tabbed))

        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 200)), .unchanged)
        XCTAssertEqual(tabbed.windowNodes.count, 3)

        let edge = fixture.stripColumn(tabbed).maxX + 20
        XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: 450)), .changed)

        XCTAssertEqual(tabbed.windowNodes.count, 2)
        XCTAssertTrue(tabbed.isTabbed)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === next)
        XCTAssertFalse(next.isHiddenInTabbedMode)
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)
        XCTAssertEqual(fixture.engine.columnIndex(of: home!, in: fixture.workspaceId), 3)
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId)[4].isLiveDropSpace)
        XCTAssertFalse(pulled.isHiddenInTabbedMode)
    }

    func testPullingTheSecondToLastTabMakesTheColumnNormal() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2, tabCount: 2, activeTab: 1)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))

        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.stripColumn(tabbed).maxX + 20, y: 450)),
            .changed
        )

        XCTAssertEqual(tabbed.displayMode, .normal)
        XCTAssertEqual(tabbed.windowNodes.count, 1)
        XCTAssertFalse(tabbed.windowNodes[0].isHiddenInTabbedMode)
    }

    func testAPulledTabsDropSpaceMovesLikeAPlainDragsAndTheReleaseLandsThere() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        let tabbedX = fixture.stripColumn(tabbed).minX
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: true,
            cursor: CGPoint(x: fixture.stripColumn(tabbed).maxX - 20, y: 450),
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        XCTAssertEqual(fixture.stripColumn(tabbed).minX, tabbedX, accuracy: 0.5)
        let neighbour = fixture.column(3)
        let placed = fixture.stripColumn(neighbour)
        let overNeighbour = CGPoint(x: min(placed.maxX - 60, fixture.frame.maxX - 30), y: 450)
        XCTAssertTrue(placed.contains(x: overNeighbour.x))

        XCTAssertEqual(fixture.move(to: overNeighbour), .changed)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let neighbourIndex = columns.firstIndex { $0 === neighbour } ?? -1
        XCTAssertTrue(columns[neighbourIndex + 1].isLiveDropSpace)
        let dropSpace = fixture.stripColumn(columns[neighbourIndex + 1])
        XCTAssertEqual(dropSpace.maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        XCTAssertTrue(fixture.stripColumn(neighbour).isFullyVisible(in: fixture.context))

        let tabs = fixture.storage(tabbed)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(
            fixture.columnOrder(),
            [[fixture.tokens[0]], [fixture.tokens[1]], tabs, [fixture.tokens[3]], [pulled.token], [fixture.tokens[4]]]
        )
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
    }

    func testPassingANeighbourAtTheScreenEdgeAfterLeavingAStackKeepsTheStackAndTheNeighbourOnTheDisplay() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 6))
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let neighbour = fixture.column(4)
        XCTAssertEqual(fixture.stripColumn(neighbour).maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        XCTAssertFalse(fixture.stripColumn(fixture.column(5)).isFullyVisible(in: fixture.context))
        XCTAssertTrue(fixture.begin(3))
        let placedStack = fixture.stripColumn(stack)
        let leave = CGPoint(x: placedStack.maxX - placedStack.width * 0.05, y: 450)
        XCTAssertEqual(fixture.move(to: leave), .changed)
        XCTAssertEqual(fixture.stripColumn(stack).minX, placedStack.minX, accuracy: 0.5)
        let placed = fixture.stripColumn(neighbour)
        let overNeighbour = CGPoint(x: min(placed.maxX - 60, fixture.frame.maxX - 30), y: 450)
        XCTAssertTrue(placed.contains(x: overNeighbour.x))

        XCTAssertEqual(fixture.move(to: overNeighbour), .changed)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let neighbourIndex = columns.firstIndex { $0 === neighbour } ?? -1
        XCTAssertTrue(columns[neighbourIndex + 1].isLiveDropSpace)
        XCTAssertEqual(
            fixture.stripColumn(columns[neighbourIndex + 1]).maxX,
            fixture.frame.maxX - fixture.gap,
            accuracy: 0.5
        )
        XCTAssertTrue(fixture.stripColumn(neighbour).isFullyVisible(in: fixture.context))
        XCTAssertTrue(fixture.stripColumn(stack).isFullyVisible(in: fixture.context))
    }

    func testCancellingATabPullRestoresTheTabsAndTheShownTab() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2, tabCount: 2, activeTab: 1)
        let tabs = fixture.storage(tabbed)
        let pulled = tabbed.windowNodes[1]
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.stripColumn(tabbed).maxX + 20, y: 450)),
            .changed
        )

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.storage(tabbed), tabs)
        XCTAssertEqual(tabbed.displayMode, .tabbed)
        XCTAssertEqual(tabbed.activeTileIdx, 1)
        XCTAssertFalse(pulled.isHiddenInTabbedMode)
        XCTAssertTrue(tabbed.windowNodes[0].isHiddenInTabbedMode)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), order)
    }

    func testAPulledTabHasAFloatingFrameOnlyWhileTheDragLasts() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        let frame = CGRect(x: 300, y: 200, width: 400, height: 500)

        fixture.engine.liveColumnMove?.floatingFrame = frame

        XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled.token, in: fixture.workspaceId), frame)
        XCTAssertNil(fixture.engine.liveFloatingFrame(for: tabbed.windowNodes[0].token, in: fixture.workspaceId))
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertNil(fixture.engine.liveFloatingFrame(for: pulled.token, in: fixture.workspaceId))
        XCTAssertEqual(fixture.storage(tabbed).count, 3)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === pulled)
    }

    func testPullingATabRequiresATabbedColumnAndATitleBarDragStillMovesItWhole() {
        var fixture = makeFixture()
        XCTAssertFalse(fixture.beginPull(fixture.window(2)))
        let tabbed = fixture.makeTabbed(3)
        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(fixture.engine.liveColumnMove?.isWholeColumn, true)
        XCTAssertEqual(fixture.engine.liveColumnMove.map { $0.home != .stackSlot }, true)
        XCTAssertTrue(fixture.engine.isLiveDraggedColumn(tabbed))
    }

    func testAHeightSpringStartsAtTheOldHeightAndSettlesAtTheNewOne() throws {
        let window = NiriWindow(token: WindowToken(pid: 943, windowId: 1))
        let delta: CGFloat = 120
        window.animateHeightFrom(delta: delta, clock: nil, animated: true)
        let spring = try XCTUnwrap(window.heightAnimation).animation

        XCTAssertEqual(window.renderHeightOffset(at: spring.startTime), delta)
        XCTAssertTrue(window.hasMoveAnimationsRunning)
        XCTAssertEqual(window.renderHeightOffset(at: .infinity), 0)
        XCTAssertFalse(window.tickMoveAnimations(at: .infinity))
        XCTAssertNil(window.heightAnimation)

        window.animateHeightFrom(delta: delta, clock: nil, animated: false)
        XCTAssertNil(window.heightAnimation)
        XCTAssertEqual(window.renderHeightOffset(at: spring.startTime), 0)
    }

    func testAHeightSpringRestartedFromAPredictedLayoutStartsFromTheDrawnHeight() throws {
        let fixture = makeFixture(widths: [0.5], activeIndex: 0)
        let window = fixture.window(0)
        let token = fixture.tokens[0]
        let delta: CGFloat = 120
        window.animateHeightFrom(delta: delta, clock: nil, animated: true)
        let previous = try XCTUnwrap(window.heightAnimation)
        let now = previous.animation.startTime
        let drawn = CGRect(x: 0, y: 0, width: 400, height: 500 + delta)
        let predicted = CGRect(x: 0, y: 0, width: 400, height: 400)

        let newFrames = fixture.engine.framesIncludingSizeAnimations(
            [token: predicted], in: fixture.workspaceId, at: now
        )
        XCTAssertEqual(newFrames, [token: CGRect(
            x: predicted.minX, y: predicted.minY, width: predicted.width, height: predicted.height + delta
        )])
        XCTAssertTrue(fixture.engine.animateFilledSizeChanges(
            in: fixture.workspaceId,
            oldFrames: [token: drawn],
            newFrames: newFrames,
            motion: .enabled,
            orientation: .horizontal
        ))

        let restarted = try XCTUnwrap(window.heightAnimation)
        let expected = drawn.height - (predicted.height + delta)
            + previous.currentOffset(at: restarted.animation.startTime)
        XCTAssertEqual(window.renderHeightOffset(at: restarted.animation.startTime), expected)
        XCTAssertEqual(window.renderHeightOffset(at: .infinity), 0)
    }

    func testWidthRetargetKeepsTheDrawnWidthAndPreservesTheHeightSpring() throws {
        let window = NiriWindow(token: WindowToken(pid: 943, windowId: 2))
        let heightDelta: CGFloat = 80
        let widthDelta: CGFloat = 120
        let nextDelta: CGFloat = -40
        window.animateHeightFrom(delta: heightDelta, clock: nil, animated: true)
        let height = try XCTUnwrap(window.heightAnimation)
        window.animateWidthFrom(delta: widthDelta, clock: nil, animated: true)
        let previous = try XCTUnwrap(window.widthAnimation)
        XCTAssertEqual(window.renderWidthOffset(at: previous.animation.startTime), widthDelta)
        XCTAssertTrue(window.tickMoveAnimations(at: previous.animation.startTime))

        window.animateWidthFrom(delta: nextDelta, clock: nil, animated: true)

        let retargeted = try XCTUnwrap(window.widthAnimation)
        let start = retargeted.animation.startTime
        XCTAssertEqual(window.renderWidthOffset(at: start), nextDelta + previous.currentOffset(at: start))
        let expectedVelocity = previous.currentVelocity(at: start)
        let expectedSpring = SpringAnimation(
            from: 1, to: 0, initialVelocity: expectedVelocity, startTime: start, config: .default
        )
        XCTAssertEqual(retargeted.currentVelocity(at: start), expectedSpring.velocity(at: start))
        XCTAssertTrue(try XCTUnwrap(window.heightAnimation).animation === height.animation)
        XCTAssertEqual(window.renderHeightOffset(at: start), height.currentOffset(at: start))
        XCTAssertTrue(window.hasAnyAnimationRunning)
        XCTAssertEqual(window.renderWidthOffset(at: .infinity), 0)
        XCTAssertEqual(window.renderHeightOffset(at: .infinity), 0)
        XCTAssertFalse(window.tickMoveAnimations(at: .infinity))
        XCTAssertFalse(window.hasMoveAnimationsRunning)
        XCTAssertNil(window.widthAnimation)
        XCTAssertNil(window.heightAnimation)
    }

    func testSizeSpringsCanStopIndependentlyAndRestartAfterBothStop() throws {
        let fixture = makeFixture(widths: [0.5], activeIndex: 0)
        let window = fixture.window(0)
        let delta = fixture.gap
        window.animateHeightFrom(delta: delta, clock: nil, animated: true)
        window.animateWidthFrom(delta: delta, clock: nil, animated: true)
        let height = try XCTUnwrap(window.heightAnimation)

        window.animateWidthFrom(delta: delta, clock: nil, animated: false)

        XCTAssertNil(window.widthAnimation)
        XCTAssertTrue(try XCTUnwrap(window.heightAnimation).animation === height.animation)
        XCTAssertEqual(window.renderHeightOffset(at: height.animation.startTime), delta)
        XCTAssertTrue(window.hasAnyAnimationRunning)
        window.animateWidthFrom(delta: delta, clock: nil, animated: true)
        let width = try XCTUnwrap(window.widthAnimation)

        window.animateHeightFrom(delta: delta, clock: nil, animated: false)

        XCTAssertNil(window.heightAnimation)
        XCTAssertTrue(try XCTUnwrap(window.widthAnimation).animation === width.animation)
        XCTAssertEqual(window.renderWidthOffset(at: width.animation.startTime), delta)
        XCTAssertTrue(window.hasAnyAnimationRunning)
        XCTAssertFalse(window.tickMoveAnimations(at: .infinity))
        XCTAssertNil(window.heightAnimation)
        XCTAssertNil(window.widthAnimation)
        window.animateHeightFrom(delta: delta, clock: nil, animated: true)
        let restarted = try XCTUnwrap(window.heightAnimation)
        XCTAssertEqual(window.renderHeightOffset(at: restarted.animation.startTime), delta)
        XCTAssertNil(window.widthAnimation)
        window.stopMoveAnimations()
        XCTAssertFalse(window.hasAnyAnimationRunning)
    }

    func testWidthAnimationRendersActualWidthAndStopsWithWindowMotion() throws {
        let window = NiriWindow(token: WindowToken(pid: 943, windowId: 3))
        let settled = CGRect(x: 20, y: 30, width: 400, height: 500)
        let oldWidth = settled.width / 2
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 1600)
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            window.animateWidthFrom(delta: oldWidth - settled.width, clock: nil, animated: true)
            let spring = try XCTUnwrap(window.widthAnimation).animation
            let start = window.animatedFrame(
                from: settled, within: bounds, at: spring.startTime, orientation: orientation
            )
            XCTAssertEqual(start, CGRect(x: settled.minX, y: settled.minY, width: oldWidth, height: settled.height))
            XCTAssertEqual(
                window.animatedFrame(from: settled, within: bounds, at: .infinity, orientation: orientation),
                settled
            )
            window.stopMoveAnimations()
            XCTAssertFalse(window.hasAnyAnimationRunning)
            XCTAssertNil(window.widthAnimation)
        }
        window.animateWidthFrom(delta: oldWidth - settled.width, clock: nil, animated: true)
        window.animateWidthFrom(delta: oldWidth - settled.width, clock: nil, animated: false)
        XCTAssertNil(window.widthAnimation)
        XCTAssertFalse(window.hasAnyAnimationRunning)
    }

    func testDisablingTabMotionClearsSpringsEvenWhenTheTabHasNoDisplacement() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = makeFixture(widths: [0.5], activeIndex: 0)
            let window = fixture.window(0)
            let delta = fixture.gap
            window.animateMoveFrom(displacement: CGPoint(x: delta, y: delta), clock: nil, animated: true)
            window.animateHeightFrom(delta: delta, clock: nil, animated: true)
            window.animateWidthFrom(delta: delta, clock: nil, animated: true)
            XCTAssertTrue(window.hasAnyAnimationRunning)

            XCTAssertTrue(fixture.engine.setColumnDisplay(
                .tabbed,
                for: fixture.column(0),
                in: fixture.workspaceId,
                motion: .disabled,
                orientation: orientation
            ))

            XCTAssertFalse(window.hasAnyAnimationRunning)
            XCTAssertNil(window.moveXAnimation)
            XCTAssertNil(window.moveYAnimation)
            XCTAssertNil(window.heightAnimation)
            XCTAssertNil(window.widthAnimation)
        }
    }

    func testAWindowThatBecomesTiledGlidesFromWhereItWasIntoItsSlot() {
        var fixture = makeFixture(widths: [0.25], activeIndex: 0)
        fixture.motion = .enabled
        let token = WindowToken(pid: 941, windowId: 99)
        let stale = WindowToken(pid: 941, windowId: 98)
        let start = CGRect(x: 300, y: 200, width: 500, height: 400)
        let now = CACurrentMediaTime()
        fixture.engine.noteStripGlide(for: token, from: start)
        fixture.engine.noteStripGlide(for: stale, from: start)
        for added in [token, stale] {
            _ = fixture.engine.addWindow(token: added, to: fixture.workspaceId, afterSelection: nil)
        }
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        let landed = fixture.frames()[token]
        fixture.engine.glideIntoStrip([token], context: fixture.context, state: fixture.state)

        let first = fixture.frames(at: now)[token]
        XCTAssertEqual(first?.minX ?? 0, start.minX, accuracy: 2)
        XCTAssertEqual(first?.minY ?? 0, start.minY, accuracy: 2)
        XCTAssertEqual(first?.height ?? 0, start.height, accuracy: 2)
        let settled = fixture.frames(at: now + 10)[token]
        XCTAssertEqual(settled?.minX ?? 0, landed?.minX ?? 1, accuracy: 1)
        XCTAssertEqual(settled?.minY ?? 0, landed?.minY ?? 1, accuracy: 1)
        XCTAssertFalse(fixture.engine.findNode(for: stale, in: fixture.workspaceId)?.hasMoveAnimationsRunning ?? true)
        XCTAssertTrue(fixture.engine.stripGlides.isEmpty)
    }

    func testAGlideWaitsForItsWindowToBePlacedHoweverLongItTakes() {
        let fixture = makeFixture(widths: [0.25], activeIndex: 0)
        let token = WindowToken(pid: 941, windowId: 96)
        fixture.engine.noteStripGlide(for: token, from: CGRect(x: 300, y: 200, width: 500, height: 400))

        for _ in 0 ..< 3 {
            fixture.engine.glideIntoStrip([], context: fixture.context, state: fixture.state)
        }

        XCTAssertNotNil(fixture.engine.stripGlides[token])
    }

    func testAWindowThatBecomesTiledOnAPortraitStripDoesntGlide() {
        let fixture = makeFixture(widths: [0.25], activeIndex: 0)
        let token = WindowToken(pid: 941, windowId: 97)
        fixture.engine.noteStripGlide(for: token, from: CGRect(x: 300, y: 200, width: 500, height: 400))
        _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, afterSelection: nil)
        let portrait = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .enabled,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .vertical
        )

        fixture.engine.glideIntoStrip([token], context: portrait, state: fixture.state)

        XCTAssertFalse(fixture.engine.findNode(for: token, in: fixture.workspaceId)?.hasMoveAnimationsRunning ?? true)
        XCTAssertTrue(fixture.engine.stripGlides.isEmpty)
    }

    func testAWindowDroppedOutOfAStackGrowsToItsFullHeightSmoothly() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        fixture.stack(3, onto: 2)
        let stacked = fixture.span(of: 3)
        XCTAssertTrue(fixture.begin(3))
        let edge = fixture.stripColumn(fixture.column(2)).maxX + 20
        XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: 450)), .changed)
        let released = CGRect(x: edge, y: stacked.minY, width: 200, height: stacked.maxY - stacked.minY)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: released,
            context: fixture.context,
            state: &fixture.state
        ))

        let now = CACurrentMediaTime()
        XCTAssertEqual(fixture.frames(at: now)[fixture.tokens[3]]?.height ?? 0, released.height, accuracy: 2)
        XCTAssertEqual(
            fixture.frames(at: now + 10)[fixture.tokens[3]]?.height ?? 0,
            fixture.frame.height - 2 * fixture.gap,
            accuracy: 2
        )
    }

    func testAPlainDropReleasedLowerOnlyMovesTheWindowAtItsOwnSize() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        guard let before = fixture.frames(at: CACurrentMediaTime())[fixture.tokens[2]] else {
            return XCTFail("no frame before the drag")
        }
        XCTAssertTrue(fixture.begin(2))
        let released = before.offsetBy(dx: 0, dy: -130)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: released,
            context: fixture.context,
            state: &fixture.state
        ))

        let now = CACurrentMediaTime()
        let samples = (0 ... 12).compactMap { step in
            fixture.frames(at: now + Double(step) * 0.05)[fixture.tokens[2]]
        }
        XCTAssertEqual(samples.first?.minY ?? 0, released.minY, accuracy: 1)
        for sample in samples {
            XCTAssertEqual(sample.width, before.width, accuracy: 0.5)
            XCTAssertEqual(sample.height, before.height, accuracy: 0.5)
        }
        let settled = fixture.frames(at: now + 10)[fixture.tokens[2]]
        XCTAssertEqual(settled?.minY ?? 0, before.minY, accuracy: 1)
        XCTAssertEqual(settled?.minX ?? 0, before.minX, accuracy: 1)
    }

    func testATabPullDetachesTheTabAtOnceAndOpensADropSpaceBesideTheTabs() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        let next = tabbed.windowNodes[2]
        let tabbedX = fixture.stripColumn(tabbed).minX
        XCTAssertTrue(fixture.beginPull(pulled))
        let cursor = CGPoint(x: fixture.stripColumn(tabbed).minX + 5, y: 450)

        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: false,
            cursor: cursor,
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertEqual(tabbed.windowNodes.count, 2)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === next)
        XCTAssertEqual(fixture.stripColumn(tabbed).minX, tabbedX, accuracy: 0.5)
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)!
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)
        XCTAssertEqual(fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX, -fixture.gap, accuracy: 0.5)
        let dropSpace = fixture.engine.columns(in: fixture.workspaceId)[2]
        XCTAssertTrue(dropSpace.isLiveDropSpace)
        XCTAssertEqual(
            fixture.stripColumn(dropSpace).maxX - fixture.stripColumn(dropSpace).minX,
            fixture.frame.width * 0.05,
            accuracy: 0.5
        )
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .origin)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(tabbed.windowNodes.count, 3)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === pulled)
    }

    func testAfterLeavingAStackTheWindowUnderThePointerDoesNotMoveTheGapUntilThePointerLeavesIt() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let neighbour = fixture.column(4)
        XCTAssertTrue(fixture.begin(3))
        let cursor = CGPoint(x: fixture.stripColumn(stack).maxX + 150, y: 450)

        let neighbourX = fixture.stripColumn(neighbour).minX
        XCTAssertEqual(fixture.move(to: cursor), .changed)
        let home = fixture.column(3)
        XCTAssertEqual(fixture.stripColumn(neighbour).minX, neighbourX, accuracy: 0.5)
        XCTAssertTrue(fixture.stripColumn(neighbour).contains(x: cursor.x))
        let expected = [[0], [1], [2], [3], [], [4]].map { $0.map { fixture.tokens[$0] } }

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x - 40, y: 300)), .unchanged)
        XCTAssertEqual(fixture.columnOrder(), expected)
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)

        let dropSpace = fixture.engine.columns(in: fixture.workspaceId)[4]
        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(dropSpace).midX, y: 450)), .unchanged)
        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(neighbour).maxX - 60, y: 450)), .changed)
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)
        XCTAssertEqual(fixture.engine.columnIndex(of: dropSpace, in: fixture.workspaceId), 5)
    }

    func testTheNearHalfOfANeighbourWithoutAGapOpensOne() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: true,
            cursor: CGPoint(x: fixture.stripColumn(tabbed).maxX - 20, y: 450),
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        let left = fixture.stripColumn(fixture.column(1))
        let facingTheTabbedColumn = CGPoint(x: left.maxX - (left.maxX - left.minX) / 4, y: 450)

        XCTAssertEqual(fixture.move(to: facingTheTabbedColumn), .changed)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let homeIndex = columns.firstIndex { $0.windowNodes.contains { $0 === pulled } || $0.isLiveDropSpace }
        let leftIndex = columns.firstIndex { $0 === fixture.column(1) }
        XCTAssertEqual(homeIndex, leftIndex.map { $0 + 1 })
    }

    func testAfterPullingATabThePointerOverItsOldColumnDoesNotMoveTheGap() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        let cursor = CGPoint(x: fixture.stripColumn(tabbed).minX + 20, y: 450)
        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: true,
            cursor: cursor,
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)!
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + 60, y: 300)), .unchanged)
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)
        XCTAssertEqual(fixture.engine.columnIndex(of: tabbed, in: fixture.workspaceId), 2)
    }

    func testCancelRestoresTheActiveWindowOfAStackEvenWhenTheDraggedWindowEndsWhereItStarted() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.stack(4, onto: 3)
        let stack = fixture.column(2)
        stack.setActiveTileIdx(2)
        XCTAssertTrue(fixture.begin(2))

        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertNotEqual(stack.activeTileIdx, 2)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(stack.activeTileIdx, 2)
    }

    func testBothAxesReorderSecondarySlotsWithoutMovingTheStrip() {
        for (orientation, frame) in axisFrames {
            var fixture = makeFixture(orientation: orientation, frame: frame)
            fixture.stack(3, onto: 2)
            fixture.stack(4, onto: 3)
            let stack = fixture.column(2)
            let stripBefore = fixture.strip().map(\.minX)
            let frames = fixture.frames()
            let secondaryOrigin = orientation == .horizontal ? frame.minY : frame.minX
            let secondarySpan = (fixture.context.secondarySpan - 4 * fixture.gap) / 3
            for (slot, index) in [2, 3, 4].enumerated() {
                let start = secondaryOrigin + fixture.gap + CGFloat(slot) * (secondarySpan + fixture.gap)
                let span = fixture.span(of: index)
                let physical = frames[fixture.tokens[index]]
                XCTAssertEqual(span.minY, start)
                XCTAssertEqual(span.maxY, start + secondarySpan)
                XCTAssertEqual(orientation == .horizontal ? physical?.minY : physical?.minX, start)
                XCTAssertEqual(orientation == .horizontal ? physical?.maxY : physical?.maxX, start + secondarySpan)
            }
            XCTAssertTrue(fixture.begin(2))
            XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)

            XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
            XCTAssertEqual(fixture.storage(stack), [3, 2, 4].map { fixture.tokens[$0] })
            XCTAssertEqual(fixture.move(to: fixture.middle(of: 2)), .unchanged)
            XCTAssertEqual(fixture.move(to: fixture.middle(of: 4)), .changed)
            XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
            XCTAssertEqual(fixture.strip().map(\.minX), stripBefore)

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.window(2).id)
            XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 3)
        }
    }

    func testBothAxesCancelSecondaryReorderAndDetachRestoresBothFixedSpecs() {
        for (orientation, frame) in axisFrames {
            for detaches in [false, true] {
                var fixture = makeFixture(orientation: orientation, frame: frame)
                fixture.stack(3, onto: 2)
                fixture.stack(4, onto: 3)
                let stack = fixture.column(2)
                stack.setActiveTileIdx(2)
                for index in [2, 3, 4] {
                    fixture.window(index).height = .fixed(CGFloat(index + 1) * fixture.gap * 3)
                    fixture.window(index).windowWidth = .fixed(CGFloat(index + 2) * fixture.gap * 3)
                }
                let state = fixture.state
                let order = fixture.columnOrder()
                let sizing = fixture.engine.containerSizingState(for: stack)
                XCTAssertTrue(fixture.begin(2))
                XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
                if detaches {
                    let cursor = fixture.context.point(
                        primary: fixture.stripColumn(stack).maxX + fixture.gap,
                        secondary: fixture.context.secondaryCoordinate(of: fixture.middle(of: 2))
                    )
                    XCTAssertEqual(fixture.move(to: cursor), .changed)
                    XCTAssertFalse(fixture.column(2) === stack)
                    XCTAssertEqual(fixture.engine.liveColumnMove?.home, .origin)
                }

                XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

                XCTAssertTrue(fixture.column(2) === stack)
                XCTAssertEqual(fixture.columnOrder(), order)
                XCTAssertEqual(stack.activeTileIdx, 2)
                XCTAssertEqual(fixture.state.selectedNodeId, state.selectedNodeId)
                XCTAssertEqual(fixture.state.activeColumnIndex, state.activeColumnIndex)
                XCTAssertEqual(fixture.state.viewOffset, state.viewOffset)
                XCTAssertEqual(fixture.engine.containerSizingState(for: stack), sizing)
                for index in [2, 3, 4] {
                    XCTAssertEqual(fixture.window(index).height, .fixed(CGFloat(index + 1) * fixture.gap * 3))
                    XCTAssertEqual(fixture.window(index).windowWidth, .fixed(CGFloat(index + 2) * fixture.gap * 3))
                    XCTAssertNil(fixture.window(index).liveSpanOverride)
                    XCTAssertNil(fixture.window(index).deferredMinimumOrientation)
                }
                XCTAssertFalse(fixture.strip().contains { $0.column.isLiveDropSpace || $0.column.isLiveHomeSpot })
            }
        }
    }

    func testBothAxesDetachedWindowReleaseUsesPhysicalSizeAndSecondaryMotion() throws {
        for (orientation, frame) in axisFrames {
            for animated in [false, true] {
                var fixture = makeFixture(orientation: orientation, frame: frame)
                fixture.engine.animationClock = AnimationClock(time: 0)
                fixture.stack(3, onto: 2)
                let stack = fixture.column(2)
                let primarySpan = fixture.stripColumn(stack).width
                let secondarySpan = (fixture.context.secondarySpan - 3 * fixture.gap) / 2
                let secondaryOrigin = orientation == .horizontal ? frame.minY : frame.minX
                let primary = fixture.stripColumn(stack).maxX + fixture.gap
                XCTAssertTrue(fixture.begin(3))
                let cursor = fixture.context.point(primary: primary, secondary: secondaryOrigin + secondarySpan / 2)
                XCTAssertEqual(fixture.move(to: cursor), .changed)
                XCTAssertFalse(fixture.column(3) === stack)
                let releaseOrigin = fixture.context.point(
                    primary: primary,
                    secondary: secondaryOrigin + 2 * fixture.gap
                )
                let release = CGRect(
                    origin: releaseOrigin,
                    size: orientation == .horizontal
                        ? CGSize(width: primarySpan, height: secondarySpan)
                        : CGSize(width: secondarySpan, height: primarySpan)
                )
                fixture.motion = animated ? .enabled : .disabled
                fixture.state.clearOffsetTransition()
                let previousViewport = fixture.state
                let driver = AnimationDriver()

                XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
                    releasedFrame: release,
                    context: fixture.context,
                    state: &fixture.state
                ))

                driver.reconcileViewportCommit(
                    workspaceId: fixture.workspaceId,
                    previous: previousViewport,
                    next: fixture.state,
                    transition: fixture.state.offsetTransition,
                    at: 0
                )
                let window = fixture.window(3)
                if animated {
                    XCTAssertTrue(driver.hasMotion(in: fixture.workspaceId))
                    let offsets = driver.renderOffsets(
                        in: fixture.workspaceId,
                        semanticOffset: fixture.state.viewOffset,
                        at: 0
                    )
                    let releasedLayout = fixture.engine.calculateLayoutWithVisibility(
                        state: fixture.state,
                        workspaceId: fixture.workspaceId,
                        monitorFrame: fixture.frame,
                        gaps: (fixture.gap, fixture.gap),
                        orientation: orientation,
                        animationTime: 0,
                        viewOffsetOverride: offsets.liveOffset,
                        settledVisibilityOffset: offsets.settledVisibilityOffset
                    )
                    XCTAssertEqual(releasedLayout.frames[fixture.tokens[3]], release)
                    if orientation == .horizontal {
                        XCTAssertNotNil(window.heightAnimation)
                        XCTAssertNil(window.widthAnimation)
                    } else {
                        XCTAssertNotNil(window.widthAnimation)
                        XCTAssertNil(window.heightAnimation)
                    }
                } else {
                    XCTAssertFalse(window.hasMoveAnimationsRunning)
                }
                let settled = try XCTUnwrap(fixture.frames(at: .infinity)[fixture.tokens[3]])
                XCTAssertEqual(
                    orientation == .horizontal ? settled.height : settled.width,
                    fixture.context.secondarySpan - 2 * fixture.gap
                )
                XCTAssertEqual(orientation == .horizontal ? settled.width : settled.height, primarySpan)
                XCTAssertEqual(orientation == .horizontal ? settled.minY : settled.minX, secondaryOrigin + fixture.gap)
                XCTAssertEqual(fixture.state.selectedNodeId, window.id)
                XCTAssertFalse(fixture.strip().contains { $0.column.isLiveDropSpace || $0.column.isLiveHomeSpot })
            }
        }
    }
}
