// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class OverviewCanonicalGeometryTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let windows: [NiriWindow]
        let area: WorkingAreaContext
        let orientation: Monitor.Orientation
        var state: ViewportState

        var geometry: NiriLayoutGeometry {
            NiriLayoutGeometry(
                workingArea: area,
                gaps: LayoutGaps(horizontal: 12, vertical: 12),
                orientation: orientation
            )
        }

        func snapshot() throws -> NiriOverviewWorkspaceSnapshot {
            try XCTUnwrap(engine.overviewSnapshot(for: workspaceId, state: state, geometry: geometry))
        }

        func layout() -> LayoutResult {
            engine.calculateLayoutWithVisibility(
                state: state, workspaceId: workspaceId,
                monitorFrame: area.workingFrame, gaps: (horizontal: 12, vertical: 12),
                workingArea: area, orientation: orientation, isSettled: true
            )
        }

        func localized(_ frame: CGRect) -> CGRect {
            frame.offsetBy(dx: -area.viewFrame.minX, dy: -area.viewFrame.minY)
        }
    }

    func testSingleWindowFitMatchesSolverInBothOrientationsWithoutChangingLiveFrames() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for fit in [SingleWindowFit.fullScreen, SingleWindowFit(mode: .custom, width: 530, height: 410)] {
                let fixture = makeFixture(count: 1, orientation: orientation)
                fixture.engine.singleWindowFit = fit
                let window = fixture.windows[0]
                let column = try XCTUnwrap(fixture.engine.column(of: window))
                let snapshot = try fixture.snapshot()
                XCTAssertNil(window.frame)
                XCTAssertNil(window.renderedFrame)
                XCTAssertNil(column.frame)
                XCTAssertNil(column.renderedFrame)
                let layoutFrame = try XCTUnwrap(fixture.layout().frames[window.token])
                let tile = try XCTUnwrap(snapshot.columns.first?.tiles.first)
                XCTAssertEqual(tile.stripFrame, fixture.localized(layoutFrame))
                XCTAssertTrue(tile.isViewportAnchored)
                XCTAssertEqual(snapshot.columns.first?.stripFrame, fixture.localized(try XCTUnwrap(column.frame)))
                XCTAssertEqual(snapshot.strip?.orientation, orientation)
                XCTAssertEqual(snapshot.strip?.workingFrame, fixture.localized(fixture.area.workingFrame))
            }
        }
    }

    func testStackedTileGeometryMatchesCanonicalSolverWithGapsAndViewportInBothOrientations() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = makeFixture(count: 4, orientation: orientation)
            try stack(fixture.windows[1], into: fixture.windows[0], fixture: &fixture)
            fixture.state.activeColumnIndex = 1
            fixture.state.selectedNodeId = fixture.windows[2].id
            fixture.state.viewOffset = -83
            _ = fixture.layout()
            let snapshot = try fixture.snapshot()
            try assertMatchesCanonicalSolver(snapshot, fixture: fixture)
            let stack = try XCTUnwrap(snapshot.columns.first)
            let first = try XCTUnwrap(stack.tiles.first?.stripFrame)
            let last = try XCTUnwrap(stack.tiles.last?.stripFrame)
            switch orientation {
            case .horizontal:
                XCTAssertEqual(first.minY - last.maxY, 12)
                XCTAssertEqual(first.width, last.width)
            case .vertical:
                XCTAssertEqual(first.minX - last.maxX, 12)
                XCTAssertEqual(first.height, last.height)
            }
        }
    }

    func testOffscreenCanonicalCardsRemainUnparkedAndLeaveAnimationFramesUntouched() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = makeFixture(count: 8, orientation: orientation)
            fixture.state.activeColumnIndex = 6
            fixture.state.selectedNodeId = fixture.windows[6].id
            fixture.state.viewOffset = -90
            let liveLayout = fixture.layout()
            let canonicalBefore = fixture.windows.map(\.frame)
            let renderedBefore = fixture.windows.map(\.renderedFrame)
            let columnFramesBefore = fixture.engine.columns(in: fixture.workspaceId).map(\.renderedFrame)
            let snapshot = try fixture.snapshot()
            XCTAssertEqual(fixture.windows.map(\.frame), canonicalBefore)
            XCTAssertEqual(fixture.windows.map(\.renderedFrame), renderedBefore)
            XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.renderedFrame), columnFramesBefore)
            XCTAssertNotNil(liveLayout.hiddenHandles[fixture.windows[0].token])
            let overviewFrame = try XCTUnwrap(snapshot.columns.first?.tiles.first?.stripFrame)
            let parkedFrame = fixture.localized(try XCTUnwrap(liveLayout.frames[fixture.windows[0].token]))
            switch orientation {
            case .horizontal: XCTAssertLessThan(overviewFrame.maxX, parkedFrame.minX)
            case .vertical: XCTAssertLessThan(overviewFrame.maxY, parkedFrame.minY)
            }
            try assertMatchesCanonicalSolver(snapshot, fixture: fixture)
        }
    }

    func testTabbedColumnsExportAllMembersActiveTokenAndActualContentInset() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var fixture = makeFixture(count: 3, orientation: orientation)
            try stack(fixture.windows[1], into: fixture.windows[0], fixture: &fixture)
            let column = try XCTUnwrap(fixture.engine.column(of: fixture.windows[0]))
            column.displayMode = .tabbed
            column.setActiveTileIdx(1)
            column.invalidateCachedPrimarySpans()
            _ = fixture.layout()
            let snapshot = try fixture.snapshot()
            let tabbed = try XCTUnwrap(snapshot.columns.first)
            XCTAssertTrue(tabbed.isTabbed)
            XCTAssertEqual(tabbed.activeToken, column.windowNodes[1].token)
            XCTAssertEqual(Set(tabbed.tiles.map(\.token)), Set(column.windowNodes.map(\.token)))
            let columnFrame = try XCTUnwrap(tabbed.stripFrame)
            let tileFrame = try XCTUnwrap(tabbed.tiles.first?.stripFrame)
            XCTAssertEqual(
                tileFrame.minX - columnFrame.minX,
                fixture.engine.renderStyle.tabIndicatorWidth + (orientation == .vertical ? 12 : 0)
            )
            try assertMatchesCanonicalSolver(snapshot, fixture: fixture)
        }
    }

    func testMaximizedAndFullscreenCardsKeepTheirMonitorFramesDespiteViewportOffset() throws {
        var fixture = makeFixture(count: 3)
        fixture.windows[0].sizingMode = .maximized
        fixture.windows[1].sizingMode = .fullscreen
        fixture.state.activeColumnIndex = 2
        fixture.state.viewOffset = 117
        _ = fixture.layout()
        let snapshot = try fixture.snapshot()
        let tiles = Dictionary(uniqueKeysWithValues: snapshot.columns.flatMap(\.tiles).map { ($0.token, $0) })
        let maximized = try XCTUnwrap(tiles[fixture.windows[0].token])
        let fullscreen = try XCTUnwrap(tiles[fixture.windows[1].token])
        XCTAssertEqual(maximized.stripFrame, fixture.localized(fixture.area.borderSafeFillFrame))
        XCTAssertEqual(fullscreen.stripFrame, fixture.localized(fixture.area.fullscreenLayoutFrame))
        XCTAssertTrue(maximized.isViewportAnchored)
        XCTAssertTrue(fullscreen.isViewportAnchored)
        XCTAssertFalse(try XCTUnwrap(tiles[fixture.windows[2].token]).isViewportAnchored)
    }

    func testColumnWidthDoesNotDependOnWorkspaceColumnCount() throws {
        let narrow = try makeFixture(count: 2).snapshot()
        let wide = try makeFixture(count: 12).snapshot()
        XCTAssertEqual(narrow.columns.count, 2)
        XCTAssertEqual(wide.columns.count, 12)
        let narrowFrame = try XCTUnwrap(narrow.columns.first?.tiles.first?.stripFrame)
        let wideFrame = try XCTUnwrap(wide.columns.first?.tiles.first?.stripFrame)
        XCTAssertEqual(narrowFrame.size, wideFrame.size)
    }

    func testExcludedColumnsKeepDurableIndicesAndProjectedGeometry() throws {
        var fixture = makeFixture(count: 4)
        fixture.engine.setProjectionExclusions([fixture.windows[1].token], in: fixture.workspaceId)
        fixture.state.activeColumnIndex = 2
        fixture.state.selectedNodeId = fixture.windows[2].id
        _ = fixture.layout()
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(snapshot.columns.map(\.index), [0, 2, 3])
        XCTAssertFalse(snapshot.columns.flatMap(\.tiles).contains { $0.token == fixture.windows[1].token })
        try assertMatchesCanonicalSolver(snapshot, fixture: fixture)
    }

    private func assertMatchesCanonicalSolver(
        _ snapshot: NiriOverviewWorkspaceSnapshot,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let activeFrame = try XCTUnwrap(columns[fixture.state.activeColumnIndex].frame)
        let offset = fixture.orientation == .horizontal
            ? activeFrame.minX - fixture.area.workingFrame.minX + fixture.state.viewOffset
            : activeFrame.minY - fixture.area.workingFrame.minY + fixture.state.viewOffset
        for snapshotColumn in snapshot.columns {
            for tile in snapshotColumn.tiles {
                let window = try XCTUnwrap(fixture.engine.findNode(for: tile.token, in: fixture.workspaceId))
                let canonical = try XCTUnwrap(window.frame)
                let shifted = canonical.offsetBy(
                    dx: fixture.orientation == .horizontal ? -offset : 0,
                    dy: fixture.orientation == .vertical ? -offset : 0
                ).roundedToPhysicalPixels(scale: fixture.area.scale)
                XCTAssertEqual(tile.stripFrame, fixture.localized(shifted), file: file, line: line)
            }
        }
    }

    private func stack(_ window: NiriWindow, into target: NiriWindow, fixture: inout Fixture) throws {
        let column = try XCTUnwrap(fixture.engine.column(of: target))
        XCTAssertTrue(fixture.engine.consumeWindow(
            window, into: column, enteringFrom: .right,
            context: NiriInteractionContext(
                workspaceId: fixture.workspaceId, motion: .disabled, workingFrame: fixture.area.workingFrame,
                gaps: 12, orientation: fixture.orientation
            ),
            state: &fixture.state
        ))
    }

    private func makeFixture(count: Int, orientation: Monitor.Orientation = .horizontal) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        var windows: [NiriWindow] = []
        for index in 0 ..< count {
            windows.append(engine.addWindow(
                token: WindowToken(pid: 871_900, windowId: index + 1),
                to: workspaceId, afterSelection: windows.last?.id
            ))
        }
        let monitorFrame = CGRect(x: 1370, y: -180, width: 1280, height: 920)
        return Fixture(
            engine: engine, workspaceId: workspaceId, windows: windows,
            area: WorkingAreaContext(
                workingFrame: monitorFrame.insetBy(dx: 28, dy: 36),
                borderSafeFillFrame: monitorFrame.insetBy(dx: 4, dy: 6),
                fullscreenLayoutFrame: monitorFrame, viewFrame: monitorFrame, scale: 2
            ),
            orientation: orientation, state: ViewportState(selectedNodeId: windows.first?.id)
        )
    }
}
