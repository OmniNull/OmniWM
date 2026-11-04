// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriSettledCoverageTests: NiriInteractionTestCase {
    private let sourceFrame = CGRect(x: 0, y: 0, width: 1_440, height: 2_560)
    private let traceWorkingFrame = CGRect(x: 16, y: 16, width: 1_408, height: 2_498)
    private let traceNeighborSpan: CGFloat = 1_581
    private let traceSelectedSpan: CGFloat = 1_241

    private var traceGap: CGFloat {
        traceWorkingFrame.minX - sourceFrame.minX
    }

    private var traceTrailingOffset: CGFloat {
        -(traceWorkingFrame.height - traceGap - traceSelectedSpan)
    }

    func testTraceGeometrySelectsTrailingFitAndIsIdempotent() {
        let source = monitorContext(
            displayId: 3,
            frame: sourceFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 2_530)
        )
        let upperNeighbor = monitorContext(
            displayId: 5,
            frame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080)
        )
        let input = NiriSettledCoverageEvaluator.Input(
            containerSpans: [traceNeighborSpan, traceNeighborSpan, traceSelectedSpan, traceNeighborSpan],
            selectedIndex: 2,
            activeIndex: 2,
            semanticOffset: -traceGap,
            gap: traceGap,
            workingFrame: traceWorkingFrame,
            sourceMonitor: source,
            monitors: [source, upperNeighbor],
            orientation: .vertical,
            scale: 2
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(for: input)

        XCTAssertEqual(recovered, traceTrailingOffset)
        XCTAssertEqual(
            NiriSettledCoverageEvaluator.bestOffset(
                for: .init(
                    containerSpans: input.containerSpans,
                    selectedIndex: input.selectedIndex,
                    activeIndex: input.activeIndex,
                    semanticOffset: recovered,
                    gap: input.gap,
                    workingFrame: input.workingFrame,
                    sourceMonitor: input.sourceMonitor,
                    monitors: input.monitors,
                    orientation: input.orientation,
                    scale: input.scale
                )
            ),
            recovered
        )
    }

    func testMirroredLowerNeighborSelectsLeadingFit() {
        let source = monitorContext(displayId: 10, frame: sourceFrame)
        let lowerNeighbor = monitorContext(
            displayId: 11,
            frame: CGRect(x: 328, y: -1_080, width: 1_920, height: 1_080)
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [traceNeighborSpan, traceSelectedSpan, traceNeighborSpan],
                selectedIndex: 1,
                activeIndex: 1,
                semanticOffset: traceTrailingOffset,
                gap: traceGap,
                workingFrame: traceWorkingFrame,
                sourceMonitor: source,
                monitors: [source, lowerNeighbor],
                orientation: .vertical,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, -traceGap)
    }

    func testHorizontalNeighborUsesTheSameAxisGenericRecovery() {
        let horizontalSourceFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let horizontalWorkingFrame = CGRect(x: 16, y: 16, width: 2_498, height: 1_408)
        let source = monitorContext(displayId: 20, frame: horizontalSourceFrame)
        let rightNeighbor = monitorContext(
            displayId: 21,
            frame: CGRect(x: 2_560, y: 328, width: 1_080, height: 1_920)
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [traceNeighborSpan, traceNeighborSpan, traceSelectedSpan, traceNeighborSpan],
                selectedIndex: 2,
                activeIndex: 2,
                semanticOffset: -traceGap,
                gap: traceGap,
                workingFrame: horizontalWorkingFrame,
                sourceMonitor: source,
                monitors: [source, rightNeighbor],
                orientation: .horizontal,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, -(horizontalWorkingFrame.width - traceGap - traceSelectedSpan))
    }

    func testOnePhysicalPixelGainStaysAndTwoPixelGainMoves() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = monitorContext(displayId: 30, frame: frame)
        let scale: CGFloat = 2
        let pixel = 1 / scale

        func recoveredOffset(from semanticOffset: CGFloat) -> CGFloat {
            NiriSettledCoverageEvaluator.bestOffset(
                for: .init(
                    containerSpans: [50, 50],
                    selectedIndex: 0,
                    activeIndex: 0,
                    semanticOffset: semanticOffset,
                    gap: 0,
                    workingFrame: frame,
                    sourceMonitor: source,
                    monitors: [source],
                    orientation: .vertical,
                    scale: scale
                )
            )
        }

        XCTAssertEqual(recoveredOffset(from: pixel), pixel)
        XCTAssertEqual(recoveredOffset(from: pixel * 2), 0)
    }

    func testSemanticCandidateUsesItsExactExistingOffset() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = monitorContext(displayId: 31, frame: frame)
        let semanticOffset: CGFloat = -97.25

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [35, 63.25, 57.5, 90.5, 43.5],
                selectedIndex: 1,
                activeIndex: 2,
                semanticOffset: semanticOffset,
                gap: 0.25,
                workingFrame: frame,
                sourceMonitor: source,
                monitors: [source],
                orientation: .vertical,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, semanticOffset)
    }

    func testInteractiveResizeRecoversOnlyAfterRelease() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let sourceMonitor = Monitor(
            id: .init(displayId: 40),
            displayId: 40,
            frame: sourceFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 2_530),
            hasNotch: false,
            name: "Portrait Source"
        )
        let upperMonitor = Monitor(
            id: .init(displayId: 41),
            displayId: 41,
            frame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080),
            hasNotch: false,
            name: "Upper Neighbor"
        )
        _ = engine.ensureMonitor(for: sourceMonitor.id, monitor: sourceMonitor, orientation: .vertical)
        _ = engine.ensureMonitor(for: upperMonitor.id, monitor: upperMonitor, orientation: .horizontal)

        var windows: [NiriWindow] = []
        for index in 0 ..< 4 {
            let window = addWindow(
                engine,
                pid: 9_000,
                windowId: index + 1,
                to: workspaceId,
                after: windows.last
            )
            windows.append(window)
        }
        engine.moveWorkspace(workspaceId, to: sourceMonitor.id, monitor: sourceMonitor)

        let columns = engine.columns(in: workspaceId)
        XCTAssertEqual(columns.count, windows.count)
        for column in columns {
            column.height = .fixed(traceNeighborSpan)
            column.cachedHeight = traceNeighborSpan
        }

        var state = ViewportState()
        state.activeColumnIndex = 2
        state.selectedNodeId = windows[2].id
        state.jumpOffset(to: -traceGap)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: windows[2].id,
                edges: .top,
                startLocation: .zero,
                in: workspaceId,
                orientation: .vertical,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: 0, y: traceSelectedSpan - traceNeighborSpan),
                monitorFrame: traceWorkingFrame,
                gaps: LayoutGaps(horizontal: traceGap, vertical: traceGap),
                viewportState: { mutate in mutate(&state) }
            )
        )

        XCTAssertEqual(columns[2].cachedHeight, traceSelectedSpan)
        XCTAssertEqual(state.viewOffset, -traceGap)

        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &state,
            workingFrame: traceWorkingFrame,
            gaps: traceGap
        )

        XCTAssertNil(engine.interactiveResize)
        XCTAssertEqual(state.viewOffset, traceTrailingOffset)

        let layout = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: sourceMonitor,
            gaps: LayoutGaps(horizontal: traceGap, vertical: traceGap),
            state: state,
            workingArea: WorkingAreaContext(
                workingFrame: traceWorkingFrame,
                fullscreenLayoutFrame: sourceMonitor.visibleFrame,
                viewFrame: sourceMonitor.frame,
                scale: 2
            )
        )
        let visibleFrames = windows.compactMap { window -> CGRect? in
            guard layout.hiddenHandles[window.token] == nil else { return nil }
            return layout.frames[window.token]
        }
        for frame in layout.frames.values {
            XCTAssertFalse(frame.intersects(upperMonitor.frame))
        }

        let intervals = visibleFrames.compactMap { frame -> ClosedRange<CGFloat>? in
            let intersection = frame.intersection(traceWorkingFrame)
            guard !intersection.isNull, intersection.height > 0 else { return nil }
            return intersection.minY ... intersection.maxY
        }
        .sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertGreaterThanOrEqual(intervals.count, 2)
        let firstInterval = try XCTUnwrap(intervals.first)
        let lastInterval = try XCTUnwrap(intervals.last)
        XCTAssertEqual(firstInterval.lowerBound, traceWorkingFrame.minY)
        XCTAssertEqual(lastInterval.upperBound, traceWorkingFrame.maxY - traceGap)
        for index in 1 ..< intervals.count {
            XCTAssertLessThanOrEqual(
                intervals[index].lowerBound - intervals[index - 1].upperBound,
                traceGap
            )
        }

        state.jumpOffset(to: -traceGap)
        engine.centerFocusedColumn = .always
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, -traceGap)

        engine.centerFocusedColumn = .never
        windows[2].sizingMode = .fullscreen
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, -traceGap)

        windows[2].sizingMode = .normal
        XCTAssertTrue(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, traceTrailingOffset)

        state.jumpOffset(to: -traceGap)
        windows[0].sizingMode = .maximized
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, -traceGap)
    }

    func testSingleWindowFitAndForcedCenteringPreserveOffset() {
        let engine = NiriLayoutEngine()
        let semanticOffset: CGFloat = 37
        let workspaceId = WorkspaceDescriptor.ID()
        let sourceMonitor = Monitor(
            id: .init(displayId: 50),
            displayId: 50,
            frame: sourceFrame,
            visibleFrame: sourceFrame,
            hasNotch: false,
            name: "Single Window Source"
        )
        _ = engine.ensureMonitor(for: sourceMonitor.id, monitor: sourceMonitor, orientation: .vertical)
        let window = addWindow(engine, pid: 9_100, windowId: 1, to: workspaceId)
        engine.moveWorkspace(workspaceId, to: sourceMonitor.id, monitor: sourceMonitor)

        var state = ViewportState()
        state.selectedNodeId = window.id
        state.jumpOffset(to: semanticOffset)
        engine.singleWindowFit = .fullScreen

        XCTAssertFalse(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, semanticOffset)

        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        engine.alwaysCenterSingleColumn = true
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: traceWorkingFrame,
                    gaps: traceGap,
                    orientation: .vertical
                ),
                state: &state
            )
        )
        XCTAssertEqual(state.viewOffset, semanticOffset)
    }

    private func monitorContext(
        displayId: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect? = nil
    ) -> HiddenPlacementMonitorContext {
        HiddenPlacementMonitorContext(
            id: .init(displayId: displayId),
            frame: frame,
            visibleFrame: visibleFrame ?? frame
        )
    }
}
