// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SurfaceReconcileScopeTests: XCTestCase {
    private enum AuxiliaryApply: Equatable {
        case tabRails(count: Int, forceOrdering: Bool)
        case nativeFullscreenPlaceholders(count: Int, forceOrdering: Bool)
    }

    func testFullSceneWinsWhenCoalescedWithBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler

        reconciler.noteBorderChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        reconciler.noteWorldChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.noteBorderChanged()
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)

        reconciler.reconcileNow()

        XCTAssertNil(reconciler.pendingReconcileScope)
        XCTAssertFalse(reconciler.reconcileScheduled)
    }

    func testForcedBorderRestackReordersAppliedAuxiliarySurfaces() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        var applies: [AuxiliaryApply] = []
        let reconciler = SurfaceReconciler(
            controller: controller,
            applyTabRails: { _, infos, forceOrdering in
                applies.append(.tabRails(count: infos.count, forceOrdering: forceOrdering))
            },
            applyNativeFullscreenPlaceholders: { _, placeholders, forceOrdering in
                applies.append(
                    .nativeFullscreenPlaceholders(
                        count: placeholders.count,
                        forceOrdering: forceOrdering
                    )
                )
            }
        )

        reconciler.noteBorderChanged()
        reconciler.reconcileNow()

        XCTAssertTrue(applies.isEmpty)

        reconciler.noteRestackOccurred()
        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        XCTAssertTrue(reconciler.forceOrderingOnNextReconcile)
        reconciler.reconcileNow()

        XCTAssertEqual(
            applies,
            [
                .tabRails(count: 0, forceOrdering: true),
                .nativeFullscreenPlaceholders(count: 0, forceOrdering: true)
            ]
        )
    }

    func testCoalescedFullSceneRestackPreservesAuxiliaryForceOrdering() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        var applies: [AuxiliaryApply] = []
        let reconciler = SurfaceReconciler(
            controller: controller,
            applyTabRails: { _, infos, forceOrdering in
                applies.append(.tabRails(count: infos.count, forceOrdering: forceOrdering))
            },
            applyNativeFullscreenPlaceholders: { _, placeholders, forceOrdering in
                applies.append(
                    .nativeFullscreenPlaceholders(
                        count: placeholders.count,
                        forceOrdering: forceOrdering
                    )
                )
            }
        )

        reconciler.noteRestackOccurred()
        reconciler.noteWorldChanged()
        reconciler.reconcileNow()

        XCTAssertEqual(
            applies,
            [
                .tabRails(count: 0, forceOrdering: true),
                .nativeFullscreenPlaceholders(count: 0, forceOrdering: true)
            ]
        )
    }

    func testDisplayScaleInvalidationSchedulesBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
    }

    func testDisabledBorderRemovesDisplayScaleObserver() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler
        controller.settings.borders.enabled = false
        controller.borderSettingsChanged()
        reconciler.reconcileNow()

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertNil(reconciler.pendingReconcileScope)
    }

    func testAnimationTickDoesNotConsumePendingFullScenePass() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let reconciler = controller.surfaceReconciler
        reconciler.noteWorldChanged()

        reconciler.reconcileAnimationTick()

        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        XCTAssertTrue(reconciler.reconcileScheduled)
    }

    func testExternalFocusProductionPathSchedulesBorderOnly() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")

        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: 812_001, windowId: 812_002))

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    func testSuppressionAndSystemModalProductionPathsRemainBorderOnly() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 812_051, windowId: 812_052)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.suppressFocusBorder(for: token)

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.setSystemModalFocus(token)

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    func testFloatingGeometryProductionPathSchedulesBorderOnly() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 812_101, windowId: 812_102)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 100, y: 120, width: 800, height: 600),
            for: token
        )

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
    }

    private func startedController() -> WMController {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        controller.workspaceManager.applyMonitorConfigurationChange([
            Monitor(
                id: .init(displayId: 812_301),
                displayId: 812_301,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                hasNotch: false,
                name: "Scope"
            )
        ])
        controller.hasStartedServices = true
        addTeardownBlock { @MainActor in
            controller.hasStartedServices = false
            controller.surfaceReconciler.cleanup()
        }
        return controller
    }

    private func tiledWindows(
        count: Int,
        controller: WMController
    ) throws -> (workspaceId: WorkspaceDescriptor.ID, tokens: [WindowToken]) {
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokens = (0 ..< count).map { WindowToken(pid: 812_201, windowId: 812_210 + $0) }
        for token in tokens {
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId
            )
            controller.workspaceManager.withEngineMutationScope {
                _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            }
        }
        return (workspaceId, tokens)
    }

    private func hiddenState(_ reason: HiddenReason) -> HiddenState {
        HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: reason)
    }

    func testLayoutEdgeHideAndRestoreScheduleBorderOnly() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let token = try XCTUnwrap(tiledWindows(count: 1, controller: controller).tokens.first)
        let reconciler = controller.surfaceReconciler
        reconciler.reconcileNow()

        controller.workspaceManager.setHiddenState(hiddenState(.layoutTransient(.left)), for: token)
        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        reconciler.reconcileNow()

        controller.workspaceManager.setHiddenState(nil, for: token)
        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
    }

    func testHidesThatSurfacesReadScheduleFullScene() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let tokens = try tiledWindows(count: 3, controller: controller).tokens
        let reconciler = controller.surfaceReconciler
        reconciler.reconcileNow()

        controller.workspaceManager.setHiddenState(hiddenState(.workspaceInactive), for: tokens[0])
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.reconcileNow()

        controller.workspaceManager.setHiddenState(hiddenState(.scratchpad), for: tokens[1])
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.reconcileNow()

        XCTAssertTrue(controller.workspaceManager.setScratchpadMembership(tokens[2], to: 1))
        reconciler.reconcileNow()
        controller.workspaceManager.setHiddenState(hiddenState(.layoutTransient(.left)), for: tokens[2])
        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
    }

    func testLayoutEdgeHideSchedulesFullSceneForWindowEventSubscribers() async throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        let token = try XCTUnwrap(tiledWindows(count: 1, controller: controller).tokens.first)
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        addTeardownBlock { await bridge.shutdown() }
        controller.ipcApplicationBridge = bridge
        let stream = await bridge.stream(for: .windowsChanged)
        XCTAssertTrue(controller.hasWindowOrLayoutEventSubscribers)
        controller.surfaceReconciler.reconcileNow()

        controller.workspaceManager.setHiddenState(hiddenState(.layoutTransient(.left)), for: token)

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .fullScene)
        withExtendedLifetime(stream) {}
    }

    func testLayoutEdgeHideSchedulesFullSceneWhileTabRailsExist() throws {
        let controller = startedController()
        let (workspaceId, tokens) = try tiledWindows(count: 2, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let columns = engine.columns(in: workspaceId)
            let moved = columns[1].windowNodes[0]
            moved.detach()
            columns[1].remove()
            columns[0].appendChild(moved)
            columns[0].displayMode = .tabbed
            columns[0].setActiveTileIdx(0)
        }
        let reconciler = controller.surfaceReconciler
        reconciler.reconcileNow()
        XCTAssertFalse(reconciler.appliedScene.tabRails.isEmpty)

        controller.workspaceManager.setHiddenState(hiddenState(.layoutTransient(.left)), for: tokens[0])

        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
    }

    func testFocusLeaseChangeSchedulesBorderOnlyAndReappliesParkingMasks() throws {
        let controller = startedController()
        let reconciler = controller.surfaceReconciler
        reconciler.reconcileNow()
        XCTAssertFalse(reconciler.appliedScene.parkingEdgeMasks.isEmpty)
        let masks = SurfaceCoordinator.shared.visibleSurfaceInfos().compactMap { $0.window as? ParkingEdgeMaskWindow }
        XCTAssertFalse(masks.isEmpty)
        masks.forEach { $0.orderOut(nil) }

        controller.focusPolicyEngine.beginLease(owner: .nativeMenu, reason: "test")

        XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
        XCTAssertTrue(masks.allSatisfy(\.isVisible))
    }

    func testBorderColorChangeSchedulesOnlyOneBorderPass() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        controller.surfaceReconciler.reconcileNow()
        controller.settings.borders.color = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)

        controller.borderSettingsChanged()

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testClearanceChangingBorderWidthSchedulesFullSceneAndLayout() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "SurfaceReconcileScopeTests")
        controller.settings.borders.enabled = true
        controller.settings.borders.width = 5
        controller.borderSettingsChanged()
        controller.surfaceReconciler.reconcileNow()
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
        controller.settings.borders.width = 6

        controller.borderSettingsChanged()

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .fullScene)
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.reason
                ?? controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutConfigChanged
        )
    }
}
