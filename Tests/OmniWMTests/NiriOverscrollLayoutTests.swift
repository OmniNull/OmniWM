// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriOverscrollLayoutTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

    private func engine(orientation: Monitor.Orientation) -> (NiriLayoutEngine, WorkspaceDescriptor.ID) {
        let engine = NiriLayoutEngine()
        engine.edgeOverscroll = .enabled(visibleFraction: 0.05)
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7), displayId: 7, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Overscroll layout"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)], orientations: [monitor.id: orientation]
        )
        return (engine, workspaceId)
    }

    func testLoneWindowUsesActualFitSizeAndRendersGestureOffsetsOnBothAxes() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for fit in [SingleWindowFit.fullScreen, SingleWindowFit(mode: .custom, width: 400, height: 300)] {
                for snap in [false, true] {
                    for projected in [-10_000.0, 10_000.0] {
                        let (engine, workspaceId) = engine(orientation: orientation)
                        engine.singleWindowFit = fit
                        let token = WindowToken(pid: 1, windowId: 1)
                        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
                        var state = ViewportState()
                        let original = try XCTUnwrap(engine.calculateLayout(
                            state: state, workspaceId: workspaceId, monitorFrame: frame,
                            gaps: (horizontal: 10, vertical: 10), orientation: orientation
                        )[token])
                        engine.resolvePrimaryContainerSpans(
                            in: workspaceId, workingFrame: frame, gaps: 10, orientation: orientation
                        )
                        let column = try XCTUnwrap(engine.columns(in: workspaceId).first)
                        let cachedWidth = column.cachedWidth
                        let context = NiriInteractionContext(
                            workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
                            gaps: 10, orientation: orientation
                        )
                        XCTAssertNotNil(engine.endProjectedGesture(
                            state: &state, context: context,
                            currentOffset: 0, projectedOffset: projected, snapToColumn: snap
                        ))
                        let rendered = try XCTUnwrap(engine.calculateLayout(
                            state: state, workspaceId: workspaceId, monitorFrame: frame,
                            gaps: (horizontal: 10, vertical: 10), orientation: orientation
                        )[token])
                        let visible = rendered.intersection(frame)
                        let actualSpan = orientation == .horizontal ? original.width : original.height
                        let visibleSpan = orientation == .horizontal ? visible.width : visible.height
                        XCTAssertEqual(visibleSpan, actualSpan * 0.05 + 10, accuracy: 0.5)
                        XCTAssertEqual(rendered.size, original.size)
                        XCTAssertEqual(column.cachedWidth, cachedWidth)
                        XCTAssertTrue(state.preservesGestureOffset)
                    }
                }
            }
        }
    }

    func testColumnRemovalCorrectionPreservesIntentionalOverscrollAndClampsStaleLimits() throws {
        let (engine, workspaceId) = engine(orientation: .horizontal)
        for index in 1 ... 3 {
            _ = engine.addWindow(token: WindowToken(pid: 1, windowId: index), to: workspaceId, afterSelection: nil)
        }
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
            gaps: 10, orientation: .horizontal
        )
        var state = ViewportState()
        XCTAssertNotNil(engine.endProjectedGesture(
            state: &state, context: context, currentOffset: 0, projectedOffset: -10_000
        ))
        let overscrolled = state.viewOffset
        XCTAssertFalse(engine.correctViewportAfterColumnRemoval(context: context, state: &state))
        XCTAssertEqual(state.viewOffset, overscrolled)
        state.jumpOffset(to: -20_000)
        XCTAssertTrue(engine.correctViewportAfterColumnRemoval(context: context, state: &state))
        XCTAssertEqual(state.viewOffset, overscrolled, accuracy: 0.5)
    }

    func testIncreasingVisibleStripReboundsPreservedLoneWindowOnBothAxes() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for fit in [SingleWindowFit.fullScreen, SingleWindowFit(mode: .custom, width: 400, height: 300)] {
                for projected in [-10_000.0, 10_000.0] {
                    let (engine, workspaceId) = engine(orientation: orientation)
                    engine.singleWindowFit = fit
                    let token = WindowToken(pid: 1, windowId: 1)
                    _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
                    var state = ViewportState()
                    let original = try XCTUnwrap(engine.calculateLayout(
                        state: state, workspaceId: workspaceId, monitorFrame: frame,
                        gaps: (horizontal: 10, vertical: 10), orientation: orientation
                    )[token])
                    let context = NiriInteractionContext(
                        workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
                        gaps: 10, orientation: orientation
                    )
                    XCTAssertNotNil(engine.endProjectedGesture(
                        state: &state, context: context, currentOffset: 0, projectedOffset: projected
                    ))
                    let overscrolled = state.viewOffset
                    engine.edgeOverscroll = .enabled(visibleFraction: 1)
                    XCTAssertTrue(engine.correctSingleWindowGestureOffset(context: context, state: &state))
                    XCTAssertNotEqual(state.viewOffset, overscrolled)
                    let rendered = try XCTUnwrap(engine.calculateLayout(
                        state: state, workspaceId: workspaceId, monitorFrame: frame,
                        gaps: (horizontal: 10, vertical: 10), orientation: orientation
                    )[token])
                    XCTAssertEqual(rendered.intersection(frame).size, original.size)
                    XCTAssertFalse(engine.correctSingleWindowGestureOffset(context: context, state: &state))
                    XCTAssertTrue(state.preservesGestureOffset)
                }
            }
        }
    }

    func testFitChangeReclampsPreservedLoneWindowAgainstNewSpanOnBothAxes() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let (engine, workspaceId) = engine(orientation: orientation)
            engine.singleWindowFit = SingleWindowFit(mode: .custom, width: 700, height: 500)
            let token = WindowToken(pid: 1, windowId: 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            var state = ViewportState()
            _ = engine.calculateLayout(
                state: state, workspaceId: workspaceId, monitorFrame: frame,
                gaps: (horizontal: 10, vertical: 10), orientation: orientation
            )
            engine.resolvePrimaryContainerSpans(
                in: workspaceId, workingFrame: frame, gaps: 10, orientation: orientation
            )
            let context = NiriInteractionContext(
                workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
                gaps: 10, orientation: orientation
            )
            XCTAssertNotNil(engine.endProjectedGesture(
                state: &state, context: context, currentOffset: 0, projectedOffset: 10_000
            ))
            let overscrolled = state.viewOffset
            engine.singleWindowFit = SingleWindowFit(mode: .custom, width: 100, height: 100)
            XCTAssertTrue(engine.correctSingleWindowGestureOffset(context: context, state: &state))
            XCTAssertNotEqual(state.viewOffset, overscrolled)
            XCTAssertTrue(state.preservesGestureOffset)
            let rendered = try XCTUnwrap(engine.calculateLayout(
                state: state, workspaceId: workspaceId, monitorFrame: frame,
                gaps: (horizontal: 10, vertical: 10), orientation: orientation
            )[token])
            XCTAssertEqual(rendered.intersection(frame).size, CGSize(width: 100, height: 100))
        }
    }

    private func assertCenteringCentersLoneWindow(
        _ command: (NiriLayoutEngine, NiriInteractionContext, inout ViewportState) -> Bool,
        orientation: Monitor.Orientation
    ) throws {
        let (engine, workspaceId) = engine(orientation: orientation)
        engine.singleWindowFit = SingleWindowFit(mode: .custom, width: 400, height: 300)
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        var state = ViewportState()
        let original = try XCTUnwrap(engine.calculateLayout(
            state: state, workspaceId: workspaceId, monitorFrame: frame,
            gaps: (horizontal: 10, vertical: 10), orientation: orientation
        )[token])
        engine.resolvePrimaryContainerSpans(
            in: workspaceId, workingFrame: frame, gaps: 10, orientation: orientation
        )
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
            gaps: 10, orientation: orientation
        )
        XCTAssertNotNil(engine.endProjectedGesture(
            state: &state, context: context, currentOffset: 0, projectedOffset: -10_000
        ))
        XCTAssertTrue(command(engine, context, &state))
        let rendered = try XCTUnwrap(engine.calculateLayout(
            state: state, workspaceId: workspaceId, monitorFrame: frame,
            gaps: (horizontal: 10, vertical: 10), orientation: orientation
        )[token])
        XCTAssertEqual(rendered, original)
    }

    func testCenterColumnCentersLoneWindowOnBothAxes() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            try assertCenteringCentersLoneWindow(
                { engine, context, state in engine.centerColumn(context: context, state: &state) },
                orientation: orientation
            )
        }
    }

    func testCenterVisibleColumnsCentersLoneWindowOnBothAxes() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            try assertCenteringCentersLoneWindow(
                { engine, context, state in engine.centerVisibleColumns(context: context, state: &state) },
                orientation: orientation
            )
        }
    }

    func testCenterVisibleColumnsFallsBackWhenOverscrollHidesTheBlock() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for centerMode in [CenterFocusedColumn.never, .always] {
                let (engine, workspaceId) = engine(orientation: orientation)
                engine.centerFocusedColumn = centerMode
                for index in 1 ... 3 {
                    _ = engine.addWindow(
                        token: WindowToken(pid: 1, windowId: index),
                        to: workspaceId,
                        afterSelection: nil
                    )
                }
                let context = NiriInteractionContext(
                    workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
                    gaps: 10, orientation: orientation
                )
                var state = ViewportState()
                XCTAssertNotNil(engine.endProjectedGesture(
                    state: &state, context: context, currentOffset: 0, projectedOffset: -10_000
                ))
                let overscrolled = state.viewOffset
                XCTAssertTrue(engine.centerVisibleColumns(context: context, state: &state))
                XCTAssertFalse(state.preservesGestureOffset)
                XCTAssertNotEqual(state.viewOffset, overscrolled)
                let expected = state.computeCenteredOffset(
                    containerIndex: state.activeColumnIndex, containers: engine.columns(in: workspaceId),
                    context: context, viewFrame: frame
                )
                XCTAssertEqual(state.viewOffset, expected, accuracy: 0.5)
            }
        }
    }

    func testCenteringWithoutColumnsDoesNotReleasePreservedGestureOffset() {
        let (engine, workspaceId) = engine(orientation: .horizontal)
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: frame,
            gaps: 10, orientation: .horizontal
        )
        var state = ViewportState()
        state.preservesGestureOffset = true
        state.viewOffset = -100
        let before = state
        XCTAssertFalse(engine.centerVisibleColumns(context: context, state: &state))
        XCTAssertEqual(state, before)
        XCTAssertFalse(engine.centerColumn(context: context, state: &state))
        XCTAssertEqual(state, before)
    }

    func testSingleWindowLiveOffsetOverrideIsNotIgnored() throws {
        let (engine, workspaceId) = engine(orientation: .horizontal)
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let result = engine.calculateLayoutWithVisibility(
            state: ViewportState(), workspaceId: workspaceId, monitorFrame: frame,
            gaps: (horizontal: 10, vertical: 10), orientation: .horizontal, viewOffsetOverride: -200
        )
        let rendered = try XCTUnwrap(result.frames[token])
        XCTAssertEqual(rendered.minX, frame.minX + 200)
    }
}
