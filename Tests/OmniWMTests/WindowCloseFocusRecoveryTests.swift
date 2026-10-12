// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

private actor WindowCloseFocusFactGate {
    private var fact: FocusedWindowFact?
    private var isResolved = false
    private var waiters: [CheckedContinuation<FocusedWindowFact?, Never>] = []

    func wait() async -> FocusedWindowFact? {
        if isResolved {
            return fact
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ fact: FocusedWindowFact?) {
        guard !isResolved else { return }
        self.fact = fact
        isResolved = true
        for waiter in waiters {
            waiter.resume(returning: fact)
        }
        waiters.removeAll()
    }
}

@MainActor
private final class WindowCloseLifecycleQueryGate {
    private var continuation: CheckedContinuation<WindowServerInfo?, Never>?

    func wait() async -> WindowServerInfo? {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ info: WindowServerInfo? = nil) {
        continuation?.resume(returning: info)
        continuation = nil
    }
}

@MainActor
final class WindowCloseFocusRecoveryTests: XCTestCase {
    private enum SameAppFocusOrder {
        case focusThenDestroy
        case destroyThenFocus
    }

    private struct CloseOutcome {
        let activeWorkspaceIsLocal: Bool
        let focusedWindowId: Int?
        let preferredWindowId: Int?
        let selectedWindowId: Int?
        let activeColumnIndex: Int
        let viewOffset: CGFloat
        let closingWindowWasRemoved: Bool
        let invariantsAreClean: Bool
    }

    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let localWorkspaceId: WorkspaceDescriptor.ID
        let remoteWorkspaceId: WorkspaceDescriptor.ID
        let pid: pid_t
        let leftToken: WindowToken
        let closingToken: WindowToken
        let rightToken: WindowToken
        let remoteToken: WindowToken
        let leftNode: NiriWindow
        let closingNode: NiriWindow
        let rightNode: NiriWindow
        let closingMetadata: ManagedReplacementMetadata
    }

    func testAuthoritativeCloseHidesBorderWhileRetainingReplacementIdentity() throws {
        for startsWithTransientDestroy in [false, true] {
            let fixture = try Self.makeFixture()
            let controller = fixture.controller
            let handler = controller.axEventHandler
            defer {
                controller.surfaceReconciler.cleanup()
                Self.stop(fixture)
            }
            controller.settings.borders.enabled = true
            let frame = try XCTUnwrap(fixture.closingMetadata.frame)
            controller.axManager.confirmFrameWrite(for: fixture.closingToken.windowId, frame: frame)
            controller.surfaceReconciler.cleanup()
            let world = WorldView(controller: controller, liveBoundsProvider: { _ in nil })
            let previous = try XCTUnwrap(SurfaceDerivation.deriveBorder(world: world))
            let handle = try XCTUnwrap(controller.workspaceManager.handle(for: fixture.closingToken))

            if startsWithTransientDestroy {
                handler.handleWindowDestroyed(
                    windowId: UInt32(fixture.closingToken.windowId), pidHint: fixture.pid,
                    evidence: .transientLifecycle, windowInfo: nil
                )
                XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world), previous)
                XCTAssertEqual(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous), previous)
                XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)
            }

            handler.handleWindowDestroyed(
                windowId: UInt32(fixture.closingToken.windowId), pidHint: fixture.pid,
                evidence: .windowClosed, windowInfo: nil
            )

            XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
            XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
            XCTAssertNil(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous))
            XCTAssertNil(SurfaceDerivation.deriveBorder(world: WorldView(
                controller: controller, liveBoundsProvider: { _ in frame }
            )))
            XCTAssertTrue(handler.hasPendingManagedReplacementDestroy(fixture.closingToken))
            XCTAssertTrue(controller.workspaceManager.handle(for: fixture.closingToken) === handle)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.closingToken)
            XCTAssertTrue(fixture.engine.findNode(for: fixture.closingToken, in: fixture.localWorkspaceId)
                === fixture.closingNode)
            XCTAssertEqual(controller.axManager.lastAppliedFrame(for: fixture.closingToken.windowId), frame)
        }
    }

    func testClosedBorderStaysHiddenThroughReplacementAcknowledgementAndReturnsForNewIdentity() async throws {
        let fixture = try Self.makeFixture()
        let controller = fixture.controller
        let handler = controller.axEventHandler
        var acknowledgement: CheckedContinuation<Bool, Never>?
        defer {
            acknowledgement?.resume(returning: false)
            handler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            Self.stop(fixture)
        }
        controller.settings.borders.enabled = true
        let frame = try XCTUnwrap(fixture.closingMetadata.frame)
        controller.axManager.confirmFrameWrite(for: fixture.closingToken.windowId, frame: frame)
        let world = WorldView(controller: controller, liveBoundsProvider: { _ in frame })
        let previous = try XCTUnwrap(SurfaceDerivation.deriveBorder(world: world))
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: fixture.closingToken))
        let entered = expectation(description: "replacement acknowledgement suspended")
        handler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }
        handler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            await withCheckedContinuation {
                acknowledgement = $0
                entered.fulfill()
            }
        }
        handler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        handler.handleWindowDestroyed(
            windowId: UInt32(fixture.closingToken.windowId), pidHint: fixture.pid,
            evidence: .windowClosed, windowInfo: nil
        )
        let replacementToken = WindowToken(pid: fixture.pid, windowId: 951_110)
        let windowId = UInt32(replacementToken.windowId)
        handler.retainPreparedWindowSubscription(windowId)
        handler.enqueueManagedReplacementCreate(.init(
            windowId: windowId,
            token: replacementToken,
            axRef: WindowAdmissionTestSupport.axRef(for: replacementToken),
            ruleEffects: .none,
            admissionHints: .none,
            appFullscreen: false,
            replacementMetadata: fixture.closingMetadata,
            structuralReplacementMatch: nil
        ))
        XCTAssertFalse(handler.hasPendingManagedReplacementDestroy(fixture.closingToken))
        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        let completion = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertNotNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNil(controller.workspaceManager.entry(for: replacementToken))
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
        XCTAssertNil(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous))

        acknowledgement?.resume(returning: true)
        acknowledgement = nil
        await completion.value

        XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(controller.workspaceManager.handle(for: replacementToken) === handle)
        XCTAssertTrue(fixture.engine.findNode(for: replacementToken, in: fixture.localWorkspaceId)
            === fixture.closingNode)
        XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world)?.token, replacementToken)
        XCTAssertEqual(
            SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous)?.token,
            replacementToken
        )
    }

    func testPendingManagedDestroyPreservesLocalFocusAndViewportForBothEventOrders() async throws {
        let control = try await Self.runCloseScenario(order: nil)
        let focusThenDestroy = try await Self.runCloseScenario(order: .focusThenDestroy)
        let destroyThenFocus = try await Self.runCloseScenario(order: .destroyThenFocus)

        XCTAssertTrue(control.activeWorkspaceIsLocal)
        XCTAssertEqual(focusThenDestroy.activeWorkspaceIsLocal, control.activeWorkspaceIsLocal)
        XCTAssertEqual(focusThenDestroy.focusedWindowId, control.focusedWindowId)
        XCTAssertEqual(focusThenDestroy.preferredWindowId, control.preferredWindowId)
        XCTAssertEqual(focusThenDestroy.selectedWindowId, control.selectedWindowId)
        XCTAssertEqual(focusThenDestroy.activeColumnIndex, control.activeColumnIndex)
        XCTAssertEqual(focusThenDestroy.viewOffset, control.viewOffset, accuracy: 0.5)
        XCTAssertEqual(destroyThenFocus.activeWorkspaceIsLocal, control.activeWorkspaceIsLocal)
        XCTAssertEqual(destroyThenFocus.focusedWindowId, control.focusedWindowId)
        XCTAssertEqual(destroyThenFocus.preferredWindowId, control.preferredWindowId)
        XCTAssertEqual(destroyThenFocus.selectedWindowId, control.selectedWindowId)
        XCTAssertEqual(destroyThenFocus.activeColumnIndex, control.activeColumnIndex)
        XCTAssertEqual(destroyThenFocus.viewOffset, control.viewOffset, accuracy: 0.5)
        XCTAssertTrue(control.closingWindowWasRemoved)
        XCTAssertTrue(focusThenDestroy.closingWindowWasRemoved)
        XCTAssertTrue(destroyThenFocus.closingWindowWasRemoved)
        XCTAssertTrue(control.invariantsAreClean)
        XCTAssertTrue(focusThenDestroy.invariantsAreClean)
        XCTAssertTrue(destroyThenFocus.invariantsAreClean)
    }

    func testPendingCloseQueryHoldsSameAppFocusWhenProbeExpires() async throws {
        let fixture = try Self.makeFixture()
        let controller = fixture.controller
        let handler = controller.axEventHandler
        let gate = WindowCloseLifecycleQueryGate()
        defer {
            handler.cleanup()
            gate.resume()
            controller.layoutRefreshController.resetState()
            Self.stop(fixture)
        }
        controller.layoutRefreshController.resetState()
        let started = expectation(description: "close query suspended")
        handler.lifecycleQueries.query = { windowId in
            XCTAssertEqual(windowId, UInt32(fixture.closingToken.windowId))
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.closed(windowId: UInt32(fixture.closingToken.windowId)))
        let queryTask = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)

        let probeId = try Self.observeRemoteFocus(in: fixture)
        controller.deadlineWheel.cancel(intentId: probeId)
        handler.handleIntentExpired(probeId)
        controller.eventIntake.drainNow()

        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.closingToken)
        XCTAssertNotNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNotNil(controller.intentLedger.openSameAppCloseProbe())

        gate.resume()
        await queryTask.value
        await handler.awaitPendingManagedReplacementBursts(for: [fixture.pid])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testSameAppFocusWithoutPendingDestroyStillResolvesAfterProbe() throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        let probeId = try Self.observeRemoteFocus(in: fixture)
        fixture.controller.deadlineWheel.cancel(intentId: probeId)
        fixture.controller.axEventHandler.handleIntentExpired(probeId)
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
    }

    func testPhantomOrFailedLifecycleQueryReleasesExpiredSameAppFocusProbe() async throws {
        for queryFails in [false, true] {
            let fixture = try Self.makeFixture()
            let controller = fixture.controller
            let handler = controller.axEventHandler
            let gate = WindowCloseLifecycleQueryGate()
            defer {
                handler.cleanup()
                gate.resume()
                controller.layoutRefreshController.resetState()
                Self.stop(fixture)
            }
            controller.layoutRefreshController.resetState()
            let started = expectation(description: "lifecycle query suspended")
            handler.lifecycleQueries.query = { windowId in
                XCTAssertEqual(windowId, UInt32(fixture.closingToken.windowId))
                started.fulfill()
                let info = await gate.wait()
                if queryFails { throw AXEventHandler.LifecycleQueryError.unavailable }
                return info
            }
            let windowId = UInt32(fixture.closingToken.windowId)
            handler.handleCGSEvent(queryFails ? .closed(windowId: windowId) : .destroyed(
                windowId: windowId,
                spaceId: 0
            ))
            let queryTask = try XCTUnwrap(handler.lifecycleQueries.task)
            await fulfillment(of: [started], timeout: 2)

            let probeId = try Self.observeRemoteFocus(in: fixture)
            controller.deadlineWheel.cancel(intentId: probeId)
            handler.handleIntentExpired(probeId)
            controller.eventIntake.drainNow()

            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
            XCTAssertEqual(controller.intentLedger.openSameAppCloseProbe()?.intent.id, probeId)

            gate.resume(WindowServerInfo(
                id: windowId, pid: fixture.pid, level: 0,
                frame: CGRect(x: 700, y: 0, width: 700, height: 800)
            ))
            await queryTask.value
            controller.eventIntake.drainNow()

            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNotNil(controller.workspaceManager.entry(for: fixture.closingToken))
            XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
            XCTAssertNil(handler.lifecycleQueries.deferredCloseProbeExpiration)
            XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        }
    }

    func testDelayedSameAppFactsCannotReopenClosedWorkspaceForBothEventOrders() async throws {
        try await Self.verifyDelayedSameAppFacts(order: .focusThenDestroy)
        try await Self.verifyDelayedSameAppFacts(order: .destroyThenFocus)
    }

    func testMouseFocusBypassesPendingDestroyHold() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        await Self.closeFocusedWindow(in: fixture)
        fixture.controller.axEventHandler.noteMouseFocusIntent(token: fixture.remoteToken)
        XCTAssertTrue(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.pid,
                source: .focusedWindowChanged
            )
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        await fixture.controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.pid])
    }

    func testExplicitAppActivationBypassesPendingDestroyHold() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        await Self.closeFocusedWindow(in: fixture)
        XCTAssertTrue(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.pid,
                source: .workspaceDidActivateApplication
            )
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        await fixture.controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.pid])
    }

    func testMatchedReplacementReplaysCurrentHeldSameAppFocus() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        fixture.controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        await Self.closeFocusedWindow(in: fixture)
        _ = try Self.observeRemoteFocus(in: fixture)

        let replacementToken = WindowToken(pid: fixture.pid, windowId: 951_105)
        fixture.controller.axEventHandler.retainPreparedWindowSubscription(
            UInt32(replacementToken.windowId)
        )
        fixture.controller.axEventHandler.enqueueManagedReplacementCreate(
            .init(
                windowId: UInt32(replacementToken.windowId),
                token: replacementToken,
                axRef: WindowAdmissionTestSupport.axRef(for: replacementToken),
                ruleEffects: .none,
                admissionHints: .none,
                appFullscreen: false,
                replacementMetadata: fixture.closingMetadata,
                structuralReplacementMatch: nil
            )
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        XCTAssertTrue(
            fixture.controller.axEventHandler.managedReplacementTraceDump()
                .contains("matched(policy:")
        )
        try await Self.waitForManagedReplacement(
            from: fixture.closingToken,
            to: replacementToken,
            controller: fixture.controller
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
    }

    func testManagedRequestSupersedesHeldProbeOnMatchedReplacement() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        fixture.controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        await Self.closeFocusedWindow(in: fixture)
        _ = try Self.observeRemoteFocus(in: fixture)
        let request = fixture.controller.intentLedger.beginManagedRequest(
            token: fixture.rightToken,
            workspaceId: fixture.localWorkspaceId
        )
        _ = fixture.controller.workspaceManager.beginManagedFocusRequest(
            fixture.rightToken,
            in: fixture.localWorkspaceId,
            requestId: request.requestId
        )

        let replacementToken = WindowToken(pid: fixture.pid, windowId: 951_106)
        fixture.controller.axEventHandler.retainPreparedWindowSubscription(
            UInt32(replacementToken.windowId)
        )
        fixture.controller.axEventHandler.enqueueManagedReplacementCreate(
            .init(
                windowId: UInt32(replacementToken.windowId),
                token: replacementToken,
                axRef: WindowAdmissionTestSupport.axRef(for: replacementToken),
                ruleEffects: .none,
                admissionHints: .none,
                appFullscreen: false,
                replacementMetadata: fixture.closingMetadata,
                structuralReplacementMatch: nil
            )
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fixture.rightToken)
        XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        try await Self.waitForManagedReplacement(
            from: fixture.closingToken,
            to: replacementToken,
            controller: fixture.controller
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fixture.rightToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
    }

    func testFailedPendingReplacementCancelsHeldFocusWithoutReplay() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        fixture.controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in false }
        fixture.controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        await Self.closeFocusedWindow(in: fixture)
        _ = try Self.observeRemoteFocus(in: fixture)

        let replacementToken = WindowToken(pid: fixture.pid, windowId: 951_107)
        fixture.controller.axEventHandler.retainPreparedWindowSubscription(
            UInt32(replacementToken.windowId)
        )
        fixture.controller.axEventHandler.enqueueManagedReplacementCreate(
            .init(
                windowId: UInt32(replacementToken.windowId),
                token: replacementToken,
                axRef: WindowAdmissionTestSupport.axRef(for: replacementToken),
                ruleEffects: .none,
                admissionHints: .none,
                appFullscreen: false,
                replacementMetadata: fixture.closingMetadata,
                structuralReplacementMatch: nil
            )
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        try await Self.waitForAdmissionRetryToFinish(
            windowId: UInt32(replacementToken.windowId),
            controller: fixture.controller
        )
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
    }

    func testResetCancelsHeldSameAppCloseProbe() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.stop(fixture) }

        await Self.closeFocusedWindow(in: fixture)
        _ = try Self.observeRemoteFocus(in: fixture)
        XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())

        fixture.controller.axEventHandler.resetManagedReplacementState()

        XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.closingToken))
    }

    private static func runCloseScenario(order: SameAppFocusOrder?) async throws -> CloseOutcome {
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer {
            controller.eventIntake.close()
            controller.deadlineWheel.stop()
        }

        let probeId: IntentID?
        switch order {
        case .focusThenDestroy:
            probeId = try observeRemoteFocus(in: fixture)
            await closeFocusedWindow(in: fixture)
        case .destroyThenFocus:
            await closeFocusedWindow(in: fixture)
            probeId = try observeRemoteFocus(in: fixture)
        case nil:
            probeId = nil
            await closeFocusedWindow(in: fixture)
        }

        if let probeId {
            controller.deadlineWheel.cancel(intentId: probeId)
            controller.axEventHandler.handleIntentExpired(probeId)
            controller.eventIntake.drainNow()
        }
        await controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.pid])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        let viewport = controller.workspaceManager.niriViewportState(for: fixture.localWorkspaceId)
        let selectedWindowId = [fixture.leftNode, fixture.rightNode]
            .first(where: { $0.id == viewport.selectedNodeId })?
            .token.windowId
        return CloseOutcome(
            activeWorkspaceIsLocal: controller.activeWorkspace()?.id == fixture.localWorkspaceId,
            focusedWindowId: controller.workspaceManager.selectedManagedToken?.windowId,
            preferredWindowId: controller.workspaceManager.preferredFocusToken(
                in: fixture.localWorkspaceId
            )?.windowId,
            selectedWindowId: selectedWindowId,
            activeColumnIndex: viewport.activeColumnIndex,
            viewOffset: viewport.viewOffset,
            closingWindowWasRemoved: controller.workspaceManager.entry(for: fixture.closingToken) == nil
                && fixture.engine.findNode(
                    for: fixture.closingToken,
                    in: fixture.localWorkspaceId
                ) == nil,
            invariantsAreClean: controller.workspaceManager.invariantViolationCountsDump() == "clean"
        )
    }

    private static func verifyDelayedSameAppFacts(order: SameAppFocusOrder) async throws {
        let fixture = try makeFixture()
        defer { stop(fixture) }
        let controller = fixture.controller
        let remoteEntry = try XCTUnwrap(controller.workspaceManager.entry(for: fixture.remoteToken))
        let remoteFact = FocusedWindowFact(
            axRef: remoteEntry.axRef,
            isFullscreen: false,
            isSystemModalSurface: false
        )
        let gate = WindowCloseFocusFactGate()
        controller.factResolver.factProvider = nil
        controller.factResolver.deferredFactProvider = { _ in
            await gate.wait()
        }

        switch order {
        case .focusThenDestroy:
            XCTAssertTrue(
                controller.axEventHandler.handleAppActivation(
                    pid: fixture.pid,
                    source: .focusedWindowChanged
                )
            )
            await closeFocusedWindow(in: fixture)
        case .destroyThenFocus:
            await closeFocusedWindow(in: fixture)
            XCTAssertTrue(
                controller.axEventHandler.handleAppActivation(
                    pid: fixture.pid,
                    source: .focusedWindowChanged
                )
            )
        }

        await controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.pid])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        let settledViewport = controller.workspaceManager.niriViewportState(for: fixture.localWorkspaceId)
        let previousSeq = controller.eventIntake.lastSeq
        await gate.resolve(remoteFact)
        await waitForIntake(after: previousSeq, controller: controller)
        controller.eventIntake.drainNow()
        let viewport = controller.workspaceManager.niriViewportState(for: fixture.localWorkspaceId)

        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertNotEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
        XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
        XCTAssertEqual(viewport.selectedNodeId, settledViewport.selectedNodeId)
        XCTAssertEqual(viewport.activeColumnIndex, settledViewport.activeColumnIndex)
        XCTAssertEqual(viewport.viewOffset, settledViewport.viewOffset, accuracy: 0.5)
    }

    private static func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowCloseFocusRecoveryTests")
        let localWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let remoteWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        let pid: pid_t = 951_001
        let leftToken = WindowToken(pid: pid, windowId: 951_101)
        let closingToken = WindowToken(pid: pid, windowId: 951_102)
        let rightToken = WindowToken(pid: pid, windowId: 951_103)
        let remoteToken = WindowToken(pid: pid, windowId: 951_104)
        let closingMetadata = ManagedReplacementMetadata(
            bundleId: "com.omniwm.tests.close-focus",
            workspaceId: localWorkspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "closing",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 700, y: 0, width: 700, height: 800)
        )
        addWindow(leftToken, workspaceId: localWorkspaceId, controller: controller)
        addWindow(
            closingToken,
            workspaceId: localWorkspaceId,
            controller: controller,
            metadata: closingMetadata
        )
        addWindow(rightToken, workspaceId: localWorkspaceId, controller: controller)
        let remoteAXRef = addWindow(
            remoteToken,
            workspaceId: remoteWorkspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let leftNode = engine.addWindow(token: leftToken, to: localWorkspaceId, afterSelection: nil)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: localWorkspaceId,
            afterSelection: leftNode.id,
            focusedToken: leftToken
        )
        let rightNode = engine.addWindow(
            token: rightToken,
            to: localWorkspaceId,
            afterSelection: closingNode.id,
            focusedToken: closingToken
        )
        let remoteNode = engine.addWindow(token: remoteToken, to: remoteWorkspaceId, afterSelection: nil)
        for node in [leftNode, closingNode, rightNode] {
            engine.column(of: node)?.cachedWidth = 700
        }

        let monitorId = controller.workspaceManager.monitorId(for: localWorkspaceId)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: closingToken,
            in: localWorkspaceId,
            onMonitor: monitorId
        )
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                closingToken,
                in: localWorkspaceId,
                onMonitor: monitorId
            )
        )
        var localViewport = controller.workspaceManager.niriViewportState(for: localWorkspaceId)
        localViewport.activeColumnIndex = 1
        localViewport.selectedNodeId = closingNode.id
        localViewport.viewOffset = 315
        controller.workspaceManager.updateNiriViewportState(localViewport, for: localWorkspaceId)
        var remoteViewport = controller.workspaceManager.niriViewportState(for: remoteWorkspaceId)
        remoteViewport.selectedNodeId = remoteNode.id
        controller.workspaceManager.updateNiriViewportState(remoteViewport, for: remoteWorkspaceId)

        controller.factResolver.factProvider = { observedPid in
            guard observedPid == pid else { return nil }
            return FocusedWindowFact(
                axRef: remoteAXRef,
                isFullscreen: false,
                isSystemModalSurface: false
            )
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)

        return Fixture(
            controller: controller,
            engine: engine,
            localWorkspaceId: localWorkspaceId,
            remoteWorkspaceId: remoteWorkspaceId,
            pid: pid,
            leftToken: leftToken,
            closingToken: closingToken,
            rightToken: rightToken,
            remoteToken: remoteToken,
            leftNode: leftNode,
            closingNode: closingNode,
            rightNode: rightNode,
            closingMetadata: closingMetadata
        )
    }

    private static func observeRemoteFocus(in fixture: Fixture) throws -> IntentID {
        XCTAssertTrue(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.pid,
                source: .focusedWindowChanged
            )
        )
        fixture.controller.eventIntake.drainNow()
        return try XCTUnwrap(fixture.controller.intentLedger.openSameAppCloseProbe()?.intent.id)
    }

    private static func closeFocusedWindow(in fixture: Fixture) async {
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(fixture.closingToken.windowId))
        )
        await fixture.controller.axEventHandler.lifecycleQueries.task?.value
    }

    private static func stop(_ fixture: Fixture) {
        fixture.controller.axEventHandler.resetManagedReplacementState()
        fixture.controller.eventIntake.close()
        fixture.controller.deadlineWheel.stop()
    }

    private static func waitForManagedReplacement(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        controller: WMController
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        let windowId = try XCTUnwrap(UInt32(exactly: newToken.windowId))
        while (controller.workspaceManager.entry(for: newToken) == nil
            || controller.axEventHandler.admissionRetryStateByWindowId[windowId] != nil),
            clock.now < deadline
        {
            await Task.yield()
        }
        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: newToken))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    private static func waitForAdmissionRetryToFinish(
        windowId: UInt32,
        controller: WMController
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while controller.axEventHandler.admissionRetryStateByWindowId[windowId] != nil,
              clock.now < deadline
        {
            await Task.yield()
        }
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    private static func waitForIntake(after sequence: UInt64, controller: WMController) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while controller.eventIntake.lastSeq <= sequence, clock.now < deadline {
            await Task.yield()
        }
        XCTAssertGreaterThan(controller.eventIntake.lastSeq, sequence)
    }

    @discardableResult
    private static func addWindow(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        metadata: ManagedReplacementMetadata? = nil
    ) -> AXWindowRef {
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        return axRef
    }
}
