// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class OverviewDragCaptureIntegrationTests: XCTestCase {
    func testDragSeedsCachedFrameAndSharesUpdatesWithoutStartingAnotherCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.overview.dismiss(animated: false) }
        fixture.overview.open()
        await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        let handle = try XCTUnwrap(fixture.overview.selectedWindowHandle)
        let first = try makeOverviewPreviewFrame()
        try await publish(first, in: fixture)

        fixture.overview.drag.beginDrag(on: fixture.monitorId, handle: handle, startPoint: CGPoint(x: 50, y: 50))
        let ghost = try XCTUnwrap(fixture.registry.visibleWindows(kind: .dragGhost).first as? OverviewDragGhost)

        XCTAssertTrue(ghost.preview === first)
        XCTAssertEqual(fixture.driver.streams.count, 1)
        XCTAssertEqual(fixture.captureStarts.count, 1)
        XCTAssertEqual(fixture.driver.streams[0].stopCount, 0)

        let replacement = try makeOverviewPreviewFrame(width: 120, height: 80)
        try await publish(replacement, in: fixture)

        XCTAssertTrue(ghost.preview === replacement)
        XCTAssertTrue(fixture.capture.preview(for: handle) === replacement)
        XCTAssertEqual(fixture.captureStarts.count, 1)

        fixture.overview.drag.cancelDrag()

        XCTAssertFalse(fixture.overview.hasActiveDragSession)
        XCTAssertNil(ghost.preview)
        XCTAssertTrue(fixture.registry.visibleWindows(kind: .dragGhost).isEmpty)
        XCTAssertEqual(fixture.driver.streams[0].stopCount, 0)
        XCTAssertEqual(fixture.captureStarts.count, 1)
        fixture.overview.dismiss(animated: false)
        await fixture.driver.waitForStops(1)
    }

    func testAuthoritativeRemovalCancelsDragAndRejectsLateSourceFrames() async throws {
        let fixture = try makeFixture()
        defer { fixture.overview.dismiss(animated: false) }
        fixture.overview.open()
        await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        let handle = try XCTUnwrap(fixture.overview.selectedWindowHandle)
        try await publish(makeOverviewPreviewFrame(), in: fixture)
        fixture.overview.drag.beginDrag(on: fixture.monitorId, handle: handle, startPoint: CGPoint(x: 50, y: 50))
        let ghost = try XCTUnwrap(fixture.registry.visibleWindows(kind: .dragGhost).first as? OverviewDragGhost)
        fixture.controller.workspaceManager.onWindowRemoved = { [weak overview = fixture.overview] entry in
            overview?.handleManagedWindowRemoved(entry)
        }

        _ = fixture.controller.workspaceManager.removeWindow(pid: handle.pid, windowId: handle.windowId)
        await fixture.driver.waitForStops(1)

        XCTAssertFalse(fixture.overview.hasActiveDragSession)
        XCTAssertNil(ghost.preview)
        XCTAssertFalse(ghost.isVisible)
        XCTAssertTrue(fixture.registry.visibleWindows(kind: .dragGhost).isEmpty)
        XCTAssertNil(fixture.capture.preview(for: handle))
        fixture.driver.streams[0].output.offer(try makeOverviewPreviewFrame())
        XCTAssertNil(fixture.driver.streams[0].output.take())
        XCTAssertNil(ghost.preview)
        XCTAssertEqual(fixture.captureStarts.count, 1)
    }

    func testReopenSeedsCardsFromPreviousSessionFramesUntilLiveFramesArrive() async throws {
        let fixture = try makeFixture()
        defer { fixture.overview.dismiss(animated: false) }
        fixture.overview.open()
        await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        let handle = try XCTUnwrap(fixture.overview.selectedWindowHandle)
        let previous = try makeOverviewPreviewFrame()
        try await publish(previous, in: fixture)
        fixture.overview.dismiss(animated: false)
        await fixture.driver.waitForStops(1)
        XCTAssertTrue(fixture.capture.preview(for: handle) === previous)

        fixture.overview.open()

        let card = try XCTUnwrap(overviewCard(for: handle, in: fixture))
        XCTAssertTrue(card.preview === previous, "Reopened card must show the previous frame before any stream starts")
        await fixture.driver.waitForStarts(2)
        fixture.driver.completeAllStarts()
        let live = try makeOverviewPreviewFrame()
        let published = expectation(description: "live frame reached the card")
        let onPreview = fixture.capture.onPreview
        fixture.capture.onPreview = { handle, preview in
            onPreview(handle, preview)
            if preview === live { published.fulfill() }
        }
        fixture.driver.streams[1].output.offer(live)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(card.preview === live)
        fixture.driver.streams[0].output.offer(try makeOverviewPreviewFrame())
        XCTAssertNil(fixture.driver.streams[0].output.take())
        XCTAssertTrue(card.preview === live)
    }

    private func overviewCard(for handle: WindowHandle, in fixture: Fixture) -> OverviewWindowLayer? {
        fixture.registry.visibleWindows(kind: .overview)
            .compactMap { ($0 as? OverviewWindow)?.contentView?.subviews.compactMap { $0 as? OverviewView }.first }
            .compactMap { $0.layerRenderer.windowLayers[handle] }
            .first
    }

    private func publish(_ frame: OverviewPreviewFrame, in fixture: Fixture) async throws {
        let published = expectation(description: "Shared source frame reached its consumers")
        let previous = fixture.capture.onPreview
        fixture.capture.onPreview = { handle, preview in
            previous(handle, preview)
            if preview === frame { published.fulfill() }
        }
        defer { fixture.capture.onPreview = previous }
        fixture.driver.streams[0].output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
    }

    private final class CaptureStarts {
        var count = 0
    }

    private struct Fixture {
        let controller: WMController
        let overview: OverviewController
        let driver: OverviewPreviewTestDriver
        let capture: OverviewThumbnailCapture
        let registry: OwnedWindowRegistry
        let monitorId: Monitor.ID
        let captureStarts: CaptureStarts
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewDragCaptureTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
            )
        )
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 91_031), displayId: 91_031, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Overview drag capture"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(91_131), windowId: 91_231),
            pid: 91_131, windowId: 91_231, to: workspaceId
        )
        let captureStarts = CaptureStarts()
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Shared preview" }
        environment.windowFrame = { _ in CGRect(x: 10, y: 10, width: 600, height: 400) }
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.activateApplication = { _ in }
        environment.addLocalEventMonitor = { _, _ in NSObject() }
        environment.removeEventMonitor = { _ in }
        environment.notificationCenter = NotificationCenter()
        environment.onThumbnailCaptureStarted = { captureStarts.count += 1 }
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let overview = OverviewController(
            wmController: controller,
            motionPolicy: controller.motionPolicy,
            environment: environment,
            ownedWindowRegistry: registry,
            previewCapture: capture
        )
        return Fixture(
            controller: controller, overview: overview, driver: driver, capture: capture,
            registry: registry, monitorId: monitor.id, captureStarts: captureStarts
        )
    }
}
