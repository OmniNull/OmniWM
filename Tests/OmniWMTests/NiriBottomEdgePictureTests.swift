// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriBottomEdgePictureTests: XCTestCase {
    private let display = CGRect(x: -1200, y: -800, width: 1200, height: 800)
    private let token = WindowToken(pid: 101, windowId: 201)
    private let scale: CGFloat = 2
    private var floor: CGFloat {
        NiriLayoutViewport.minimumNativeBottomVisibility
    }

    private var pixel: CGFloat {
        1 / scale
    }

    private var span: CGFloat {
        display.height / 2
    }

    func testSettledSubFloorRetiresPictureAndKeepsSourceParkedOnOneAndTwoDisplays() {
        for anotherDisplay in [false, true] {
            let result = layout(top: display.minY + pixel, settled: true, anotherDisplay: anotherDisplay)
            XCTAssertEqual(result.hiddenHandles[token], AxisHideEdge.minimum.encodedHideSide)
            XCTAssertTrue(result.edgeHiddenFrames.isEmpty)
        }
        let fallback = layout(top: display.minY + pixel, settled: true, available: false)
        XCTAssertNil(fallback.hiddenHandles[token])
        XCTAssertTrue(fallback.edgeHiddenFrames.isEmpty)
    }

    func testMovingSubFloorNeedsReadyPictureAndKeepsLiveGeometryOnOneDisplay() throws {
        let top = display.minY + floor - pixel
        let result = layout(top: top)
        XCTAssertEqual(result.hiddenHandles[token], AxisHideEdge.minimum.encodedHideSide)
        let picture = try XCTUnwrap(result.edgeHiddenFrames[token])
        XCTAssertEqual(picture.maxY, top)
        XCTAssertEqual(picture.height, span)
        XCTAssertNotEqual(try XCTUnwrap(result.frames[token]), picture)
        let late = layout(top: top, ready: false)
        XCTAssertNil(late.hiddenHandles[token])
        XCTAssertTrue(late.edgeHiddenFrames.isEmpty)
        let native = layout(top: display.minY + floor)
        XCTAssertNil(native.hiddenHandles[token])
        XCTAssertTrue(native.edgeHiddenFrames.isEmpty)
    }

    func testFloorUsesVisibleFrameAndPhysicalPixelBoundary() throws {
        let dockInset = floor * 2
        let visible = CGRect(
            x: display.minX, y: display.minY + dockInset,
            width: display.width, height: display.height - dockInset
        )
        for top in [visible.minY + floor - pixel, visible.minY + floor] {
            let result = layout(top: top, visible: visible)
            if top < visible.minY + floor {
                XCTAssertEqual(result.hiddenHandles[token], AxisHideEdge.minimum.encodedHideSide)
                XCTAssertEqual(try XCTUnwrap(result.edgeHiddenFrames[token]).maxY, top)
            } else {
                XCTAssertNil(result.hiddenHandles[token])
                XCTAssertTrue(result.edgeHiddenFrames.isEmpty)
            }
        }
    }

    func testBetweenNativeFloorAndWorkingAreaIsNativeOnlyDuringMotion() {
        let gap = floor * 2
        let top = display.minY + floor + pixel
        let moving = layout(top: top, bottomGap: gap, sampleTarget: false)
        XCTAssertNil(moving.hiddenHandles[token])
        XCTAssertTrue(moving.edgeHiddenFrames.isEmpty)
        let settled = layout(top: top, settled: true, bottomGap: gap, sampleTarget: false)
        XCTAssertEqual(settled.hiddenHandles[token], AxisHideEdge.minimum.encodedHideSide)
        XCTAssertTrue(settled.edgeHiddenFrames.isEmpty)
    }

    func testActiveEntryOnlyContinuesReadyBottomParkAndRevealsAtFloor() {
        let top = display.minY + floor - pixel
        let incoming = layout(top: top, active: true, parkedBelow: true)
        XCTAssertEqual(incoming.hiddenHandles[token], AxisHideEdge.minimum.encodedHideSide)
        XCTAssertNotNil(incoming.edgeHiddenFrames[token])
        for result in [
            layout(top: top, active: true),
            layout(top: top, ready: false, active: true, parkedBelow: true),
            layout(top: display.minY + floor, active: true, parkedBelow: true)
        ] {
            XCTAssertNil(result.hiddenHandles[token])
            XCTAssertTrue(result.edgeHiddenFrames.isEmpty)
        }
    }

    func testHorizontalIgnoresBottomPictureState() {
        let top = display.minY + floor - pixel
        let capable = layout(top: top, orientation: .horizontal)
        let legacy = layout(top: top, available: false, orientation: .horizontal)
        XCTAssertEqual(capable.frames, legacy.frames)
        XCTAssertEqual(capable.hiddenHandles, legacy.hiddenHandles)
        XCTAssertTrue(capable.edgeHiddenFrames.isEmpty)
    }

    private func layout(
        top: CGFloat,
        settled: Bool = false,
        ready: Bool = true,
        active: Bool = false,
        parkedBelow: Bool = false,
        available: Bool = true,
        anotherDisplay: Bool = false,
        visible: CGRect? = nil,
        bottomGap: CGFloat? = nil,
        sampleTarget: Bool = true,
        orientation: Monitor.Orientation = .vertical
    ) -> LayoutResult {
        let visible = visible ?? display
        let bottomGap = bottomGap ?? floor / 2
        let working = CGRect(
            x: visible.minX, y: visible.minY + bottomGap,
            width: visible.width, height: visible.height - bottomGap
        )
        let area = WorkingAreaContext(workingFrame: working, viewFrame: display, scale: scale)
        let monitor = HiddenPlacementMonitorContext(id: .init(displayId: 1), frame: display, visibleFrame: visible)
        let neighbor = HiddenPlacementMonitorContext(
            id: .init(displayId: 2), frame: display.offsetBy(dx: display.width, dy: -display.height),
            visibleFrame: display.offsetBy(dx: display.width, dy: -display.height)
        )
        let column = NiriContainer()
        column.appendChild(NiriWindow(token: token))
        let position = top - span - working.minY
        let context = NiriCalculationContext(
            geometry: NiriLayoutGeometry(
                workingArea: area, gaps: LayoutGaps(horizontal: 0, vertical: 0), orientation: orientation
            ),
            time: 0, hiddenPlacementMonitor: monitor,
            hiddenPlacementMonitors: anotherDisplay ? [monitor, neighbor] : [monitor],
            edgePictures: NiriEdgePictureState(
                isAvailable: available, readyTokens: ready ? [token] : [], parkedBelowTokens: parkedBelow ? [token] : []
            )
        )
        let pass = NiriColumnLayoutPass(
            context: context,
            viewport: NiriLayoutViewport(
                area: area, orientation: orientation, workspaceOffset: 0,
                viewPositions: sampleTarget ? [position, 0] : [0], revealMargin: 0
            ),
            activeIndex: active ? 0 : 1, viewPosition: 0, selectedNodeId: nil,
            settledContentFrame: settled ? working : nil
        )
        var result = LayoutResult(frames: [:], hiddenHandles: [:])
        NiriLayoutEngine().layoutProjectedColumn(
            NiriProjectedColumn(column: column, windows: column.windowNodes, durableIndex: 0),
            prepared: NiriPreparedLayoutColumn(span: span, renderOffset: .zero, position: position),
            at: 0, pass: pass, result: &result
        )
        return result
    }
}
