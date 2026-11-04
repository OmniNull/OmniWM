// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class NiriBottomEdgeParkingTests: XCTestCase {
    func testOnlyReadyVerticalBottomCrossingSubmitsNativeParkOnTick() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for edge in [AxisHideEdge.minimum, .maximum] {
                for pictured in [false, true] {
                    let fixture = try makeFixture(orientation: orientation)
                    let manager = fixture.controller.axManager
                    var submittedFrames: [CGRect] = []
                    manager.onParkFrameApplyFailed = { result in
                        submittedFrames.append(result.targetFrame)
                        manager.clearParkPending(for: result.windowId, pid: result.pid)
                    }
                    defer { manager.onParkFrameApplyFailed = nil }
                    let expected = try parkFrame(fixture, edge: edge)

                    applyHide(fixture, edge: edge, pictured: pictured)

                    let needsNativePark = orientation == .vertical && edge == .minimum && pictured
                    XCTAssertEqual(submittedFrames, needsNativePark ? [expected] : [])
                    if needsNativePark {
                        let parked = try XCTUnwrap(submittedFrames.first)
                        XCTAssertLessThan(parked.minX, fixture.monitor.frame.minX)
                        XCTAssertFalse(parked.intersects(fixture.monitor.frame.insetBy(
                            dx: LayoutRefreshController.hiddenWindowEdgeRevealEpsilon, dy: 0
                        )))
                    }
                    XCTAssertEqual(
                        fixture.controller.workspaceManager.hiddenState(for: fixture.token)?.offscreenSide,
                        edge.encodedHideSide
                    )
                }
            }
        }
    }

    func testBottomParkCoalescesThroughPictureExitAndAcceptsItsOriginalCompletion() throws {
        let fixture = try makeFixture(orientation: .vertical)
        let manager = fixture.controller.axManager
        let target = AXFrameApplicationTarget(
            pid: fixture.token.pid, window: fixture.window,
            frame: try parkFrame(fixture, edge: .minimum)
        )
        let pending = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)
        var failures: [AXFrameRequestId] = []
        manager.onParkFrameApplyFailed = { failures.append($0.requestId) }
        defer { manager.onParkFrameApplyFailed = nil }

        applyHide(fixture, edge: .minimum, pictured: true)
        XCTAssertEqual(manager.pendingParkFrameRequest(for: fixture.token.windowId), pending)

        applyHide(fixture, edge: .minimum, pictured: false)
        XCTAssertEqual(manager.pendingParkFrameRequest(for: fixture.token.windowId), pending)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: pending)
        ]).isEmpty)
        XCTAssertEqual(manager.verifiedParkFrame(for: fixture.token.windowId), target.frame)
        XCTAssertFalse(manager.pendingParkWindowIds.contains(fixture.token.windowId))
    }

    func testTopAnimationHideRetainsItsDeferredParkPolicy() throws {
        let fixture = try makeFixture(orientation: .vertical)
        let manager = fixture.controller.axManager
        let target = AXFrameApplicationTarget(
            pid: fixture.token.pid, window: fixture.window,
            frame: try parkFrame(fixture, edge: .maximum)
        )
        let pending = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)

        applyHide(fixture, edge: .maximum, pictured: true)

        XCTAssertNil(manager.pendingParkFrameRequest(for: fixture.token.windowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(fixture.token.windowId))
        XCTAssertTrue(manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: pending)
        ]).isEmpty)
        XCTAssertNil(manager.verifiedParkFrame(for: fixture.token.windowId))
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let snapshot: LayoutMonitorSnapshot
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let window: AXWindowRef
        let sourceFrame: CGRect
    }

    private func makeFixture(orientation: Monitor.Orientation) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriBottomEdgeParkingTests")
        let monitor = Monitor(
            id: .init(displayId: 977_001), displayId: 977_001,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            hasNotch: false, name: "Bottom edge parking"
        )
        controller.settings.monitors.updateOrientationSettings(
            .init(monitorName: monitor.name, monitorDisplayId: monitor.displayId, orientation: orientation),
            for: monitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        let token = WindowToken(pid: 977_101, windowId: 977_201)
        let window = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let sourceFrame = CGRect(
            origin: monitor.visibleFrame.origin,
            size: CGSize(width: monitor.visibleFrame.width / 2, height: monitor.visibleFrame.height / 2)
        )
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? sourceFrame : nil
        }
        return Fixture(
            controller: controller, monitor: monitor,
            snapshot: LayoutMonitorSnapshot(
                monitorId: monitor.id, displayId: monitor.displayId, frame: monitor.frame,
                visibleFrame: monitor.visibleFrame, workingFrame: monitor.visibleFrame,
                fullscreenLayoutFrame: monitor.visibleFrame, scale: 1, orientation: orientation
            ),
            workspaceId: workspaceId, token: token, window: window, sourceFrame: sourceFrame
        )
    }

    private func parkFrame(_ fixture: Fixture, edge: AxisHideEdge) throws -> CGRect {
        CGRect(
            origin: try XCTUnwrap(fixture.controller.layoutRefreshController.liveFrameHideOrigin(
                for: fixture.sourceFrame, monitor: fixture.monitor, side: edge.encodedHideSide, reason: .layoutTransient
            )),
            size: fixture.sourceFrame.size
        )
    }

    private func applyHide(_ fixture: Fixture, edge: AxisHideEdge, pictured: Bool) {
        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [.hide(fixture.token, side: edge.encodedHideSide)]
        if pictured {
            diff.edgeHiddenFrames[fixture.token] = fixture.sourceFrame.offsetBy(
                dx: 0,
                dy: fixture.monitor.frame.minY - fixture.sourceFrame.maxY
                    + LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
            )
        }
        let plan = WorkspaceLayoutPlan(
            workspaceId: fixture.workspaceId, monitor: fixture.snapshot,
            sessionPatch: .init(workspaceId: fixture.workspaceId, viewportState: nil),
            diff: diff, isAnimationTick: true
        )
        var application = LayoutVisibilityApplication(
            plan: plan, monitor: fixture.monitor, controller: fixture.controller,
            refreshController: fixture.controller.layoutRefreshController
        )
        application.execute()
    }
}
