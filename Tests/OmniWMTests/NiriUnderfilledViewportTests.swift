// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriUnderfilledViewportTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let windows: [NiriWindow]

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }
    }

    private func fixture(count: Int = 2, visibleCount: Int = 3) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: visibleCount)
        engine.defaultContainerPrimarySpan = nil
        let workspaceId = WorkspaceDescriptor.ID()
        let windows = (0 ..< count).map {
            engine.addWindow(token: WindowToken(pid: 615, windowId: $0 + 1), to: workspaceId, afterSelection: nil)
        }
        return Fixture(engine: engine, workspaceId: workspaceId, windows: windows)
    }

    private func layout(
        _ fixture: Fixture,
        gap: CGFloat = 0,
        orientation: Monitor.Orientation = .horizontal,
        excludedTokens: Set<WindowToken> = []
    ) -> [WindowToken: CGRect] {
        var state = ViewportState()
        state.jumpOffset(to: -gap)
        return fixture.engine.calculateLayout(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: frame,
            gaps: (gap, gap),
            orientation: orientation,
            excludedTokens: excludedTokens
        )
    }

    func testTwoColumnsFillThreeColumnViewportWithGaps() throws {
        let fixture = fixture()
        let frames = layout(fixture, gap: 12)
        let first = try XCTUnwrap(frames[fixture.windows[0].token])
        let second = try XCTUnwrap(frames[fixture.windows[1].token])

        XCTAssertEqual(first.width, 582)
        XCTAssertEqual(second.width, 582)
        XCTAssertEqual(first.minX, 12)
        XCTAssertEqual(second.minX - first.maxX, 12)
        XCTAssertEqual(second.maxX, frame.maxX - 12)
        XCTAssertEqual(fixture.columns.map(\.width), [.proportion(1.0 / 3), .proportion(1.0 / 3)])
    }

    func testThirdColumnRestoresChosenSpansAndClosingItRefills() throws {
        let fixture = fixture()
        _ = layout(fixture)
        let third = fixture.engine.addWindow(
            token: WindowToken(pid: 615, windowId: 3), to: fixture.workspaceId, afterSelection: nil
        )
        let threeFrames = layout(fixture)
        for window in fixture.windows + [third] {
            XCTAssertEqual(try XCTUnwrap(threeFrames[window.token]).width, 400)
        }

        fixture.engine.removeWindow(token: third.token, in: fixture.workspaceId)
        let twoFrames = layout(fixture)
        for window in fixture.windows {
            XCTAssertEqual(try XCTUnwrap(twoFrames[window.token]).width, 600)
        }
    }

    func testCustomWidthsGrowInProportionWithoutReplacingStoredChoices() throws {
        let fixture = fixture()
        fixture.columns[0].width = .fixed(200)
        fixture.columns[1].width = .fixed(400)
        let frames = layout(fixture)

        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 400)
        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[1].token]).width, 800)
        XCTAssertEqual(fixture.columns.map(\.width), [.fixed(200), .fixed(400)])
    }

    func testAtAndAboveVisibleCountKeepNormalScrollingWidths() throws {
        for count in [3, 4] {
            let fixture = fixture(count: count)
            let frames = layout(fixture)
            XCTAssertEqual(fixture.columns.map(\.cachedWidth), Array(repeating: 400, count: count))
            XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 400)
        }
    }

    func testAlreadyOverflowingWidthsAreNotShrunk() throws {
        let fixture = fixture()
        for column in fixture.columns {
            column.width = .proportion(0.7)
        }
        let frames = layout(fixture)

        XCTAssertEqual(fixture.columns.map(\.cachedWidth), [840, 840])
        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 840)
    }

    func testVerticalContainersFillHeight() throws {
        let fixture = fixture()
        let frames = layout(fixture, orientation: .vertical)
        let first = try XCTUnwrap(frames[fixture.windows[0].token])
        let second = try XCTUnwrap(frames[fixture.windows[1].token])

        XCTAssertEqual(first.height, 450)
        XCTAssertEqual(second.height, 450)
        XCTAssertEqual(first.maxY, second.minY)
        XCTAssertEqual(fixture.columns.map(\.height), [.proportion(1.0 / 3), .proportion(1.0 / 3)])
    }

    func testExcludedColumnDoesNotConsumeFitSpace() throws {
        let fixture = fixture(count: 3)
        _ = layout(fixture)
        let excluded = fixture.windows[2].token
        let frames = layout(fixture, excludedTokens: [excluded])

        XCTAssertNil(frames[excluded])
        for window in fixture.windows.prefix(2) {
            XCTAssertEqual(try XCTUnwrap(frames[window.token]).width, 600)
        }
        let restored = layout(fixture)
        for window in fixture.windows {
            XCTAssertEqual(try XCTUnwrap(restored[window.token]).width, 400)
        }
    }

    func testMaximumWidthLeavesRemainingSpaceForOtherColumn() throws {
        let fixture = fixture()
        fixture.engine.updateWindowConstraints(
            for: fixture.windows[0].token,
            constraints: WindowSizeConstraints(
                minSize: .init(width: 1, height: 1),
                maxSize: .init(width: 300, height: 0),
                isFixed: false
            ),
            in: fixture.workspaceId,
            motion: .disabled
        )
        let frames = layout(fixture)

        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 300)
        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[1].token]).width, 900)
    }

    func testSingleWindowFitRemainsAuthoritative() throws {
        let fixture = fixture(count: 1)
        fixture.engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let frames = layout(fixture)

        XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 400)
    }

    func testSingleContainerWithMultipleWindowsFillsPrimarySpan() throws {
        for tabbed in [false, true] {
            let fixture = fixture()
            let column = fixture.columns[0]
            var state = ViewportState()
            XCTAssertTrue(fixture.engine.consumeWindow(
                fixture.windows[1], into: column, enteringFrom: .right,
                context: .init(
                    workspaceId: fixture.workspaceId,
                    motion: .disabled,
                    workingFrame: frame,
                    gaps: 0,
                    orientation: .horizontal
                ),
                state: &state
            ))
            if tabbed {
                column.displayMode = .tabbed
            }
            let frames = layout(fixture)

            XCTAssertEqual(fixture.columns.count, 1)
            XCTAssertEqual(try XCTUnwrap(frames[fixture.windows[0].token]).width, 1200)
            XCTAssertEqual(column.width, .proportion(1.0 / 3))
        }
    }

    func testZeroMovementDragDoesNotPromoteFittedWidthToChosenWidth() throws {
        let fixture = fixture()
        let before = layout(fixture)
        let first = try XCTUnwrap(before[fixture.windows[0].token])
        let start = CGPoint(x: first.maxX, y: first.midY)
        XCTAssertTrue(fixture.engine.interactiveResizeBegin(
            windowId: fixture.windows[0].id, edges: .right, startLocation: start,
            in: fixture.workspaceId, orientation: .horizontal
        ))
        XCTAssertFalse(fixture.engine.interactiveResizeUpdate(
            currentLocation: start, monitorFrame: frame, gaps: .init(horizontal: 0, vertical: 0)
        ))

        let after = layout(fixture)
        XCTAssertEqual(after, before)
        XCTAssertEqual(fixture.columns[0].width, .proportion(1.0 / 3))
    }

    func testFitWidthAnimationKeepsRenderedAndSettledSpansSeparate() throws {
        let fixture = fixture(count: 3)
        _ = layout(fixture)
        let sampleTime = CACurrentMediaTime()
        fixture.engine.animationClock = AnimationClock(time: sampleTime)
        var state = ViewportState()
        _ = fixture.engine.removeWindows(
            [fixture.windows[2].token],
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: frame,
                gaps: 0,
                orientation: .horizontal
            ),
            state: &state,
            selectedNodeId: fixture.windows[0].id,
            removedNodeIds: []
        )
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId, workingFrame: frame, gaps: 0, orientation: .horizontal, motion: .enabled
        )
        let first = fixture.columns[0]
        let spring = try XCTUnwrap(first.widthAnimation)

        XCTAssertEqual(first.cachedWidth, 400)
        XCTAssertEqual(first.settledWidth, 600)
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId, workingFrame: frame, gaps: 0, orientation: .horizontal, motion: .enabled
        )
        XCTAssertTrue(first.widthAnimation === spring)
        let running = fixture.engine.calculateLayoutWithVisibility(
            state: ViewportState(), workspaceId: fixture.workspaceId, monitorFrame: frame,
            gaps: (0, 0), orientation: .horizontal, animationTime: sampleTime
        )
        XCTAssertEqual(try XCTUnwrap(running.frames[fixture.windows[0].token]).width, 400)
        XCTAssertTrue(spring.isComplete(at: sampleTime + 10))
        _ = first.tickWidthAnimation(at: sampleTime + 10)
        XCTAssertEqual(first.cachedWidth, 600)
        XCTAssertNil(first.widthAnimation)
    }

    func testZeroMovementDragAfterFitAnimationSettlementPreservesChosenWidth() throws {
        let fixture = fixture()
        for column in fixture.columns {
            column.cachedWidth = 400
        }
        fixture.engine.animationClock = AnimationClock(time: 100)
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId, workingFrame: frame, gaps: 0, orientation: .horizontal, motion: .enabled
        )
        XCTAssertEqual(fixture.columns[0].settledWidth, 600)
        XCTAssertTrue(fixture.engine.cancelAnimations(in: fixture.workspaceId))
        let start = CGPoint(x: 600, y: 450)
        XCTAssertTrue(fixture.engine.interactiveResizeBegin(
            windowId: fixture.windows[0].id, edges: .right, startLocation: start,
            in: fixture.workspaceId, orientation: .horizontal
        ))
        XCTAssertFalse(fixture.engine.interactiveResizeUpdate(
            currentLocation: start, monitorFrame: frame, gaps: .init(horizontal: 0, vertical: 0)
        ))
        _ = layout(fixture)

        XCTAssertEqual(fixture.columns[0].width, .proportion(1.0 / 3))
        XCTAssertEqual(fixture.columns.map(\.settledWidth), [600, 600])
    }
}
