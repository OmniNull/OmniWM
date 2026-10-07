// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

private actor DwindleCloseFocusFactGate {
    private var fact: FocusedWindowFact?
    private var isResolved = false
    private var waiters: [CheckedContinuation<FocusedWindowFact?, Never>] = []

    func wait() async -> FocusedWindowFact? {
        if isResolved { return fact }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ fact: FocusedWindowFact) {
        self.fact = fact
        isResolved = true
        for waiter in waiters {
            waiter.resume(returning: fact)
        }
        waiters.removeAll()
    }
}

@MainActor
final class DwindleWindowCloseFocusRecoveryTests: XCTestCase {
    private enum LayoutPair: CaseIterable {
        case dwindleToDwindle
        case dwindleToNiri
        case niriToDwindle

        var local: LayoutType {
            self == .niriToDwindle ? .niri : .dwindle
        }

        var remote: LayoutType {
            self == .dwindleToNiri ? .niri : .dwindle
        }
    }

    private enum FocusOrder: CaseIterable {
        case focusThenDestroy
        case destroyThenFocus
    }

    private enum FocusBypass {
        case mouse
        case appActivation
        case managedRequest
    }

    private struct Fixture {
        let controller: WMController
        let localWorkspaceId: WorkspaceDescriptor.ID
        let remoteWorkspaceId: WorkspaceDescriptor.ID
        let closingToken: WindowToken
        let fallbackToken: WindowToken
        let remoteToken: WindowToken
    }

    func testDwindleCloseHoldsDwindleFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .dwindleToDwindle)
    }

    func testDwindleCloseHoldsNiriFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .dwindleToNiri)
    }

    func testNiriCloseHoldsDwindleFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .niriToDwindle)
    }

    func testDwindleCloseFocusesTreeNeighborAheadOfOldestWindow() async throws {
        let oldestToken = WindowToken(pid: 952_103, windowId: 952_204)
        let fixture = try Self.makeFixture(layouts: .dwindleToDwindle, oldestToken: oldestToken)
        defer { Self.stop(fixture) }
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let closingNode = try XCTUnwrap(engine.findNode(for: fixture.closingToken, in: fixture.localWorkspaceId))
        XCTAssertEqual(closingNode.sibling()?.windowToken, fixture.fallbackToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.windowQueries
                .windows(in: fixture.localWorkspaceId, mode: .tiling).first?.token,
            oldestToken
        )

        await Self.closeFocusedWindow(in: fixture)
        await Self.settleClose(fixture)

        Self.assertRecoveredLocally(fixture)
        XCTAssertEqual(engine.projectedActiveToken(in: fixture.localWorkspaceId), fixture.fallbackToken)
        XCTAssertTrue(engine.containsWindow(oldestToken, in: fixture.localWorkspaceId))
    }

    func testDwindleCloseOfStackTopFocusesWindowBelowAfterObservedFocus() async throws {
        try await Self.verifyCloseFocusesNearestWindow(.stack, keyboardPathToClosing: nil)
    }

    func testDwindleCloseOfStackTopFocusesWindowBelowAfterKeyboardFocus() async throws {
        try await Self.verifyCloseFocusesNearestWindow(.stack, keyboardPathToClosing: [.up, .up, .up])
    }

    func testDwindleCloseOfSpiralRootFocusesTopNeighborAfterObservedFocus() async throws {
        try await Self.verifyCloseFocusesNearestWindow(.spiral, keyboardPathToClosing: nil)
    }

    func testDwindleCloseOfSpiralRootFocusesTopNeighborAfterKeyboardFocus() async throws {
        try await Self.verifyCloseFocusesNearestWindow(.spiral, keyboardPathToClosing: [.left, .up, .left])
    }

    private enum TreeShape {
        case stack
        case spiral

        var smartSplit: Bool {
            self == .stack
        }

        var structuralFirstLeafIndex: Int {
            self == .stack ? 3 : 2
        }

        var siblingDirection: Direction {
            self == .stack ? .down : .right
        }

        var navigationNeighborIndex: Int {
            self == .stack ? 1 : 2
        }
    }

    func testDwindleCloseWithEdgeGapsFocusesTopNeighborOfTiedSubtree() async throws {
        let (fixture, windows) = try Self.makeSequentialFixture(
            windowCount: 6,
            smartSplit: false,
            closingIndex: 2,
            nearestIndex: 3,
            monitorFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            gaps: (inner: 16, outer: 0)
        )
        defer { Self.stop(fixture) }
        let controller = fixture.controller
        let workspaceId = fixture.localWorkspaceId
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let closing = fixture.closingToken
        let top = fixture.fallbackToken
        let bottomLeft = windows[4]
        try Self.observeFocus(on: closing, controller: controller, confirmRequest: false)

        let closingNode = try XCTUnwrap(engine.findNode(for: closing, in: workspaceId))
        XCTAssertEqual(closingNode.sibling()?.descendToFirstLeaf().windowToken, bottomLeft)
        let frames = engine.currentFrames(in: workspaceId)
        let closingFrame = try XCTUnwrap(frames[closing])
        let topFrame = try XCTUnwrap(frames[top])
        let bottomLeftFrame = try XCTUnwrap(frames[bottomLeft])
        XCTAssertEqual(bottomLeftFrame.minY, closingFrame.minY, accuracy: 0.5)
        XCTAssertEqual(topFrame.maxY, closingFrame.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(bottomLeftFrame.height, topFrame.height)
        XCTAssertEqual(engine.findGeometricNeighbor(from: closing, direction: .right, in: workspaceId), bottomLeft)

        await Self.closeFocusedWindow(in: fixture)
        await Self.settleClose(fixture)

        Self.assertRecoveredLocally(fixture)
        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), top)
    }

    func testDwindleCloseBelowSideBySideNeighborsFocusesLeftmostOnTie() async throws {
        let (fixture, windows) = try Self.makeSequentialFixture(
            windowCount: 5,
            smartSplit: false,
            closingIndex: 2,
            nearestIndex: 4,
            admissionAnchors: [3: 1, 4: 1]
        )
        defer { Self.stop(fixture) }
        let controller = fixture.controller
        let workspaceId = fixture.localWorkspaceId
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let closing = fixture.closingToken
        let shortLeft = fixture.fallbackToken
        let tallRight = windows[3]
        try Self.observeFocus(on: closing, controller: controller, confirmRequest: false)

        let frames = engine.currentFrames(in: workspaceId)
        let closingFrame = try XCTUnwrap(frames[closing])
        let shortLeftFrame = try XCTUnwrap(frames[shortLeft])
        let tallRightFrame = try XCTUnwrap(frames[tallRight])
        XCTAssertGreaterThan(shortLeftFrame.minY, closingFrame.maxY)
        XCTAssertGreaterThan(tallRightFrame.minY, closingFrame.maxY)
        XCTAssertLessThan(shortLeftFrame.minX, tallRightFrame.minX)
        XCTAssertGreaterThan(tallRightFrame.maxY, shortLeftFrame.maxY)
        XCTAssertGreaterThan(tallRightFrame.width, shortLeftFrame.width)

        await Self.closeFocusedWindow(in: fixture)
        await Self.settleClose(fixture)

        Self.assertRecoveredLocally(fixture)
        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), shortLeft)
    }

    func testDwindleFocusRightFromSpiralRootKeepsTreeOrderTieResolution() throws {
        let (fixture, windows) = try Self.makeSequentialFixture(windowCount: 3, smartSplit: false)
        defer { Self.stop(fixture) }
        let controller = fixture.controller
        let workspaceId = fixture.localWorkspaceId
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let root = windows[0]
        let topRight = windows[1]
        let bottomRight = windows[2]
        try Self.observeFocus(on: root, controller: controller, confirmRequest: false)

        let frames = engine.currentFrames(in: workspaceId)
        let rootFrame = try XCTUnwrap(frames[root])
        let topRightFrame = try XCTUnwrap(frames[topRight])
        let bottomRightFrame = try XCTUnwrap(frames[bottomRight])
        XCTAssertGreaterThan(topRightFrame.minY, bottomRightFrame.minY)
        XCTAssertGreaterThan(topRightFrame.minX, rootFrame.maxX)
        XCTAssertGreaterThan(bottomRightFrame.minX, rootFrame.maxX)
        XCTAssertEqual(topRightFrame.height, bottomRightFrame.height, accuracy: 0.5)

        XCTAssertEqual(engine.findGeometricNeighbor(from: root, direction: .right, in: workspaceId), bottomRight)
        XCTAssertTrue(controller.dwindleLayoutHandler.focusNeighbor(direction: .right))
        XCTAssertEqual(engine.activeToken(in: workspaceId), bottomRight)
    }

    private static func verifyCloseFocusesNearestWindow(
        _ shape: TreeShape,
        keyboardPathToClosing: [Direction]?
    ) async throws {
        let (fixture, windows) = try makeSequentialFixture(windowCount: 4, smartSplit: shape.smartSplit)
        defer { stop(fixture) }
        let controller = fixture.controller
        let workspaceId = fixture.localWorkspaceId
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let closing = fixture.closingToken
        let nearest = fixture.fallbackToken

        if let keyboardPathToClosing {
            for direction in keyboardPathToClosing {
                XCTAssertTrue(controller.dwindleLayoutHandler.focusNeighbor(direction: direction))
                let focused = try XCTUnwrap(engine.activeToken(in: workspaceId))
                try observeFocus(on: focused, controller: controller)
            }
            XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, closing)
        } else {
            try observeFocus(on: closing, controller: controller, confirmRequest: false)
        }

        let closingNode = try XCTUnwrap(engine.findNode(for: closing, in: workspaceId))
        XCTAssertEqual(
            closingNode.sibling()?.descendToFirstLeaf().windowToken,
            windows[shape.structuralFirstLeafIndex]
        )
        XCTAssertEqual(
            engine.findGeometricNeighbor(from: closing, direction: shape.siblingDirection, in: workspaceId),
            windows[shape.navigationNeighborIndex]
        )

        await closeFocusedWindow(in: fixture)
        await settleClose(fixture)

        assertRecoveredLocally(fixture)
        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), nearest)
    }

    func testDelayedFocusFactsCannotLeaveLocalWorkspaceAfterRemoval() async throws {
        for layouts in LayoutPair.allCases {
            for order in FocusOrder.allCases {
                let fixture = try Self.makeFixture(layouts: layouts)
                defer { Self.stop(fixture) }
                let controller = fixture.controller
                let gate = DwindleCloseFocusFactGate()
                let remoteEntry = try XCTUnwrap(controller.workspaceManager.entry(for: fixture.remoteToken))
                let remoteFact = FocusedWindowFact(
                    axRef: remoteEntry.axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
                controller.factResolver.factProvider = nil
                controller.factResolver.deferredFactProvider = { _ in await gate.wait() }

                if order == .destroyThenFocus { await Self.closeFocusedWindow(in: fixture) }
                XCTAssertTrue(
                    controller.axEventHandler.handleAppActivation(
                        pid: fixture.closingToken.pid,
                        source: .focusedWindowChanged
                    )
                )
                if order == .focusThenDestroy { await Self.closeFocusedWindow(in: fixture) }
                Self.assertPendingCloseStaysLocal(fixture)
                await Self.settleClose(fixture)
                Self.assertRecoveredLocally(fixture)

                let previousSeq = controller.eventIntake.lastSeq
                await gate.resolve(remoteFact)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                while controller.eventIntake.lastSeq <= previousSeq, clock.now < deadline {
                    await Task.yield()
                }
                XCTAssertGreaterThan(controller.eventIntake.lastSeq, previousSeq)
                controller.eventIntake.drainNow()
                Self.assertRecoveredLocally(fixture)
            }
        }
    }

    func testSameAppFocusWithoutDestroyResolvesWhenProbeExpires() throws {
        for layouts in LayoutPair.allCases {
            let fixture = try Self.makeFixture(layouts: layouts)
            defer { Self.stop(fixture) }
            let probeId = try Self.observeRemoteFocus(in: fixture)
            Self.assertPendingCloseStaysLocal(fixture)

            Self.expireProbe(probeId, in: fixture)

            XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
            XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.closingToken))
        }
    }

    func testMouseFocusBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.mouse)
    }

    func testExplicitAppActivationBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.appActivation)
    }

    func testMatchingManagedRequestBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.managedRequest)
    }

    private static func verifyCloseRecovery(layouts: LayoutPair) async throws {
        for order in FocusOrder.allCases {
            let fixture = try makeFixture(layouts: layouts)
            defer { stop(fixture) }
            if order == .destroyThenFocus { await closeFocusedWindow(in: fixture) }
            let probeId = try observeRemoteFocus(in: fixture)
            if order == .focusThenDestroy { await closeFocusedWindow(in: fixture) }
            assertPendingCloseStaysLocal(fixture)

            expireProbe(probeId, in: fixture)
            assertPendingCloseStaysLocal(fixture)
            XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())

            await settleClose(fixture)
            assertRecoveredLocally(fixture)
        }
    }

    private static func verifyFocusBypass(_ bypass: FocusBypass) async throws {
        for layouts in LayoutPair.allCases {
            let fixture = try makeFixture(layouts: layouts)
            defer { stop(fixture) }
            let controller = fixture.controller
            await closeFocusedWindow(in: fixture)
            switch bypass {
            case .mouse:
                controller.axEventHandler.noteMouseFocusIntent(token: fixture.remoteToken)
            case .appActivation:
                break
            case .managedRequest:
                let request = controller.intentLedger.beginManagedRequest(
                    token: fixture.remoteToken,
                    workspaceId: fixture.remoteWorkspaceId
                )
                _ = controller.workspaceManager.beginManagedFocusRequest(
                    fixture.remoteToken,
                    in: fixture.remoteWorkspaceId,
                    requestId: request.requestId
                )
                assertPendingCloseStaysLocal(fixture)
            }
            XCTAssertTrue(
                controller.axEventHandler.handleAppActivation(
                    pid: fixture.closingToken.pid,
                    source: bypass == .appActivation ? .workspaceDidActivateApplication : .focusedWindowChanged
                )
            )
            controller.eventIntake.drainNow()

            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
            await settleClose(fixture, confirmRecovery: false)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
            XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        }
    }

    private struct Scaffold {
        let controller: WMController
        let monitor: Monitor
        let localWorkspaceId: WorkspaceDescriptor.ID
        let remoteWorkspaceId: WorkspaceDescriptor.ID
    }

    private static func makeScaffold(
        layouts: LayoutPair,
        monitorFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 860)
    ) throws -> Scaffold {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMDwindleCloseFocusTests")
        controller.settings.animationsEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 952_001),
            displayId: 952_001,
            frame: monitorFrame,
            visibleFrame: visibleFrame,
            hasNotch: false,
            name: "Dwindle Close Focus"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let localWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "91", layoutType: layouts.local, controller: controller
        ))
        let remoteWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "92", layoutType: layouts.remote, controller: controller
        ))
        _ = controller.workspaceManager.focusWorkspace(named: "91")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        controller.layoutRefreshController.resetState()
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        return Scaffold(
            controller: controller,
            monitor: monitor,
            localWorkspaceId: localWorkspaceId,
            remoteWorkspaceId: remoteWorkspaceId
        )
    }

    private static func makeSequentialFixture(
        windowCount: Int,
        smartSplit: Bool,
        closingIndex: Int = 0,
        nearestIndex: Int = 1,
        monitorFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 860),
        gaps: (inner: CGFloat, outer: CGFloat)? = nil,
        admissionAnchors: [Int: Int] = [:]
    ) throws -> (fixture: Fixture, windows: [WindowToken]) {
        let scaffold = try makeScaffold(
            layouts: .dwindleToDwindle,
            monitorFrame: monitorFrame,
            visibleFrame: visibleFrame
        )
        let controller = scaffold.controller
        let workspaceId = scaffold.localWorkspaceId
        controller.settings.dwindle.smartSplit = smartSplit
        if let gaps {
            controller.settings.gaps.size = gaps.inner
            controller.settings.gaps.outerGapLeft = gaps.outer
            controller.settings.gaps.outerGapRight = gaps.outer
            controller.settings.gaps.outerGapTop = gaps.outer
            controller.settings.gaps.outerGapBottom = gaps.outer
        }
        var windows: [WindowToken] = []
        for index in 0 ..< windowCount {
            let token = WindowToken(pid: 952_301, windowId: 952_401 + index)
            if let anchorIndex = admissionAnchors[index] {
                try observeFocus(on: windows[anchorIndex], controller: controller, confirmRequest: false)
            }
            admitWindow(token, to: workspaceId, controller: controller)
            relayout(workspaceId, controller: controller)
            try observeFocus(on: token, controller: controller, confirmRequest: false)
            windows.append(token)
        }
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        let fixture = Fixture(
            controller: controller,
            localWorkspaceId: workspaceId,
            remoteWorkspaceId: scaffold.remoteWorkspaceId,
            closingToken: windows[closingIndex],
            fallbackToken: windows[nearestIndex],
            remoteToken: WindowToken(pid: 952_301, windowId: 952_499)
        )
        return (fixture, windows)
    }

    private static func admitWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) {
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.omniwm.tests.dwindle-close-focus",
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "stacked \(token.windowId)",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 860)
            )
        )
    }

    private static func relayout(_ workspaceId: WorkspaceDescriptor.ID, controller: WMController) {
        let plan = controller.layoutRefreshController.buildRelayoutEffectPlan(
            useScrollAnimationPath: false,
            recoverFocus: false,
            affectedWorkspaceIds: [workspaceId]
        )
        controller.layoutRefreshController.applyEffectPlan(plan, controller: controller)
    }

    private static func observeFocus(
        on token: WindowToken,
        controller: WMController,
        confirmRequest: Bool? = nil
    ) throws {
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: confirmRequest
        )
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, token)
        XCTAssertEqual(controller.dwindleEngine?.activeToken(in: entry.workspaceId), token)
    }

    private static func makeFixture(layouts: LayoutPair, oldestToken: WindowToken? = nil) throws -> Fixture {
        let scaffold = try makeScaffold(layouts: layouts)
        let controller = scaffold.controller
        let monitor = scaffold.monitor
        let localWorkspaceId = scaffold.localWorkspaceId
        let remoteWorkspaceId = scaffold.remoteWorkspaceId

        let closingToken = WindowToken(pid: 952_101, windowId: 952_201)
        let fallbackToken = WindowToken(pid: 952_102, windowId: 952_202)
        let remoteToken = WindowToken(pid: closingToken.pid, windowId: 952_203)
        if let oldestToken {
            addWindow(oldestToken, to: localWorkspaceId, controller: controller)
        }
        addWindow(fallbackToken, to: localWorkspaceId, controller: controller)
        addWindow(
            closingToken,
            to: localWorkspaceId,
            controller: controller,
            metadata: ManagedReplacementMetadata(
                bundleId: "com.omniwm.tests.dwindle-close-focus",
                workspaceId: localWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "closing",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 720, y: 0, width: 720, height: 860)
            )
        )
        let remoteAXRef = addWindow(remoteToken, to: remoteWorkspaceId, controller: controller)
        let closingNode = controller.niriEngine?.findNode(for: closingToken, in: localWorkspaceId)
        controller.workspaceManager.withEngineMutationScope(in: localWorkspaceId) {
            if let closingNode {
                controller.niriEngine?.activateWindow(closingNode.id, in: localWorkspaceId)
            } else {
                _ = controller.dwindleEngine?.activateWindow(closingToken, in: localWorkspaceId)
            }
        }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode?.id,
            focusedToken: closingToken,
            in: localWorkspaceId,
            onMonitor: monitor.id
        )
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(
            closingToken,
            in: localWorkspaceId,
            onMonitor: monitor.id
        ))
        controller.factResolver.factProvider = { pid in
            guard pid == closingToken.pid else { return nil }
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
            localWorkspaceId: localWorkspaceId,
            remoteWorkspaceId: remoteWorkspaceId,
            closingToken: closingToken,
            fallbackToken: fallbackToken,
            remoteToken: remoteToken
        )
    }

    @discardableResult
    private static func addWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
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
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return axRef
    }

    private static func observeRemoteFocus(in fixture: Fixture) throws -> IntentID {
        XCTAssertTrue(fixture.controller.axEventHandler.handleAppActivation(
            pid: fixture.closingToken.pid,
            source: .focusedWindowChanged
        ))
        fixture.controller.eventIntake.drainNow()
        assertPendingCloseStaysLocal(fixture)
        return try XCTUnwrap(fixture.controller.intentLedger.openSameAppCloseProbe()?.intent.id)
    }

    private static func closeFocusedWindow(in fixture: Fixture) async {
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(fixture.closingToken.windowId))
        )
        await fixture.controller.axEventHandler.lifecycleQueries.task?.value
    }

    private static func expireProbe(_ probeId: IntentID, in fixture: Fixture) {
        fixture.controller.deadlineWheel.cancel(intentId: probeId)
        fixture.controller.axEventHandler.handleIntentExpired(probeId)
        fixture.controller.eventIntake.drainNow()
    }

    private static func assertPendingCloseStaysLocal(_ fixture: Fixture) {
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.closingToken)
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.closingToken))
    }

    private static func settleClose(_ fixture: Fixture, confirmRecovery: Bool = true) async {
        let controller = fixture.controller
        await controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.closingToken.pid])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        guard confirmRecovery else { return }
        guard let request = controller.intentLedger.activeManagedRequest else {
            XCTFail("Closing the focused window must request focus on the surviving local window")
            return
        }
        XCTAssertEqual(request.token, fixture.fallbackToken)
        XCTAssertEqual(request.workspaceId, fixture.localWorkspaceId)
        guard request.token == fixture.fallbackToken, request.workspaceId == fixture.localWorkspaceId else { return }
        XCTAssertTrue(controller.workspaceManager.pendingManagedFocusMatches(
            token: fixture.fallbackToken,
            workspaceId: fixture.localWorkspaceId,
            requestId: request.requestId
        ))
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            fixture.fallbackToken,
            in: fixture.localWorkspaceId,
            activateWorkspaceOnMonitor: false,
            requestId: request.requestId
        ))
        XCTAssertNotNil(controller.intentLedger.confirmManagedRequest(
            token: fixture.fallbackToken,
            source: .focusedWindowChanged
        ))
    }

    private static func assertRecoveredLocally(_ fixture: Fixture) {
        let controller = fixture.controller
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.fallbackToken)
        XCTAssertEqual(
            controller.workspaceManager.preferredFocusToken(in: fixture.localWorkspaceId),
            fixture.fallbackToken
        )
        XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNil(controller.niriEngine?.findNode(for: fixture.closingToken, in: fixture.localWorkspaceId))
        XCTAssertFalse(controller.dwindleEngine?
            .containsWindow(fixture.closingToken, in: fixture.localWorkspaceId) ?? false)
        XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    private static func stop(_ fixture: Fixture) {
        fixture.controller.axEventHandler.resetManagedReplacementState()
        fixture.controller.eventIntake.close()
        fixture.controller.deadlineWheel.stop()
        fixture.controller.layoutRefreshController.resetState()
        fixture.controller.hasStartedServices = false
    }
}
