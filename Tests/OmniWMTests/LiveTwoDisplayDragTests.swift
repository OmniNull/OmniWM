// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testCrossingClosesTheWindowsPlaceAndOpensADropSpaceBesideTheColumnUnderThePointer() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture

        try dragOnto(drag.residents[0], .right, drag)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        let move = try XCTUnwrap(fixture.niri.liveColumnMove)
        XCTAssertEqual(move.workspaceId, fixture.target)
        XCTAssertEqual(move.carry?.originalWorkspaceId, fixture.source)
        XCTAssertEqual(move.home, .origin)
        XCTAssertNotNil(move.originClosedToward)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved], []])
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let strip = fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        )
        let column = try XCTUnwrap(carriedColumn(drag))
        XCTAssertFalse(column.isLiveHomeSpot)
        let placed = try XCTUnwrap(strip.first { $0.column === column })
        XCTAssertEqual(placed.maxX - placed.minX, -context.gaps, accuracy: 0.5)
        let dropSpace = try XCTUnwrap(fixture.niri.liveDropSpace(for: move))
        let space = try XCTUnwrap(strip.first { $0.column === dropSpace })
        XCTAssertEqual(space.maxX - space.minX, fixture.niri.liveDropSpaceWidth(context: context), accuracy: 0.5)
        let display = fixture.monitors[1].frame
        XCTAssertTrue(space.minX >= display.minX && space.maxX <= display.maxX)
        let under = try XCTUnwrap(strip.first { $0.column.windowNodes.first?.token == drag.residents[0] })
        XCTAssertEqual(space.minX, under.maxX + context.gaps, accuracy: 0.5)
    }

    func testAnEdgeHopAfterACarryMovesTheDropSpaceAndOpensNoSecondGap() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 4)
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)
        let column = try XCTUnwrap(carriedColumn(drag))
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))

        let passed = fixture.manager.withNiriViewportState(for: fixture.target) { state in
            fixture.niri.liveColumnMoveHop(towardTrailingEdge: true, context: context, state: &state)
        }

        let beside = try XCTUnwrap(passed)
        let columns = fixture.niri.columns(in: fixture.target)
        XCTAssertEqual(columns.filter(\.isLiveDropSpace).count, 1)
        let index = try XCTUnwrap(columns.firstIndex { $0 === beside })
        XCTAssertTrue(columns.indices.contains(index + 1) && columns[index + 1].isLiveDropSpace)
        XCTAssertTrue(fixture.niriNode(drag.moved)?.parent === column)
    }

    func testTheDropSpaceOnTheOtherDisplayHasTheRegularWidthWhateverTheWindow() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        let window = try XCTUnwrap(fixture.niriNode(drag.moved))
        window.packingHints = ObservedPackingHints(width: ObservedAxisHint(requested: 40, observed: 640))

        try dragOnto(drag.residents[0], .right, drag)

        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let placed = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column.isLiveDropSpace })
        XCTAssertEqual(placed.maxX - placed.minX, fixture.niri.liveDropSpaceWidth(context: context), accuracy: 0.5)
    }

    func testOnTheOtherDisplayTheColumnUnderThePointerStaysPutUpToTheEdge() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 7)
        let fixture = drag.fixture
        let widths: [CGFloat] = [0.5, 0.5, 0.5, 0.5, 0.15, 0.15, 0.15]
        for (column, width) in zip(fixture.niri.columns(in: fixture.target), widths) {
            column.width = .proportion(width)
            column.cachedWidth = 0
        }
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        func placed(_ token: WindowToken) throws -> LiveColumnMove.StripColumn {
            try XCTUnwrap(fixture.niri.liveColumnStrip(
                context: context,
                state: fixture.manager.niriViewportState(for: fixture.target)
            ).first { $0.column.windowNodes.first?.token == token })
        }
        let entered = try placed(drag.residents[1])
        let point = CGPoint(x: entered.maxX - 60, y: fixture.monitors[1].frame.midY)

        fixture.handler.dispatchMouseDragged(at: point)
        fixture.handler.dispatchMouseDragged(at: point)

        var expected = drag.residents.map { [$0] }
        expected.insert([drag.moved], at: 2)
        expected.insert([], at: 3)
        XCTAssertEqual(fixture.columns(fixture.target), expected)
        let dropSpace = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column.isLiveDropSpace })
        let underPointer = try [placed(drag.residents[1]), dropSpace]
        XCTAssertTrue(underPointer.contains { $0.contains(x: point.x) })

        let entering = try placed(drag.residents[1])
        let edge = fixture.monitors[1].frame.maxX - 2
        for x in stride(from: point.x, through: edge, by: 20) {
            fixture.handler.dispatchMouseDragged(at: CGPoint(x: x, y: point.y))
        }
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: edge, y: point.y))

        XCTAssertEqual(fixture.columns(fixture.target), expected)
        XCTAssertEqual(try placed(drag.residents[1]).minX, entering.minX, accuracy: 0.5)
    }

    func testReleasingOnTheOtherDisplayStartsTheSettleFromWhereTheStripIs() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 7)
        let fixture = drag.fixture
        fixture.controller.motionPolicy.animationsEnabled = true
        let widths: [CGFloat] = [0.5, 0.5, 0.5, 0.5, 0.15, 0.15, 0.15]
        for (column, width) in zip(fixture.niri.columns(in: fixture.target), widths) {
            column.width = .proportion(width)
            column.cachedWidth = 0
        }
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        func minX(_ token: WindowToken, _ state: ViewportState) throws -> CGFloat {
            try XCTUnwrap(fixture.niri.liveColumnStrip(context: context, state: state)
                .first { $0.column.windowNodes.first?.token == token }).minX
        }
        let entered = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column.windowNodes.first?.token == drag.residents[1] })
        let point = CGPoint(x: entered.maxX - 60, y: fixture.monitors[1].frame.midY)
        fixture.handler.dispatchMouseDragged(at: point)
        var state = fixture.manager.niriViewportState(for: fixture.target)
        state.clearOffsetTransition()
        let shown = try minX(drag.residents[1], state)
        let offsetBefore = state.viewOffset

        fixture.manager.withEngineMutationScope(in: fixture.target) {
            _ = fixture.niri.liveColumnMoveEnd(releasedAt: point, context: context, state: &state)
        }

        var settleStart = state
        settleStart.viewOffset = offsetBefore + state.offsetTransition.rebaseDelta
        XCTAssertEqual(try minX(drag.residents[1], settleStart), shown, accuracy: 0.5)
    }

    func testATitleBarDragAloneCarriesTheWindowAndLandsItOnTheOtherDisplay() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture

        let point = try dragOnto(drag.residents[0], .right, drag)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved], []])

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved]])
    }

    func testANativeFullscreenSpaceOnTheOtherDisplayGetsTheHandOverAndTheDragResumesBack() throws {
        for pending in [false, true] {
            let drag = try startLiveTwoDisplayDrag()
            let fixture = drag.fixture
            let sourceColumns = [[drag.neighbour], [drag.moved]]
            let resident = drag.residents[0]
            fixture.layout()
            let over = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right)
            if pending {
                XCTAssertTrue(fixture.manager.requestNativeFullscreenEnter(resident, in: fixture.target))
            } else {
                XCTAssertTrue(fixture.manager.markNativeFullscreenSuspended(resident, ownsNativeFocus: false))
            }
            fixture.manager.commitSpaceTopology(SpaceTopology(
                displays: fixture.monitors.enumerated().map { index, monitor in
                    .init(
                        displayIdentifier: String(monitor.displayId),
                        spaceIds: [UInt64(index + 1)],
                        currentSpaceId: UInt64(index + 1)
                    )
                },
                activeSpaceId: 1,
                fullscreenSpaceIds: pending ? [] : [2]
            ))
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive, "pending \(pending)")

            fixture.handler.dispatchMouseDragged(at: over)

            XCTAssertFalse(fixture.handler.isLiveColumnDragActive, "pending \(pending)")
            XCTAssertNil(fixture.niri.liveColumnMove, "pending \(pending)")
            XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source, "pending \(pending)")
            XCTAssertEqual(fixture.columns(fixture.source), sourceColumns, "pending \(pending)")

            fixture.layout()
            let back = try dropPoint(in: XCTUnwrap(fixture.frame(drag.neighbour)), .left)
            fixture.handler.dispatchMouseDragged(at: back)

            XCTAssertTrue(fixture.handler.isLiveColumnDragActive, "pending \(pending)")
            XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.source, "pending \(pending)")
            XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source, "pending \(pending)")
        }
    }

    func testCrossingOnATargetsLeftHalfOpensTheDropSpaceBeforeIt() throws {
        let drag = try startLiveTwoDisplayDrag()

        try dragOnto(drag.residents[0], .left, drag)

        XCTAssertEqual(drag.fixture.columns(drag.fixture.target), [[], [drag.moved], [drag.residents[0]]])
    }

    func testCrossingFromAStackClosesTheSlotAndKeepsTheStack() throws {
        let drag = try startLiveTwoDisplayDrag(stacked: true)
        let fixture = drag.fixture
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour, drag.moved]])

        try dragOnto(drag.residents[0], .right, drag)

        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved], []])
    }

    func testCrossingIntoAnEmptyWorkspaceMakesTheOnlyColumn() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 0)
        let fixture = drag.fixture

        fixture.handler.dispatchMouseDragged(at: fixture.monitors[1].frame.center)

        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.moved]])
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
    }

    func testAStillPointerAfterCrossingChangesNothingMore() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        let point = try dragOnto(drag.residents[0], .right, drag)
        let columns = fixture.columns(fixture.target)

        fixture.handler.dispatchMouseDragged(at: point)
        fixture.handler.dispatchMouseDragged(at: point)

        XCTAssertEqual(fixture.columns(fixture.target), columns)
    }

    func testOnTheOtherDisplayATargetMovesTheDropSpace() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [], [drag.residents[1]]]
        )

        fixture.layout()
        let display = try XCTUnwrap(fixture.manager.monitor(for: fixture.target)).frame
        let visible = try XCTUnwrap(fixture.frame(drag.residents[1])).intersection(display)
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: visible.maxX - visible.width / 4, y: visible.midY))

        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [drag.residents[1]], []]
        )
        XCTAssertNotNil(fixture.niri.liveColumnMove?.dropSpaceId)
    }

    func testOnTheOtherDisplayTheDropSpaceMovesLikeAPlainDragsWithTheWindowUnderThePointerStill() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 3)
        let fixture = drag.fixture
        let narrow = try XCTUnwrap(fixture.niriNode(drag.residents[1])?.parent as? NiriContainer)
        narrow.width = .proportion(0.3)
        narrow.cachedWidth = 0
        let target = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        try dragOnto(drag.residents[0], .right, drag)
        func placed(_ token: WindowToken) throws -> LiveColumnMove.StripColumn {
            try XCTUnwrap(fixture.niri.liveColumnStrip(
                context: target,
                state: fixture.manager.niriViewportState(for: fixture.target)
            ).first { $0.column.windowNodes.first?.token == token })
        }
        let next = try placed(drag.residents[1])
        fixture.layout()
        let display = try XCTUnwrap(fixture.manager.monitor(for: fixture.target)).frame
        let visible = try XCTUnwrap(fixture.frame(drag.residents[1])).intersection(display)
        let point = CGPoint(x: visible.maxX - visible.width / 4, y: visible.midY)
        XCTAssertTrue(next.contains(x: point.x))

        fixture.handler.dispatchMouseDragged(at: point)

        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [drag.residents[1]], [], [drag.residents[2]]]
        )
        XCTAssertEqual(try placed(drag.residents[1]).minX, next.minX, accuracy: 0.5)

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.residents[1]], [drag.moved], [drag.residents[2]]]
        )
    }

    func testTheWindowLandsAtItsOwnWidthOnTheOtherDisplay() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        let width = try XCTUnwrap(fixture.handler.nativeWindowFrameProvider(
            XCTUnwrap(XCTUnwrap(fixture.manager.entry(for: drag.moved)).axRef)
        )).width
        let point = try dragOnto(drag.residents[0], .right, drag)

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved]])
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.target).last)
        XCTAssertFalse(column.isLiveHomeSpot)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        XCTAssertEqual(column.width, fixture.niri.liveCarriedSizing(windowPrimarySpan: width, context: context).width)
        XCTAssertEqual(
            column.resolvedPrimarySpan(
                column.width,
                orientation: .horizontal,
                availableSpace: context.workingFrame.width,
                gaps: context.gaps,
                applyingPackingHints: false
            ),
            width,
            accuracy: 0.5
        )
    }

    func testACarriedWindowWiderThanTheDisplayLandsAtThatDisplaysEdgePeekCap() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2, edgePeekPercent: 5)
        let fixture = drag.fixture
        let start = try XCTUnwrap(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        let wide = CGRect(x: start.minX + 30, y: start.minY, width: 3000, height: start.height)
        fixture.handler.nativeWindowFrameProvider = { _ in wide }
        let point = try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [], [drag.residents[1]]]
        )

        fixture.handler.dispatchMouseUp(at: point)
        settleStackDrop(in: fixture.target, fixture)
        fixture.layout()

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [drag.residents[1]]]
        )
        let cap = try XCTUnwrap(carriedColumn(drag)?.edgePeekCap)
        let fullWidth = fixture.controller.insetWorkingFrame(for: fixture.monitors[1]).width
            - 2 * fixture.controller.innerGap(for: fixture.monitors[1])
        XCTAssertLessThan(cap, fullWidth)
        XCTAssertEqual(try XCTUnwrap(fixture.frame(drag.moved)).width, cap, accuracy: 0.5)
    }

    func testComingBackOpensADropSpaceAtThePointerAndLandsThere() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)

        let point = try dragOnto(drag.neighbour, .right, drag)

        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]]])
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour], [drag.moved], []])

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour], [drag.moved]])
    }

    func testCancellingAfterCrossingRestoresBothStrips() throws {
        for stacked in [false, true] {
            let drag = try startLiveTwoDisplayDrag(stacked: stacked)
            let fixture = drag.fixture
            let sourceColumns = fixture.columns(fixture.source)
            try dragOnto(drag.residents[0], .right, drag)

            fixture.handler.cancelLiveColumnDrag()

            XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
            XCTAssertNil(fixture.niri.liveColumnMove)
            XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
            XCTAssertEqual(fixture.columns(fixture.source), sourceColumns)
            XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]]])
        }
    }

    func testCancellingAfterCarryingTheLastWindowOfAStackRestoresItsHeight() throws {
        let drag = try startLiveTwoDisplayDrag(stacked: true, movedHeight: .fixed(300))
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)

        fixture.handler.cancelLiveColumnDrag()

        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour, drag.moved]])
        XCTAssertEqual(fixture.niriNode(drag.moved)?.height, .fixed(300))
    }

    func testAPointerCrossingIntoAGapLandsBesideTheNearestColumn() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 3)
        let fixture = drag.fixture
        fixture.layout()
        let first = try XCTUnwrap(fixture.frame(drag.residents[0]))
        let second = try XCTUnwrap(fixture.frame(drag.residents[1]))
        XCTAssertLessThan(first.maxX, second.minX)

        let source = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.source))
        let target = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        var carried: [WindowToken] = []
        let nearerTheFirst = CGPoint(x: (first.maxX + second.minX) / 2 - 3, y: first.midY)
        XCTAssertLessThan(nearerTheFirst.x - first.maxX, second.minX - nearerTheFirst.x)
        XCTAssertLessThan(abs(first.midX - nearerTheFirst.x), abs(second.midX - nearerTheFirst.x))

        fixture.manager.withBatchedCrossWorkspaceDrop(
            into: fixture.target,
            niriWorkspaceIds: [fixture.source, fixture.target]
        ) { viewports in
            carried = fixture.niri.liveColumnMoveCarry(
                cursor: nearerTheFirst,
                windowPrimarySpan: nil,
                from: source,
                to: target,
                viewports: &viewports
            )
            return carried.map { .init(token: $0, workspaceId: fixture.target) }
        }

        XCTAssertEqual(carried, [drag.moved])
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [], [drag.residents[1]], [drag.residents[2]]]
        )
    }

    func testGrabbingTheWindowWhileItsWriteBackIsPendingStartsALiveDrag() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        let entry = try XCTUnwrap(fixture.manager.entry(for: drag.moved))
        let start = try XCTUnwrap(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        try dragOnto(drag.residents[0], .right, drag)
        fixture.handler.cancelLiveColumnDrag()
        fixture.handler.dispatchMouseUp(at: start.center)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        fixture.controller.axManager.invalidateAppliedFrame(for: drag.moved.windowId)
        fixture.controller.axManager.forceApplyNextFrame(for: drag.moved.windowId)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: drag.moved.pid, window: try XCTUnwrap(entry.axRef), frame: start)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(drag.moved.windowId))
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: drag.moved.windowId))

        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: start.center, modifiers: [], windowIdUnderPointer: drag.moved.windowId
        ))
        fixture.handler.dispatchMouseDragged(at: start.center)
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 30, dy: 0) }
        _ = fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
    }

    func testCancellingAfterCrossingTwiceRestoresEveryStrip() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        let sourceColumns = fixture.columns(fixture.source)
        try dragOnto(drag.residents[0], .right, drag)
        try dragOnto(drag.neighbour, .left, drag)

        fixture.handler.cancelLiveColumnDrag()

        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.source), sourceColumns)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]]])
        XCTAssertNil(fixture.niri.liveColumnMove)
    }

    func testALoneWindowKeepsItsShownWidthWhileADragIsOverIt() throws {
        let drag = try startLiveTwoDisplayDrag(fusion: false)
        let fixture = drag.fixture
        fixture.layout()
        let lone = try XCTUnwrap(fixture.niri.columns(in: fixture.target).first)
        let ownWidth = lone.width
        let shown = try XCTUnwrap(fixture.frame(drag.residents[0]))

        fixture.handler.dispatchMouseDragged(at: CGPoint(x: shown.minX + shown.width * 0.3, y: shown.midY))

        XCTAssertEqual(fixture.columns(fixture.target), [[], [drag.moved], [drag.residents[0]]])
        XCTAssertEqual(lone.width, .fixed(shown.width))
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let placed = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column === lone })
        XCTAssertEqual(placed.maxX - placed.minX, shown.width, accuracy: 0.5)
        XCTAssertNotEqual(ownWidth, lone.width)
    }

    func testALoneWindowTakesItsOwnWidthBackOnReleaseCancelOrLeaving() throws {
        for ending in ["release", "cancel", "leave"] {
            let drag = try startLiveTwoDisplayDrag()
            let fixture = drag.fixture
            let lone = try XCTUnwrap(fixture.niri.columns(in: fixture.target).first)
            let ownWidth = lone.width
            let point = try dragOnto(drag.residents[0], .right, drag)
            XCTAssertNotEqual(lone.width, ownWidth, ending)

            switch ending {
            case "release": fixture.handler.dispatchMouseUp(at: point)
            case "cancel": fixture.handler.cancelLiveColumnDrag()
            default: try dragOnto(drag.neighbour, .right, drag)
            }

            XCTAssertEqual(lone.width, ownWidth, ending)
        }
    }

    func testALoneWindowTakesItsOwnWidthBackWhenTheEngineCutsTheDragOff() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        let lone = try XCTUnwrap(fixture.niri.columns(in: fixture.target).first)
        let ownWidth = lone.width
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertNotEqual(lone.width, ownWidth)
        let moved = try XCTUnwrap(fixture.niriNode(drag.moved))

        fixture.manager.withEngineMutationScope(in: fixture.target) {
            fixture.niri.cancelInteractions(for: [moved.id], in: fixture.target)
        }

        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(lone.width, ownWidth)
    }

    func testReleasingOnTheNearHalfOfTheNextWindowOnTheOtherDisplayLandsTheWindowBeforeIt() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 3)
        let fixture = drag.fixture
        try dragOnto(drag.residents[1], .left, drag)
        let columns = [[drag.residents[0]], [drag.moved], [drag.residents[1]], [drag.residents[2]]]
        let dragging = [[drag.residents[0]], [], [drag.moved], [drag.residents[1]], [drag.residents[2]]]
        XCTAssertEqual(fixture.columns(fixture.target), dragging)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.target)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let next = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column.windowNodes.first?.token == drag.residents[1] })
        let point = CGPoint(x: next.minX + (next.maxX - next.minX) * 0.2, y: fixture.monitors[1].frame.midY)
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.columns(fixture.target), dragging)

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.target), columns)
    }

    func testAWholeTabbedColumnCrossesWithItsTabs() throws {
        let drag = try startLiveTabbedColumnDrag()
        let fixture = drag.fixture
        let tabs = fixture.columns(fixture.source)[0]

        let point = try dragOnto(drag.resident, .right, drag.fixture)

        XCTAssertEqual(fixture.columns(fixture.source), [[drag.other]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs, []])
        for tab in tabs {
            XCTAssertEqual(fixture.manager.workspace(for: tab), fixture.target)
        }

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs])
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.target).last)
        XCTAssertTrue(column.isTabbed)
        XCTAssertFalse(column.isLiveHomeSpot)
        for tab in tabs {
            XCTAssertEqual(fixture.manager.workspace(for: tab), fixture.target)
        }
    }

    func testCancellingAfterAWholeTabbedColumnCrossesPutsItBack() throws {
        let drag = try startLiveTabbedColumnDrag()
        let fixture = drag.fixture
        let sourceColumns = fixture.columns(fixture.source)
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        let width = column.width
        try dragOnto(drag.resident, .right, drag.fixture)

        fixture.handler.cancelLiveColumnDrag()

        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(fixture.columns(fixture.source), sourceColumns)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident]])
        XCTAssertTrue(column.isTabbed)
        XCTAssertFalse(column.isLiveHomeSpot)
        XCTAssertEqual(column.width, width)
        for tab in sourceColumns[0] {
            XCTAssertEqual(fixture.manager.workspace(for: tab), fixture.source)
        }
    }

    func testALiveDragReturnsFromDwindleAfterACrossDisplaySwap() throws {
        let fixture = try makeNativeFixture([.niri, .dwindle])
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        fixture.niri.liveHoverDelay = 0
        let moved = addWindow(1, to: fixture.source, fixture)
        let neighbour = addWindow(2, to: fixture.source, fixture)
        let resident = addWindow(3, to: fixture.target, fixture)
        let start = try beginNativeDrag(moved, fixture)
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: start.width / 8, dy: 0) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        fixture.handler.dispatchMouseDragged(at: fixture.monitors[1].frame.center)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.columns(fixture.source), [[resident], [neighbour]])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.dwindle.liveMoveWorkspaceId, fixture.target)

        fixture.layout()
        let back = try dropPoint(in: XCTUnwrap(fixture.frame(neighbour)), .right)
        fixture.handler.dispatchMouseDragged(at: back)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.source)
        XCTAssertEqual(fixture.columns(fixture.source), [[resident], [neighbour], [moved]])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertEqual(fixture.dwindle.existingState(for: fixture.target)?.tileCount, 0)
        XCTAssertEqual(fixture.manager.entries(in: fixture.target).map(\.token), [])
        fixture.handler.handleInputSuppressionBegan()
        XCTAssertEqual(fixture.columns(fixture.source), [[moved], [neighbour]])
        XCTAssertEqual(fixture.dwindleTile(resident), [resident])
        XCTAssertEqual(fixture.manager.workspace(for: resident), fixture.target)
        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertTrue(fixture.handler.liveCrossDisplayMove == nil)
        XCTAssertEqual(fixture.niri.states[fixture.source]?.layoutHistory.undoSnapshots.count, 0)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.target).undo, 0)
    }

    func testALiveDragContinuesFromADwindleSwapOntoAThirdNiriDisplay() throws {
        let fixture = try makeNativeFixture([.niri, .dwindle, .niri])
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        fixture.niri.liveHoverDelay = 0
        let moved = addWindow(1, to: fixture.workspaces[0], fixture)
        let neighbour = addWindow(2, to: fixture.workspaces[0], fixture)
        let swapped = addWindow(3, to: fixture.workspaces[1], fixture)
        let resident = addWindow(4, to: fixture.workspaces[2], fixture)
        let start = try beginNativeDrag(moved, fixture)
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: start.width / 8, dy: 0) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        fixture.handler.dispatchMouseDragged(at: fixture.monitors[1].frame.center)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.dwindle.liveMoveWorkspaceId, fixture.workspaces[1])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.workspaces[1])

        fixture.layout()
        let over = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right)
        fixture.handler.dispatchMouseDragged(at: over)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.workspaces[2])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.workspaces[2])
        XCTAssertEqual(fixture.columns(fixture.workspaces[0]), [[swapped], [neighbour]])
        XCTAssertEqual(fixture.columns(fixture.workspaces[2]), [[resident], [moved]])
        XCTAssertEqual(fixture.dwindle.existingState(for: fixture.workspaces[1])?.tileCount, 0)
        XCTAssertEqual(fixture.manager.entries(in: fixture.workspaces[1]).map(\.token), [])
        fixture.handler.handleInputSuppressionBegan()
        XCTAssertEqual(fixture.columns(fixture.workspaces[0]), [[moved], [neighbour]])
        XCTAssertEqual(fixture.dwindleTile(swapped), [swapped])
        XCTAssertEqual(fixture.manager.workspace(for: swapped), fixture.workspaces[1])
        XCTAssertEqual(fixture.columns(fixture.workspaces[2]), [[resident]])
        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertTrue(fixture.handler.liveCrossDisplayMove == nil)
        XCTAssertEqual(fixture.niri.states[fixture.workspaces[0]]?.layoutHistory.undoSnapshots.count, 0)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.workspaces[1]).undo, 0)
        XCTAssertEqual(fixture.niri.states[fixture.workspaces[2]]?.layoutHistory.undoSnapshots.count, 0)
    }

    func testAWindowAloneOnItsDisplayCarriesALiveDragOntoTheOtherDisplay() throws {
        let fixture = try makeLiveFixture([.niri, .niri])
        let moved = addWindow(2, to: fixture.source, fixture)
        let resident = addWindow(10, to: fixture.target, fixture)
        try startLiveDrag(moved, fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)

        let point = try dragOnto(resident, .right, fixture)

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [])
        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [moved], []])

        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [moved]])
    }

    func testCancellingAfterAWindowAloneOnItsDisplayCrossesPutsItBack() throws {
        let fixture = try makeLiveFixture([.niri, .niri])
        let moved = addWindow(2, to: fixture.source, fixture)
        let resident = addWindow(10, to: fixture.target, fixture)
        try startLiveDrag(moved, fixture)
        try dragOnto(resident, .right, fixture)
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)

        fixture.handler.cancelLiveColumnDrag()

        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.source), [[moved]])
        XCTAssertEqual(fixture.columns(fixture.target), [[resident]])
    }

    func testAWindowAloneOnItsDisplayReleasedAtHomeStaysAsItWas() throws {
        let fixture = try makeLiveFixture([.niri, .niri])
        let moved = addWindow(2, to: fixture.source, fixture)
        _ = addWindow(10, to: fixture.target, fixture)
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        let width = column.width
        let start = try startLiveDrag(moved, fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)

        fixture.handler.dispatchMouseUp(at: start.center)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.niri.liveColumnMove)
        XCTAssertEqual(fixture.columns(fixture.source), [[moved]])
        let home = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        XCTAssertFalse(home.isLiveHomeSpot)
        XCTAssertEqual(home.width, width)
        XCTAssertFalse(home.hasManualSingleWindowWidthOverride)
    }

    func testALoneNiriWindowStartsLiveDragOnlyWhenAnotherDisplayExists() throws {
        for layouts: [LayoutType] in [[.niri], [.niri, .dwindle]] {
            let fixture = try makeLiveFixture(layouts)
            let moved = addWindow(2, to: fixture.source, fixture)
            if layouts.count > 1 {
                _ = addWindow(10, to: fixture.target, fixture)
            }

            try startLiveDrag(moved, fixture)

            XCTAssertEqual(fixture.handler.isLiveColumnDragActive, layouts.count > 1)
            if layouts.count > 1 {
                XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.source)
                XCTAssertEqual(fixture.niri.liveColumnMove?.windowToken, moved)
                fixture.handler.handleInputSuppressionBegan()
            }
            XCTAssertNil(fixture.niri.liveColumnMove)
            XCTAssertEqual(fixture.columns(fixture.source), [[moved]])
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        }
    }

    func testAWindowGatheredWhileADragIsHeldIsSentBackByThatDragsUndo() throws {
        let fixture = try makeLiveFixture([.niri, .niri])
        let dragged = addWindow(1, to: fixture.source, fixture)
        _ = addWindow(2, to: fixture.source, fixture)
        let gathered = addWindow(10, to: fixture.target, fixture)
        _ = addWindow(11, to: fixture.target, fixture)
        fixture.layout()
        let there = fixture.columns(fixture.target)
        let start = try startLiveDrag(dragged, fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.handler.state.liveDragLayoutStart?.coversEveryNiriWorkspace, true)

        let outcome = fixture.controller.niriLayoutHandler.gatherWindows(
            [gathered],
            from: .all,
            into: NiriGatherDestination(workspaceId: fixture.source, monitor: fixture.monitors[0])
        )
        guard case .gathered = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: gathered), fixture.source)

        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        fixture.layout()
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.source))

        XCTAssertEqual(fixture.manager.workspace(for: gathered), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.target), there)
    }

    func testACarriedDropOntoAStackItDoesNotFitIsUndoneBackOntoTheFirstDisplay() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        fixture.controller.serviceLifecycleManager.connectAXFrameCallbacks(fixture.controller)
        addTeardownBlock { @MainActor in fixture.controller.columnModeToast.destroy() }
        fixture.handler.liveDragClock = { 1_000 }
        try dragOnto(drag.residents[0], .right, drag)
        fixture.layout()
        let point = try XCTUnwrap(fixture.frame(drag.residents[0])).center
        fixture.handler.dispatchMouseDragged(at: point)
        fixture.handler.liveDragClock = { 1_000.2 }
        fixture.handler.liveDragSession?.hoverTimer?.fire()
        XCTAssertNotNil(fixture.niri.liveColumnMove?.landing)
        fixture.handler.dispatchMouseUp(at: point)
        settleStackDrop(in: fixture.target, fixture)
        fixture.layout()
        XCTAssertEqual(fixture.columns(fixture.target).first?.count, 2)

        let asked = try XCTUnwrap(fixture.frame(drag.moved))
        var taken = asked
        taken.size.height += 200
        fixture.handler.nativeWindowFrameProvider = { [taken] _ in taken }
        fixture.controller.axManager.onTerminalFrameRefusal?(AXFrameTerminalRefusal(
            pid: drag.moved.pid,
            windowId: drag.moved.windowId,
            targetFrame: asked,
            observedFrame: taken,
            failureReason: .verificationMismatch
        ))
        fixture.controller.layoutRefreshController.dropQueuedRefreshes()
        fixture.controller.niriLayoutHandler.checkOverflowReports()
        fixture.layout()
        fixture.controller.niriLayoutHandler.followOverflowMessage(in: fixture.source)

        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.residents[1]]])
        XCTAssertEqual(fixture.controller.columnModeToast.source?.workspaceId, fixture.source)
        XCTAssertNil(fixture.niri.peekLayoutHistory(.redo, in: fixture.target))
    }

    func testAllCarryAxesInsertOnEitherSideAndKeepOneGapAtAStillPointer() throws {
        for axes in carryAxisPairs {
            for after in [false, true] {
                let drag = try startLiveTwoDisplayDrag(
                    residents: 2, orientations: axes, frames: carryDisplayFrames(axes)
                )
                let fixture = drag.fixture
                let direction: Direction = axes[1] == .horizontal
                    ? (after ? .right : .left) : (after ? .up : .down)
                let point = try carryOnto(drag.residents[0], direction, fixture)
                let expected = after
                    ? [[drag.residents[0]], [drag.moved], [], [drag.residents[1]]]
                    : [[], [drag.moved], [drag.residents[0]], [drag.residents[1]]]
                XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
                XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
                XCTAssertEqual(fixture.columns(fixture.target), expected)
                XCTAssertEqual(fixture.niri.columns(in: fixture.target).filter(\.isLiveDropSpace).count, 1)

                fixture.handler.dispatchMouseDragged(at: point)

                XCTAssertEqual(fixture.columns(fixture.target), expected)
                fixture.handler.dispatchMouseUp(at: point)
                XCTAssertNil(fixture.niri.liveColumnMove)
                XCTAssertEqual(fixture.columns(fixture.target), expected.filter { !$0.isEmpty })
                XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
            }
        }
    }

    func testAllCarryAxesUseTheObservedTargetPrimarySpanAndCapOversizedWindows() throws {
        for axes in carryAxisPairs {
            for oversized in [false, true] {
                let drag = try startLiveTwoDisplayDrag(
                    residents: 2, orientations: axes, frames: carryDisplayFrames(axes)
                )
                let fixture = drag.fixture
                let target = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
                let point = try dropPoint(
                    in: XCTUnwrap(fixture.frame(drag.residents[0])), axes[1] == .horizontal ? .right : .up
                )
                let extent = oversized ? target.primarySpan * 2 : target.primarySpan / 3
                let otherExtent = target.secondarySpan / 4
                let size = axes[1] == .horizontal
                    ? CGSize(width: extent, height: otherExtent) : CGSize(width: otherExtent, height: extent)
                let observed = CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height
                )
                fixture.handler.nativeWindowFrameProvider = { _ in observed }

                fixture.handler.dispatchMouseDragged(at: point)
                fixture.handler.dispatchMouseUp(at: point)

                let column = try XCTUnwrap(fixture.niriNode(drag.moved)?.parent as? NiriContainer)
                let expected = ProportionalSize.proportion(
                    min(1, (extent + target.gaps) / (target.primarySpan - target.gaps))
                )
                XCTAssertEqual(axes[1] == .horizontal ? column.width : column.height, expected)
                XCTAssertEqual(
                    fixture.columns(fixture.target),
                    [[drag.residents[0]], [drag.moved], [drag.residents[1]]]
                )
                XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
                XCTAssertNil(fixture.niri.liveColumnMove)
            }
        }
    }

    func testAllCarryAxesRebaseOnlyCrossAxisGripAndClearItWhenTheFrameIsMissing() throws {
        for axes in carryAxisPairs {
            for missing in [false, true] {
                let drag = try startLiveTwoDisplayDrag(
                    orientations: axes, frames: carryDisplayFrames(axes)
                )
                let fixture = drag.fixture
                let point = fixture.monitors[1].frame.center
                let priorOffset: CGFloat = 37
                let grip = CGPoint(x: 19, y: -31)
                let size = CGSize(width: 420, height: 310)
                let observed = CGRect(
                    x: point.x + grip.x - size.width / 2,
                    y: point.y + grip.y - size.height / 2,
                    width: size.width, height: size.height
                )
                fixture.handler.liveDragSession?.referenceOffset = priorOffset
                fixture.handler.nativeWindowFrameProvider = { _ in missing ? nil : observed }

                fixture.handler.dispatchMouseDragged(at: point)

                XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
                if axes[0] == axes[1] {
                    XCTAssertEqual(fixture.handler.liveDragSession?.referenceOffset, priorOffset)
                    XCTAssertEqual(
                        fixture.handler.liveDragWindowMidX(point, orientation: axes[1]),
                        (axes[1] == .horizontal ? point.x : point.y) + priorOffset
                    )
                } else if missing {
                    XCTAssertNil(fixture.handler.liveDragSession?.referenceOffset)
                    XCTAssertEqual(fixture.handler.liveDragReference(point, orientation: axes[1]), point)
                } else {
                    XCTAssertEqual(
                        fixture.handler.liveDragSession?.referenceOffset, axes[1] == .horizontal ? grip.x : grip.y
                    )
                    XCTAssertEqual(
                        fixture.handler.liveDragWindowMidX(point, orientation: axes[1]),
                        axes[1] == .horizontal ? observed.midX : observed.midY
                    )
                }
                fixture.handler.cancelLiveColumnDrag()
                XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour], [drag.moved]])
            }
        }
    }

    func testAllCarryAxesHoldTheDestinationEdgeUntilRealOutwardMotion() throws {
        for axes in carryAxisPairs {
            let drag = try startLiveTwoDisplayDrag(
                residents: 4, orientations: axes, frames: carryDisplayFrames(axes)
            )
            let fixture = drag.fixture
            let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
            let display = fixture.monitors[1].frame
            let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: context.primarySpan(of: display))
            let primary = context.primaryEnd(of: display) - zone / 2
            let secondary = context.secondaryCoordinate(of: display.center)
            let point = context.point(primary: primary, secondary: secondary)

            fixture.handler.dispatchMouseDragged(at: point)

            XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeZoneHold?.edge, .trailing)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeZoneHold?.primaryPosition, primary)
            fixture.handler.trackLiveEdgeZone(
                at: context.point(primary: primary, secondary: secondary + zone),
                monitorFrame: display, orientation: axes[1]
            )
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
            fixture.handler.trackLiveEdgeZone(
                at: context.point(primary: primary - zone / 4, secondary: secondary),
                monitorFrame: display, orientation: axes[1]
            )
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
            fixture.handler.trackLiveEdgeZone(
                at: context.point(primary: primary + zone / 4, secondary: secondary),
                monitorFrame: display, orientation: axes[1]
            )
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
            XCTAssertNil(fixture.handler.liveDragSession?.edgeZoneHold)
            fixture.handler.cancelLiveColumnDrag()
        }
    }

    func testAllCarryAxesCancelRepeatedCrossingsWithBothWindowSpecificationsAndSelections() throws {
        for axes in carryAxisPairs {
            let fixture = try makeLiveFixture(
                [.niri, .niri], orientations: axes, frames: carryDisplayFrames(axes)
            )
            let neighbour = addWindow(1, to: fixture.source, fixture)
            let moved = addWindow(2, to: fixture.source, fixture)
            let resident = addWindow(10, to: fixture.target, fixture)
            try stack(moved, onto: neighbour, in: fixture.source, fixture)
            let window = try XCTUnwrap(fixture.niriNode(moved))
            let height = WeightedSize.fixed(310)
            let width = WeightedSize.fixed(470)
            window.height = height
            window.windowWidth = width
            fixture.layout()
            let sourceViewport = fixture.manager.niriViewportState(for: fixture.source)
            let targetViewport = fixture.manager.niriViewportState(for: fixture.target)
            try startLiveDrag(moved, fixture)
            try carryOnto(resident, axes[1] == .horizontal ? .right : .up, fixture)
            try carryOnto(neighbour, axes[0] == .horizontal ? .right : .up, fixture)
            try carryOnto(resident, axes[1] == .horizontal ? .right : .up, fixture)

            fixture.handler.cancelLiveColumnDrag()

            XCTAssertEqual(fixture.columns(fixture.source), [[neighbour, moved]])
            XCTAssertEqual(fixture.columns(fixture.target), [[resident]])
            XCTAssertTrue(fixture.niriNode(moved) === window)
            XCTAssertEqual(window.height, height)
            XCTAssertEqual(window.windowWidth, width)
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
            XCTAssertEqual(
                fixture.manager.niriViewportState(for: fixture.source).selectedNodeId,
                sourceViewport.selectedNodeId
            )
            XCTAssertEqual(
                fixture.manager.niriViewportState(for: fixture.target).selectedNodeId,
                targetViewport.selectedNodeId
            )
            XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.source).viewOffset, sourceViewport.viewOffset)
            XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.target).viewOffset, targetViewport.viewOffset)
            XCTAssertNil(fixture.niri.liveColumnMove)
        }
    }

    func testAllCarryAxesPreserveWholeTabbedIdentityThroughReleaseAndHistory() throws {
        for axes in carryAxisPairs {
            let drag = try startLiveTabbedColumnDrag(orientations: axes, frames: carryDisplayFrames(axes))
            let fixture = drag.fixture
            fixture.niri.clearLayoutHistory(in: fixture.source)
            fixture.niri.clearLayoutHistory(in: fixture.target)
            XCTAssertNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
            let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
            let tabs = column.windowNodes.map(\.token)
            let active = try XCTUnwrap(column.activeWindow).token
            let columnId = column.id
            let point = try carryOnto(drag.resident, axes[1] == .horizontal ? .right : .up, fixture)
            XCTAssertTrue(fixture.niriNode(active)?.parent === column)
            XCTAssertEqual(column.activeWindow?.token, active)
            XCTAssertEqual(fixture.columns(fixture.source), [[drag.other]])
            XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs, []])

            fixture.handler.dispatchMouseUp(at: point)
            fixture.layout()

            XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs])
            XCTAssertTrue(column.isTabbed)
            XCTAssertEqual(column.id, columnId)
            XCTAssertTrue(fixture.niriNode(active)?.parent === column)
            XCTAssertEqual(column.activeWindow?.token, active)
            XCTAssertNotNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
            XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.source))
            XCTAssertNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
            XCTAssertNotNil(fixture.niri.peekLayoutHistory(.redo, in: fixture.source))
            XCTAssertEqual(fixture.columns(fixture.source), [tabs, [drag.other]])
            XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident]])
            for tab in tabs { XCTAssertEqual(fixture.manager.workspace(for: tab), fixture.source) }
            XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo, in: fixture.source))
            XCTAssertNil(fixture.niri.peekLayoutHistory(.redo, in: fixture.source))
            XCTAssertNotNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
            XCTAssertEqual(fixture.columns(fixture.source), [[drag.other]])
            XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs])
            let restored = try XCTUnwrap(fixture.niriNode(active)?.parent as? NiriContainer)
            XCTAssertTrue(restored.isTabbed)
            XCTAssertEqual(restored.windowNodes.map(\.token), tabs)
            XCTAssertEqual(restored.activeWindow?.token, active)
            for tab in tabs { XCTAssertEqual(fixture.manager.workspace(for: tab), fixture.target) }
        }
    }

    func testAllCarryAxesCancelWholeTabbedCarryWithBothContainerSpecifications() throws {
        for axes in carryAxisPairs {
            let drag = try startLiveTabbedColumnDrag(orientations: axes, frames: carryDisplayFrames(axes))
            let fixture = drag.fixture
            let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
            let tabs = column.windowNodes.map(\.token)
            let active = column.activeWindow?.token
            let width = column.width
            let height = column.height
            try carryOnto(drag.resident, axes[1] == .horizontal ? .right : .up, fixture)

            fixture.handler.cancelLiveColumnDrag()

            XCTAssertTrue(fixture.niri.columns(in: fixture.source).first === column)
            XCTAssertEqual(fixture.columns(fixture.source), [tabs, [drag.other]])
            XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident]])
            XCTAssertEqual(column.activeWindow?.token, active)
            XCTAssertEqual(column.width, width)
            XCTAssertEqual(column.height, height)
            XCTAssertTrue(column.isTabbed)
            XCTAssertNil(fixture.niri.liveColumnMove)
        }
    }

    func testAllCarryAxesAdmitALoneSourceAndReleaseIntoAnEmptyTarget() throws {
        for axes in carryAxisPairs {
            let fixture = try makeLiveFixture(
                [.niri, .niri], orientations: axes, frames: carryDisplayFrames(axes)
            )
            let moved = addWindow(1, to: fixture.source, fixture)
            try startLiveDrag(moved, fixture)
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
            let point = fixture.monitors[1].frame.center

            fixture.handler.dispatchMouseDragged(at: point)

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertEqual(fixture.columns(fixture.source), [])
            XCTAssertEqual(fixture.columns(fixture.target), [[moved]])
            fixture.handler.dispatchMouseUp(at: point)
            XCTAssertEqual(fixture.columns(fixture.target), [[moved]])
            XCTAssertNil(fixture.niri.liveColumnMove)
        }
    }

    func testBothSourceAxesAllowALoneLiveDragOnlyWhenAnotherDisplayExists() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for layouts: [LayoutType] in [[.niri], [.niri, .dwindle]] {
                let axes = layouts.map { _ in orientation }
                let fixture = try makeLiveFixture(layouts, orientations: axes, frames: carryDisplayFrames(axes))
                let moved = addWindow(1, to: fixture.source, fixture)
                if layouts.count > 1 { _ = addWindow(10, to: fixture.target, fixture) }

                try startLiveDrag(moved, fixture)

                XCTAssertEqual(fixture.handler.isLiveColumnDragActive, layouts.count > 1)
                if layouts.count > 1 {
                    XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.source)
                    XCTAssertEqual(fixture.niri.liveColumnMove?.windowToken, moved)
                    fixture.handler.handleInputSuppressionBegan()
                }
                XCTAssertNil(fixture.niri.liveColumnMove)
                XCTAssertEqual(fixture.columns(fixture.source), [[moved]])
                XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
            }
        }
    }

    private var carryAxisPairs: [[Monitor.Orientation]] {
        [[.horizontal, .horizontal], [.horizontal, .vertical], [.vertical, .horizontal], [.vertical, .vertical]]
    }

    private func carryDisplayFrames(_ axes: [Monitor.Orientation]) -> [CGRect] {
        axes.enumerated().map { index, orientation in
            CGRect(
                x: index == 0 ? 137 : 1901,
                y: index == 0 ? -241 : 89,
                width: orientation == .horizontal ? 1512 : 912,
                height: orientation == .horizontal ? 912 : 1512
            )
        }
    }

    @discardableResult
    private func carryOnto(_ token: WindowToken, _ direction: Direction, _ fixture: Fixture) throws -> CGPoint {
        fixture.layout()
        let point = try dropPoint(in: XCTUnwrap(fixture.frame(token)), direction)
        let start = try XCTUnwrap(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        let observed = CGRect(
            x: point.x - start.width / 2, y: point.y - start.height / 2,
            width: start.width, height: start.height
        )
        fixture.handler.nativeWindowFrameProvider = { _ in observed }
        fixture.handler.dispatchMouseDragged(at: point)
        return point
    }

    private func makeLiveFixture(
        _ layouts: [LayoutType],
        orientations: [Monitor.Orientation]? = nil,
        frames: [CGRect]? = nil
    ) throws -> Fixture {
        let fixture = try makeNativeFixture(layouts, orientations: orientations, frames: frames)
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        fixture.niri.liveHoverDelay = 0
        return fixture
    }

    @discardableResult
    private func startLiveDrag(_ token: WindowToken, _ fixture: Fixture) throws -> CGRect {
        let start = try beginNativeDrag(token, fixture)
        let dragged = start.offsetBy(dx: 30, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in dragged }
        _ = fixture.handler.handleNativeTitleBarDragFrameChanged(for: try XCTUnwrap(fixture.manager.entry(for: token)))
        return start
    }

    private func settleStackDrop(in workspaceId: WorkspaceDescriptor.ID, _ fixture: Fixture) {
        fixture.manager.animationDriver.removeMotions(for: [workspaceId])
        _ = fixture.niri.cancelAnimations(in: workspaceId)
        fixture.handler.handleNiriAnimationsSettled(in: workspaceId)
    }

    private struct LiveTabbedColumnDrag {
        let fixture: Fixture
        let other: WindowToken
        let resident: WindowToken
    }

    private func startLiveTabbedColumnDrag(
        orientations: [Monitor.Orientation]? = nil,
        frames: [CGRect]? = nil
    ) throws -> LiveTabbedColumnDrag {
        let fixture = try makeNativeFixture([.niri, .niri], orientations: orientations, frames: frames)
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        fixture.niri.liveHoverDelay = 0
        let first = addWindow(1, to: fixture.source, fixture)
        let moved = addWindow(2, to: fixture.source, fixture)
        let other = addWindow(3, to: fixture.source, fixture)
        try stack(moved, onto: first, in: fixture.source, fixture)
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            column.displayMode = .tabbed
            column.setActiveTileIdx(column.windowNodes.firstIndex { $0.token == moved } ?? 0)
            fixture.niri.updateTabbedColumnVisibility(column: column)
        }
        let resident = addWindow(10, to: fixture.target, fixture)
        let start = try beginNativeDrag(moved, fixture)
        let dragged = start.offsetBy(dx: 30, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in dragged }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        XCTAssertEqual(fixture.niri.liveColumnMove?.isWholeColumn, true)
        return LiveTabbedColumnDrag(fixture: fixture, other: other, resident: resident)
    }

    @discardableResult
    private func dragOnto(_ token: WindowToken, _ direction: Direction, _ fixture: Fixture) throws -> CGPoint {
        fixture.layout()
        let point = try dropPoint(in: XCTUnwrap(fixture.frame(token)), direction)
        fixture.handler.dispatchMouseDragged(at: point)
        return point
    }

    private struct LiveTwoDisplayDrag {
        let fixture: Fixture
        let moved: WindowToken
        let neighbour: WindowToken
        let residents: [WindowToken]
    }

    private func startLiveTwoDisplayDrag(
        residents residentCount: Int = 1,
        stacked: Bool = false,
        movedHeight: WeightedSize? = nil,
        fusion: Bool = true,
        edgePeekPercent: Double? = nil,
        orientations: [Monitor.Orientation]? = nil,
        frames: [CGRect]? = nil
    ) throws -> LiveTwoDisplayDrag {
        let fixture = try makeNativeFixture(
            [.niri, .niri], orientations: orientations, frames: frames
        )
        if let edgePeekPercent {
            fixture.controller.settings.niri.edgePeekPercent = edgePeekPercent
        }
        if fusion {
            fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        }
        fixture.niri.liveHoverDelay = 0
        let neighbour = addWindow(1, to: fixture.source, fixture)
        let moved = addWindow(2, to: fixture.source, fixture)
        if stacked {
            try stack(moved, onto: neighbour, in: fixture.source, fixture)
        }
        if let movedHeight {
            fixture.niriNode(moved)?.height = movedHeight
        }
        let residents = (0 ..< residentCount).map { addWindow(10 + $0, to: fixture.target, fixture) }
        let start = try beginNativeDrag(moved, fixture)
        let dragged = start.offsetBy(dx: 30, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in dragged }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        return LiveTwoDisplayDrag(fixture: fixture, moved: moved, neighbour: neighbour, residents: residents)
    }

    @discardableResult
    private func dragOnto(_ token: WindowToken, _ direction: Direction, _ drag: LiveTwoDisplayDrag) throws -> CGPoint {
        drag.fixture.layout()
        let point = try dropPoint(in: XCTUnwrap(drag.fixture.frame(token)), direction)
        drag.fixture.handler.dispatchMouseDragged(at: point)
        return point
    }

    private func carriedColumn(_ drag: LiveTwoDisplayDrag) -> NiriContainer? {
        drag.fixture.niriNode(drag.moved)?.parent as? NiriContainer
    }
}
