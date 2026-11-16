// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class LiveResizeFrameApplicationTests: XCTestCase {
    private let screenFrame = CGRect(x: 137, y: -241, width: 1440, height: 900)

    func testTrackpadResizeSubmitsRealFramesBeforeRelease() async throws {
        let fixture = try makeLayoutFixture(animationsEnabled: false)
        let mouse = fixture.controller.mouseEventHandler
        let resized = try XCTUnwrap(fixture.engine.findNode(for: fixture.left, in: fixture.workspaceId))
        let frame = try XCTUnwrap(resized.renderedFrame ?? resized.frame)
        let start = CGPoint(x: frame.maxX - FrameTolerance.frameWrite, y: frame.midY)
        XCTAssertTrue(mouse.beginNiriResize(
            window: resized, engine: fixture.engine, wsId: fixture.workspaceId, at: start, source: .trackpadGesture
        ))
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        fixture.controller.hasStartedServices = true

        mouse.updateManagedResize(at: CGPoint(x: start.x - frame.width / 8, y: start.y))
        try await completeRefreshes(fixture)

        XCTAssertTrue(mouse.state.isResizing)
        XCTAssertTrue(mouse.state.gestureOwnsWindowInteraction)
        XCTAssertNil(mouse.state.activeInteractionButton)
        XCTAssertLessThan(try XCTUnwrap(resized.renderedFrame ?? resized.frame).width, frame.width)
        XCTAssertFalse(frameApplicationEvents(fixture).isEmpty)
        mouse.completeActiveResize()
        try await completeRefreshes(fixture)
        XCTAssertFalse(mouse.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasMotion(in: fixture.workspaceId))
    }

    func testKeyboardResizeSubmitsRealFramesDuringAnimation() async throws {
        let fixture = try makeLayoutFixture()
        let handler = fixture.controller.layoutRefreshController.niriHandler
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.left))
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        fixture.controller.hasStartedServices = true
        XCTAssertTrue(fixture.controller.niriLayoutHandler.setContainerPrimarySpan(
            .adjustProportion(10), target: .window(handle)
        ))
        let springs = fixture.engine.columns(in: fixture.workspaceId).compactMap(\.widthAnimation)
        let spring = try XCTUnwrap(springs.first)
        try await completeRefreshes(fixture)
        let beforeTick = frameApplicationEvents(fixture).count

        handler.tickScrollAnimation(
            targetTime: spring.startTime + spring.duration / 2, displayId: fixture.monitor.displayId
        )
        try await completeRefreshes(fixture)

        XCTAssertGreaterThan(frameApplicationEvents(fixture).count, beforeTick)
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).contains { $0.widthAnimation != nil })
        let settled = try XCTUnwrap(springs.map { ($0.startTime + $0.duration).nextUp }.max())
        handler.tickScrollAnimation(targetTime: settled, displayId: fixture.monitor.displayId)
        try await completeRefreshes(fixture)
        XCTAssertFalse(frameApplicationEvents(fixture).isEmpty)
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).allSatisfy { $0.widthAnimation == nil })
    }

    private struct LayoutFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let left: WindowToken
        let right: WindowToken
    }

    private func makeLayoutFixture(animationsEnabled: Bool = true) throws -> LayoutFixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "LiveResizeFrameApplicationTests")
        let directory = controller.settings.settingsFileURL.deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { @MainActor in
            controller.hasStartedServices = false
            controller.hotkeys.stop()
            controller.mouseEventHandler.cleanup()
            controller.layoutRefreshController.resetState()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        controller.setAnimationsEnabled(animationsEnabled)
        XCTAssertEqual(controller.motionPolicy.snapshot().animationsEnabled, animationsEnabled)
        let monitor = Monitor(
            id: .init(displayId: 92),
            displayId: 92,
            frame: screenFrame,
            visibleFrame: screenFrame,
            hasNotch: false,
            name: "Main"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.resetState()
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefreshTask)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let engine = try XCTUnwrap(controller.niriEngine)

        let pid: pid_t = 962_001
        let tokens = [962_101, 962_102].map { windowId in
            controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: workspaceId
            )
        }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        controller.layoutRefreshController.renderInteractiveResize(for: workspaceId)
        for (token, frame) in engine.captureWindowFrames(in: workspaceId) {
            controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        }
        return LayoutFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            left: tokens[0],
            right: tokens[1]
        )
    }

    private func completeRefreshes(_ fixture: LayoutFixture) async throws {
        let refresh = fixture.controller.layoutRefreshController
        while let task = refresh.layoutState.activeRefreshTask {
            try Task.checkCancellation()
            await task.value
        }
        XCTAssertNil(refresh.layoutState.activeRefresh)
        XCTAssertNil(refresh.layoutState.pendingRefresh)
    }

    private func frameApplicationEvents(_ fixture: LayoutFixture) -> [Substring] {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter { line in
            !line.contains("cancelled") && [fixture.left, fixture.right]
                .contains { line.contains("win=\($0.windowId) ") }
        }
    }
}
