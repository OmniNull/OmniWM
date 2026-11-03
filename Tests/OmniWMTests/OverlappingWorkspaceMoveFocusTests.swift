// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class OverlappingWorkspaceMoveFocusTests: XCTestCase {
    func testHostedSelectionThenMoveKeepsSourceSiblingFocusRequest() async throws {
        let fixture = try HostedManagementFixture(layout: .niri, follows: false)
        defer { fixture.close() }
        let moving = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        try await exercise(
            controller: fixture.controller, moving: moving.token, sibling: sibling.token,
            source: fixture.source, destination: fixture.sourceOther
        ) {
            XCTAssertNotNil(fixture.controller.focusWindow(moving.token))
            fixture.manager.windowDidBecomeKey(
                Notification(name: NSWindow.didBecomeKeyNotification, object: moving.window)
            )
        }
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testAXSelectionThenMoveKeepsSourceSiblingFocusRequest() async throws {
        let fixture = try ExternalFixture()
        defer { fixture.close() }
        fixture.controller.layoutRefreshController.requestImmediateRelayout(
            reason: .workspaceTransition, affectedWorkspaceIds: [fixture.source]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertNotNil(fixture.controller.niriEngine?.findNode(for: fixture.moving, in: fixture.source))
        XCTAssertNotNil(fixture.controller.niriEngine?.findNode(for: fixture.sibling, in: fixture.source))

        try await exercise(
            controller: fixture.controller, moving: fixture.moving, sibling: fixture.sibling,
            source: fixture.source, destination: fixture.destination
        ) {
            XCTAssertNotNil(fixture.controller.focusWindow(fixture.moving))
            let handler = fixture.controller.axEventHandler
            let generation = handler.beginActivationObservation(
                pid: fixture.moving.pid, source: .focusedWindowChanged,
                causalGeneration: nil, controller: fixture.controller
            )
            handler.handleActivationFactsResolved(ActivationFacts(
                pid: fixture.moving.pid, source: .focusedWindowChanged, origin: .external,
                observationGeneration: generation, requestedAtSeq: fixture.controller.workspaceManager.worldSeq,
                focusedWindow: FocusedWindowFact(
                    axRef: try XCTUnwrap(fixture.controller.workspaceManager.entry(for: fixture.moving)?.axRef),
                    isFullscreen: false, isSystemModalSurface: false
                ),
                appVisibilityGeneration: fixture.controller.workspaceManager
                    .appVisibilityGeneration(for: fixture.moving.pid)
            ))
        }
        XCTAssertEqual(fixture.focusedTokens.last, fixture.sibling)
    }

    private func exercise(
        controller: WMController, moving: WindowToken, sibling: WindowToken,
        source: WorkspaceDescriptor.ID, destination: WorkspaceDescriptor.ID,
        select: () throws -> Void
    ) async throws {
        let world = controller.workspaceManager
        let refresh = controller.layoutRefreshController
        XCTAssertFalse(controller.settings.focus.followsWindowToMonitor)
        XCTAssertNil(refresh.layoutState.activeRefreshTask)
        try select()
        XCTAssertEqual(world.selectedManagedToken, moving)
        XCTAssertEqual(world.nativeManagedFocusToken, moving)
        XCTAssertEqual(refresh.layoutState.activeRefresh?.kind, .immediateRelayout)
        XCTAssertNotNil(refresh.layoutState.activeRefreshTask)
        XCTAssertNil(refresh.layoutState.pendingRefresh)
        let selectionIntent = controller.intentLedger.newestFocusIntentId()
        let targetName = try XCTUnwrap(world.descriptor(for: destination)?.name)
        controller.workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: targetName)
        XCTAssertEqual(world.workspace(for: moving), destination)
        XCTAssertEqual(refresh.layoutState.pendingRefresh?.kind, .immediateRelayout)
        let focusEpoch = world.worldSeq
        XCTAssertTrue(world.isSeqEpochCurrent(focusEpoch, domains: .focus))
        XCTAssertNil(world.hiddenState(for: moving))

        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(controller.activeWorkspace()?.id, source)
        XCTAssertEqual(world.workspace(for: sibling), source)
        XCTAssertNotNil(world.hiddenState(for: moving))
        let newest = controller.intentLedger.newestFocusIntentId()
        let token = newest.flatMap { controller.intentLedger.intent(id: $0)?.kind.focusTargetToken }
        print(
            "overlap target=\(moving) sibling=\(sibling) selection=\(String(describing: selectionIntent)) latest=\(String(describing: newest)) requested=\(String(describing: token)) focusEpochCurrent=\(world.isSeqEpochCurrent(focusEpoch, domains: .focus))"
        )
        XCTAssertNotEqual(newest, selectionIntent)
        XCTAssertEqual(token, sibling)
        XCTAssertEqual(world.pendingFocusedToken, sibling)
    }

    @MainActor
    private final class ExternalFixture {
        let controller: WMController
        let source: WorkspaceDescriptor.ID
        let destination: WorkspaceDescriptor.ID
        let moving = WindowToken(pid: 952_001, windowId: 952_101)
        let sibling = WindowToken(pid: 952_001, windowId: 952_102)
        var focusedTokens: [WindowToken] = []

        init() throws {
            var focused: ((WindowToken) -> Void)?
            controller = WindowAdmissionTestSupport.controller(
                prefix: "OverlappingWorkspaceMoveFocus",
                windowFocusOperations: WindowFocusOperations(
                    activateApp: { _ in },
                    focusSpecificWindow: { pid, id, _ in focused?(WindowToken(pid: pid, windowId: Int(id))) },
                    afterSubmittedFocus: { _ in }, raiseWindow: { _ in }
                )
            )
            controller.setAnimationsEnabled(false)
            controller.hasStartedServices = true
            controller.settings.focus.followsWindowToMonitor = false
            controller.settings.workspaces.defaultLayoutType = .niri
            controller.settings.workspaces.configurations = ["1", "2"].map {
                WorkspaceConfiguration(name: $0, monitorAssignment: .main, layoutType: .niri)
            }
            let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
            let monitor = Monitor(
                id: .init(displayId: .max), displayId: .max, frame: frame, visibleFrame: frame,
                hasNotch: false, name: "Overlapping Move Focus"
            )
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
            controller.workspaceManager.applySettings()
            source = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
            destination = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
            let engine = NiriLayoutEngine()
            engine.animationClock = controller.animationClock
            controller.niriEngine = engine
            controller.niriLayoutHandler.syncMonitorsToNiriEngine()
            XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(source, on: monitor.id))
            for token in [moving, sibling] {
                _ = WindowAdmissionTestSupport.track(token, in: source, controller: controller)
            }
            controller.layoutRefreshController.fastFrameProvider = { _, _ in frame }
            controller.layoutRefreshController.resetState()
            focused = { [weak self] in self?.focusedTokens.append($0) }
        }

        func close() {
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
            controller.deadlineWheel.stop()
        }
    }
}
