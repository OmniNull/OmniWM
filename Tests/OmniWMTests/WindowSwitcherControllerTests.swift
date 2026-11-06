// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WindowSwitcherControllerTests: XCTestCase {
    func testWindowOrderControlsDisplayedCardsAndCyclingWithinEachScope() throws {
        for order in [WindowSwitcherOrder.omniLayout, .lastUsed] {
            for scope in WindowSwitcherScope.allCases {
                let fixture = try makePresentationFixture(windowCount: 3)
                defer {
                    fixture.switcher.shutdown()
                    fixture.driver.finish()
                    fixture.controller.layoutRefreshController.resetState()
                    fixture.controller.surfaceReconciler.cleanup()
                }
                let manager = fixture.controller.workspaceManager
                let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: false))
                let otherWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
                    named: "2", layoutType: .niri, controller: fixture.controller
                ))
                let otherToken = WindowToken(pid: 81_001, windowId: 81_104)
                _ = WindowAdmissionTestSupport.track(otherToken, in: otherWorkspaceId, controller: fixture.controller)
                manager.setManagedFocus(fixture.tokens[1], in: workspaceId)
                manager.setManagedFocus(otherToken, in: otherWorkspaceId)
                manager.setManagedFocus(fixture.tokens[2], in: workspaceId)
                manager.setManagedFocus(fixture.tokens[0], in: workspaceId)
                fixture.controller.settings.windowSwitcher.order = order

                fixture.switcher.handle(.begin(reverse: false, scope: scope))

                let panel = try XCTUnwrap(fixture.registry.visibleWindows().first as? WindowSwitcherPanel)
                let content = try XCTUnwrap(panel.contentView)
                let expected: [WindowToken]
                switch order {
                case .omniLayout:
                    expected = fixture.tokens + (scope == .allWorkspaces ? [otherToken] : [])
                case .lastUsed:
                    expected = [fixture.tokens[0], fixture.tokens[2]]
                        + (scope == .allWorkspaces ? [otherToken] : []) + [fixture.tokens[1]]
                }
                XCTAssertEqual(tiles(in: content).map(\.handle.id), expected)
                XCTAssertEqual(
                    tiles(in: content).filter { $0.layer?.borderWidth == WindowSwitcherTile.selectedBorderWidth }
                        .map(\.handle.id),
                    [fixture.tokens[2]]
                )

                fixture.switcher.handle(.cycle(reverse: false))

                let selectedIndex = try XCTUnwrap(expected.firstIndex(of: fixture.tokens[2]))
                XCTAssertEqual(
                    tiles(in: content).filter { $0.layer?.borderWidth == WindowSwitcherTile.selectedBorderWidth }
                        .map(\.handle.id),
                    [expected[(selectedIndex + 1) % expected.count]]
                )
                XCTAssertEqual(manager.nativeManagedFocusToken, fixture.tokens[0])
            }
        }
    }

    func testSingleAndTwoWindowScopesPresentCardsWithoutChangingFocusAndCanCancel() throws {
        for windowCount in [1, 2] {
            for scope in WindowSwitcherScope.allCases {
                for reverse in [false, true] {
                    let fixture = try makePresentationFixture(windowCount: windowCount)
                    defer {
                        fixture.switcher.shutdown()
                        fixture.driver.finish()
                        fixture.controller.layoutRefreshController.resetState()
                        fixture.controller.surfaceReconciler.cleanup()
                    }

                    fixture.switcher.handle(.begin(reverse: reverse, scope: scope))

                    XCTAssertTrue(fixture.switcher.isVisible)
                    XCTAssertEqual(fixture.registry.visibleSurfaceIDs(), ["window-switcher"])
                    let panel = try XCTUnwrap(fixture.registry.visibleWindows().first as? WindowSwitcherPanel)
                    let cards = tiles(in: try XCTUnwrap(panel.contentView))
                    XCTAssertEqual(cards.map(\.handle.id), fixture.tokens)
                    XCTAssertEqual(
                        cards.filter { $0.layer?.borderWidth == WindowSwitcherTile.selectedBorderWidth }
                            .map(\.handle.id),
                        [fixture.tokens[windowCount - 1]]
                    )
                    XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, fixture.tokens[0])

                    fixture.switcher.handle(.cycle(reverse: reverse))
                    XCTAssertTrue(fixture.switcher.isVisible)
                    fixture.switcher.handle(.cancel)

                    XCTAssertFalse(fixture.switcher.isVisible)
                    XCTAssertTrue(fixture.registry.visibleWindows().isEmpty)
                    XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, fixture.tokens[0])
                    XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
                }
            }
        }
    }

    func testSingleWindowScopeCanExpandToWindowsOnAnotherWorkspace() throws {
        let fixture = try makePresentationFixture(windowCount: 1)
        defer {
            fixture.switcher.shutdown()
            fixture.driver.finish()
            fixture.controller.layoutRefreshController.resetState()
            fixture.controller.surfaceReconciler.cleanup()
        }
        let otherWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "2", layoutType: .niri, controller: fixture.controller
        ))
        let otherToken = WindowToken(pid: 81_001, windowId: 81_102)
        _ = WindowAdmissionTestSupport.track(otherToken, in: otherWorkspaceId, controller: fixture.controller)

        fixture.switcher.handle(.begin(reverse: false, scope: .activeWorkspace))

        XCTAssertTrue(fixture.switcher.isVisible)
        let panel = try XCTUnwrap(fixture.registry.visibleWindows().first as? WindowSwitcherPanel)
        XCTAssertEqual(tiles(in: try XCTUnwrap(panel.contentView)).map(\.handle.id), fixture.tokens)

        fixture.switcher.handle(.toggleScope)

        XCTAssertTrue(fixture.switcher.isVisible)
        XCTAssertEqual(
            Set(tiles(in: try XCTUnwrap(panel.contentView)).map(\.handle.id)),
            Set(fixture.tokens + [otherToken])
        )
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, fixture.tokens[0])
    }

    func testHiddenSwitcherRefreshDoesNotPinRetainedPreviews() async throws {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMWindowSwitcherControllerTests",
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.settings.windowSwitcher.enabled = true
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(81_001), windowId: 81_002),
            pid: 81_001,
            windowId: 81_002,
            to: workspaceId
        )
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .windowSwitcher)
        let switcher = WindowSwitcherController(controller: controller, previewCapture: capture)
        defer {
            capture.clear()
            driver.finish()
        }

        capture.reconcile(represented: [handle], visible: [
            OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)
        ])
        try await driver.waitForStarts(1)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "frame published")
        capture.onPreview = { _, preview in if preview === frame { published.fulfill() } }
        driver.streams[0].output.offer(frame)
        guard await XCTWaiter.fulfillment(of: [published], timeout: failureBound) == .completed else {
            XCTFail("Expected preview publication")
            throw OverviewPreviewTestWaitError.publication
        }
        switcher.dismiss()
        XCTAssertFalse(capture.isPresenting)
        XCTAssertTrue(capture.preview(for: handle) === frame)

        switcher.refreshWindows()
        XCTAssertFalse(capture.isPresenting)
        driver.coordinator.releaseCaches(reason: .memoryPressure)
        XCTAssertEqual(capture.cachedByteCount, 0)
        XCTAssertNil(capture.preview(for: handle))
    }

    func testDisablingSwitcherReleasesItsController() {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMWindowSwitcherControllerTests",
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.settings.windowSwitcher.enabled = true
        _ = controller.windowSwitcherController
        XCTAssertNotNil(controller.windowSwitcherControllerStorage)
        controller.settings.windowSwitcher.enabled = false
        controller.updateWindowSwitcherSettings()
        XCTAssertNil(controller.windowSwitcherControllerStorage)
    }

    func testQueuedBeginAfterDisableDoesNotRecreateController() async {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMWindowSwitcherControllerTests",
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.settings.windowSwitcher.enabled = true
        controller.hotkeys.onWindowSwitcherAction?(.begin(reverse: false), 1)
        controller.settings.windowSwitcher.enabled = false
        controller.updateWindowSwitcherSettings()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(controller.windowSwitcherControllerStorage)
    }

    private struct PresentationFixture {
        let controller: WMController
        let switcher: WindowSwitcherController
        let registry: OwnedWindowRegistry
        let driver: OverviewPreviewTestDriver
        let tokens: [WindowToken]
    }

    private func makePresentationFixture(windowCount: Int) throws -> PresentationFixture {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMWindowSwitcherPresentationTests", ownedWindowRegistry: registry
        )
        controller.settings.windowSwitcher.enabled = true
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let monitor = Monitor(
            id: .init(displayId: 81_000), displayId: 81_000,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Window Switcher Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (1 ... windowCount).map { WindowToken(pid: 81_001, windowId: 81_100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            tokens[0], in: workspaceId, onMonitor: monitor.id, activateWorkspaceOnMonitor: true
        ))
        controller.commandHandler.frontmostAppPidProvider = { tokens[0].pid }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { tokens[0] }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .windowSwitcher, hasCaptureAccess: { false })
        let switcher = WindowSwitcherController(controller: controller, previewCapture: capture)
        return PresentationFixture(
            controller: controller, switcher: switcher, registry: registry, driver: driver, tokens: tokens
        )
    }

    private func tiles(in view: NSView) -> [WindowSwitcherTile] {
        if let tile = view as? WindowSwitcherTile { return [tile] }
        return view.subviews.flatMap { tiles(in: $0) }
    }
}
