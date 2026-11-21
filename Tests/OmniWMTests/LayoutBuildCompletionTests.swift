// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class LayoutBuildCompletionTests: XCTestCase {
    func testRelayoutForwardsCurrentCompletionAcrossItsOwnViewportChange() throws {
        let (controller, workspaceId) = try fixture()
        let manager = controller.workspaceManager
        var completions = 0
        var invalidations = 0
        let action = RefreshPostLayoutAction(
            workspaceSeqs: [workspaceId: manager.worldSeq],
            domains: .layoutCommit.union(.focusCommit),
            action: { completions += 1 },
            invalidatedAction: { invalidations += 1 }
        )
        XCTAssertTrue(action.isCurrent(using: manager))
        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 120)

        XCTAssertTrue(executeRelayout(controller, workspaceId: workspaceId, action: action))

        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 0)
        XCTAssertFalse(action.isCurrent(using: manager))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(invalidations, 0)
    }

    func testRelayoutDoesNotReviveCompletionStaleBeforeItsBuild() throws {
        let (controller, workspaceId) = try fixture()
        let manager = controller.workspaceManager
        var completions = 0
        var invalidations = 0
        let action = RefreshPostLayoutAction(
            workspaceSeqs: [workspaceId: manager.worldSeq],
            domains: .layoutCommit.union(.focusCommit),
            action: { completions += 1 },
            invalidatedAction: { invalidations += 1 }
        )
        manager.withNiriViewportState(for: workspaceId) { $0.jumpOffset(to: 240) }
        XCTAssertFalse(action.isCurrent(using: manager))
        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 240)

        XCTAssertTrue(executeRelayout(controller, workspaceId: workspaceId, action: action))

        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 0)
        XCTAssertFalse(action.isCurrent(using: manager))
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(invalidations, 1)
    }

    func testAViewportMutationStoresItsViewportInItsOwnWorldEvent() throws {
        let (controller, workspaceId) = try fixture()
        let manager = controller.workspaceManager
        let shifted = manager.niriViewportState(for: workspaceId).viewOffset + 1
        let recorded = manager.recordedWorldEventCount

        manager.withNiriViewportState(for: workspaceId) { $0.jumpOffset(to: shifted) }

        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, shifted)
        XCTAssertEqual(manager.worldEvents(after: recorded), [manager.viewportMutationEvent(in: workspaceId)])
    }

    func testAViewportMutationThatDeclinesStoresNoViewport() throws {
        let (controller, workspaceId) = try fixture()
        let manager = controller.workspaceManager
        let viewport = manager.niriViewportState(for: workspaceId)
        let recorded = manager.recordedWorldEventCount

        let stored = manager.withNiriViewportState(for: workspaceId, committingIf: { $0 }) { state in
            state.jumpOffset(to: state.viewOffset + 1)
            return false
        }

        XCTAssertFalse(stored)
        XCTAssertEqual(manager.niriViewportState(for: workspaceId), viewport)
        XCTAssertEqual(manager.worldEvents(after: recorded), [manager.viewportMutationEvent(in: workspaceId)])
    }

    private func executeRelayout(
        _ controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        action: RefreshPostLayoutAction
    ) -> Bool {
        let refreshController = controller.layoutRefreshController
        return refreshController.executeRelayout(
            refresh: .init(
                kind: .relayout,
                reason: .interactiveGesture,
                affectedWorkspaceIds: [workspaceId],
                postLayout: action,
                suppressesWindowActivation: true
            ),
            useScrollAnimationPath: false,
            recoverFocus: false,
            generation: refreshController.layoutState.refreshGeneration
        )
    }

    func testBatchedBuildAppliesItsViewportPatchAndStampsTheFinalSequence() throws {
        let (controller, workspaceId) = try fixture()
        let manager = controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitor(for: workspaceId))
        var target = manager.niriViewportState(for: workspaceId)
        target.jumpOffset(to: 0)
        XCTAssertNotEqual(manager.niriViewportState(for: workspaceId).viewOffset, target.viewOffset)
        var entrySeq: UInt64?

        let plans = manager.withBatchedLayoutBuild {
            entrySeq = manager.worldSeq
            manager.withEngineMutationScope(in: workspaceId) {}
            return [WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
                sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId, viewportState: target),
                diff: WorkspaceLayoutDiff()
            )]
        }

        let patch = try XCTUnwrap(plans.first).sessionPatch
        XCTAssertNil(patch.viewportState)
        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, target.viewOffset)
        XCTAssertEqual(patch.plannedSeq, manager.worldSeq)
        XCTAssertGreaterThan(patch.plannedSeq, try XCTUnwrap(entrySeq))
    }

    private func fixture() throws -> (WMController, WorkspaceDescriptor.ID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings, windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
        ))
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1), displayId: 1, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Layout build completion"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: monitor.id))
        controller.niriLayoutHandler.enableNiriLayout()
        let pid: pid_t = 764_931
        let windowId = 764_932
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: workspaceId
        )
        manager.setCachedConstraints(.unconstrained, for: token)
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        XCTAssertNotNil(engine.singleWindowLayoutContext(in: workspaceId))
        manager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = node.id
            state.jumpOffset(to: 120)
        }
        controller.layoutRefreshController.fastFrameProvider = { _, _ in frame }
        controller.axManager.confirmFrameWrite(for: windowId, frame: frame)
        return (controller, workspaceId)
    }
}
