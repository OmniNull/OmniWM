// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testCrossingClosesTheHomeSpotAndOpensADropSpaceUnderThePointer() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture

        try dragOnto(drag.residents[0], .right, drag)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.target)
        XCTAssertEqual(fixture.niri.liveColumnMove?.carry?.originalWorkspaceId, fixture.source)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved]])
        let column = try XCTUnwrap(carriedColumn(drag))
        XCTAssertTrue(column.isLiveHomeSpot)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        XCTAssertEqual(column.width, .fixed(fixture.niri.liveDropSpaceWidth(context: context)))
    }

    func testTheDropSpaceOnTheOtherDisplayHasTheRegularWidthWhateverTheWindow() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        let window = try XCTUnwrap(fixture.niriNode(drag.moved))
        window.packingHints = ObservedPackingHints(width: ObservedAxisHint(requested: 40, observed: 640))

        try dragOnto(drag.residents[0], .right, drag)

        let column = try XCTUnwrap(carriedColumn(drag))
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let placed = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column === column })
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
        XCTAssertEqual(fixture.columns(fixture.target), expected)
        let underPointer = try [placed(drag.residents[1]), placed(drag.moved)]
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

    func testCrossingOnATargetsLeftHalfOpensTheDropSpaceBeforeIt() throws {
        let drag = try startLiveTwoDisplayDrag()

        try dragOnto(drag.residents[0], .left, drag)

        XCTAssertEqual(drag.fixture.columns(drag.fixture.target), [[drag.moved], [drag.residents[0]]])
    }

    func testCrossingFromAStackClosesTheSlotAndKeepsTheStack() throws {
        let drag = try startLiveTwoDisplayDrag(stacked: true)
        let fixture = drag.fixture
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour, drag.moved]])

        try dragOnto(drag.residents[0], .right, drag)

        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]], [drag.moved]])
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

    func testOnTheOtherDisplayATargetMovesTheCarriedColumn() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.moved], [drag.residents[1]]]
        )

        fixture.layout()
        let display = try XCTUnwrap(fixture.manager.monitor(for: fixture.target)).frame
        let visible = try XCTUnwrap(fixture.frame(drag.residents[1])).intersection(display)
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: visible.maxX - visible.width / 4, y: visible.midY))

        XCTAssertEqual(
            fixture.columns(fixture.target),
            [[drag.residents[0]], [drag.residents[1]], [drag.moved]]
        )
        XCTAssertNil(fixture.niri.liveColumnMove?.dropSpaceId)
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
        XCTAssertEqual(column.width, fixture.niri.liveCarriedSizing(windowWidth: width, context: context).width)
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

    func testACarriedWindowWiderThanTheDisplayIsSizedToFullWidth() throws {
        let drag = try startLiveTwoDisplayDrag()
        let context = try XCTUnwrap(drag.fixture.handler.liveColumnContext(for: drag.fixture.target))

        let sizing = drag.fixture.niri.liveCarriedSizing(windowWidth: 3000, context: context)

        XCTAssertEqual(sizing.width, .proportion(1.0))
        XCTAssertFalse(sizing.isFullWidth)
    }

    func testComingBackOpensADropSpaceAtThePointerAndLandsThere() throws {
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        try dragOnto(drag.residents[0], .right, drag)

        let point = try dragOnto(drag.neighbour, .right, drag)

        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.residents[0]]])
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour], [drag.moved]])

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

        fixture.manager.withBatchedCrossWorkspaceDrop(
            into: fixture.target,
            niriWorkspaceIds: [fixture.source, fixture.target]
        ) { viewports in
            var sourceState = viewports[fixture.source] ?? ViewportState()
            var targetState = viewports[fixture.target] ?? ViewportState()
            carried = fixture.niri.liveColumnMoveCarry(
                cursor: CGPoint(x: (first.maxX + second.minX) / 2, y: first.midY),
                windowWidth: nil,
                from: source,
                sourceState: &sourceState,
                to: target,
                targetState: &targetState
            )
            viewports[fixture.source] = sourceState
            viewports[fixture.target] = targetState
            return carried.map { .init(token: $0, workspaceId: fixture.target) }
        }

        XCTAssertEqual(carried, [drag.moved])
        let order = fixture.niri.columns(in: fixture.target).map { $0.windowNodes.map(\.token) }
        XCTAssertNotEqual(order.last, [drag.moved])
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
        let drag = try startLiveTwoDisplayDrag()
        let fixture = drag.fixture
        fixture.layout()
        let lone = try XCTUnwrap(fixture.niri.columns(in: fixture.target).first)
        let ownWidth = lone.width
        let shown = try XCTUnwrap(fixture.frame(drag.residents[0]))

        fixture.handler.dispatchMouseDragged(at: CGPoint(x: shown.minX + shown.width * 0.3, y: shown.midY))

        XCTAssertEqual(fixture.columns(fixture.target), [[drag.moved], [drag.residents[0]]])
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

    func testTheEdgeScrollKeepsTheCarriedColumnOnThePointersSide() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 3)
        let fixture = drag.fixture
        try dragOnto(drag.residents[1], .left, drag)
        let columns = fixture.columns(fixture.target)
        XCTAssertEqual(columns, [[drag.residents[0]], [drag.moved], [drag.residents[1]], [drag.residents[2]]])
        fixture.handler.handleNiriAnimationsSettled(in: fixture.target)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.target))
        let target = try XCTUnwrap(fixture.niri.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.target)
        ).first { $0.column.windowNodes.first?.token == drag.residents[1] })
        let point = CGPoint(x: target.minX + (target.maxX - target.minX) * 0.2, y: fixture.monitors[1].frame.midY)
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.columns(fixture.target), columns)

        XCTAssertFalse(fixture.niri.liveColumnMoveWouldChange(
            cursor: point,
            strip: fixture.niri.liveColumnStrip(
                context: context,
                state: fixture.manager.niriViewportState(for: fixture.target)
            ),
            context: context
        ))
        fixture.handler.updateLiveColumnDrag(at: point, immediate: true)

        XCTAssertEqual(fixture.columns(fixture.target), columns)
    }

    func testAWholeTabbedColumnCrossesWithItsTabs() throws {
        let drag = try startLiveTabbedColumnDrag()
        let fixture = drag.fixture
        let tabs = fixture.columns(fixture.source)[0]

        let point = try dragOnto(drag.resident, .right, drag.fixture)

        XCTAssertEqual(fixture.columns(fixture.source), [[drag.other]])
        XCTAssertEqual(fixture.columns(fixture.target), [[drag.resident], tabs])
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

    func testBackFromAHandOverTheLiveDragResumesOnItsOwnDisplay() throws {
        let fixture = try makeNativeFixture([.niri, .dwindle])
        fixture.controller.settings.niri.macOSFusion = true
        fixture.handler.liveDragModifierCapture.installsEventTap = false
        fixture.niri.moveConfiguration.liveHoverDelay = 0
        let moved = addWindow(1, to: fixture.source, fixture)
        let neighbour = addWindow(2, to: fixture.source, fixture)
        _ = addWindow(3, to: fixture.target, fixture)
        let sourceColumns = fixture.columns(fixture.source)
        let start = try beginNativeDrag(moved, fixture)
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 30, dy: 0) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        fixture.handler.dispatchMouseDragged(at: fixture.monitors[1].frame.center)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.columns(fixture.source), sourceColumns)

        fixture.layout()
        let back = try dropPoint(in: XCTUnwrap(fixture.frame(neighbour)), .right)
        fixture.handler.dispatchMouseDragged(at: back)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.source)
        XCTAssertEqual(fixture.columns(fixture.source), [[moved], [neighbour], []])
    }

    func testFromAHandOverOntoAnotherLiveStripTheDragIsCarried() throws {
        let fixture = try makeNativeFixture([.niri, .dwindle, .niri])
        fixture.controller.settings.niri.macOSFusion = true
        fixture.handler.liveDragModifierCapture.installsEventTap = false
        fixture.niri.moveConfiguration.liveHoverDelay = 0
        let moved = addWindow(1, to: fixture.workspaces[0], fixture)
        let neighbour = addWindow(2, to: fixture.workspaces[0], fixture)
        _ = addWindow(3, to: fixture.workspaces[1], fixture)
        let resident = addWindow(4, to: fixture.workspaces[2], fixture)
        let start = try beginNativeDrag(moved, fixture)
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 30, dy: 0) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(
            for: try XCTUnwrap(fixture.manager.entry(for: moved))
        ))
        fixture.handler.dispatchMouseDragged(at: fixture.monitors[1].frame.center)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)

        fixture.layout()
        let over = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right)
        fixture.handler.dispatchMouseDragged(at: over)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.workspaces[2])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.workspaces[2])
        XCTAssertEqual(fixture.columns(fixture.workspaces[0]), [[neighbour]])
        XCTAssertEqual(fixture.columns(fixture.workspaces[2]), [[resident], [moved]])
    }

    func testStackModeOnTheOtherDisplayStacksIntoTheTarget() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 2)
        let fixture = drag.fixture
        let target = drag.residents[1]
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.target)

        fixture.layout()
        let targetX = try XCTUnwrap(fixture.frame(target)).minX
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        let point = try dragOnto(target, .down, drag)
        XCTAssertEqual(fixture.niri.liveColumnMove?.stackMode, true)
        XCTAssertNotNil(fixture.niri.liveColumnMove?.landing)
        fixture.layout()
        XCTAssertEqual(try XCTUnwrap(fixture.frame(target)).minX, targetX, accuracy: 0.5)
        fixture.handler.dispatchMouseUp(at: point)
        settleStackDrop(in: fixture.target, fixture)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertEqual(fixture.columns(fixture.source), [[drag.neighbour]])
        let columns = fixture.columns(fixture.target)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns.first, [drag.residents[0]])
        XCTAssertEqual(Set(columns.last ?? []), [target, drag.moved])
        XCTAssertFalse(fixture.niri.columns(in: fixture.target).contains { $0.isLiveHomeSpot })
    }

    func testATabbedTargetOnTheOtherDisplayTakesTheWindowAsATab() throws {
        let drag = try startLiveTwoDisplayDrag(residents: 3)
        let fixture = drag.fixture
        try stack(drag.residents[2], onto: drag.residents[1], in: fixture.target, fixture)
        let tabbed = try XCTUnwrap(fixture.niriNode(drag.residents[1])?.parent as? NiriContainer)
        fixture.manager.withEngineMutationScope(in: fixture.target) {
            tabbed.displayMode = .tabbed
            fixture.niri.updateTabbedColumnVisibility(column: tabbed)
        }
        try dragOnto(drag.residents[0], .right, drag)
        XCTAssertEqual(fixture.niri.liveColumnMove?.workspaceId, fixture.target)

        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        let shown = try XCTUnwrap(tabbed.windowNodes[tabbed.activeTileIdx].token)
        let point = try dragOnto(shown, .down, drag)
        XCTAssertEqual(tabbed.windowNodes.count, 3)
        fixture.handler.dispatchMouseUp(at: point)
        settleStackDrop(in: fixture.target, fixture)

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.manager.workspace(for: drag.moved), fixture.target)
        XCTAssertTrue(tabbed.isTabbed)
        XCTAssertEqual(tabbed.windowNodes.count, 3)
        XCTAssertEqual(tabbed.windowNodes[tabbed.activeTileIdx].token, drag.moved)
        XCTAssertEqual(fixture.niri.columns(in: fixture.target).count, 2)
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
        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [moved]])

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

    func testAWindowAloneOnTheOnlyNiriStripGetsNoLiveDrag() throws {
        for layouts: [LayoutType] in [[.niri], [.niri, .dwindle]] {
            let fixture = try makeLiveFixture(layouts)
            let moved = addWindow(2, to: fixture.source, fixture)
            if layouts.count > 1 {
                _ = addWindow(10, to: fixture.target, fixture)
            }

            try startLiveDrag(moved, fixture)

            XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
            XCTAssertNil(fixture.niri.liveColumnMove)
        }
    }

    private func makeLiveFixture(_ layouts: [LayoutType]) throws -> Fixture {
        let fixture = try makeNativeFixture(layouts)
        fixture.controller.settings.niri.macOSFusion = true
        fixture.handler.liveDragModifierCapture.installsEventTap = false
        fixture.niri.moveConfiguration.liveHoverDelay = 0
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

    private func startLiveTabbedColumnDrag() throws -> LiveTabbedColumnDrag {
        let fixture = try makeNativeFixture([.niri, .niri])
        fixture.controller.settings.niri.macOSFusion = true
        fixture.handler.liveDragModifierCapture.installsEventTap = false
        fixture.niri.moveConfiguration.liveHoverDelay = 0
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
        movedHeight: WeightedSize? = nil
    ) throws -> LiveTwoDisplayDrag {
        let fixture = try makeNativeFixture([.niri, .niri])
        fixture.controller.settings.niri.macOSFusion = true
        fixture.handler.liveDragModifierCapture.installsEventTap = false
        fixture.niri.moveConfiguration.liveHoverDelay = 0
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
