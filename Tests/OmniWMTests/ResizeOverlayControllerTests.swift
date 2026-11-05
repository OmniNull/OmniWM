// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ResizeOverlayControllerTests: XCTestCase {
    private let screenFrame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testPanelsAppearOnlyForWindowsThatMove() {
        let moving = WindowToken(pid: 1001, windowId: 101)
        let still = WindowToken(pid: 1001, windowId: 102)
        let overlay = makeOverlay(currentFrames: [moving: frame(x: 0, width: 400), still: frame(x: 420, width: 400)])

        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .glass, pointerDriven: true)
        let grown = frame(x: 0, width: 480)
        overlay.update([change(moving, grown), change(still, frame(x: 420, width: 400))])

        XCTAssertEqual(Set(overlay.panels.keys), [moving])
        XCTAssertEqual(overlay.panels[moving]?.targetFrame, grown)
        overlay.reset()
    }

    func testTilesShareOneHostWindowThatOutlivesTheSession() throws {
        let left = WindowToken(pid: 1006, windowId: 108)
        let right = WindowToken(pid: 1006, windowId: 109)
        let overlay = makeOverlay(currentFrames: [left: frame(x: 0, width: 400), right: frame(x: 420, width: 400)])
        let workspaceId = WorkspaceDescriptor.ID()

        overlay.begin(workspaceId: workspaceId, style: .glass, pointerDriven: true)
        overlay.update([change(left, frame(x: 0, width: 480)), change(right, frame(x: 500, width: 400))])
        let host = try XCTUnwrap(overlay.panels[left]?.window)
        XCTAssertIdentical(overlay.panels[right]?.window, host)
        XCTAssertEqual(host.frame, screenFrame)
        XCTAssertTrue(host.isVisible)

        overlay.update([change(left, frame(x: 0, width: 520)), change(right, frame(x: 540, width: 400))])
        XCTAssertEqual(host.frame, screenFrame)
        XCTAssertEqual(overlay.panels[right]?.targetFrame, frame(x: 540, width: 400))

        overlay.reset()
        XCTAssertFalse(host.isVisible)
        overlay.begin(workspaceId: workspaceId, style: .glass, pointerDriven: true)
        overlay.update([change(left, frame(x: 0, width: 300))])
        XCTAssertIdentical(overlay.panels[left]?.window, host)
        overlay.reset()
    }

    func testTilesSitInTheirMonitorsCoordinates() throws {
        let token = WindowToken(pid: 1007, windowId: 110)
        let monitor = screenFrame.offsetBy(dx: screenFrame.width, dy: 0)
        let start = CGRect(x: monitor.minX + 420, y: monitor.minY + 20, width: 400, height: 300)
        let overlay = ResizeOverlayController(
            previews: PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry()),
            captureImage: { _, _ in nil },
            currentFrame: { $0 == token ? start : nil },
            monitorFrame: { _ in monitor }
        )
        defer { overlay.reset() }

        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .glass, pointerDriven: true)
        overlay.update([change(token, start.insetBy(dx: 40, dy: 0))])

        let tile = try XCTUnwrap(overlay.panels[token])
        XCTAssertEqual(tile.window?.frame, monitor)
        XCTAssertEqual(tile.frame, CGRect(x: 460, y: 20, width: 320, height: 300))
    }

    func testGlassNeverCaptures() {
        let token = WindowToken(pid: 1002, windowId: 103)
        let overlay = makeOverlay(currentFrames: [token: frame(x: 0, width: 400)])

        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .glass, pointerDriven: true)
        overlay.update([change(token, frame(x: 0, width: 300))])

        XCTAssertNotNil(overlay.panels[token])
        XCTAssertTrue(overlay.captureTasks.isEmpty)
        XCTAssertEqual(overlay.panels[token]?.isVisible, true)
        overlay.reset()
    }

    func testSnapshotFallsBackToGlassWithoutPermission() {
        let token = WindowToken(pid: 1003, windowId: 104)
        let overlay = makeOverlay(currentFrames: [token: frame(x: 0, width: 400)], captureAllowed: false)

        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .snapshot, pointerDriven: true)
        overlay.update([change(token, frame(x: 0, width: 300))])

        XCTAssertEqual(overlay.panels[token]?.isVisible, true)
        XCTAssertTrue(overlay.captureTasks.isEmpty)
        overlay.reset()
    }

    func testSnapshotShowsCapturedImage() async throws {
        let token = WindowToken(pid: 1004, windowId: 105)
        let overlay = makeOverlay(currentFrames: [token: frame(x: 0, width: 400)]) { _, _ in CGImage.blank() }
        defer { overlay.reset() }

        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .snapshot, pointerDriven: true)
        overlay.update([change(token, frame(x: 0, width: 300))])
        let capture = try XCTUnwrap(overlay.captureTasks[token])
        XCTAssertEqual(overlay.panels[token]?.showsSnapshot, false)
        await capture.value

        XCTAssertEqual(overlay.panels[token]?.showsSnapshot, true)
    }

    func testLiveStyleNeverStarts() {
        let overlay = makeOverlay(currentFrames: [:])
        overlay.begin(workspaceId: WorkspaceDescriptor.ID(), style: .live, pointerDriven: true)
        XCTAssertFalse(overlay.isActive)
    }

    func testFinishKeepsPanelsUntilTheirWriteLands() {
        let written = WindowToken(pid: 1005, windowId: 106)
        let pending = WindowToken(pid: 1005, windowId: 107)
        let currentFrames = FrameBox([written: frame(x: 0, width: 400), pending: frame(x: 420, width: 400)])
        let overlay = ResizeOverlayController(captureImage: { _, _ in nil }, currentFrame: { currentFrames.map[$0] })
        let workspaceId = WorkspaceDescriptor.ID()
        overlay.begin(workspaceId: workspaceId, style: .glass, pointerDriven: false)
        let writtenTarget = frame(x: 0, width: 480)
        overlay.update([change(written, writtenTarget), change(pending, frame(x: 500, width: 400))])

        currentFrames.map[written] = writtenTarget
        overlay.finish()
        XCTAssertEqual(Set(overlay.panels.keys), [pending])
        XCTAssertFalse(overlay.isTracking(workspaceId))

        overlay.frameApplied(windowId: pending.windowId)
        XCTAssertTrue(overlay.panels.isEmpty)
        XCTAssertFalse(overlay.isActive)
    }

    func testMouseResizeDefersFrameSubmissionsUntilRelease() async throws {
        let fixture = try makeLayoutFixture(animationsEnabled: false)
        let mouse = fixture.controller.mouseEventHandler
        let resized = try XCTUnwrap(fixture.engine.findNode(for: fixture.left, in: fixture.workspaceId))
        let frame = try XCTUnwrap(resized.renderedFrame ?? resized.frame)
        let start = CGPoint(x: frame.maxX - 2, y: frame.midY)
        fixture.controller.settings.gestures.resizePreviewStyle = .glass

        XCTAssertTrue(mouse.beginNiriResize(
            window: resized, engine: fixture.engine, wsId: fixture.workspaceId, at: start, source: .mouse(.right)
        ))
        let overlay = fixture.controller.resizeOverlay
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        mouse.updateManagedResize(at: CGPoint(x: start.x - 120, y: start.y))

        XCTAssertLessThan(try XCTUnwrap(overlay.panels[fixture.left]?.targetFrame.width), frame.width)
        XCTAssertNotNil(overlay.panels[fixture.right])
        XCTAssertEqual(frameApplicationEvents(fixture).count, 0)

        fixture.controller.hasStartedServices = true
        mouse.completeActiveResize()
        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasMotion(in: fixture.workspaceId))
        let releaseState = fixture.controller.layoutRefreshController.layoutState
        XCTAssertTrue(
            releaseState.activeRefresh?.reason == .interactiveGesture
                || releaseState.pendingRefresh?.reason == .interactiveGesture
        )
        XCTAssertFalse(mouse.state.isResizing)
        XCTAssertTrue(overlay.settlesOnLayout)
        XCTAssertEqual(frameApplicationEvents(fixture).count, 0)
        try await drainRefreshes(fixture)
        XCTAssertGreaterThan(frameApplicationEvents(fixture).count, 0)
        XCTAssertTrue(frameApplicationEvents(fixture).contains { $0.contains(" event=outcome=") })
        XCTAssertFalse(overlay.isTracking(fixture.workspaceId))
        overlay.reset()
    }

    func testKeyboardResizeAnimatesPanelsAndSubmitsFramesAfterSettlement() async throws {
        let fixture = try makeLayoutFixture()
        fixture.controller.settings.gestures.resizePreviewStyle = .glass
        let handler = fixture.controller.layoutRefreshController.niriHandler
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.left))

        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        XCTAssertTrue(fixture.controller.niriLayoutHandler.setContainerPrimarySpan(
            .adjustProportion(10),
            target: .window(handle)
        ))
        let overlay = fixture.controller.resizeOverlay
        XCTAssertTrue(overlay.isTracking(fixture.workspaceId))
        try await drainRefreshes(fixture)
        XCTAssertEqual(frameApplicationEvents(fixture).count, 0, "relayout during the animation must be held")
        XCTAssertTrue(overlay.isTracking(fixture.workspaceId))

        let heldFrames = overlay.panels.mapValues(\.targetFrame)
        let springs = try XCTUnwrap(fixture.controller.niriEngine?.columns(in: fixture.workspaceId))
            .compactMap(\.widthAnimation)
        let spring = try XCTUnwrap(springs.first)
        handler.tickScrollAnimation(
            targetTime: spring.startTime + spring.duration / 2,
            displayId: fixture.monitor.displayId
        )
        XCTAssertNotEqual(overlay.panels.mapValues(\.targetFrame), heldFrames)
        XCTAssertFalse(overlay.panels.isEmpty)
        XCTAssertEqual(frameApplicationEvents(fixture).count, 0)

        let settled = try XCTUnwrap(springs.map { ($0.startTime + $0.duration).nextUp }.max())
        handler.tickScrollAnimation(targetTime: settled, displayId: fixture.monitor.displayId)
        XCTAssertGreaterThan(frameApplicationEvents(fixture).count, 0)
        XCTAssertTrue(frameApplicationEvents(fixture).contains { $0.contains(" event=outcome=") })
        XCTAssertFalse(overlay.isTracking(fixture.workspaceId))
        overlay.reset()
    }

    @MainActor
    private final class FrameBox {
        var map: [WindowToken: CGRect]
        init(_ map: [WindowToken: CGRect]) {
            self.map = map
        }
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
        let controller = WindowAdmissionTestSupport.controller(prefix: "ResizeOverlayControllerTests")
        let directory = controller.settings.settingsFileURL.deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { @MainActor in
            controller.hasStartedServices = false
            controller.hotkeys.stop()
            controller.mouseEventHandler.cleanup()
            controller.resizeOverlay.reset()
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

    private enum RefreshDrainFailure: Error {
        case unfinished
    }

    private func drainRefreshes(_ fixture: LayoutFixture) async throws {
        let refreshController = fixture.controller.layoutRefreshController
        var completed = 0
        try Task.checkCancellation()
        while let task = refreshController.layoutState.activeRefreshTask {
            try Task.checkCancellation()
            guard completed < 200 else {
                XCTFail("Layout refresh chain exceeded 200 completed tasks")
                throw RefreshDrainFailure.unfinished
            }
            await task.value
            completed += 1
        }
        let state = refreshController.layoutState
        guard state.activeRefreshTask == nil, state.activeRefresh == nil, state.pendingRefresh == nil else {
            XCTFail("Layout refresh work remains without an active task")
            throw RefreshDrainFailure.unfinished
        }
    }

    private func change(_ token: WindowToken, _ frame: CGRect) -> LayoutFrameChange {
        LayoutFrameChange(token: token, frame: frame, forceApply: false)
    }

    private func frameApplicationEvents(_ fixture: LayoutFixture) -> [Substring] {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter { line in
            !line.contains("cancelled") && [fixture.left, fixture.right]
                .contains { line.contains("win=\($0.windowId) ") }
        }
    }

    private func frame(x: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX + x, y: screenFrame.minY, width: width, height: 300)
    }

    private func makeOverlay(
        currentFrames: [WindowToken: CGRect],
        captureAllowed: Bool = true,
        capture: ResizeOverlayController.ImageCapture? = nil
    ) -> ResizeOverlayController {
        ResizeOverlayController(
            previews: PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry()),
            captureAccessAllowed: { captureAllowed },
            captureImage: capture ?? { _, _ in nil },
            currentFrame: { currentFrames[$0] }
        )
    }
}

extension CGImage {
    fileprivate static func blank() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
