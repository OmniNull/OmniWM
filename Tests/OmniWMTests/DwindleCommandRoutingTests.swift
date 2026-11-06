// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class DwindleCommandRoutingTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let sourceMonitor: Monitor
        let targetMonitor: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let firstToken: WindowToken
        let activeToken: WindowToken
    }

    func testFocusAtGroupEdgeUsesEligibleAdjacentMonitorWithoutLocalWrap() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.targetMonitor.id
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertTrue(pending.affectedWorkspaceIds.contains(fixture.targetWorkspaceId))
    }

    func testFocusAtGroupEdgeWrapsLocallyWhenAdjacentWorkspaceHasNoCandidate() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.firstToken)
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .layoutCommand)
        XCTAssertTrue(pending.affectedWorkspaceIds.contains(fixture.sourceWorkspaceId))
    }

    func testLocalSpatialExitPrecedesEligibleAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let localNeighbor = addWindow(
            pid: 31_105,
            windowId: 31_205,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            XCTAssertTrue(fixture.engine.setPreselection(.down, in: fixture.sourceWorkspaceId))
            _ = fixture.engine.addWindow(
                token: localNeighbor,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), localNeighbor)
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
    }

    func testSharedWrapAndReorderCommandsRouteToDwindleGroups() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.focusNavigation(.windowDownOrTop)),
            .executed
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.firstToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.focusNavigation(.windowUpOrBottom)),
            .executed
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.windowMovement(.up)),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.activeToken, fixture.firstToken]
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.windowMovement(.up)),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.activeToken, fixture.firstToken]
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.windowMovement(.down)),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.firstToken, fixture.activeToken]
        )
    }

    func testMoveAtSingletonEdgeTransfersToAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        fixture.controller.settings.focus.moveCrossesMonitorAtEdge = true
        fixture.controller.settings.focus.followsWindowToMonitor = false
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.move(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.targetWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.targetMonitor.id
        )
        XCTAssertNil(fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId))
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertEqual(
            pending.affectedWorkspaceIds,
            [fixture.sourceWorkspaceId, fixture.targetWorkspaceId]
        )
    }

    func testEligibilityBlockedMoveDoesNotTransferToAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        fixture.controller.settings.focus.moveCrossesMonitorAtEdge = true
        let before = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        fixture.controller.workspaceManager.setLayoutReason(
            .nativeFullscreen,
            for: fixture.activeToken
        )
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.move(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId),
            before
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testMoveContainerSwapsWholeGroupAndNeverTransfersAtMonitorEdge() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        fixture.controller.settings.focus.moveCrossesMonitorAtEdge = true
        let thirdToken = addWindow(
            pid: 31_104,
            windowId: 31_204,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            XCTAssertTrue(fixture.engine.setPreselection(.right, in: fixture.sourceWorkspaceId))
            _ = fixture.engine.addWindow(
                token: thirdToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let groupedBefore = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        let thirdBefore = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: thirdToken, in: fixture.sourceWorkspaceId)
        )
        let groupedNodeIdBefore = try XCTUnwrap(
            fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId)?.id
        )
        let thirdNodeIdBefore = try XCTUnwrap(
            fixture.engine.findNode(for: thirdToken, in: fixture.sourceWorkspaceId)?.id
        )
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.moveColumn(.right)),
            .executed
        )

        let groupedAfter = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        XCTAssertEqual(groupedAfter.id, groupedBefore.id)
        XCTAssertEqual(groupedAfter.members.map(\.token), [fixture.firstToken, fixture.activeToken])
        XCTAssertEqual(groupedAfter.activeToken, fixture.activeToken)
        XCTAssertEqual(
            fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId)?.id,
            thirdNodeIdBefore
        )
        XCTAssertEqual(
            fixture.engine.findNode(for: thirdToken, in: fixture.sourceWorkspaceId)?.id,
            groupedNodeIdBefore
        )
        XCTAssertNotEqual(groupedBefore.id, thirdBefore.id)
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.moveColumn(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testSharedCycleSizeCommandRoutesToDwindleSplitRatio() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        let secondToken = addWindow(
            pid: 31_106,
            windowId: 31_206,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = fixture.engine.addWindow(
                token: secondToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            fixture.engine.setSelectedNode(
                fixture.engine.findNode(for: fixture.firstToken, in: fixture.sourceWorkspaceId),
                in: fixture.sourceWorkspaceId
            )
        }
        let before = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId)?.splitRatio)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.sizing(.cycleSizeForward)),
            .executed
        )

        let after = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId)?.splitRatio)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, 1.4)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
    }

    func testIPCResizeRoutesGrowAndShrinkAlongAxis() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        let secondToken = addWindow(
            pid: 31_107,
            windowId: 31_207,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = fixture.engine.addWindow(
                token: secondToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.firstToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))

        XCTAssertEqual(router.handle(.dwindle(.resize(axis: .horizontal, operation: .grow))), .executed)
        XCTAssertEqual(root.splitRatio ?? 0, 1.1)

        XCTAssertEqual(router.handle(.dwindle(.resize(axis: .horizontal, operation: .shrink))), .executed)
        XCTAssertEqual(root.splitRatio ?? 0, 1.0)
    }

    func testExplicitConsumeOrExpelCommandsRejectDwindleLayout() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)

        for command in [
            HotkeyCommand.windowMovement(.consumeOrExpelLeft),
            .windowMovement(.consumeOrExpelRight)
        ] {
            XCTAssertEqual(
                fixture.controller.commandHandler.performCommand(command),
                .ignoredLayoutMismatch
            )
        }
    }

    func testIPCRootPromotionReportsNoChangeForGroupedRootChild() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        _ = addSourceTile(to: fixture, windowId: 31_208, direction: .down)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = fixture.engine.activateWindowOutcome(fixture.activeToken, in: fixture.sourceWorkspaceId)
        }
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))
        let group = try XCTUnwrap(fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId))
        XCTAssertTrue(group.parent === root)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.sourceWorkspaceId), 3)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.sourceWorkspaceId), 2)
        let before = fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        let children = root.children.map(\.id)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

        let result = router.handle(.dwindle(.moveToRoot))

        XCTAssertEqual(result, .noChange)
        XCTAssertEqual(root.children.map(\.id), children)
        XCTAssertEqual(fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId), before)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        let response = IPCApplicationBridge.response(for: result, id: "root-promotion", kind: .command)
        XCTAssertEqual(response.status, .ignored)
        XCTAssertEqual(response.code, .noChange)
    }

    func testIPCRootPromotionExecutesOnceForNestedTile() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        _ = addSourceTile(to: fixture, windowId: 31_209)
        let nestedToken = addSourceTile(to: fixture, windowId: 31_210, direction: .down)
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))
        let nested = try XCTUnwrap(fixture.engine.findNode(for: nestedToken, in: fixture.sourceWorkspaceId))
        XCTAssertFalse(nested.parent === root)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.dwindle(.moveToRoot)), .executed)
        XCTAssertTrue(nested.parent === root)
        XCTAssertEqual(fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason, .layoutCommand)
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        XCTAssertEqual(router.handle(.dwindle(.moveToRoot)), .noChange)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testIPCSplitCommandsReportChangesAndSingleTileNoOps() throws {
        for command in [IPCDwindleCommand.toggleSplit, .swapSplit] {
            let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
            let blocker = try blockLayoutRefresh(fixture)
            defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
            let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

            XCTAssertEqual(router.handle(.dwindle(command)), .noChange)
            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

            _ = addSourceTile(to: fixture, windowId: 31_211)
            let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))
            let orientation = try XCTUnwrap(root.splitOrientation)
            let children = root.children.map(\.id)
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

            XCTAssertEqual(router.handle(.dwindle(command)), .executed)
            if command == .toggleSplit {
                XCTAssertEqual(root.splitOrientation, orientation.perpendicular)
                XCTAssertEqual(root.children.map(\.id), children)
            } else {
                XCTAssertEqual(root.splitOrientation, orientation)
                XCTAssertEqual(root.children.map(\.id), Array(children.reversed()))
            }
            XCTAssertEqual(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
                .layoutCommand
            )
        }
    }

    func testIPCResizeCommandsReportChangesAndClampedNoOps() throws {
        let commands: [IPCDwindleCommand] = [
            .resize(axis: .horizontal, operation: .grow),
            .resizeFocused(operation: .grow)
        ]
        for command in commands {
            let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
            _ = addSourceTile(to: fixture, windowId: 31_212)
            fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
                _ = fixture.engine.activateWindowOutcome(fixture.firstToken, in: fixture.sourceWorkspaceId)
            }
            let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))
            let before = try XCTUnwrap(root.splitRatio)
            let blocker = try blockLayoutRefresh(fixture)
            defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
            let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

            XCTAssertEqual(router.handle(.dwindle(command)), .executed)
            XCTAssertGreaterThan(try XCTUnwrap(root.splitRatio), before)
            XCTAssertEqual(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
                .layoutCommand
            )

            fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
                XCTAssertTrue(fixture.engine.resizeSelected(
                    by: 100,
                    orientation: .horizontal,
                    in: fixture.sourceWorkspaceId
                ))
            }
            let limit = root.splitRatio
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

            XCTAssertEqual(router.handle(.dwindle(command)), .noChange)
            XCTAssertEqual(root.splitRatio, limit)
            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        }
    }

    func testIPCPreselectionCommandsReportChangesWithoutRelayout() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        let blocker = try blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        let state = try XCTUnwrap(fixture.engine.existingState(for: fixture.sourceWorkspaceId))
        let cases: [(IPCDwindleCommand, ExternalCommandResult, Direction?)] = [
            (.preselectClear, .noChange, nil),
            (.preselect(direction: .left), .executed, .left),
            (.preselect(direction: .left), .noChange, .left),
            (.preselectClear, .executed, nil),
            (.preselectClear, .noChange, nil)
        ]

        for (command, expected, direction) in cases {
            XCTAssertEqual(router.handle(.dwindle(command)), expected)
            XCTAssertEqual(state.preselection, direction)
            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        }
    }

    private func addSourceTile(
        to fixture: Fixture,
        windowId: Int,
        direction: Direction = .right
    ) -> WindowToken {
        let token = addWindow(
            pid: 31_108,
            windowId: windowId,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            XCTAssertTrue(fixture.engine.setPreselection(direction, in: fixture.sourceWorkspaceId))
            _ = fixture.engine.addWindow(token: token, to: fixture.sourceWorkspaceId, activeWindowFrame: nil)
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
        }
        return token
    }

    private func makeFixture(
        groupedSource: Bool,
        includeTargetCandidate: Bool
    ) throws -> Fixture {
        let sourceMonitor = Monitor(
            id: .init(displayId: 31_001),
            displayId: 31_001,
            frame: CGRect(x: 0, y: 900, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1600, height: 900),
            hasNotch: false,
            name: "Source"
        )
        let targetMonitor = Monitor(
            id: .init(displayId: 31_002),
            displayId: 31_002,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Target"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDwindleCommandRoutingTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .dwindle
            )
        ]
        settings.focus.crossesMonitorAtEdge = true
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, targetMonitor])
        controller.workspaceManager.applySettings()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: "1")
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                targetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                sourceWorkspaceId,
                on: sourceMonitor.id
            )
        )

        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let firstToken = addWindow(
            pid: 31_101,
            windowId: 31_201,
            to: sourceWorkspaceId,
            controller: controller
        )
        let activeToken = groupedSource ? addWindow(
            pid: 31_102,
            windowId: 31_202,
            to: sourceWorkspaceId,
            controller: controller
        ) : firstToken
        let targetToken = includeTargetCandidate ? addWindow(
            pid: 31_103,
            windowId: 31_203,
            to: targetWorkspaceId,
            controller: controller
        ) : nil

        controller.workspaceManager.withEngineMutationScope(in: sourceWorkspaceId) {
            _ = engine.addWindow(token: firstToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            if groupedSource {
                _ = engine.addWindow(token: activeToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            }
            _ = engine.calculateLayout(for: sourceWorkspaceId, screen: sourceMonitor.visibleFrame)
            if groupedSource {
                XCTAssertTrue(engine.groupWindow(direction: .left, in: sourceWorkspaceId))
                _ = engine.calculateLayout(for: sourceWorkspaceId, screen: sourceMonitor.visibleFrame)
            }
            if let targetToken {
                _ = engine.addWindow(token: targetToken, to: targetWorkspaceId, activeWindowFrame: nil)
                _ = engine.calculateLayout(for: targetWorkspaceId, screen: targetMonitor.visibleFrame)
            }
        }
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                activeToken,
                in: sourceWorkspaceId,
                onMonitor: sourceMonitor.id
            )
        )
        if let targetToken {
            XCTAssertNotNil(controller.preferredKeyboardFocusFrame(for: targetToken))
        }

        return Fixture(
            controller: controller,
            engine: engine,
            sourceMonitor: sourceMonitor,
            targetMonitor: targetMonitor,
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            firstToken: firstToken,
            activeToken: activeToken
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func blockLayoutRefresh(_ fixture: Fixture) throws -> Task<Void, Never> {
        try LayoutRefreshTestSupport.block(fixture.controller, in: fixture.sourceWorkspaceId, reason: .layoutCommand)
    }

    private func unblockLayoutRefresh(
        _ controller: WMController,
        blocker: Task<Void, Never>
    ) {
        LayoutRefreshTestSupport.unblock(controller, blocker: blocker)
    }
}
