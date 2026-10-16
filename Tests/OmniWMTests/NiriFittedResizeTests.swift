// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriFittedResizeTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        var windows: [NiriWindow]
        let frame: CGRect
        let orientation: Monitor.Orientation
        let gap: CGFloat
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var context: NiriInteractionContext {
            .init(
                workspaceId: workspaceId, motion: .disabled,
                workingFrame: frame, gaps: gap, orientation: orientation
            )
        }

        var spans: [CGFloat] {
            columns.map { orientation == .horizontal ? $0.cachedWidth : $0.cachedHeight }
        }

        var specs: [ProportionalSize] {
            columns.map { orientation == .horizontal ? $0.width : $0.height }
        }
    }

    private func fixture(
        count: Int = 2, visibleCount: Int = 3,
        orientation: Monitor.Orientation = .horizontal, gap: CGFloat = 0
    ) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: visibleCount)
        engine.defaultContainerPrimarySpan = nil
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 1200)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7), displayId: 7,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Fitted resize"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)], orientations: [monitor.id: orientation]
        )
        let windows = (0 ..< count).map {
            engine.addWindow(token: WindowToken(pid: 615, windowId: $0 + 1), to: workspaceId, afterSelection: nil)
        }
        var state = ViewportState(selectedNodeId: windows[0].id)
        state.jumpOffset(to: -gap)
        return Fixture(
            engine: engine, workspaceId: workspaceId, windows: windows,
            frame: frame, orientation: orientation, gap: gap, state: state
        )
    }

    private func layout(_ fixture: Fixture) -> [WindowToken: CGRect] {
        fixture.engine.calculateLayout(
            state: fixture.state, workspaceId: fixture.workspaceId, monitorFrame: fixture.frame,
            gaps: (fixture.gap, fixture.gap), orientation: fixture.orientation
        )
    }

    private func begin(
        _ fixture: inout Fixture, index: Int, leading: Bool, select: Bool = true
    ) throws -> CGPoint {
        _ = layout(fixture)
        if select {
            fixture.state.activeColumnIndex = index
            fixture.state.selectedNodeId = fixture.windows[index].id
            fixture.state.jumpOffset(to: -fixture.gap - fixture.state.containerPosition(
                at: index, containers: fixture.columns, gap: fixture.gap,
                sizeKeyPath: fixture.orientation.settledSpanKeyPath
            ))
        }
        let frame = try XCTUnwrap(layout(fixture)[fixture.windows[index].token])
        let horizontal = fixture.orientation == .horizontal
        let edge: ResizeEdge = horizontal ? (leading ? .left : .right) : (leading ? .bottom : .top)
        let start = CGPoint(
            x: horizontal ? (leading ? frame.minX : frame.maxX) : frame.midX,
            y: horizontal ? frame.midY : (leading ? frame.minY : frame.maxY)
        )
        XCTAssertTrue(fixture.engine.interactiveResizeBegin(
            windowId: fixture.windows[index].id, edges: edge, startLocation: start,
            in: fixture.workspaceId, orientation: fixture.orientation, viewOffset: fixture.state.viewOffset
        ))
        return start
    }

    private func shifted(_ point: CGPoint, by delta: CGFloat, orientation: Monitor.Orientation) -> CGPoint {
        CGPoint(
            x: point.x + (orientation == .horizontal ? delta : 0),
            y: point.y + (orientation == .vertical ? delta : 0)
        )
    }

    private func update(_ fixture: inout Fixture, location: CGPoint, expectChange: Bool = true) {
        let engine = fixture.engine
        let frame = fixture.frame
        let gap = fixture.gap
        XCTAssertEqual(engine.interactiveResizeUpdate(
            currentLocation: location, monitorFrame: frame,
            gaps: .init(horizontal: gap, vertical: gap),
            viewportState: { mutate in mutate(&fixture.state) }
        ), expectChange)
    }

    private func end(_ fixture: inout Fixture) {
        let engine = fixture.engine
        let frame = fixture.frame
        let gap = fixture.gap
        engine.interactiveResizeEnd(
            motion: .disabled, state: &fixture.state, workingFrame: frame, gaps: gap
        )
    }

    private func assertShownSpans(_ fixture: Fixture, _ expected: [CGFloat]) throws {
        let frames = layout(fixture)
        XCTAssertEqual(fixture.spans.count, expected.count)
        for index in fixture.windows.indices {
            XCTAssertEqual(fixture.spans[index], expected[index], accuracy: 0.000001)
            let frame = try XCTUnwrap(frames[fixture.windows[index].token])
            XCTAssertEqual(fixture.orientation == .horizontal ? frame.width : frame.height, expected[index])
        }
    }

    func testEveryPrimaryEdgeResizesFromShownSpanAndRetainsPeers() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for index in 0 ... 1 {
                for leading in [false, true] {
                    for delta: CGFloat in [-100, 100] {
                        var fixture = fixture(orientation: orientation)
                        let start = try begin(&fixture, index: index, leading: leading)
                        let location = shifted(start, by: delta, orientation: orientation)
                        let requested = 600 + (leading ? -delta : delta)
                        var expected: [CGFloat] = [600, 600]
                        expected[index] = requested

                        update(&fixture, location: location)

                        try assertShownSpans(fixture, expected)
                        let frame = try XCTUnwrap(layout(fixture)[fixture.windows[index].token])
                        let edge = orientation == .horizontal
                            ? (leading ? frame.minX : frame.maxX) : (leading ? frame.minY : frame.maxY)
                        XCTAssertEqual(edge, orientation == .horizontal ? location.x : location.y)
                        XCTAssertEqual(fixture.specs[index], .fixed(requested))
                        XCTAssertEqual(fixture.specs[1 - index], .proportion(1.0 / 3))
                        end(&fixture)
                        try assertShownSpans(fixture, expected)
                        try assertShownSpans(fixture, expected)
                    }
                }
            }
        }
    }

    func testZeroPrimaryMovementKeepsAutomaticFitAndStoredChoice() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            let start = try begin(&fixture, index: 0, leading: false)

            update(&fixture, location: start, expectChange: false)
            end(&fixture)

            try assertShownSpans(fixture, [600, 600])
            XCTAssertEqual(fixture.specs, [.proportion(1.0 / 3), .proportion(1.0 / 3)])
        }
    }

    func testDraggingBackToStartKeepsTheOriginalShownSpan() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            let start = try begin(&fixture, index: 0, leading: false)
            update(&fixture, location: shifted(start, by: 100, orientation: orientation))
            update(&fixture, location: start)
            end(&fixture)

            try assertShownSpans(fixture, [600, 600])
            XCTAssertEqual(fixture.specs, [.fixed(600), .proportion(1.0 / 3)])
        }
    }

    func testMiddleResizeRetainsShownPeersAndTheFocusedAnchor() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(count: 3, visibleCount: 4, orientation: orientation)
            let start = try begin(&fixture, index: 1, leading: false, select: false)
            update(&fixture, location: shifted(start, by: 100, orientation: orientation))

            try assertShownSpans(fixture, [400, 500, 400])
            XCTAssertEqual(fixture.specs, [.proportion(0.25), .fixed(500), .proportion(0.25)])
            XCTAssertEqual(fixture.state.activeColumnIndex, 0)
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.windows[0].id)
            end(&fixture)
            try assertShownSpans(fixture, [400, 500, 400])
        }
    }

    func testCountChangeRestoresPeerSpecsAndResumesAutomaticFit() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            let start = try begin(&fixture, index: 0, leading: false)
            update(&fixture, location: shifted(start, by: 100, orientation: orientation))
            end(&fixture)
            try assertShownSpans(fixture, [700, 600])
            fixture.columns[1].invalidateCachedPrimarySpans()
            try assertShownSpans(fixture, [700, 600])
            XCTAssertEqual(fixture.specs[1], .proportion(1.0 / 3))
            let third = fixture.engine.addWindow(
                token: WindowToken(pid: 615, windowId: 3), to: fixture.workspaceId, afterSelection: nil
            )
            fixture.windows.append(third)

            try assertShownSpans(fixture, [700, 400, 400])
            XCTAssertEqual(fixture.specs, [.fixed(700), .proportion(1.0 / 3), .proportion(1.0 / 3)])
            fixture.engine.removeWindow(token: third.token, in: fixture.workspaceId)
            fixture.windows.removeLast()
            _ = layout(fixture)
            XCTAssertEqual(fixture.spans[0], 8400.0 / 11, accuracy: 0.000001)
            XCTAssertEqual(fixture.spans[1], 4800.0 / 11, accuracy: 0.000001)
            XCTAssertEqual(fixture.specs, [.fixed(700), .proportion(1.0 / 3)])
        }
    }

    func testColumnCountChangesOnTheOtherAxisResumeAutomaticFit() throws {
        var fixture = fixture()
        let start = try begin(&fixture, index: 0, leading: false)
        update(&fixture, location: shifted(start, by: 100, orientation: .horizontal))
        end(&fixture)
        let third = fixture.engine.addWindow(
            token: WindowToken(pid: 615, windowId: 3), to: fixture.workspaceId, afterSelection: nil
        )
        _ = fixture.engine.calculateLayout(
            state: fixture.state, workspaceId: fixture.workspaceId, monitorFrame: fixture.frame,
            gaps: (0, 0), orientation: .vertical
        )
        fixture.engine.removeWindow(token: third.token, in: fixture.workspaceId)
        _ = layout(fixture)

        XCTAssertEqual(fixture.spans[0], 8400.0 / 11, accuracy: 0.000001)
        XCTAssertEqual(fixture.spans[1], 4800.0 / 11, accuracy: 0.000001)
        XCTAssertEqual(fixture.specs, [.fixed(700), .proportion(1.0 / 3)])
    }

    func testRelativePrimaryCommandsAdjustTheShownSpanInBothDirections() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for grow in [false, true] {
                for proportional in [false, true] {
                    var fixture = fixture(orientation: orientation)
                    _ = layout(fixture)
                    let sign: CGFloat = grow ? 1 : -1
                    let change: NiriSizeChange = proportional ? .adjustProportion(sign * 10) : .adjustFixed(sign * 100)
                    let expected = 600 + sign * (proportional ? 120 : 100)
                    let engine = fixture.engine
                    engine.setWindowPrimarySpan(
                        fixture.windows[0], change: change, context: fixture.context, state: &fixture.state
                    )

                    try assertShownSpans(fixture, [expected, 600])
                    try assertShownSpans(fixture, [expected, 600])
                    XCTAssertEqual(fixture.specs[0], proportional ? .proportion(0.5 + sign * 0.1) : .fixed(expected))
                    XCTAssertEqual(fixture.specs[1], .proportion(1.0 / 3))
                }
            }
        }
    }

    func testProportionalShrinkEscapesPackingHintsInBothOrientations() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(count: 3, visibleCount: 3, orientation: orientation)
            let column = fixture.columns[0]
            column.width = .proportion(0.5)
            column.height = .proportion(0.5)
            let hint = ObservedAxisHint(requested: 600, observed: 616)
            let hints = orientation == .horizontal
                ? ObservedPackingHints(width: hint) : ObservedPackingHints(height: hint)
            fixture.engine.updateWindowConstraints(
                for: fixture.windows[0].token,
                constraints: .unconstrained,
                packingHints: hints,
                in: fixture.workspaceId,
                motion: .disabled
            )
            try assertShownSpans(fixture, [616, 400, 400])
            let engine = fixture.engine

            for step in 1 ... 5 {
                engine.setWindowPrimarySpan(
                    fixture.windows[0], change: .adjustProportion(-1), context: fixture.context, state: &fixture.state
                )
                _ = layout(fixture)
                XCTAssertEqual(fixture.spans[0], 600 - CGFloat(step) * 12, accuracy: 0.000001)
                XCTAssertEqual(fixture.windows[0].packingHints, hints)
            }

            engine.setWindowPrimarySpan(
                fixture.windows[0], change: .setProportion(50), context: fixture.context, state: &fixture.state
            )
            try assertShownSpans(fixture, [616, 400, 400])
        }
    }

    func testProportionalResizeDoesNotBankStepsOutsideApplicationBounds() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(count: 3, visibleCount: 3, orientation: orientation)
            let engine = fixture.engine
            engine.updateWindowConstraints(
                for: fixture.windows[0].token,
                constraints: WindowSizeConstraints(
                    minSize: .init(width: 500, height: 500),
                    maxSize: .init(width: 700, height: 700), isFixed: false
                ),
                in: fixture.workspaceId, motion: .disabled
            )
            _ = layout(fixture)

            for grow in [false, true] {
                for _ in 0 ..< 5 {
                    engine.setWindowPrimarySpan(
                        fixture.windows[0], change: .adjustProportion(grow ? 10 : -10),
                        context: fixture.context, state: &fixture.state
                    )
                    _ = layout(fixture)
                }
                XCTAssertEqual(fixture.spans[0], grow ? 700 : 500, accuracy: 0.000001)
                engine.setWindowPrimarySpan(
                    fixture.windows[0], change: .adjustProportion(grow ? -10 : 10),
                    context: fixture.context, state: &fixture.state
                )
                _ = layout(fixture)
                XCTAssertEqual(fixture.spans[0], grow ? 580 : 620, accuracy: 0.000001)
            }
        }
    }

    func testPresetCyclingUsesTheShownSpanAndRetainsTheResult() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            _ = layout(fixture)
            fixture.columns[0].presetWidthIdx = 0
            let engine = fixture.engine
            engine.toggleContainerPrimarySpan(
                fixture.columns[0], forwards: true, context: fixture.context, state: &fixture.state
            )

            try assertShownSpans(fixture, [800, 600])
            try assertShownSpans(fixture, [800, 600])
            XCTAssertFalse(fixture.specs[0].isFixed)
            XCTAssertEqual(fixture.specs[0].value, 2.0 / 3, accuracy: 0.000000000001)
            XCTAssertEqual(fixture.specs[1], .proportion(1.0 / 3))
            engine.toggleContainerPrimarySpan(
                fixture.columns[0], forwards: false, context: fixture.context, state: &fixture.state
            )
            try assertShownSpans(fixture, [600, 600])
            XCTAssertEqual(fixture.specs, [.proportion(0.5), .proportion(1.0 / 3)])
        }
    }

    func testFullPrimarySpanRestoresTheShownSpanAndRetainsPeers() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            _ = layout(fixture)
            let engine = fixture.engine
            engine.toggleContainerFullPrimarySpan(fixture.columns[0], context: fixture.context, state: &fixture.state)

            try assertShownSpans(fixture, [1200, 600])
            let column = fixture.columns[0]
            XCTAssertTrue(orientation == .horizontal ? column.isFullWidth : column.isFullHeight)
            XCTAssertEqual(orientation == .horizontal ? column.savedWidth : column.savedHeight, .fixed(600))
            engine.toggleContainerFullPrimarySpan(column, context: fixture.context, state: &fixture.state)
            try assertShownSpans(fixture, [600, 600])
            try assertShownSpans(fixture, [600, 600])
            XCTAssertEqual(fixture.specs, [.fixed(600), .proportion(1.0 / 3)])
        }
    }

    func testBalanceKeepsTheConfiguredSpansUntilCountChanges() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = fixture(orientation: orientation)
            _ = layout(fixture)
            let engine = fixture.engine
            XCTAssertTrue(engine.balanceSizes(
                in: fixture.workspaceId, motion: .disabled, workingFrame: fixture.frame,
                gaps: fixture.gap, orientation: orientation
            ))

            try assertShownSpans(fixture, [400, 400])
            try assertShownSpans(fixture, [400, 400])
            XCTAssertEqual(fixture.specs, [.proportion(1.0 / 3), .proportion(1.0 / 3)])
        }
    }

    func testManualResizeStillClampsApplicationBounds() throws {
        var fixture = fixture()
        fixture.engine.updateWindowConstraints(
            for: fixture.windows[0].token,
            constraints: WindowSizeConstraints(
                minSize: .init(width: 500, height: 1), maxSize: .init(width: 700, height: 0), isFixed: false
            ),
            in: fixture.workspaceId, motion: .disabled
        )
        let start = try begin(&fixture, index: 0, leading: false)
        let peerSpan = fixture.spans[1]
        update(&fixture, location: shifted(start, by: -300, orientation: .horizontal))

        XCTAssertEqual(fixture.columns[0].cachedWidth, 500)
        XCTAssertEqual(fixture.columns[0].width, .fixed(500))
        update(&fixture, location: shifted(start, by: 300, orientation: .horizontal))
        end(&fixture)
        _ = layout(fixture)
        XCTAssertEqual(fixture.columns[0].cachedWidth, 700)
        XCTAssertEqual(fixture.columns[0].width, .fixed(700))
        XCTAssertEqual(fixture.spans[1], peerSpan)
        XCTAssertEqual(fixture.specs[1], .proportion(1.0 / 3))
    }

    func testObservedPackingUsesActualSpanForLeadingCompensation() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = fixture(orientation: orientation)
            if orientation == .horizontal {
                fixture.windows[1].packingHints.width = ObservedAxisHint(requested: 700, observed: 720)
            } else {
                fixture.windows[1].packingHints.height = ObservedAxisHint(requested: 700, observed: 720)
            }
            let start = try begin(&fixture, index: 1, leading: true)
            update(&fixture, location: shifted(start, by: -100, orientation: orientation))
            let frame = try XCTUnwrap(layout(fixture)[fixture.windows[1].token])

            try assertShownSpans(fixture, [600, 720])
            XCTAssertEqual(orientation == .horizontal ? frame.maxX : frame.maxY, 1200)
            XCTAssertEqual(fixture.state.viewOffset, -480)
            XCTAssertEqual(fixture.specs, [.proportion(1.0 / 3), .fixed(720)])
            end(&fixture)
            try assertShownSpans(fixture, [600, 720])
        }
    }
}
