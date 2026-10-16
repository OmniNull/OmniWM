// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import QuartzCore
import XCTest

@MainActor
final class OverviewStructuralCommandTests: XCTestCase {
    func testEmptiedDynamicWorkspaceSurvivesOverviewUntilClose() async throws {
        let fixture = try makeFixture(layouts: [.niri])
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let configuredId = fixture.workspaceIds[0]
        defer {
            controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()
        }
        let dynamicId = try await emptyDynamicWorkspaceInOverview(fixture)

        controller.motionPolicy.animationsEnabled = true
        controller.windowActionHandler.dismissOverview()
        guard case .closing = controller.windowActionHandler.overviewState else {
            return XCTFail("Expected Overview to retain its closing presentation")
        }
        controller.layoutRefreshController.collectUnusedWorkspacesIfIdle()
        XCTAssertNotNil(manager.descriptor(for: dynamicId))

        controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()

        XCTAssertFalse(controller.isOverviewOpen())
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        XCTAssertNil(manager.descriptor(for: dynamicId))
        XCTAssertNotNil(manager.descriptor(for: configuredId))
    }

    func testEmptiedDynamicWorkspaceIsCollectedWhenOverviewClosesWithoutRefresh() async throws {
        let fixture = try makeFixture(layouts: [.niri])
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let configuredId = fixture.workspaceIds[0]
        defer {
            controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()
        }
        let dynamicId = try await emptyDynamicWorkspaceInOverview(fixture)
        let refresh = controller.layoutRefreshController
        XCTAssertNil(refresh.layoutState.activeRefreshTask)
        XCTAssertNil(refresh.layoutState.activeRefresh)
        XCTAssertNil(refresh.layoutState.pendingRefresh)

        controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()

        XCTAssertFalse(controller.isOverviewOpen())
        XCTAssertNil(refresh.layoutState.activeRefreshTask)
        XCTAssertNil(refresh.layoutState.activeRefresh)
        XCTAssertNil(refresh.layoutState.pendingRefresh)
        XCTAssertNil(manager.descriptor(for: dynamicId))
        XCTAssertNotNil(manager.descriptor(for: configuredId))
    }

    func testOverviewGuardExemptsOnlyToggleOverview() {
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.presentation(.overview), isOverviewOpen: true))
        XCTAssertTrue(CommandHandler.shouldIgnoreCommand(.column(.moveToFirst), isOverviewOpen: true))
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.column(.moveToFirst), isOverviewOpen: false))
    }

    func testNativeFullscreenWindowsGetCardsButRefuseDragAndStructuralMutation() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let fullscreen = try addManagedWindow(pid: 461_040, windowId: 40, to: workspaceId, fixture: fixture)
        _ = try addManagedWindow(pid: 461_040, windowId: 41, to: workspaceId, fixture: fixture)
        let workspaceManager = fixture.controller.workspaceManager
        XCTAssertTrue(workspaceManager.markNativeFullscreenSuspended(fullscreen.id, ownsNativeFocus: false))
        XCTAssertEqual(workspaceManager.nativeFullscreenRecord(for: fullscreen.id)?.transition, .suspended)
        let entry = try XCTUnwrap(workspaceManager.entry(for: fullscreen))

        var environment = OverviewEnvironment()
        environment.windowTitle = { "Window \($0.windowId)" }
        environment.windowFrame = { _ in CGRect(x: 0, y: 0, width: 400, height: 300) }
        let facts = OverviewWindowFacts(wmController: fixture.controller, environment: environment)
        XCTAssertTrue(facts.isOverviewEligible(entry, workspaceManager: workspaceManager))
        XCTAssertFalse(facts.isStructurallyMutable(entry))
        XCTAssertTrue(
            facts.makeOverviewWindowData(for: entry, preferredFrame: nil, appInfoCache: fixture.controller.appInfoCache)
                .isNativeFullscreen
        )

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        overview.drag.beginDrag(on: fixture.monitor.id, handle: fullscreen, startPoint: .zero)
        XCTAssertFalse(overview.hasActiveDragSession)
        XCTAssertEqual(
            overview.performStructuralHotkey(.workspace(.moveTo(1)), selectedHandle: fullscreen),
            .unchanged
        )
        XCTAssertEqual(workspaceManager.workspace(for: fullscreen.id), workspaceId)
    }

    func testNativeFullscreenSnapshotIncludesCardWithFullScreenCaption() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let fullscreen = try addManagedWindow(
            pid: 461_041, windowId: 42, to: fixture.workspaceIds[0], fixture: fixture
        )
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fullscreen.id, ownsNativeFocus: false))
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Fullscreen Document" }
        environment.windowFrame = { _ in CGRect(x: 100, y: 100, width: 600, height: 500) }
        let facts = OverviewWindowFacts(wmController: fixture.controller, environment: environment)
        let snapshot = OverviewSnapshot(wmController: fixture.controller, facts: facts)
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: fixture.controller, snapshot: snapshot, scale: 1)
        projection.rebuildProjectedLayouts()
        let layout = try XCTUnwrap(projection.layoutsByMonitor[fixture.monitor.id])
        let card = try XCTUnwrap(layout.window(for: fullscreen))
        XCTAssertTrue(card.isNativeFullscreen)
        XCTAssertEqual(card.workspaceId, fixture.workspaceIds[0])
        let layer = OverviewWindowLayer()
        layer.updateContent(card, contentsScale: 2)
        let captions = (layer.root.sublayers ?? []).flatMap { $0.sublayers ?? [] }
            .compactMap { ($0 as? CATextLayer)?.string as? String }
        XCTAssertTrue(captions.contains("Full Screen"))
        XCTAssertTrue(captions.contains("Fullscreen Document"))
    }

    func testOverviewActivationUsesNativeFullscreenOwner() async throws {
        let fixture = try makeFixture(layouts: [.niri])
        let fullscreen = try addManagedWindow(
            pid: 461_042, windowId: 43, to: fixture.workspaceIds[0], fixture: fixture
        )
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fullscreen.id, ownsNativeFocus: false))
        let focused = expectation(description: "Overview fronts the native fullscreen window")
        fixture.focusRecorder.onFocus = { focused.fulfill() }
        fixture.controller.toggleOverview()
        XCTAssertTrue(fixture.controller.isOverviewOpen())

        fixture.controller.windowActionHandler.dismissOverview()

        XCTAssertFalse(fixture.controller.isOverviewOpen())
        await fulfillment(of: [focused], timeout: 1)
        XCTAssertEqual(fixture.focusRecorder.activatedPIDs, [])
        XCTAssertEqual(fixture.focusRecorder.focusedTokens, [fullscreen.id])
        XCTAssertEqual(fixture.focusRecorder.raisedCount, 1)
        XCTAssertEqual(manager.nativeFullscreenRecord(for: fullscreen.id)?.transition, .suspended)
        XCTAssertEqual(manager.layoutReason(for: fullscreen.id), .nativeFullscreen)
        XCTAssertEqual(manager.selectedManagedToken, fullscreen.id)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }

    func testPerformCommandToggleOverviewClosesOpenOverview() throws {
        let fixture = try makeFixture(layouts: [.niri])
        _ = try addManagedWindow(pid: 461_030, windowId: 30, to: fixture.workspaceIds[0], fixture: fixture)
        fixture.controller.toggleOverview()
        defer {
            if fixture.controller.isOverviewOpen() {
                fixture.controller.toggleOverview()
            }
        }
        XCTAssertTrue(fixture.controller.isOverviewOpen())

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.column(.moveToFirst)), .ignoredOverview)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.presentation(.overview)), .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())

        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        XCTAssertEqual(router.handle(IPCCommandRequest.presentation(.overview)), .executed)
        XCTAssertTrue(fixture.controller.isOverviewOpen())
        XCTAssertEqual(router.handle(IPCCommandRequest.column(.moveToFirst)), .ignoredOverview)
        XCTAssertEqual(router.handle(IPCCommandRequest.presentation(.overview)), .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
    }

    private final class FocusRecorder {
        var activatedPIDs: [pid_t] = []
        var focusedTokens: [WindowToken] = []
        var raisedCount = 0
        var onFocus: (() -> Void)?

        var callCount: Int {
            activatedPIDs.count + focusedTokens.count + raisedCount
        }
    }

    private struct Fixture {
        let controller: WMController
        let workspaceIds: [WorkspaceDescriptor.ID]
        let monitor: Monitor
        let focusRecorder: FocusRecorder
    }

    func testUnassignableConsumeOrExpelCommandsHaveNoOverviewRouting() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let selected = try addManagedWindow(
            pid: 461_020,
            windowId: 22,
            to: fixture.workspaceIds[0],
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let cases = [
            ("consumeOrExpelWindowLeft", HotkeyCommand.windowMovement(.consumeOrExpelLeft)),
            ("consumeOrExpelWindowRight", .windowMovement(.consumeOrExpelRight))
        ]

        for (id, command) in cases {
            XCTAssertNil(HotkeyBindingRegistry.command(for: id))
            XCTAssertNil(
                overview.performStructuralHotkey(command, selectedHandle: selected)
            )
        }
    }

    func testSelectedOverviewHandleMovesInsteadOfLiveFocusedHandle() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(pid: 461_001, windowId: 1, to: workspaceId, fixture: fixture)
        let liveFocused = try addManagedWindow(pid: 461_001, windowId: 2, to: workspaceId, fixture: fixture)
        let trailing = try addManagedWindow(pid: 461_001, windowId: 3, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(liveFocused.id, in: workspaceId))

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.column(.moveToLast), selectedHandle: selected)
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [liveFocused.id, trailing.id, selected.id]
        )
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.controller.workspaceManager.lastFocusedToken(in: workspaceId), selected.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testSelectedOverviewHandleMovesToActiveAdjacentMonitorWorkspaceWithoutAXFocus() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let targetFrame = CGRect(x: 1600, y: 0, width: 1600, height: 900)
        let targetMonitor = Monitor(
            id: .init(displayId: 46_101),
            displayId: 46_101,
            frame: targetFrame,
            visibleFrame: targetFrame,
            hasNotch: false,
            name: "Overview Structural Target"
        )
        fixture.controller.settings.workspaces.configurations.append(contentsOf: [
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            )
        ])
        fixture.controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, targetMonitor])
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let inactiveTargetWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        let activeTargetWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "3")
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(
                inactiveTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(
                activeTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: fixture.monitor.id)
        )

        let selected = try addManagedWindow(
            pid: 461_017,
            windowId: 20,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let liveFocused = try addManagedWindow(
            pid: 461_017,
            windowId: 21,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                liveFocused.id,
                in: sourceWorkspaceId,
                onMonitor: fixture.monitor.id
            )
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = withBlockedLayoutRefreshes(fixture) {
            overview.executeStructuralHotkey(
                .workspace(.moveToMonitor(.right)),
                selectedHandle: selected
            )
        }
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, activeTargetWorkspaceId)
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: selected.id),
            activeTargetWorkspaceId
        )
        XCTAssertNotEqual(
            fixture.controller.workspaceManager.workspace(for: selected.id),
            inactiveTargetWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: liveFocused.id),
            sourceWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, targetMonitor.id)
        XCTAssertEqual(overview.selectedWindowHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testPhysicalStructuralRoutingBlocksTriggerlessAndUnsupportedCommands() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(pid: 461_016, windowId: 18, to: workspaceId, fixture: fixture)
        let trailing = try addManagedWindow(pid: 461_016, windowId: 19, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(selected.id, in: workspaceId))

        fixture.controller.toggleOverview()
        defer {
            if fixture.controller.isOverviewOpen() {
                fixture.controller.toggleOverview()
            }
        }
        XCTAssertTrue(fixture.controller.isOverviewOpen())

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .column(.moveToLast),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )
        XCTAssertEqual(
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [trailing.id, selected.id]
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.column(.moveToFirst)),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.column(.moveToFirst)),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .fullscreen(.managed),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .workspace(.moveToMonitor(.right)),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .workspace(.moveWorkspaceToMonitor(.right)),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .ignoredOverview
        )
    }

    func testCoalescedStructuralActionsRefreshUnionOfAffectedWorkspacesOnce() async throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let firstWorkspaceId = fixture.workspaceIds[0]
        let secondWorkspaceId = fixture.workspaceIds[1]
        let firstSelected = try addManagedWindow(
            pid: 461_014,
            windowId: 14,
            to: firstWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_014,
            windowId: 15,
            to: firstWorkspaceId,
            fixture: fixture
        )
        let secondSelected = try addManagedWindow(
            pid: 461_015,
            windowId: 16,
            to: secondWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_015,
            windowId: 17,
            to: secondWorkspaceId,
            fixture: fixture
        )
        var refreshedWorkspaceSets: [Set<WorkspaceDescriptor.ID>] = []
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Window" }
        environment.windowFrame = { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        environment.onCachedProjectionRefreshed = { refreshedWorkspaceSets.append($0) }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)

        XCTAssertTrue(
            overview.executeStructuralHotkey(
                .column(.moveToLast),
                selectedHandle: firstSelected
            )?.didMutate == true
        )
        XCTAssertTrue(
            overview.executeStructuralHotkey(
                .column(.moveToLast),
                selectedHandle: secondSelected
            )?.didMutate == true
        )

        for _ in 0 ..< 100
            where fixture.controller.layoutRefreshController.layoutState.activeRefreshTask != nil
            || fixture.controller.layoutRefreshController.layoutState.pendingRefresh != nil
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(refreshedWorkspaceSets.count, 1)
        XCTAssertEqual(refreshedWorkspaceSets.first, [firstWorkspaceId, secondWorkspaceId])
    }

    func testCompletedWorkspaceTransferActivatesDestinationWithoutAXFocus() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_002,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let liveFocused = try addManagedWindow(
            pid: 461_002,
            windowId: 2,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_003,
            windowId: 1,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                liveFocused.id,
                in: sourceWorkspaceId,
                onMonitor: fixture.monitor.id
            )
        )

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = withBlockedLayoutRefreshes(fixture) {
            overview.executeStructuralHotkey(.workspace(.moveTo(1)), selectedHandle: selected)
        }
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            destinationWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.monitor.id)
        XCTAssertEqual(overview.selectedWindowHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testFloatingWindowTransfersAcrossNiriWorkspaces() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let pid = pid_t(461_010)
        let windowId = 10
        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: sourceWorkspaceId,
            mode: .floating
        )
        let selected = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: token))
        XCTAssertNil(fixture.controller.niriEngine?.findNode(for: token, in: sourceWorkspaceId))

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.workspace(.moveTo(1)), selectedHandle: selected)
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.windowMode(for: token), .floating)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFloatingFocusedToken(in: destinationWorkspaceId),
            token
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testNiriStructuralNoOpPreservesOrderingAndRememberedFocus() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_004, windowId: 1, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_004, windowId: 2, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(second.id, in: workspaceId))
        let originalOrder = engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.column(.moveToFirst), selectedHandle: first)

        XCTAssertEqual(outcome, StructuralMutationOutcome.unchanged)
        XCTAssertEqual(engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }, originalOrder)
        XCTAssertEqual(fixture.controller.workspaceManager.lastFocusedToken(in: workspaceId), second.id)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, second.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testHiddenWindowCannotExecuteOverviewStructuralHotkey() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        _ = try addManagedWindow(pid: 461_030, windowId: 40, to: workspaceId, fixture: fixture)
        let selected = try addManagedWindow(
            pid: 461_031,
            windowId: 41,
            to: workspaceId,
            fixture: fixture
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let originalColumns = engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: selected.pid,
            source: .service
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .column(.moveToFirst),
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            originalColumns
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testCombinedVerticalMoveCreatesAdjacentWorkspaceAtEdge() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_009,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))

        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.moveWindow(handle: selected, direction: .down),
            .atWorkspaceEdge
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .windowMovement(.downOrToWorkspaceDown),
            selectedHandle: selected
        )
        let createdWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: createdWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeLayoutKind(for: createdWorkspaceId),
            .niri
        )
        let mutation = try XCTUnwrap(outcome?.mutation)
        let destinationWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: destinationWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testWholeColumnTransferPreservesSelectedMemberAndMembership() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_005,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let stacked = try addManagedWindow(
            pid: 461_005,
            windowId: 2,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let sourceRemainder = try addManagedWindow(
            pid: 461_005,
            windowId: 3,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_006,
            windowId: 1,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.niriLayoutHandler.consumeOrExpelWindow(
                handle: stacked,
                direction: .left
            ).didMutate
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let sourceSelectedNode = try XCTUnwrap(engine.findNode(for: selected, in: sourceWorkspaceId))
        let sourceColumn = try XCTUnwrap(
            engine.findColumn(containing: sourceSelectedNode, in: sourceWorkspaceId)
        )
        XCTAssertEqual(Set(sourceColumn.windowNodes.map(\.token)), [selected.id, stacked.id])

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .column(.moveToWorkspace(1)),
            selectedHandle: selected
        )
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: stacked.id), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: sourceRemainder.id), sourceWorkspaceId)
        XCTAssertNil(engine.findNode(for: selected, in: sourceWorkspaceId))
        XCTAssertNil(engine.findNode(for: stacked, in: sourceWorkspaceId))
        let destinationSelectedNode = try XCTUnwrap(engine.findNode(for: selected, in: destinationWorkspaceId))
        let destinationColumn = try XCTUnwrap(
            engine.findColumn(containing: destinationSelectedNode, in: destinationWorkspaceId)
        )
        XCTAssertEqual(Set(destinationColumn.windowNodes.map(\.token)), [selected.id, stacked.id])
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: destinationWorkspaceId).selectedNodeId,
            destinationSelectedNode.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
    }

    func testDwindleSourceRejectsWholeColumnTransfer() throws {
        let fixture = try makeFixture(layouts: [.dwindle, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_007,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let dwindleEngine = try XCTUnwrap(fixture.controller.dwindleEngine)

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .column(.moveToWorkspace(1)),
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, StructuralMutationOutcome.unchanged)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), sourceWorkspaceId)
        XCTAssertNotNil(dwindleEngine.findNode(for: selected.id, in: sourceWorkspaceId))
        XCTAssertNil(dwindleEngine.findNode(for: selected.id, in: destinationWorkspaceId))
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testDwindleOverviewRejectsMoveAndMoveContainerInEveryDirection() throws {
        let fixture = try makeFixture(layouts: [.dwindle])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_025, windowId: 31, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_025, windowId: 32, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        _ = fixture.controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.calculateLayout(for: workspaceId, screen: fixture.monitor.visibleFrame)
        }
        let firstNode = try XCTUnwrap(engine.findNode(for: first.id, in: workspaceId))
        let secondNode = try XCTUnwrap(engine.findNode(for: second.id, in: workspaceId))
        let parent = try XCTUnwrap(firstNode.parent)
        XCTAssertEqual(secondNode.parent?.id, parent.id)
        let originalChildIds = parent.children.map(\.id)
        let originalFirstTile = try XCTUnwrap(engine.tileSnapshot(for: first.id, in: workspaceId))
        let originalSecondTile = try XCTUnwrap(engine.tileSnapshot(for: second.id, in: workspaceId))
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let assertUnchanged = {
            XCTAssertEqual(parent.children.map(\.id), originalChildIds)
            XCTAssertEqual(engine.tileSnapshot(for: first.id, in: workspaceId), originalFirstTile)
            XCTAssertEqual(engine.tileSnapshot(for: second.id, in: workspaceId), originalSecondTile)
            XCTAssertEqual(engine.tileCount(in: workspaceId), 2)
        }

        for direction in [Direction.left, .right, .up, .down] {
            XCTAssertEqual(
                overview.performStructuralHotkey(.move(direction), selectedHandle: second),
                .unchanged,
                direction.rawValue
            )
            assertUnchanged()
            XCTAssertEqual(
                overview.performStructuralHotkey(.moveColumn(direction), selectedHandle: second),
                .unchanged,
                direction.rawValue
            )
            assertUnchanged()
        }

        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testFloatingColumnMoveNoOpDoesNotCreateAdjacentWorkspace() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let pid = pid_t(461_011)
        let windowId = 11
        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let selected = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: token))
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .column(.moveToWorkspaceDown),
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), workspaceId)
    }

    func testColumnMoveDoesNotCreateIncompatibleDynamicWorkspace() throws {
        let fixture = try makeFixture(layouts: [.niri])
        fixture.controller.settings.workspaces.defaultLayoutType = .dwindle
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_012,
            windowId: 12,
            to: workspaceId,
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .column(.moveToWorkspaceDown),
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), workspaceId)
    }

    func testAdjacentCreationSkipsNumericWorkspaceOnAnotherMonitor() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let secondary = Monitor(
            id: .init(displayId: 46_101),
            displayId: 46_101,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Overview Structural Secondary"
        )
        fixture.controller.settings.workspaces.configurations.append(
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary, layoutType: .niri)
        )
        fixture.controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, secondary])
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let secondaryWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: secondaryWorkspaceId),
            secondary.id
        )
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_013,
            windowId: 13,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .windowMovement(.downOrToWorkspaceDown),
            selectedHandle: selected
        )
        let mutation = try XCTUnwrap(outcome?.mutation)
        let destinationWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "3")
        )

        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: destinationWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
    }

    func testRemovalCallbackObservesAuthoritativeWindowRemoval() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let handle = try addManagedWindow(pid: 461_008, windowId: 1, to: workspaceId, fixture: fixture)
        let manager = fixture.controller.workspaceManager
        var callbackTokens: [WindowToken] = []
        var callbackEntryWasPresent = true
        var callbackWorkspaceWasPresent = true
        manager.onWindowRemoved = { entry in
            callbackTokens.append(entry.token)
            callbackEntryWasPresent = manager.entry(for: entry.token) != nil
            callbackWorkspaceWasPresent = manager.workspace(for: entry.token) != nil
        }
        defer { manager.onWindowRemoved = nil }

        let removed = manager.removeWindow(pid: handle.id.pid, windowId: handle.id.windowId)

        XCTAssertEqual(removed?.token, handle.id)
        XCTAssertEqual(callbackTokens, [handle.id])
        XCTAssertFalse(callbackEntryWasPresent)
        XCTAssertFalse(callbackWorkspaceWasPresent)
        XCTAssertNil(manager.entry(for: handle.id))
        XCTAssertNil(manager.workspace(for: handle.id))
    }

    func testHiddenWindowCannotBeginOverviewDrag() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let handle = try addManagedWindow(
            pid: 461_032,
            windowId: 42,
            to: workspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: handle.pid,
            source: .service
        )

        prepared.overview.drag.beginDrag(
            on: fixture.monitor.id,
            handle: handle,
            startPoint: .zero
        )

        XCTAssertFalse(prepared.overview.hasActiveDragSession)
    }

    func testDragDoesNotMutateAfterDraggedApplicationBecomesHidden() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(
            pid: 461_033,
            windowId: 43,
            to: workspaceId,
            fixture: fixture
        )
        let dragged = try addManagedWindow(
            pid: 461_034,
            windowId: 44,
            to: workspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.maxY - targetFrame.height * 0.1
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let originalColumns = engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }

        prepared.overview.drag.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
        prepared.overview.drag.updateDrag(on: fixture.monitor.id, at: dropPoint)
        XCTAssertTrue(prepared.overview.hasActiveDragSession)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: dragged.pid,
            source: .service
        )
        prepared.overview.drag.endDrag(on: fixture.monitor.id, at: dropPoint)

        XCTAssertFalse(prepared.overview.hasActiveDragSession)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            originalColumns
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriCardBeforeTarget() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(pid: 461_020, windowId: 20, to: workspaceId, fixture: fixture)
        _ = try addManagedWindow(pid: 461_020, windowId: 21, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_020, windowId: 22, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.maxY - targetFrame.height * 0.1
        )

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.drag.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.drag.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.drag.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let targetNode = try XCTUnwrap(engine.findNode(for: target, in: workspaceId))
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: targetNode, in: workspaceId))
        XCTAssertEqual(
            targetColumn.windowNodes.map(\.token),
            [target.id, dragged.id]
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriCardAfterTarget() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(pid: 461_021, windowId: 23, to: workspaceId, fixture: fixture)
        _ = try addManagedWindow(pid: 461_021, windowId: 24, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_021, windowId: 25, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.minY + targetFrame.height * 0.1
        )

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.drag.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.drag.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.drag.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let targetNode = try XCTUnwrap(engine.findNode(for: target, in: workspaceId))
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: targetNode, in: workspaceId))
        XCTAssertEqual(
            targetColumn.windowNodes.map(\.token),
            [dragged.id, target.id]
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriWindowAtExactColumnGap() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_022, windowId: 26, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_022, windowId: 27, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_022, windowId: 28, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let gap = try XCTUnwrap(
            prepared.layout.niriColumnDropZonesByWorkspace[workspaceId]?
                .first(where: { $0.insertIndex == 1 })
        )
        let dropPoint = CGPoint(x: gap.frame.midX, y: gap.frame.midY)

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.drag.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.drag.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.drag.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            [[first.id], [dragged.id], [second.id]]
        )
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragOntoDwindleCardUsesWorkspaceOnlyPlacement() async throws {
        let fixture = try makeFixture(layouts: [.dwindle, .dwindle])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let dragged = try addManagedWindow(
            pid: 461_023,
            windowId: 29,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let destination = try addManagedWindow(
            pid: 461_024,
            windowId: 30,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        let destinationFrame = try XCTUnwrap(prepared.layout.window(for: destination)?.overviewFrame)
        let dropPoint = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)

        prepared.overview.drag.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
        prepared.overview.drag.updateDrag(on: fixture.monitor.id, at: dropPoint)
        prepared.overview.drag.endDrag(on: fixture.monitor.id, at: dropPoint)
        try await waitForLayoutRefreshes(fixture)

        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        XCTAssertNil(engine.findNode(for: dragged.id, in: sourceWorkspaceId))
        XCTAssertNotNil(engine.findNode(for: dragged.id, in: destinationWorkspaceId))
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: dragged.id),
            destinationWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            destinationWorkspaceId
        )
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testDeferredColumnInsertIndexPreservesOriginalGap() {
        XCTAssertEqual(
            OverviewStructuralActions.deferredColumnInsertIndex(
                requestedIndex: 0,
                admittedColumnIndex: 2
            ),
            0
        )
        XCTAssertEqual(
            OverviewStructuralActions.deferredColumnInsertIndex(
                requestedIndex: 1,
                admittedColumnIndex: 0
            ),
            2
        )
        XCTAssertEqual(
            OverviewStructuralActions.deferredColumnInsertIndex(
                requestedIndex: 1,
                admittedColumnIndex: 1
            ),
            1
        )
        XCTAssertEqual(
            OverviewStructuralActions.deferredColumnInsertIndex(
                requestedIndex: 3,
                admittedColumnIndex: 0
            ),
            4
        )
        XCTAssertEqual(
            OverviewStructuralActions.deferredColumnInsertIndex(
                requestedIndex: 3,
                admittedColumnIndex: nil
            ),
            3
        )
    }

    func testOverviewSelectionSettlesOffViewportDestinationBeforeRelayout() async throws {
        for targetLayout in [LayoutType.niri, .dwindle] {
            let fixture = try makeFixture(layouts: [.niri, targetLayout])
            let controller = fixture.controller
            let manager = controller.workspaceManager
            let source = fixture.workspaceIds[0]
            let destination = fixture.workspaceIds[1]
            _ = try addManagedWindow(pid: 461_050, windowId: 50, to: source, fixture: fixture)
            var handles: [WindowHandle] = []
            for index in 0 ..< 4 {
                handles.append(try addManagedWindow(
                    pid: 461_051, windowId: 51 + index, to: destination, fixture: fixture
                ))
            }
            let refresh = controller.layoutRefreshController
            refresh.requestImmediateRelayout(reason: .overviewMutation, affectedWorkspaceIds: Set(fixture.workspaceIds))
            while let task = refresh.layoutState.activeRefreshTask { await task.value }
            let target = try XCTUnwrap(handles.last)
            let parked = CGRect(x: -20000, y: -20000, width: 500, height: 400)
            var environment = OverviewEnvironment()
            environment.windowTitle = { _ in "Window" }
            environment.windowFrame = { _ in parked }
            environment.activateOmniWM = {}
            environment.schedulePostCloseHandoff = { _ in }
            controller.motionPolicy.animationsEnabled = true
            let overview = OverviewController(
                wmController: controller,
                motionPolicy: controller.motionPolicy,
                environment: environment,
                animationInstaller: { _, _, _ in true },
                animationMediaTimeProvider: { 0 }
            )
            overview.onPrepareActivation = controller.windowActionHandler.prepareOverviewSelection
            overview.open()
            overview.onAnimationComplete(state: .open)
            let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
                .compactMap { $0 as? OverviewView }.first)
            if targetLayout == .niri {
                XCTAssertEqual(view.layout.window(for: target)?.originalFrame, parked)
            }
            let watermark = controller.intentLedger.newestFocusIntentId()

            overview.input.selectAndActivateWindow(target)

            guard case .closing = overview.state else { return XCTFail("Expected close before relayout runs") }
            let request = try XCTUnwrap(refresh.layoutState.activeRefresh ?? refresh.layoutState.pendingRefresh)
            XCTAssertEqual(request.reason, .overviewMutation)
            XCTAssertEqual(request.affectedWorkspaceIds, [source, destination])
            XCTAssertEqual(manager.activeWorkspace(on: fixture.monitor.id)?.id, destination)
            let restFrame = try XCTUnwrap(view.layout.window(for: target)?.interpolatedFrame(progress: 0))
            XCTAssertTrue(fixture.monitor.frame.intersects(restFrame))
            XCTAssertEqual(view.layout.anchorWorkspaceId, destination)
            XCTAssertFalse(manager.niriViewportState(for: destination).hasPendingOffsetAnimation)
            XCTAssertFalse(manager.animationDriver.hasMotion(in: destination))
            XCTAssertEqual(fixture.focusRecorder.callCount, 0)

            while let task = refresh.layoutState.activeRefreshTask { await task.value }

            let frames = targetLayout == .niri
                ? controller.niriEngine?.captureWindowFrames(in: destination)
                : controller.dwindleEngine?.calculateLayout(
                    for: destination,
                    screen: controller.insetWorkingFrame(for: fixture.monitor)
                )
            XCTAssertEqual(restFrame, frames?[target.id])
            XCTAssertEqual(view.layout.window(for: target)?.interpolatedFrame(progress: 0), restFrame)
            XCTAssertEqual(controller.intentLedger.newestFocusIntentId(), watermark)
            XCTAssertEqual(fixture.focusRecorder.callCount, 0)
            overview.completeCloseTransition(targetWindow: nil)
        }
    }

    func testOverviewSelectionSettlesExistingReorderAndViewportMotion() async throws {
        let fixture = try makeFixture(layouts: [.niri])
        let controller = fixture.controller
        let workspaceId = fixture.workspaceIds[0]
        var handles: [WindowHandle] = []
        for index in 0 ..< 4 {
            handles.append(try addManagedWindow(pid: 461_060, windowId: 60 + index, to: workspaceId, fixture: fixture))
        }
        let refresh = controller.layoutRefreshController
        refresh.requestImmediateRelayout(reason: .overviewMutation, affectedWorkspaceIds: [workspaceId])
        while let task = refresh.layoutState.activeRefreshTask { await task.value }
        let target = try XCTUnwrap(handles.last)
        let prepared = try prepareDragOverview(fixture)
        let overview = prepared.overview
        controller.motionPolicy.animationsEnabled = true
        let engine = try XCTUnwrap(controller.niriEngine)
        overview.onPrepareActivation = controller.windowActionHandler.prepareOverviewSelection
        refresh.displayLinkActivationForTests = { _ in true }

        XCTAssertTrue(overview.executeStructuralHotkey(.column(.moveToFirst), selectedHandle: target)?
            .didMutate == true)
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        var previous = state
        previous.viewOffset -= 200
        var spring = state
        spring.springOffset(to: state.viewOffset)
        controller.workspaceManager.animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId, previous: previous, next: state, transition: spring.offsetTransition
        )
        XCTAssertTrue(controller.workspaceManager.animationDriver.hasMotion(in: workspaceId))

        overview.dismiss(reason: .selection, targetWindow: target, animated: false)

        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId))
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: workspaceId))
        XCTAssertFalse(controller.workspaceManager.niriViewportState(for: workspaceId).hasPendingOffsetAnimation)
        let settled = try XCTUnwrap(controller.niriLayoutHandler.settledFrames(in: workspaceId)?[target.id])
        while let task = refresh.layoutState.activeRefreshTask { await task.value }
        XCTAssertEqual(engine.captureWindowFrames(in: workspaceId)[target.id], settled)
    }

    func testConsumeAndExpelPreserveOverviewViewportInBothOrientations() async throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeFixture(layouts: [.niri, .niri, .niri])
            let controller = fixture.controller
            let workspaceId = fixture.workspaceIds[1]
            controller.settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(monitorName: fixture.monitor.name, orientation: orientation),
                for: fixture.monitor
            )
            controller.syncMonitorsToNiriEngine()
            var handles: [WindowHandle] = []
            for index in 0 ..< 8 {
                handles.append(try addManagedWindow(
                    pid: 461_080, windowId: 80 + index, to: workspaceId, fixture: fixture
                ))
            }
            let destination = fixture.workspaceIds[2]
            for index in 0 ..< 2 {
                _ = try addManagedWindow(pid: 461_081, windowId: 90 + index, to: destination, fixture: fixture)
            }
            let selected = handles[1]
            let stationary = handles[0]
            XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: fixture.monitor.id))
            XCTAssertTrue(controller.workspaceManager.setManagedFocus(selected.id, in: workspaceId))
            let refresh = controller.layoutRefreshController
            refresh.requestImmediateRelayout(reason: .overviewMutation, affectedWorkspaceIds: [workspaceId])
            while let task = refresh.layoutState.activeRefreshTask { await task.value }
            let overview = try prepareDragOverview(fixture).overview
            overview.windowSession.createWindows(controller: overview, monitors: [fixture.monitor], palette: .default)
            overview.windowSession.updateWindowDisplays(state: .open)
            defer { overview.windowSession.closeWindows() }
            let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
                .compactMap { $0 as? OverviewView }.first)
            overview.input.selectTab(selected, on: fixture.monitor.id)
            overview.input.adjustScrollOffset(by: -80, on: fixture.monitor.id)
            let ribbon = try XCTUnwrap(view.layout.workspaceSections.first { $0.workspaceId == workspaceId })
            overview.input.panStrip(
                at: CGPoint(x: ribbon.ribbonFrame.midX, y: ribbon.ribbonFrame.midY - view.layout.scrollOffset),
                by: 30,
                on: fixture.monitor.id
            )
            let axis = OverviewRibbonAxis(orientation)
            for command in [
                HotkeyCommand.windowMovement(.consumeIntoColumn),
                .windowMovement(.expelFromColumn),
                .column(.moveToLast)
            ] {
                let before = view.layout
                let beforeFrame = try XCTUnwrap(before.window(for: stationary)?.overviewFrame)
                XCTAssertTrue(overview.executeStructuralHotkey(command, selectedHandle: selected)?.didMutate == true)
                while let task = refresh.layoutState.activeRefreshTask { await task.value }
                let afterFrame = try XCTUnwrap(view.layout.window(for: stationary)?.overviewFrame)

                XCTAssertEqual(
                    view.layout.scrollOffset,
                    before.scrollOffset,
                    accuracy: 0.001,
                    "\(orientation), \(command)"
                )
                XCTAssertEqual(
                    axis.minimum(afterFrame),
                    axis.minimum(beforeFrame),
                    accuracy: 0.001,
                    "\(orientation), \(command)"
                )
                XCTAssertEqual(
                    view.layout.workspaceSections.map(\.ribbonFrame),
                    before.workspaceSections.map(\.ribbonFrame)
                )
                XCTAssertEqual(overview.selectedWindowHandle, selected)
                let snapshot = try XCTUnwrap(controller.niriLayoutHandler.overviewSnapshot(for: workspaceId)?.strip)
                let viewportOrigin = snapshot.viewportPosition - (view.layout.stripPanByWorkspace[workspaceId] ?? 0)
                overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [workspaceId], revealingSelection: false)
                XCTAssertEqual(
                    snapshot.viewportPosition - (view.layout.stripPanByWorkspace[workspaceId] ?? 0),
                    viewportOrigin,
                    accuracy: 0.001
                )
            }
            XCTAssertNotEqual(view.layout.stripPanRevealing(selected), 0)
            overview.input.selectTab(selected, on: fixture.monitor.id)
            XCTAssertEqual(view.layout.stripPanRevealing(selected), 0, accuracy: 0.001)
            let sourceScrollOffset = view.layout.scrollOffset

            XCTAssertTrue(overview.executeStructuralHotkey(.workspace(.moveTo(2)), selectedHandle: selected)?
                .didMutate == true)
            XCTAssertTrue(overview.executeStructuralHotkey(.column(.moveToFirst), selectedHandle: selected)?
                .didMutate == true)
            while let task = refresh.layoutState.activeRefreshTask { await task.value }

            let movedFrame = try XCTUnwrap(view.layout.window(for: selected)?.overviewFrame)
            XCTAssertEqual(view.layout.window(for: selected)?.workspaceId, destination)
            XCTAssertNotEqual(view.layout.scrollOffset, sourceScrollOffset)
            XCTAssertEqual(
                view.layout.scrollOffset,
                OverviewLayoutCalculator.scrollOffsetRevealing(
                    targetFrame: movedFrame,
                    currentOffset: view.layout.scrollOffset,
                    layout: view.layout,
                    screenFrame: OverviewLayoutCalculator.viewportFrame(for: fixture.monitor.frame)
                ),
                accuracy: 0.001
            )
        }
    }

    private func emptyDynamicWorkspaceInOverview(_ fixture: Fixture) async throws -> WorkspaceDescriptor.ID {
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let configuredId = fixture.workspaceIds[0]
        let dynamic = try XCTUnwrap(manager.createDynamicWorkspace(named: "2", on: fixture.monitor.id))
        controller.syncMonitorsToNiriEngine()
        let moved = try addManagedWindow(pid: 461_050, windowId: 50, to: dynamic.id, fixture: fixture)
        XCTAssertTrue(manager.setActiveWorkspace(dynamic.id, on: fixture.monitor.id))
        XCTAssertTrue(manager.setManagedFocus(moved.id, in: dynamic.id, onMonitor: fixture.monitor.id))
        controller.toggleOverview()
        XCTAssertTrue(controller.isOverviewOpen())

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .workspace(.moveTo(0)),
                    trigger: PhysicalHotkeyTrigger(keyCode: 18, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }

        XCTAssertEqual(manager.workspace(for: moved.id), configuredId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitor.id)?.id, configuredId)
        XCTAssertEqual(manager.windowQueries.windowCount(in: dynamic.id), 0)
        XCTAssertNotNil(manager.descriptor(for: dynamic.id))
        XCTAssertTrue(controller.isOverviewOpen())
        return dynamic.id
    }

    private func makeFixture(layouts: [LayoutType]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewStructuralCommandTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.workspaces.configurations = layouts.enumerated().map { index, layout in
            WorkspaceConfiguration(name: String(index + 1), monitorAssignment: .main, layoutType: layout)
        }
        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { focusRecorder.activatedPIDs.append($0) },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                    focusRecorder.onFocus?()
                },
                raiseWindow: { _ in focusRecorder.raisedCount += 1 }
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 46_100),
            displayId: 46_100,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Overview Structural Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()

        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()

        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine

        let workspaceIds = try layouts.indices.map { index in
            try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: String(index + 1), createIfMissing: false)
            )
        }
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceIds[0], on: monitor.id))

        return Fixture(
            controller: controller,
            workspaceIds: workspaceIds,
            monitor: monitor,
            focusRecorder: focusRecorder
        )
    }

    private func prepareDragOverview(
        _ fixture: Fixture
    ) throws -> (overview: OverviewController, layout: OverviewLayout) {
        let workspaceManager = fixture.controller.workspaceManager
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]
        var framesByToken: [WindowToken: CGRect] = [:]

        for monitor in workspaceManager.monitors {
            let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
            for workspace in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append(OverviewWorkspaceLayoutItem(
                    id: workspace.id,
                    name: workspace.name,
                    isActive: workspace.id == activeWorkspaceId
                ))
                for entry in workspaceManager.entries(in: workspace.id) {
                    guard let handle = workspaceManager.handle(for: entry.token) else { continue }
                    let ordinal = CGFloat(entry.windowId % 10)
                    let frame = CGRect(
                        x: 50 + ordinal * 20,
                        y: 80 + ordinal * 15,
                        width: 520,
                        height: 360
                    )
                    framesByToken[entry.token] = frame
                    windowData[handle] = OverviewWindowLayoutData(
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        title: "Window \(entry.windowId)",
                        appName: "Test",
                        appIcon: nil,
                        frame: frame
                    )
                }
            }
        }

        var environment = OverviewEnvironment()
        environment.windowTitle = { "Window \($0.windowId)" }
        environment.windowFrame = { framesByToken[$0.token] }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)

        var niriSnapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        for workspaceId in fixture.workspaceIds
            where workspaceManager.activeLayoutKind(for: workspaceId) == .niri
        {
            niriSnapshots[workspaceId] = fixture.controller.niriLayoutHandler.overviewSnapshot(for: workspaceId)
        }
        let layout = OverviewLayoutCalculator(
            screenFrame: OverviewLayoutCalculator.viewportFrame(for: fixture.monitor.frame),
            scale: OverviewLayoutCalculator.clampedScale(
                CGFloat(fixture.controller.settings.overview.zoom)
            )
        ).calculateLayout(
            workspaces: workspaces,
            windows: windowData,
            niriSnapshotsByWorkspace: niriSnapshots,
            searchQuery: ""
        )
        return (overview, layout)
    }

    private func waitForLayoutRefreshes(_ fixture: Fixture) async throws {
        let refreshController = fixture.controller.layoutRefreshController
        for _ in 0 ..< 200 {
            if refreshController.layoutState.activeRefreshTask == nil,
               refreshController.layoutState.pendingRefresh == nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Layout refreshes did not settle")
    }

    private func addManagedWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws -> WindowHandle {
        let controller = fixture.controller
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(
                    token: token,
                    to: workspaceId,
                    activeWindowFrame: nil
                )
            }
        }
        return try XCTUnwrap(controller.workspaceManager.handle(for: token))
    }

    private func withBlockedLayoutRefreshes<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = fixture.controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .overviewMutation,
            affectedWorkspaceIds: [fixture.workspaceIds[0]]
        )
        defer {
            blocker.cancel()
            refreshController.layoutState.activeRefreshTask = nil
            refreshController.layoutState.activeRefresh = nil
            refreshController.layoutState.pendingRefresh = nil
        }
        return try body()
    }
}
