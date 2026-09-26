// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarHoverPreviewTests: XCTestCase {
    @MainActor
    private final class ManualScheduler {
        private(set) var pending: [(delay: Duration, action: @MainActor () -> Void, cancelled: Bool)] = []

        var scheduler: WorkspaceBarHoverPreviewController.Scheduler {
            { [self] delay, action in
                let index = pending.count
                pending.append((delay, action, false))
                return { [self] in pending[index].cancelled = true }
            }
        }

        var liveDelays: [Duration] {
            pending.filter { !$0.cancelled }.map(\.delay)
        }

        func fireLatest() {
            guard let index = pending.lastIndex(where: { !$0.cancelled }) else { return }
            pending[index].cancelled = true
            pending[index].action()
        }
    }

    private let workspaceId = WorkspaceDescriptor.ID()

    private func target(_ windowIds: [Int], token: WindowToken? = nil) -> WorkspaceBarHoverTarget {
        let windows = windowIds.map { id in
            WorkspaceBarHoverTarget.Window(
                handle: WindowHandle(id: WindowToken(pid: 50, windowId: id)),
                title: "Window \(id)",
                appName: "App",
                icon: nil
            )
        }
        return WorkspaceBarHoverTarget(
            key: .window(workspaceId, token ?? windows[0].handle.id),
            windows: windows,
            attachment: PopupAttachment(sourceFrame: CGRect(x: 100, y: 800, width: 20, height: 20), edge: .below),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            level: .statusBar
        )
    }

    private func makeController(
        driver: OverviewPreviewTestDriver,
        scheduler: ManualScheduler,
        hasCaptureAccess: Bool = true
    ) -> WorkspaceBarHoverPreviewController {
        WorkspaceBarHoverPreviewController(
            capture: driver.makeCapture(),
            hasCaptureAccess: { hasCaptureAccess },
            scheduleAfter: scheduler.scheduler
        )
    }

    func testPreviewOpensAfterTheHoverDelayAndStreamsOnlyWhileVisible() async {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let hovered = target([1])

        controller.hoverBegan(hovered)
        XCTAssertNil(controller.visibleTarget)
        XCTAssertEqual(scheduler.liveDelays, [WorkspaceBarHoverPreviewController.openDelay])
        XCTAssertTrue(driver.streams.isEmpty)

        scheduler.fireLatest()
        XCTAssertEqual(controller.visibleTarget, hovered)
        await driver.waitForStarts(1)
        driver.completeAllStarts()

        controller.hoverEnded(hovered.key)
        XCTAssertEqual(scheduler.liveDelays, [WorkspaceBarHoverPreviewController.closeGrace])
        XCTAssertEqual(controller.visibleTarget, hovered)
        scheduler.fireLatest()
        XCTAssertNil(controller.visibleTarget)
        await driver.waitForStops(1)
    }

    func testLeavingBeforeTheDelayCancelsTheOpen() {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let hovered = target([2])

        controller.hoverBegan(hovered)
        controller.hoverEnded(hovered.key)
        scheduler.fireLatest()

        XCTAssertNil(controller.visibleTarget)
        XCTAssertTrue(scheduler.liveDelays.isEmpty)
        XCTAssertTrue(driver.streams.isEmpty)
    }

    func testMovingToAnotherIconWhilePreviewingSwitchesInstantly() async {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let first = target([3])
        let second = target([4])

        controller.hoverBegan(first)
        scheduler.fireLatest()
        await driver.waitForStarts(1)
        controller.hoverEnded(first.key)
        controller.hoverBegan(second)

        XCTAssertEqual(controller.visibleTarget, second)
        XCTAssertTrue(scheduler.liveDelays.isEmpty)
        await driver.waitForStarts(2)
        XCTAssertEqual(driver.streams.map(\.request.handle), [first.windows[0].handle, second.windows[0].handle])
    }

    func testPointerInsideThePreviewKeepsItOpen() {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let grouped = target([5, 6])

        controller.hoverBegan(grouped)
        scheduler.fireLatest()
        controller.hoverEnded(grouped.key)
        controller.pointerInPanelChanged(true)
        XCTAssertTrue(scheduler.liveDelays.isEmpty)
        XCTAssertEqual(controller.visibleTarget, grouped)

        controller.pointerInPanelChanged(false)
        scheduler.fireLatest()
        XCTAssertNil(controller.visibleTarget)
    }

    func testClickingSuppressesReopeningUntilThePointerLeavesTheIcon() {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let hovered = target([7])

        controller.hoverBegan(hovered)
        scheduler.fireLatest()
        controller.dismiss(suppressing: hovered.key)
        XCTAssertNil(controller.visibleTarget)

        controller.hoverBegan(hovered)
        XCTAssertTrue(scheduler.liveDelays.isEmpty)
        controller.hoverEnded(hovered.key)
        controller.hoverBegan(hovered)
        XCTAssertEqual(scheduler.liveDelays, [WorkspaceBarHoverPreviewController.openDelay])
    }

    func testWithoutScreenRecordingThePreviewShowsWithoutStreams() {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler, hasCaptureAccess: false)
        let hovered = target([8])

        controller.hoverBegan(hovered)
        scheduler.fireLatest()

        XCTAssertEqual(controller.visibleTarget, hovered)
        XCTAssertTrue(driver.streams.isEmpty)
    }

    func testBarUpdatesRefreshChangedContentAndDismissMovedOrRemovedIcons() {
        let driver = OverviewPreviewTestDriver()
        let scheduler = ManualScheduler()
        let controller = makeController(driver: driver, scheduler: scheduler)
        let hovered = target([9, 19])
        let retitled = WorkspaceBarHoverTarget(
            key: hovered.key,
            windows: [hovered.windows[0]],
            attachment: hovered.attachment,
            visibleFrame: hovered.visibleFrame,
            level: hovered.level
        )
        let moved = WorkspaceBarHoverTarget(
            key: hovered.key,
            windows: retitled.windows,
            attachment: PopupAttachment(
                anchor: CGPoint(x: hovered.attachment.anchor.x + 40, y: hovered.attachment.anchor.y),
                edge: hovered.attachment.edge
            ),
            visibleFrame: hovered.visibleFrame,
            level: hovered.level
        )

        controller.hoverBegan(hovered)
        scheduler.fireLatest()
        controller.targetsDidChange { _ in hovered }
        XCTAssertEqual(controller.visibleTarget, hovered)
        controller.targetsDidChange { _ in retitled }
        XCTAssertEqual(controller.visibleTarget, retitled)
        controller.targetsDidChange { _ in moved }
        XCTAssertNil(controller.visibleTarget)

        controller.hoverEnded(hovered.key)
        controller.hoverBegan(hovered)
        controller.targetsDidChange { _ in nil }
        XCTAssertTrue(scheduler.liveDelays.isEmpty)
        scheduler.fireLatest()
        XCTAssertNil(controller.visibleTarget)
    }

    func testPreviewOpensInwardFromEveryBarEdge() {
        let panel = WorkspaceBarPreviewPanel(ownedWindowRegistry: OwnedWindowRegistry())
        defer { panel.hide() }
        let base = target([10])
        let cases: [(WorkspaceBarPosition, CGRect)] = [
            (.overlappingMenuBar, CGRect(x: 300, y: 876, width: 800, height: 24)),
            (.bottom, CGRect(x: 300, y: 0, width: 800, height: 24)),
            (.left, CGRect(x: 0, y: 200, width: 24, height: 500)),
            (.right, CGRect(x: 1576, y: 200, width: 24, height: 500))
        ]
        for (position, barFrame) in cases {
            let hovered = WorkspaceBarHoverTarget(
                key: base.key, windows: base.windows,
                attachment: PopupAttachment(sourceFrame: barFrame, edge: position.popupEdge),
                visibleFrame: base.visibleFrame, level: base.level
            )
            panel.show(
                hovered, windows: hovered.windows, overflowCount: 0,
                showsThumbnails: true, cachedPreview: { _ in nil }
            )
            XCTAssertTrue(base.visibleFrame.contains(panel.frame), "\(position)")
            XCTAssertFalse(panel.frame.intersects(barFrame), "\(position)")
            switch position.popupEdge {
            case .above: XCTAssertGreaterThan(panel.frame.minY, barFrame.maxY)
            case .below: XCTAssertLessThan(panel.frame.maxY, barFrame.minY)
            case .left: XCTAssertLessThan(panel.frame.maxX, barFrame.minX)
            case .right: XCTAssertGreaterThan(panel.frame.minX, barFrame.maxX)
            }
        }
    }

    func testGroupedPreviewsFitNarrowDisplaysWithoutCoveringSideBars() {
        let panel = WorkspaceBarPreviewPanel(ownedWindowRegistry: OwnedWindowRegistry())
        defer { panel.hide() }
        let base = target([11, 12, 13, 14])
        for width: CGFloat in [640, 320] {
            let visible = CGRect(x: -800, y: -500, width: width, height: 180)
            for position in [WorkspaceBarPosition.left, .right] {
                let bar = CGRect(
                    x: position == .left ? visible.minX : visible.maxX - 32,
                    y: visible.minY, width: 32, height: visible.height
                )
                let hovered = WorkspaceBarHoverTarget(
                    key: base.key, windows: base.windows,
                    attachment: PopupAttachment(sourceFrame: bar, edge: position.popupEdge),
                    visibleFrame: visible, level: base.level
                )
                for thumbnails in [true, false] {
                    for overflow in [0, 17] {
                        panel.show(
                            hovered, windows: hovered.windows, overflowCount: overflow,
                            showsThumbnails: thumbnails, cachedPreview: { _ in nil }
                        )
                        XCTAssertTrue(visible.contains(panel.frame))
                        XCTAssertFalse(panel.frame.intersects(bar))
                        let content = panel.contentView!
                        XCTAssertEqual(content.subviews.count, 4 + (overflow > 0 ? 1 : 0))
                        for tile in content.subviews {
                            XCTAssertTrue(content.bounds.contains(tile.frame))
                            XCTAssertGreaterThan(tile.frame.width, 0)
                        }
                    }
                }
            }
        }
    }

    func testPanelIsClickableOnlyForGroupedPreviews() throws {
        let registry = OwnedWindowRegistry()
        let panel = WorkspaceBarPreviewPanel(ownedWindowRegistry: registry)
        let single = target([10])
        panel.show(
            single,
            windows: single.windows,
            overflowCount: 0,
            showsThumbnails: true,
            cachedPreview: { _ in nil }
        )
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(single.visibleFrame.contains(panel.frame))
        XCTAssertGreaterThan(panel.frame.width, WorkspaceBarPreviewPanel.tileSize(forWindowCount: 1).width)
        panel.updatePreview(try makeOverviewPreviewFrame(), for: single.windows[0].handle)

        let grouped = target([11, 12, 13, 14, 15])
        panel.show(
            grouped,
            windows: Array(grouped.windows.prefix(WorkspaceBarHoverPreviewController.maximumTiles)),
            overflowCount: 1,
            showsThumbnails: false,
            cachedPreview: { _ in nil }
        )
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        panel.hide()
        XCTAssertFalse(panel.isVisible)
    }
}
