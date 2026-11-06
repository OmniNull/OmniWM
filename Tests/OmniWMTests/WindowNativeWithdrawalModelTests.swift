// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WindowNativeWithdrawalModelTests: XCTestCase {
    func testNiriWithdrawalRetainsIdentityAndColumnsWhileSurvivorFillsScreen() throws {
        for withdrawnIndex in 0 ... 1 {
            let controller = WindowAdmissionTestSupport.controller()
            let manager = controller.workspaceManager
            let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
            _ = manager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            let tokens = [WindowToken(pid: 776_001, windowId: 776_101), WindowToken(pid: 776_001, windowId: 776_102)]
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            _ = manager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
            let columnIds = engine.columns(in: workspaceId).map(\.id)
            let sizing = engine.columns(in: workspaceId).map(\.width)
            let withdrawn = tokens[withdrawnIndex]
            let survivor = tokens[1 - withdrawnIndex]
            let handle = try XCTUnwrap(manager.handle(for: withdrawn))
            let nodeId = try XCTUnwrap(engine.findNode(for: withdrawn, in: workspaceId)?.id)
            let axRef = try XCTUnwrap(manager.entry(for: withdrawn)?.axRef)

            XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: withdrawn))
            XCTAssertFalse(manager.setWindowNativeWithdrawn(true, token: withdrawn))

            let monitor = try XCTUnwrap(manager.monitor(for: workspaceId))
            let input = try XCTUnwrap(controller.layoutRefreshController.buildRefreshInput(
                workspaceId: workspaceId, monitor: monitor, resolveConstraints: false, isActiveWorkspace: true
            ))
            XCTAssertEqual(input.excludedTokens, [withdrawn])
            XCTAssertEqual(Set(input.windows.map(\.token)), Set(tokens))
            let plan = try XCTUnwrap(manager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            })
            XCTAssertFalse(plan.diff.frameChanges.contains { $0.token == withdrawn })
            XCTAssertFalse(plan.diff.restoreChanges.contains { $0.token == withdrawn })
            let visibleFrame = try XCTUnwrap(engine.findNode(for: survivor, in: workspaceId)?.frame)
            XCTAssertEqual(visibleFrame, controller.borderSafeFillFrame(for: monitor))
            XCTAssertTrue(manager.handle(for: withdrawn) === handle)
            XCTAssertEqual(engine.findNode(for: withdrawn, in: workspaceId)?.id, nodeId)
            XCTAssertEqual(try XCTUnwrap(manager.entry(for: withdrawn)).axRef, axRef)
            XCTAssertFalse(try XCTUnwrap(manager.entry(for: withdrawn)).observedState.isMinimized)
            XCTAssertNil(manager.hiddenState(for: withdrawn))
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.id), columnIds)
            XCTAssertEqual(controller.resolveAndSetWorkspaceFocusToken(for: workspaceId), survivor)

            XCTAssertTrue(manager.setWindowNativeWithdrawn(false, token: withdrawn))
            _ = manager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
            XCTAssertTrue(manager.handle(for: withdrawn) === handle)
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.id), columnIds)
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.width), sizing)
            XCTAssertEqual(engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }, tokens)
            XCTAssertFalse(manager.isWindowSuppressedByMacOS(withdrawn))
        }
    }

    func testDwindleWithdrawalAndMinimizationOverlapUntilBothClear() throws {
        for clearWithdrawalFirst in [true, false] {
            let controller = WindowAdmissionTestSupport.controller()
            let manager = controller.workspaceManager
            let workspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
                named: "776",
                layoutType: .dwindle,
                controller: controller
            ))
            controller.dwindleLayoutHandler.enableDwindleLayout()
            let first = WindowToken(pid: 776_002, windowId: 776_201)
            let second = WindowToken(pid: 776_002, windowId: 776_202)
            _ = WindowAdmissionTestSupport.track(first, in: workspaceId, controller: controller)
            _ = WindowAdmissionTestSupport.track(second, in: workspaceId, controller: controller)
            let engine = try XCTUnwrap(controller.dwindleEngine)
            _ = manager.withEngineMutationScope {
                engine.syncWindows([first, second], in: workspaceId, focusedToken: first)
            }
            let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            let original = manager.withEngineMutationScope {
                engine.calculateLayout(for: workspaceId, screen: frame)
            }
            let root = try XCTUnwrap(engine.root(for: workspaceId))
            let ratio = root.splitRatio

            manager.setWindowNativeWithdrawn(true, token: first)
            manager.setWindowMinimized(true, token: first)
            if clearWithdrawalFirst {
                manager.setWindowNativeWithdrawn(false, token: first)
            } else {
                manager.setWindowMinimized(false, token: first)
            }

            XCTAssertTrue(try XCTUnwrap(manager.entry(for: first)).observedState.isNativeSuppressed)
            XCTAssertTrue(manager.isWindowSuppressedByMacOS(first))
            XCTAssertEqual(manager.withEngineMutationScope {
                engine.calculateLayout(for: workspaceId, screen: frame)
            }, [second: frame])
            XCTAssertEqual(engine.root(for: workspaceId)?.id, root.id)
            XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, ratio)

            if clearWithdrawalFirst {
                manager.setWindowMinimized(false, token: first)
            } else {
                manager.setWindowNativeWithdrawn(false, token: first)
            }

            XCTAssertFalse(manager.isWindowSuppressedByMacOS(first))
            XCTAssertEqual(manager.withEngineMutationScope {
                engine.calculateLayout(for: workspaceId, screen: frame)
            }, original)
            XCTAssertEqual(engine.root(for: workspaceId)?.id, root.id)
            XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, ratio)
        }
    }

    func testWithdrawalAtomicallyClearsMatchingFocusAndInvalidatesLayout() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        let token = WindowToken(pid: 776_003, windowId: 776_301)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        XCTAssertTrue(manager.confirmManagedFocus(token, in: workspaceId, activateWorkspaceOnMonitor: false))
        _ = manager.beginManagedFocusRequest(token, in: workspaceId, requestId: 776)
        manager.setSystemModalFocus(token)
        let seq = manager.worldSeq

        manager.setWindowNativeWithdrawn(true, token: token)

        XCTAssertEqual(manager.selectedManagedToken, token)
        XCTAssertNil(manager.pendingFocusedToken)
        XCTAssertEqual(manager.nativeFocusOwner, .none)
        XCTAssertNil(manager.systemModalFocusToken)
        XCTAssertNil(manager.renderableFocusToken)
        XCTAssertFalse(controller.isManagedWindowDisplayable(token))
        XCTAssertFalse(controller.canFocusWindow(pid: token.pid, windowId: token.windowId))
        XCTAssertNil(controller.resolveAndSetWorkspaceFocusToken(for: workspaceId))
        XCTAssertFalse(manager.isSeqCurrent(seq, for: workspaceId, domains: .layoutCommit))

        manager.setWindowNativeWithdrawn(false, token: token)

        XCTAssertNil(manager.pendingFocusedToken)
        XCTAssertEqual(manager.nativeFocusOwner, .none)
        XCTAssertTrue(controller.isManagedWindowDisplayable(token))
        XCTAssertTrue(controller.canFocusWindow(pid: token.pid, windowId: token.windowId))
    }

    func testWithdrawalSurvivesReadmissionAndRekeyButEndsWithRetirement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 776_004, windowId: 776_401)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let handle = try XCTUnwrap(manager.handle(for: token))
        manager.setWindowNativeWithdrawn(true, token: token)

        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)

        XCTAssertTrue(manager.handle(for: token) === handle)
        XCTAssertTrue(try XCTUnwrap(manager.entry(for: token)).observedState.isNativeWithdrawn)
        let replacement = WindowToken(pid: token.pid, windowId: 776_402)
        let axRef = WindowAdmissionTestSupport.axRef(for: replacement)
        XCTAssertNotNil(manager.rekeyWindow(from: token, to: replacement, newAXRef: axRef))
        XCTAssertTrue(manager.handle(for: replacement) === handle)
        XCTAssertTrue(try XCTUnwrap(manager.entry(for: replacement)).observedState.isNativeWithdrawn)

        _ = manager.removeWindow(pid: replacement.pid, windowId: replacement.windowId)
        _ = WindowAdmissionTestSupport.track(replacement, in: workspaceId, controller: controller)

        XCTAssertFalse(try XCTUnwrap(manager.entry(for: replacement)).observedState.isNativeWithdrawn)
        XCTAssertFalse(manager.handle(for: replacement) === handle)
    }
}
