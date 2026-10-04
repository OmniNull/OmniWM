// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarNotificationBadgeIntegrationTests: XCTestCase {
    func testHiddenBarsKeepDeduplicatedVisibleIconDemandWithoutWorldOrSurfaceUpdates() async {
        let published = expectation(description: "Badge labels published")
        let expected: Set<String> = [
            "com.example.mail", "com.example.notes", "com.example.chat", "com.example.music"
        ]
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { targets, _ in
                XCTAssertEqual(targets, expected)
                return DockBadgeReadResult(labels: ["com.example.mail": "7"], dockPID: 42)
            },
            sleep: { _ in
                published.fulfill()
                throw CancellationError()
            }
        )
        let (controller, manager) = makeManager(service: service)
        defer {
            controller.hasStartedServices = false
            manager.cleanup()
        }
        let initialSequence = controller.workspaceManager.worldSeq
        XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)

        manager.apply([surface(
            tiled: [window("com.example.mail", id: 1)],
            floating: [window("COM.EXAMPLE.MAIL", id: 2), window(nil, id: 3)],
            scratchpads: [
                WorkspaceBarScratchpadItem(
                    index: 1, label: nil,
                    windows: [
                        window("com.example.notes", id: 4),
                        window("com.example.chat", id: 5),
                        window("com.example.music", id: 6),
                        window("com.example.overflow", id: 7)
                    ],
                    isVisible: false, presentation: .expanded
                ),
                WorkspaceBarScratchpadItem(
                    index: 2, label: nil, windows: [window("com.example.compact", id: 8)],
                    isVisible: false, presentation: .compact
                )
            ]
        )])
        await fulfillment(of: [published], timeout: 2)

        XCTAssertEqual(service.bundleIDs, expected)
        XCTAssertEqual(service.label(for: "com.example.mail"), "7")
        XCTAssertTrue(manager.barsByMonitor.isEmpty)
        XCTAssertEqual(controller.workspaceManager.worldSeq, initialSequence)
        XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testDisabledBarMonitorAndServicesDoNotCreateBadgeDemand() {
        for disabledGate in 0 ..< 4 {
            let service = WorkspaceBarBadgeService(
                notificationCenter: NotificationCenter(),
                read: { _, _ in
                    XCTFail("Disabled badge demand must not read the Dock")
                    return DockBadgeReadResult()
                },
                sleep: { _ in throw CancellationError() }
            )
            let (controller, manager) = makeManager(service: service)
            defer {
                controller.hasStartedServices = false
                manager.cleanup()
            }
            switch disabledGate {
            case 0:
                controller.settings.workspaceBar.enabled = false
            case 1:
                controller.settings.workspaceBar.update(
                    MonitorBarSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId, enabled: false),
                    for: monitor
                )
            case 2:
                controller.hasStartedServices = false
            default:
                controller.settings.workspaceBar.notificationBadges = .off
            }

            manager.apply([surface(tiled: [window("com.example.mail", id: 1)])])

            XCTAssertTrue(service.bundleIDs.isEmpty, "Gate \(disabledGate)")
            XCTAssertTrue(service.labels.isEmpty, "Gate \(disabledGate)")
        }
    }

    func testRemovingAllBarsClearsBadgeDemandAndLabels() async {
        let published = expectation(description: "Badge labels published")
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { _, _ in DockBadgeReadResult(labels: ["com.example.mail": "!"], dockPID: 42) },
            sleep: { _ in
                published.fulfill()
                throw CancellationError()
            }
        )
        let (controller, manager) = makeManager(service: service)
        defer {
            controller.hasStartedServices = false
            manager.cleanup()
        }
        manager.apply([surface(tiled: [window("com.example.mail", id: 1)])])
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(service.label(for: "com.example.mail"), "!")

        manager.apply([])

        XCTAssertTrue(service.bundleIDs.isEmpty)
        XCTAssertTrue(service.labels.isEmpty)
    }

    func testWidthCompactionUsesPreparedIconDemandInsteadOfDesiredExpandedScratchpad() throws {
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { _, _ in
                XCTFail("Compacted scratchpad has no displayed app icons to read")
                return DockBadgeReadResult()
            },
            sleep: { _ in throw CancellationError() }
        )
        let narrowMonitor = Monitor(
            id: monitor.id, displayId: monitor.displayId,
            frame: CGRect(x: 0, y: 0, width: 100, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 100, height: 1055),
            hasNotch: false, name: monitor.name
        )
        let (controller, manager) = makeManager(service: service, monitor: narrowMonitor)
        defer {
            controller.hasStartedServices = false
            manager.cleanup()
        }
        let desired = surface(
            tiled: [],
            scratchpads: [WorkspaceBarScratchpadItem(
                index: 1, label: "Messages", windows: [window("com.example.mail", id: 1)],
                isVisible: false, presentation: .expanded
            )],
            monitor: narrowMonitor,
            visible: true
        )

        manager.apply([desired])

        let instance = try XCTUnwrap(manager.barsByMonitor[narrowMonitor.id])
        XCTAssertEqual(desired.snapshot.scratchpads.first?.presentation, .expanded)
        XCTAssertEqual(instance.model.snapshot.scratchpads.first?.presentation, .compact)
        XCTAssertTrue(service.bundleIDs.isEmpty)
    }

    private func makeManager(
        service: WorkspaceBarBadgeService,
        monitor: Monitor? = nil
    ) -> (WMController, WorkspaceBarManager) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WorkspaceBarNotificationBadgeIntegration")
        controller.settings.workspaceBar.enabled = true
        controller.settings.workspaceBar.hoverPreviewsEnabled = false
        controller.settings.workspaceBar.notificationBadges = .text
        controller.workspaceManager.replaceMonitorsForTopologyTransition(with: [monitor ?? self.monitor])
        controller.surfaceReconciler.cleanup()
        controller.hasStartedServices = true
        let manager = WorkspaceBarManager(
            motionPolicy: MotionPolicy(animationsEnabled: false), notificationBadges: service
        )
        manager.screenProvider = { _ in nil }
        manager.frameApplier = { _, _ in }
        manager.setup(controller: controller, settings: controller.settings)
        return (controller, manager)
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 92_201), displayId: 92_201,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            hasNotch: false, name: "Test"
        )
    }

    private func surface(
        tiled: [WorkspaceBarWindowItem],
        floating: [WorkspaceBarWindowItem] = [],
        scratchpads: [WorkspaceBarScratchpadItem] = [],
        monitor: Monitor? = nil,
        visible: Bool = false
    ) -> DesiredBarSurface {
        DesiredBarSurface(
            monitor: monitor ?? self.monitor,
            visible: visible,
            snapshot: WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(
                    items: [WorkspaceBarItem(
                        id: UUID(), name: "1", rawName: "1", isFocused: true,
                        tiledWindows: tiled, floatingWindows: floating
                    )],
                    scratchpads: scratchpads
                ),
                showLabels: true, showSystemStatsButton: false, backgroundOpacity: 0.1,
                barHeight: 28, accentColor: nil, textColor: nil
            )
        )
    }

    private func window(_ bundleID: String?, id: Int) -> WorkspaceBarWindowItem {
        let token = WindowToken(pid: 42, windowId: id)
        return WorkspaceBarWindowItem(
            id: token, handle: WindowHandle(id: token), windowId: id, appName: "App \(id)",
            bundleId: bundleID, icon: nil, isFocused: false, windowCount: 1,
            hiddenWindowCount: 0, allWindows: []
        )
    }
}
