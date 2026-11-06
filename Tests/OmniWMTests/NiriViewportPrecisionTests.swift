// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriViewportPrecisionTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let windows: [NiriWindow]
        let workingFrame: CGRect
        let gap: CGFloat
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var context: NiriInteractionContext {
            .init(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        }
    }

    private func makeFixture(width: CGFloat, gap: CGFloat, visibleCount: Int = 3) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: visibleCount)
        engine.defaultContainerPrimarySpan = nil
        let workspaceId = WorkspaceDescriptor.ID()
        let windows = (1 ... 2).map {
            engine.addWindow(token: WindowToken(pid: 615, windowId: $0), to: workspaceId, afterSelection: nil)
        }
        let workingFrame = CGRect(x: 0, y: 0, width: width, height: 900)
        var state = ViewportState(selectedNodeId: windows[0].id)
        state.jumpOffset(to: -gap)
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (gap, gap),
            orientation: .horizontal
        )
        return Fixture(
            engine: engine, workspaceId: workspaceId, windows: windows,
            workingFrame: workingFrame, gap: gap, state: state
        )
    }

    func testFittedPairDoesNotCenterForFloatingOverflow() {
        for scale: CGFloat in [1, 2] {
            var fixture = makeFixture(width: 3440, gap: 8)
            let columns = fixture.columns
            let context = fixture.context
            fixture.state.transitionToColumn(
                1,
                columns: columns,
                context: context,
                animate: false,
                centerMode: .onOverflow,
                scale: scale
            )

            let viewStart = fixture.state.columnX(at: 1, columns: columns, gap: fixture.gap)
                + fixture.state.viewOffset
            XCTAssertEqual(viewStart, -fixture.gap)
            XCTAssertEqual(columns.map(\.width), [.proportion(1.0 / 3), .proportion(1.0 / 3)])
        }
    }

    func testFilledPairExpansionPreservesChosenWidthsAndFullWidthState() {
        for (width, gap): (CGFloat, CGFloat) in [(3440, 8), (1000, 6)] {
            for activeIndex in 0 ... 1 {
                var fixture = makeFixture(width: width, gap: gap)
                let columns = fixture.columns
                let originalSpans = columns.map(\.cachedWidth)
                fixture.state.activeColumnIndex = activeIndex
                fixture.state.selectedNodeId = fixture.windows[activeIndex].id
                fixture.state.jumpOffset(to: -gap - fixture.state.columnX(
                    at: activeIndex, columns: columns, gap: gap
                ))

                for scale: CGFloat in [1, 2] {
                    XCTAssertNil(NiriColumnExpansionPlan(
                        column: columns[activeIndex],
                        columns: columns,
                        state: fixture.state,
                        context: fixture.context,
                        scale: scale
                    ))
                }
                fixture.engine.expandContainerToAvailablePrimarySpan(
                    columns[activeIndex],
                    context: fixture.context,
                    state: &fixture.state
                )

                XCTAssertEqual(columns.map(\.width), [.proportion(1.0 / 3), .proportion(1.0 / 3)])
                XCTAssertEqual(columns.map(\.cachedWidth), originalSpans)
                XCTAssertEqual(columns.map(\.isFullWidth), [false, false])
                XCTAssertEqual(columns.map(\.savedWidth), [nil, nil])
            }
        }
    }

    func testOnOverflowStillCentersForOnePhysicalPixelOfOverflow() {
        for scale: CGFloat in [1, 2] {
            let fixture = makeFixture(width: 1000, gap: 0, visibleCount: 2)
            let columns = fixture.columns
            let targetWidth = 600 + 1 / scale
            for (column, width) in zip(columns, [CGFloat(400), targetWidth]) {
                column.width = .fixed(width)
                column.cachedWidth = width
            }
            let offset = fixture.state.computeVisibleOffset(
                containerIndex: 1,
                containers: columns,
                context: fixture.context,
                currentViewStart: 0,
                centerMode: .onOverflow,
                fromContainerIndex: 0,
                scale: scale
            )

            XCTAssertEqual(offset, -(1000 - targetWidth) / 2)
        }
    }

    func testExpansionStillUsesOnePhysicalPixelOfAvailableSpace() throws {
        for scale: CGFloat in [1, 2] {
            var fixture = makeFixture(width: 1000, gap: 0, visibleCount: 2)
            let columns = fixture.columns
            let pixel = 1 / scale
            for (column, width) in zip(columns, [CGFloat(400), 600 - pixel]) {
                column.width = .fixed(width)
                column.cachedWidth = width
            }
            let plan = try XCTUnwrap(NiriColumnExpansionPlan(
                column: columns[0],
                columns: columns,
                state: fixture.state,
                context: fixture.context,
                scale: scale
            ))
            XCTAssertEqual(plan.availableWidth, pixel)
            XCTAssertTrue(plan.countedNonActiveColumn)

            fixture.engine.expandContainerToAvailablePrimarySpan(
                columns[0],
                context: fixture.context,
                state: &fixture.state
            )

            XCTAssertEqual(columns[0].width, .fixed(400 + pixel))
            XCTAssertEqual(columns[0].cachedWidth, 400 + pixel)
            XCTAssertEqual(columns[1].width, .fixed(600 - pixel))
            XCTAssertEqual(columns.map(\.isFullWidth), [false, false])
        }
    }
}
