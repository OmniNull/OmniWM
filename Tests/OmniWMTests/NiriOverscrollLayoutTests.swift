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
