// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ParkingEdgeMaskTests: XCTestCase {
    func testDerivesOnePointMasksFromVisibleFrame() throws {
        let visibleFrame = CGRect(x: -1900, y: -40, width: 1840, height: 1010)
        let monitor = makeMonitor(
            displayId: 91,
            frame: CGRect(x: -1920, y: -80, width: 1920, height: 1080),
            visibleFrame: visibleFrame
        )

        let masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: [monitor], spaceTopology: .init())
        let left = try XCTUnwrap(masks.first { $0.key.side == .left })
        let right = try XCTUnwrap(masks.first { $0.key.side == .right })

        XCTAssertEqual(masks.count, 2)
        XCTAssertEqual(left.key.monitorId, monitor.id)
        XCTAssertEqual(left.frame, CGRect(x: -1900, y: -40, width: 1, height: 1010))
        XCTAssertEqual(right.key.monitorId, monitor.id)
        XCTAssertEqual(right.frame, CGRect(x: -61, y: -40, width: 1, height: 1010))
    }

    func testDerivesBothEdgesForEveryMonitor() {
        let first = makeMonitor(
            displayId: 92,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let second = makeMonitor(
            displayId: 93,
            frame: CGRect(x: 1440, y: 100, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1440, y: 100, width: 2560, height: 1415)
        )

        let masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: [first, second], spaceTopology: .init())

        XCTAssertEqual(masks.count, 4)
        XCTAssertEqual(
            Set(masks.map(\.key)),
            Set([
                ParkingEdgeMaskKey(monitorId: first.id, side: .left),
                ParkingEdgeMaskKey(monitorId: first.id, side: .right),
                ParkingEdgeMaskKey(monitorId: second.id, side: .left),
                ParkingEdgeMaskKey(monitorId: second.id, side: .right)
            ])
        )
    }

    func testSkipsDegenerateVisibleFrames() {
        let monitor = makeMonitor(
            displayId: 94,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 100)
        )

        XCTAssertTrue(SurfaceDerivation.deriveParkingEdgeMasks(monitors: [monitor], spaceTopology: .init()).isEmpty)
    }

    func testNativeFullscreenSuppressesOnlyItsDisplayAndDesktopRestoresGeometry() {
        let first = makeMonitor(
            displayId: 96,
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 55, y: 0, width: 3785, height: 2130)
        )
        let second = makeMonitor(
            displayId: 97,
            frame: CGRect(x: 3840, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 3840, y: 0, width: 1440, height: 875)
        )
        var topology = makeTopology(first: first, second: second, firstIsFullscreen: true)

        let fullscreenMasks = SurfaceDerivation.deriveParkingEdgeMasks(
            monitors: [first, second],
            spaceTopology: topology
        )

        XCTAssertEqual(fullscreenMasks, [
            DesiredParkingEdgeMask(
                key: ParkingEdgeMaskKey(monitorId: second.id, side: .left),
                frame: CGRect(x: 3840, y: 0, width: 1, height: 875)
            ),
            DesiredParkingEdgeMask(
                key: ParkingEdgeMaskKey(monitorId: second.id, side: .right),
                frame: CGRect(x: 5279, y: 0, width: 1, height: 875)
            )
        ])

        topology.displays[0].currentSpaceId = 1
        let desktopMasks = SurfaceDerivation.deriveParkingEdgeMasks(
            monitors: [first, second],
            spaceTopology: topology
        )

        XCTAssertEqual(desktopMasks, [
            DesiredParkingEdgeMask(
                key: ParkingEdgeMaskKey(monitorId: first.id, side: .left),
                frame: CGRect(x: 55, y: 0, width: 1, height: 2130)
            ),
            DesiredParkingEdgeMask(
                key: ParkingEdgeMaskKey(monitorId: first.id, side: .right),
                frame: CGRect(x: 3839, y: 0, width: 1, height: 2130)
            )
        ] + fullscreenMasks)
    }

    func testUnknownDisplayTopologyKeepsMasks() {
        let monitor = makeMonitor(
            displayId: 98,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let topology = SpaceTopology(
            displays: [.init(displayIdentifier: "other-display", spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1,
            fullscreenSpaceIds: [1]
        )

        let masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: [monitor], spaceTopology: topology)

        XCTAssertEqual(masks.count, 2)
        XCTAssertTrue(masks.allSatisfy { $0.key.monitorId == monitor.id })
    }

    @MainActor
    func testFullSceneRemovesAndRestoresMasksAfterActiveSpaceChanges() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ParkingEdgeMaskTests")
        controller.settings.workspaceBar.enabled = false
        let first = makeMonitor(
            displayId: 95_002,
            frame: CGRect(x: 91_000, y: 92_000, width: 1440, height: 900),
            visibleFrame: CGRect(x: 91_055, y: 92_000, width: 1385, height: 875)
        )
        let second = makeMonitor(
            displayId: 95_003,
            frame: CGRect(x: 93_000, y: 92_000, width: 1440, height: 900),
            visibleFrame: CGRect(x: 93_000, y: 92_000, width: 1440, height: 875)
        )
        controller.workspaceManager.applyMonitorConfigurationChange([first, second])
        controller.hasStartedServices = true
        let reconciler = controller.surfaceReconciler
        defer {
            controller.hasStartedServices = false
            reconciler.cleanup()
        }
        controller.workspaceManager.commitSpaceTopology(
            makeTopology(first: first, second: second, firstIsFullscreen: false)
        )
        reconciler.noteWorldChanged()
        reconciler.reconcileNow()
        let desktopMasks = reconciler.appliedScene.parkingEdgeMasks
        XCTAssertEqual(desktopMasks.count, 4)
        let firstSurfaceId = "parking-edge-mask-95002-left"
        let secondSurfaceId = "parking-edge-mask-95003-left"
        let firstWindow = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == firstSurfaceId }?.window
        )
        let secondWindow = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == secondSurfaceId }?.window
        )

        controller.workspaceManager.commitSpaceTopology(
            makeTopology(first: first, second: second, firstIsFullscreen: true)
        )
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.reconcileNow()

        XCTAssertEqual(reconciler.appliedScene.parkingEdgeMasks, desktopMasks.filter { $0.key.monitorId == second.id })
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs().contains(firstSurfaceId))
        XCTAssertTrue(
            secondWindow === SurfaceCoordinator.shared.visibleSurfaceInfos()
                .first { $0.id == secondSurfaceId }?.window
        )

        controller.workspaceManager.commitSpaceTopology(
            makeTopology(first: first, second: second, firstIsFullscreen: false)
        )
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        reconciler.reconcileNow()

        XCTAssertEqual(reconciler.appliedScene.parkingEdgeMasks, desktopMasks)
        let restoredSurface = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == firstSurfaceId }
        )
        XCTAssertEqual(restoredSurface.frame, CGRect(x: 91_055, y: 92_000, width: 1, height: 875))
        XCTAssertTrue(secondWindow.isVisible)
    }

    @MainActor
    func testManagerRegistersReusesAndRemovesInputBlockingMask() throws {
        let manager = ParkingEdgeMaskManager()
        let key = ParkingEdgeMaskKey(
            monitorId: Monitor.ID(displayId: 95_001),
            side: .left
        )
        let surfaceId = "parking-edge-mask-95001-left"
        let firstFrame = CGRect(x: 91_000, y: 92_000, width: 1, height: 700)
        let secondFrame = CGRect(x: 91_100, y: 92_100, width: 1, height: 800)

        manager.apply([DesiredParkingEdgeMask(key: key, frame: firstFrame)])

        let firstInfo = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceId }
        )
        let firstWindow = try XCTUnwrap(firstInfo.window)
        XCTAssertEqual(firstInfo.kind, .parkingEdgeMask)
        XCTAssertEqual(firstInfo.hitTestPolicy, .interactive)
        XCTAssertEqual(firstInfo.capturePolicy, .excluded)
        XCTAssertFalse(firstInfo.suppressesManagedFocusRecovery)
        XCTAssertEqual(firstInfo.frame, firstFrame)
        XCTAssertEqual(firstWindow.level, .statusBar)
        XCTAssertFalse(firstWindow.ignoresMouseEvents)

        manager.apply([DesiredParkingEdgeMask(key: key, frame: secondFrame)])

        let secondInfo = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceId }
        )
        XCTAssertTrue(firstWindow === secondInfo.window)
        XCTAssertEqual(secondInfo.frame, secondFrame)

        manager.apply([])

        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs().contains(surfaceId))
        manager.removeAll()
        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs().contains(surfaceId))
    }

    private func makeTopology(first: Monitor, second: Monitor, firstIsFullscreen: Bool) -> SpaceTopology {
        SpaceTopology(
            displays: [
                .init(
                    displayIdentifier: String(first.displayId),
                    spaceIds: [1, 2],
                    currentSpaceId: firstIsFullscreen ? 2 : 1
                ),
                .init(displayIdentifier: String(second.displayId), spaceIds: [3], currentSpaceId: 3)
            ],
            activeSpaceId: 3,
            fullscreenSpaceIds: [2]
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: visibleFrame,
            hasNotch: false,
            name: "Display \(displayId)"
        )
    }
}
