// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePictureVisibilityTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let first = WindowToken(pid: 101, windowId: 201)
    private let second = WindowToken(pid: 101, windowId: 202)

    func testReadyNativeActiveNeverBecomesAPicture() {
        let result = layout(ready: [first], parked: [], position: display.height)
        XCTAssertNil(result.hiddenHandles[first])
        XCTAssertTrue(result.edgeHiddenFrames.isEmpty)
    }

    func testParkedActiveHoldsAfterTopClearsUntilSettled() throws {
        let position = display.height / 4
        let moving = layout(ready: [first], parked: [first], position: position)
        XCTAssertEqual(moving.hiddenHandles[first], .right)
        XCTAssertEqual(try XCTUnwrap(moving.edgeHiddenFrames[first]), CGRect(
            x: display.minX, y: position, width: display.width, height: display.height / 2
        ))
        let landed = layout(ready: [first], parked: [first], position: position, settled: true)
        XCTAssertNil(landed.hiddenHandles[first])
        XCTAssertTrue(landed.edgeHiddenFrames.isEmpty)
    }

    func testWhollyAboveStaysParkedWithoutAReadyImage() {
        let above = layout(ready: [], parked: [first], position: display.maxY)
        XCTAssertEqual(above.hiddenHandles[first], .right)
        XCTAssertTrue(above.edgeHiddenFrames.isEmpty)
        let intersecting = display.maxY - display.height / 4
        let missed = layout(ready: [], parked: [first], position: intersecting)
        XCTAssertNil(missed.hiddenHandles[first])
        let ready = layout(ready: [first], parked: [first], position: intersecting)
        XCTAssertEqual(ready.hiddenHandles[first], .right)
        XCTAssertNotNil(ready.edgeHiddenFrames[first])
    }

    func testWholeRowMustBeParkedAndReady() {
        let position = display.height / 4
        for (ready, parked): (Set<WindowToken>, Set<WindowToken>) in [
            ([first], [first, second]),
            ([first, second], [first])
        ] {
            let result = layout(ready: ready, parked: parked, position: position, tokens: [first, second])
            XCTAssertNil(result.hiddenHandles[first])
            XCTAssertNil(result.hiddenHandles[second])
        }
    }

    func testTabbedColumnNeedsAllTabsParkedButOnlySelectedImage() {
        let position = display.height / 4
        let nativeTabSwitch = layout(
            ready: [first], parked: [first], position: position, tokens: [first, second], tabbed: true
        )
        XCTAssertNil(nativeTabSwitch.hiddenHandles[first])
        let parked = layout(
            ready: [first], parked: [first, second], position: position, tokens: [first, second], tabbed: true
        )
        XCTAssertEqual(parked.hiddenHandles[first], .right)
        XCTAssertEqual(Set(parked.edgeHiddenFrames.keys), [first])
    }

    func testNonNormalAndOversizedActiveStayNative() {
        let position = display.height / 4
        let nonNormal = layout(ready: [first], parked: [first], position: position, maximized: true)
        XCTAssertNil(nonNormal.hiddenHandles[first])
        let oversized = layout(
            ready: [first], parked: [first], position: position, span: display.height + display.height / 2
        )
        XCTAssertNil(oversized.hiddenHandles[first])
    }

    func testSingleDisplayInactiveHideReadsCapabilityNotReadiness() {
        let position = display.maxY - display.height / 4
        let without = layout(ready: [], parked: [], position: position, active: false, available: false)
        XCTAssertNil(without.hiddenHandles[first])
        for ready: Set<WindowToken> in [[], [first]] {
            let capable = layout(ready: ready, parked: [], position: position, active: false)
            XCTAssertEqual(capable.hiddenHandles[first], .right)
            XCTAssertNotNil(capable.edgeHiddenFrames[first])
        }
    }

    private func layout(
        ready: Set<WindowToken>,
        parked: Set<WindowToken>,
        position: CGFloat,
        settled: Bool = false,
        tokens: [WindowToken]? = nil,
        tabbed: Bool = false,
        maximized: Bool = false,
        span: CGFloat? = nil,
        active: Bool = true,
        available: Bool = true
    ) -> LayoutResult {
        let column = NiriContainer()
        for token in tokens ?? [first] { column.appendChild(NiriWindow(token: token)) }
        if tabbed { column.displayMode = .tabbed }
        if maximized { column.windowNodes.first?.sizingMode = .maximized }
        let area = WorkingAreaContext(workingFrame: display, viewFrame: display, scale: 1)
        let monitor = HiddenPlacementMonitorContext(id: .init(displayId: 1), frame: display, visibleFrame: display)
        let context = NiriCalculationContext(
            geometry: NiriLayoutGeometry(
                workingArea: area, gaps: LayoutGaps(horizontal: 0, vertical: 0), orientation: .vertical
            ),
            time: 0, hiddenPlacementMonitor: monitor, hiddenPlacementMonitors: [monitor],
            edgePictures: NiriEdgePictureState(isAvailable: available, readyTokens: ready, parkedAboveTokens: parked)
        )
        let pass = NiriColumnLayoutPass(
            context: context,
            viewport: NiriLayoutViewport(
                area: area, orientation: .vertical, workspaceOffset: 0, viewPositions: [position, 0], revealMargin: 0
            ),
            activeIndex: active ? 0 : 1, viewPosition: 0, selectedNodeId: nil,
            settledContentFrame: settled ? display : nil
        )
        var result = LayoutResult(frames: [:], hiddenHandles: [:])
        NiriLayoutEngine().layoutProjectedColumn(
            NiriProjectedColumn(column: column, windows: column.windowNodes, durableIndex: 0),
            prepared: NiriPreparedLayoutColumn(
                span: span ?? display.height / 2,
                renderOffset: .zero,
                position: position
            ),
            at: 0, pass: pass, result: &result
        )
        return result
    }
}
