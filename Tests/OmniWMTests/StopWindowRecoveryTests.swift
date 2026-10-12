// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class StopWindowRecoveryTests: XCTestCase {
    func testAllParkingReasonsAndInterruptedRevealAreCapturedBeforeReset() throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        for (index, reason) in [HiddenReason.workspaceInactive, .scratchpad, .layoutTransient(.left)].enumerated() {
            let token = fixture.track(index)
            fixture.hide(token, reason: reason)
        }
        let revealed = fixture.track(4)
        let entry = try XCTUnwrap(fixture.manager.entry(for: revealed))
        _ = fixture.controller.layoutRefreshController.beginPendingRevealTransaction(
            for: entry, hiddenState: fixture.hidden(.workspaceInactive),
            targetFrame: CGRect(x: 200, y: 100, width: 400, height: 300), monitor: fixture.monitor
        )
        XCTAssertNil(fixture.manager.entry(for: revealed)?.hiddenState)
        let targets = fixture.controller.serviceLifecycleManager.stopWindowTargets()
        XCTAssertEqual(Set(targets.map(\.token)), Set([0, 1, 2, 4].map(fixture.token)))
        fixture.controller.layoutRefreshController.resetState()
        XCTAssertEqual(targets.count, 4)
    }

    func testOffscreenFallbackExcludesOnscreenFullscreenAndInactiveNativeSpaces() throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let onscreen = fixture.track(0)
        let offscreen = fixture.track(1)
        let fullscreen = fixture.track(2)
        let inactive = fixture.track(3)
        fixture.controller.layoutRefreshController.fastFrameProvider = { token, _ in
            token == onscreen ? CGRect(x: 100, y: 100, width: 300, height: 200)
                : CGRect(x: 3000, y: -200, width: 300, height: 200)
        }
        fixture.manager.setLayoutReason(.nativeFullscreen, for: fullscreen)
        fixture.manager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: "696", spaceIds: [1, 2], currentSpaceId: 1)],
            activeSpaceId: 1, windowSpace: [inactive.windowId: 2]
        ))
        XCTAssertEqual(fixture.controller.serviceLifecycleManager.stopWindowTargets().map(\.token), [offscreen])
    }

    func testMissingReferenceMonitorUsesConnectedWorkspaceMonitor() throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let token = fixture.track(0)
        fixture.hide(token, reason: .workspaceInactive)
        let target = try XCTUnwrap(fixture.controller.serviceLifecycleManager.stopWindowTargets().first)
        XCTAssertEqual(target.visibleFrame, fixture.monitor.visibleFrame)
        XCTAssertEqual(
            target.destination(for: CGRect(x: 2000, y: -100, width: 300, height: 200)),
            CGRect(x: 500, y: 200, width: 300, height: 200)
        )
    }

    func testNativeWithdrawalRecoversOnlyWindowsOmniWMParked() throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let parked = fixture.track(0)
        let offscreen = fixture.track(1)
        let minimized = fixture.track(2)
        for token in [parked, minimized] { fixture.hide(token, reason: .workspaceInactive) }
        for token in [parked, offscreen] { fixture.manager.setWindowNativeWithdrawn(true, token: token) }
        fixture.manager.setWindowMinimized(true, token: minimized)
        fixture.controller.layoutRefreshController.fastFrameProvider = { token, _ in
            token == offscreen ? CGRect(x: 3000, y: -200, width: 300, height: 200)
                : CGRect(x: 100, y: 100, width: 300, height: 200)
        }

        let targets = fixture.controller.serviceLifecycleManager.stopWindowTargets()
        XCTAssertEqual(Set(targets.map(\.token)), [parked, minimized])
    }

    func testLatestFloatingOriginWinsOverOldHiddenProportion() throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let token = fixture.track(0)
        fixture.hide(token, reason: .scratchpad)
        _ = fixture.manager.setWindowMode(.floating, for: token)
        fixture.manager.setFloatingState(.init(
            lastFrame: CGRect(x: 150, y: 180, width: 900, height: 300), normalizedOrigin: nil,
            referenceMonitorId: fixture.monitor.id, restoreToFloating: true
        ), for: token)
        let target = try XCTUnwrap(fixture.controller.serviceLifecycleManager.stopWindowTargets().first)
        XCTAssertEqual(
            target.destination(for: CGRect(x: 3000, y: -400, width: 320, height: 200)),
            CGRect(x: 150, y: 180, width: 320, height: 200)
        )
    }

    func testRecoveryRevealsEachAppOnceAndOnlyUnminimizesCandidates() async throws {
        let fixture = try Fixture()
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let first = fixture.track(0)
        let second = fixture.track(1)
        let unrelated = fixture.track(2)
        for token in [first, second] { fixture.hide(token, reason: .workspaceInactive) }
        for token in [first, second, unrelated] { fixture.manager.setWindowMinimized(true, token: token) }
        fixture.manager.setAppHidden(true, pid: first.pid, source: .service)
        var reveals: [pid_t] = []
        var restores: [WindowToken] = []
        let operations = StopRecoveryOperations(
            hasContext: { _ in true }, reveal: { pid, _ in reveals.append(pid)
                return true
            },
            restore: { target, _ in
                restores.append(target.token)
                return StopWindowOutcome(
                    target: target,
                    confirmedMinimized: false,
                    frame: CGRect(x: 100, y: 100, width: 400, height: 300)
                )
            }
        )
        let lifecycle = fixture.controller.serviceLifecycleManager
        await lifecycle.recoverStopWindows(lifecycle.stopWindowTargets(), deadline: 100, operations: operations)
        XCTAssertEqual(reveals, [first.pid])
        XCTAssertEqual(Set(restores), [first, second])
        XCTAssertFalse(fixture.manager.isAppHidden(first))
        XCTAssertEqual(fixture.manager.entry(for: unrelated)?.observedState.isMinimized, true)
        for token in [first, second] {
            XCTAssertNil(fixture.manager.entry(for: token)?.hiddenState)
            XCTAssertEqual(fixture.manager.entry(for: token)?.observedState.isMinimized, false)
        }
    }

    func testMissingContextOrRefusedAppLeavesParkingStateIntact() async throws {
        for hasContext in [false, true] {
            let fixture = try Fixture()
            defer { fixture.controller.serviceLifecycleManager.stop() }
            let token = fixture.track(0)
            fixture.hide(token, reason: .scratchpad)
            var revealCount = 0
            let operations = StopRecoveryOperations(
                hasContext: { _ in hasContext },
                reveal: { _, _ in revealCount += 1
                    return !hasContext
                },
                restore: { target, _ in XCTFail("Must not move without native reveal")
                    return StopWindowOutcome(target: target)
                }
            )
            let lifecycle = fixture.controller.serviceLifecycleManager
            await lifecycle.recoverStopWindows(lifecycle.stopWindowTargets(), deadline: 100, operations: operations)
            XCTAssertNotNil(fixture.manager.entry(for: token)?.hiddenState)
            XCTAssertEqual(revealCount, 1)
        }
    }

    @MainActor
    private final class Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StopWindowRecovery")
        let monitor = Monitor(
            id: .init(displayId: 696), displayId: 696,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 720), hasNotch: false, name: "Recovery"
        )
        let workspace: WorkspaceDescriptor.ID
        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        init() throws {
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
            workspace = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
                named: "91",
                layoutType: .niri,
                controller: controller
            ))
            controller.layoutRefreshController.fastFrameProvider = { _, _ in CGRect(
                x: 100,
                y: 100,
                width: 300,
                height: 200
            ) }
        }

        func token(_ index: Int) -> WindowToken {
            WindowToken(pid: 696_011, windowId: 696_020 + index)
        }

        func track(_ index: Int) -> WindowToken {
            let token = token(index)
            _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            return token
        }

        func hidden(_ reason: HiddenReason) -> HiddenState {
            HiddenState(
                proportionalPosition: CGPoint(x: 0.5, y: 0.5),
                referenceMonitorId: .init(displayId: 999),
                reason: reason
            )
        }

        func hide(_ token: WindowToken, reason: HiddenReason) {
            manager.setHiddenState(hidden(reason), for: token)
        }
    }
}
