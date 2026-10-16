// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellBadgesTests: XCTestCase {
    func testIslandDemandReadsManagedAppsWithTheBarDisabled() async throws {
        let published = expectation(description: "Managed badge labels published")
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { targets, _ in
                XCTAssertEqual(targets, ["com.example.mail", "com.example.notes"])
                return DockBadgeReadResult(labels: ["com.example.mail": "9", "com.example.notes": "!"], dockPID: 42)
            },
            sleep: { _ in published.fulfill()
                throw CancellationError()
            }
        )
        let (controller, manager) = try makeManager(service: service)
        defer { controller.hasStartedServices = false
            manager.cleanup()
        }
        let host = makeHost()
        let feed = ShellDataFeed(deliver: { _ in })
        host.feed = feed
        manager.shellHost = host
        service.onLabelsChange = { [weak manager] in manager?.publishShellBadges() }

        manager.setShellBadgeDemand(true)
        await fulfillment(of: [published], timeout: 2)

        XCTAssertFalse(controller.settings.workspaceBar.enabled)
        XCTAssertTrue(manager.barsByMonitor.isEmpty)
        XCTAssertEqual(service.mode, .off)
        XCTAssertNil(service.label(for: "com.example.mail"))
        XCTAssertEqual(feed.current.badges, ["com.example.mail": "9", "com.example.notes": "!"])
    }

    func testBarPresentationAndShellReaderDemandStayIndependent() {
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(), read: { _, _ in DockBadgeReadResult() },
            sleep: { _ in throw CancellationError() }
        )
        defer { service.stop() }
        service.configure(mode: .off, interval: 5, bundleIDs: ["bar"], shellBundleIDs: ["SHELL", ""])
        XCTAssertEqual(service.mode, .off)
        XCTAssertEqual(service.bundleIDs, ["shell"])
        service.configure(mode: .text, interval: 5, bundleIDs: ["BAR"], shellBundleIDs: ["SHELL", "BAR"])
        XCTAssertEqual(service.bundleIDs, ["bar", "shell"])
        service.configure(mode: .dot, interval: 5, bundleIDs: ["bar"])
        XCTAssertEqual(service.bundleIDs, ["bar"])
        XCTAssertEqual(service.mode, .dot)
        service.configure(mode: .off, interval: 5, bundleIDs: ["bar"])
        XCTAssertTrue(service.bundleIDs.isEmpty)
    }

    func testBadgeFeedDemandStartsPausesResumesAndStopsWithoutItsOwnTimer() {
        var demand: [Bool] = []
        var deliveries = 0
        let feed = ShellDataFeed(onBadgesDemandChange: { demand.append($0) }, deliver: { _ in deliveries += 1 })
        let cadence = ShellDataFeed.Cadence.of([(ShellDataKey.badges.bit, nil)])
        XCTAssertEqual(cadence.tick, 0)
        XCTAssertEqual(cadence.sampling, 0)
        feed.setDemand(ShellDataKey.badges.bit, cadence: cadence)
        XCTAssertEqual(demand.last, false)
        feed.start()
        XCTAssertEqual(demand.last, true)
        XCTAssertEqual(feed.interval, 0)
        feed.setBadges(["com.example.mail": "7"])
        let before = deliveries
        feed.setBadges(["com.example.mail": "7"])
        XCTAssertEqual(deliveries, before)
        feed.setPaused(true)
        XCTAssertEqual(demand.last, false)
        XCTAssertTrue(feed.current.badges.isEmpty)
        feed.setPaused(false)
        XCTAssertEqual(demand.last, true)
        feed.setDemand(0, cadence: .init())
        XCTAssertEqual(demand.last, false)
        feed.stop()
        XCTAssertEqual(demand.last, false)
    }

    func testBarCleanupPreservesShellDemandAndWorldRemovalRefreshesTargets() throws {
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(), read: { _, _ in DockBadgeReadResult() },
            sleep: { _ in throw CancellationError() }
        )
        let (controller, manager) = try makeManager(service: service)
        defer { controller.hasStartedServices = false
            manager.cleanup()
        }
        manager.setShellBadgeDemand(true)
        XCTAssertEqual(service.bundleIDs, ["com.example.mail", "com.example.notes"])
        manager.cleanup(keepingShell: true)
        XCTAssertTrue(manager.shellBadgeDemand)
        XCTAssertEqual(service.bundleIDs, ["com.example.mail", "com.example.notes"])
        controller.workspaceManager.removeWindowsForApp(pid: 85002)
        manager.updateNotificationBadgeTargets([])
        XCTAssertEqual(service.bundleIDs, ["com.example.mail"])
        controller.hasStartedServices = false
        manager.syncNotificationBadges()
        XCTAssertTrue(service.bundleIDs.isEmpty)
        controller.hasStartedServices = true
        manager.syncNotificationBadges()
        XCTAssertEqual(service.bundleIDs, ["com.example.mail"])
        manager.cleanup()
        XCTAssertFalse(manager.shellBadgeDemand)
        XCTAssertTrue(service.bundleIDs.isEmpty)
    }

    func testPublicBadgeMapPreservesLabelsAndOnlyChangesItsDataKey() throws {
        var data = ShellWidgetData()
        data.badges = ["com.example.mail": "99+", "com.example.notes": "●"]
        XCTAssertEqual(data.changedKeys(from: ShellWidgetData()), ShellDataKey.badges.bit)
        let widget = try ShellRenderedWidget(name: "badge-fixture", source: """
        function render(ctx)
            local badges = ctx.data.badges
            return ui.text{text = badges["com.example.mail"] .. ":" .. badges["com.example.notes"]}
        end
        """)
        widget.set("badges") { writer in
            writer.map(data.badges.count)
            for (bundleID, label) in data.badges {
                writer.key(bundleID)
                writer.string(label)
            }
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("99+:●"))
    }

    private func makeManager(service: WorkspaceBarBadgeService) throws -> (WMController, WorkspaceBarManager) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ShellBadges")
        controller.settings.workspaceBar.enabled = false
        controller.settings.workspaceBar.notificationBadges = .off
        controller.settings.workspaceBar.hoverPreviewsEnabled = false
        controller.settings.island.enabled = true
        controller.workspaceManager.replaceMonitorsForTopologyTransition(with: [Monitor(
            id: .init(displayId: 85_001), displayId: 85_001,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            hasNotch: false, name: "Badge fixture"
        )])
        let workspace = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "99",
            layoutType: .niri,
            controller: controller
        ))
        for (pid, windowID, bundleID, mode) in [
            (pid_t(85001), 85101, "COM.EXAMPLE.MAIL", TrackedWindowMode.tiling),
            (pid_t(85001), 85102, "com.example.mail", TrackedWindowMode.tiling),
            (pid_t(85002), 85103, "com.example.notes", TrackedWindowMode.floating)
        ] {
            let token = WindowToken(pid: pid, windowId: windowID)
            controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: pid, windowId: windowID, to: workspace,
                mode: mode, managedReplacementMetadata: ManagedReplacementMetadata(
                    bundleId: bundleID, workspaceId: workspace, mode: mode
                )
            )
        }
        controller.surfaceReconciler.cleanup()
        controller.hasStartedServices = true
        let manager = WorkspaceBarManager(
            configDirectory: controller.settings.settingsFileURL.deletingLastPathComponent(),
            motionPolicy: MotionPolicy(animationsEnabled: false),
            notificationBadges: service
        )
        manager.setup(controller: controller, settings: controller.settings)
        return (controller, manager)
    }

    private func makeHost() -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {}, onCommand: { _, _ in },
            onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
    }
}
