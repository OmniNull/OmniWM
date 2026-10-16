// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriResizeAnimationTakeoverTests: NiriInteractionTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let window: NiriWindow
        let column: NiriContainer
        let rawSpan: CGFloat
        let clickedFrame: CGRect
    }

    @MainActor
    func testLiveResizeSettlesGrowthBeforeCapturingBaselineAndKeepsClickedEdges() throws {
        let fixture = try makeFixture()
        let expectedSpan = fixture.column.settledWidth
        let start = CGPoint(
            x: fixture.clickedFrame.minX + fixture.clickedFrame.width * 0.625,
            y: fixture.clickedFrame.midY
        )
        XCTAssertNotNil(fixture.column.widthAnimation)

        XCTAssertTrue(beginResize(fixture, at: start))

        let resize = try XCTUnwrap(fixture.engine.interactiveResize)
        XCTAssertEqual(try XCTUnwrap(resize.originalContainerSpan), expectedSpan, accuracy: 0.001)
        XCTAssertTrue(resize.edges.contains(.right))
        XCTAssertFalse(resize.edges.contains(.left))
        XCTAssertNil(fixture.column.widthAnimation)
        XCTAssertEqual(fixture.column.cachedWidth, expectedSpan, accuracy: 0.001)
        XCTAssertTrue(fixture.controller.mouseEventHandler.state.isResizing)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.capturedInteractionButton, .right)
    }

    @MainActor
    func testLeadingResizeCapturesViewportOffsetAfterGestureSettlement() async throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler
        let driver = fixture.controller.workspaceManager.animationDriver
        handler.state.gesturePhase = .committed
        handler.state.activeGestureMode = .columnScroll
        handler.state.lockedGestureContext = .init(
            workspaceId: fixture.workspaceId, monitorId: fixture.monitor.id,
            fingerCount: 3, columnScrollCandidate: true, columnScrollAxis: .horizontal,
            workspaceAxis: nil, overviewAction: nil, windowGestureTarget: nil,
            startLocation: .zero, contactSession: nil
        )
        handler.state.viewportGestureSessionID = driver.beginGesture(
            in: fixture.workspaceId, isTrackpad: true, timestamp: 100
        )
        driver.updateGesture(
            in: fixture.workspaceId, delta: 80, timestamp: 100,
            isTrackpad: true, viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        let oldOffset = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).viewOffset
        let liveOffset = try XCTUnwrap(driver.liveViewOffset(in: fixture.workspaceId, semanticOffset: oldOffset))
        XCTAssertNotEqual(liveOffset, oldOffset)
        let start = CGPoint(x: fixture.clickedFrame.minX + 1, y: fixture.clickedFrame.midY)

        XCTAssertTrue(beginResize(fixture, at: start))

        let resize = try XCTUnwrap(fixture.engine.interactiveResize)
        XCTAssertEqual(try XCTUnwrap(resize.originalViewOffset), liveOffset, accuracy: 0.001)
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).viewOffset,
            liveOffset, accuracy: 0.001
        )
        XCTAssertFalse(driver.hasMotion(in: fixture.workspaceId))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
    }

    @MainActor
    func testIneligibleResizeLeavesGrowthAndViewportMotionRunning() throws {
        for fullscreen in [true, false] {
            let fixture = try makeFixture()
            if fullscreen {
                fixture.window.sizingMode = .fullscreen
            } else {
                fixture.window.constraints = .fixed(size: fixture.clickedFrame.size)
            }
            let spring = try XCTUnwrap(fixture.column.widthAnimation)
            let driver = fixture.controller.workspaceManager.animationDriver
            let session = driver.beginGesture(in: fixture.workspaceId, isTrackpad: true)

            XCTAssertFalse(beginResize(fixture, at: fixture.clickedFrame.center))

            XCTAssertTrue(fixture.column.widthAnimation === spring)
            XCTAssertEqual(fixture.column.cachedWidth, fixture.rawSpan, accuracy: 0.001)
            XCTAssertEqual(driver.gestureSessionID(in: fixture.workspaceId), session)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertFalse(fixture.controller.mouseEventHandler.state.isResizing)
        }
    }

    @MainActor
    func testExistingResizeRejectsTakeoverWithoutSettlingGrowth() throws {
        let fixture = try makeFixture()
        let spring = try XCTUnwrap(fixture.column.widthAnimation)
        XCTAssertTrue(fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.interactiveResizeBegin(
                windowId: fixture.window.id, edges: .right, startLocation: fixture.clickedFrame.center,
                in: fixture.workspaceId, orientation: .horizontal
            )
        })
        let baseline = fixture.engine.interactiveResize?.originalContainerSpan

        XCTAssertFalse(beginResize(fixture, at: fixture.clickedFrame.center))

        XCTAssertTrue(fixture.column.widthAnimation === spring)
        XCTAssertEqual(fixture.engine.interactiveResize?.originalContainerSpan, baseline)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.isResizing)
    }

    @MainActor
    private func beginResize(_ fixture: Fixture, at location: CGPoint) -> Bool {
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.controller.mouseEventHandler.beginNiriResize(
                window: fixture.window, engine: fixture.engine,
                wsId: fixture.workspaceId, at: location, source: .mouse(.right)
            )
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriResizeAnimationTakeoverTests")
        controller.settings.niri.visibleContainerCount = 3
        controller.settings.niri.defaultContainerPrimarySpan = nil
        let monitor = Monitor(
            id: .init(displayId: 51_061), displayId: 51_061,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            hasNotch: false, name: "Niri Resize Takeover"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let engine = NiriLayoutEngine(visibleContainerCount: 3)
        engine.defaultContainerPrimarySpan = nil
        controller.niriEngine = engine
        controller.syncMonitorsToNiriEngine()
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let window = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            let first = addWindow(engine, pid: 51_061, to: workspaceId)
            _ = addWindow(engine, pid: 51_061, windowId: 2, to: workspaceId, after: first)
            for projected in engine.projectedColumns(in: workspaceId) {
                projected.column.cachedWidth = engine.rawProjectedPrimarySpan(
                    for: projected, workingFrame: geometry.workingFrame,
                    gap: geometry.innerGap, orientation: .horizontal
                )
            }
            engine.animationClock = AnimationClock(time: 100)
            engine.resolvePrimaryContainerSpans(
                in: workspaceId, workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap, orientation: .horizontal, motion: .enabled
            )
            return first
        }
        let frames = engine.calculateLayoutWithVisibility(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId, monitorFrame: geometry.workingFrame,
            gaps: (geometry.innerGap, geometry.innerGap), orientation: .horizontal, animationTime: 100
        ).frames
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        return try Fixture(
            controller: controller, engine: engine, workspaceId: workspaceId, monitor: monitor,
            window: window, column: column,
            rawSpan: column.cachedWidth, clickedFrame: XCTUnwrap(frames[window.token])
        )
    }
}
