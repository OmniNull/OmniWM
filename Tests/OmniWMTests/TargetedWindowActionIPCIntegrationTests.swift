// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class TargetedWindowActionIPCIntegrationTests: XCTestCase {
    private final class FocusRecorder {
        var focusedTokens: [WindowToken] = []
    }

    @MainActor
    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let niriWorkspaceId: WorkspaceDescriptor.ID
        let dwindleWorkspaceId: WorkspaceDescriptor.ID
        let otherNiriWorkspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let focusRecorder: FocusRecorder
        let windows: [WindowHandle]
        let focused: WindowHandle

        var engine: NiriLayoutEngine {
            controller.niriEngine!
        }

        var viewport: ViewportState {
            controller.workspaceManager.niriViewportState(for: niriWorkspaceId)
        }

        func frame(of handle: WindowHandle) -> CGRect? {
            controller.niriLayoutHandler.settledFrames(in: niriWorkspaceId)?[handle.id]
        }

        func columnSignature() -> [String] {
            engine.columns(in: niriWorkspaceId).map { column in
                "\(column.windowNodes.map(\.token))-\(column.width)-\(column.isFullWidth)-\(column.displayMode)"
            }
        }
    }

    private struct Scenario {
        let name: String
        let targetIndex: Int
        let request: (String) -> IPCWindowRequest
    }

    func testBackgroundColumnActionsKeepFocusAndTheFocusedFrame() async throws {
        let scenarios: [Scenario] = [
            .init(name: "full span of the off-screen column left of focus", targetIndex: 1) {
                IPCWindowRequest(name: .toggleContainerFullPrimarySpan, windowId: $0)
            },
            .init(name: "grow the column right of focus", targetIndex: 3) {
                IPCWindowRequest(name: .setContainerPrimarySpan, windowId: $0, change: .setProportion(60))
            },
            .init(name: "grow the window right of focus", targetIndex: 3) {
                IPCWindowRequest(name: .setWindowPrimarySpan, windowId: $0, change: .adjustProportion(20))
            },
            .init(name: "cycle the column left of focus", targetIndex: 1) {
                IPCWindowRequest(name: .cycleWindowPrimarySpan, windowId: $0, cycle: .forward)
            },
            .init(name: "tab the column right of focus", targetIndex: 3) {
                IPCWindowRequest(name: .toggleColumnTabbed, windowId: $0)
            },
            .init(name: "move a right column first", targetIndex: 3) {
                IPCWindowRequest(name: .moveColumnToFirst, windowId: $0)
            },
            .init(name: "move a left column last", targetIndex: 1) {
                IPCWindowRequest(name: .moveColumnToLast, windowId: $0)
            },
            .init(name: "move the last column to index two", targetIndex: 4) {
                IPCWindowRequest(name: .moveColumnToIndex, windowId: $0, columnIndex: 2)
            },
            .init(name: "move a right column left past focus", targetIndex: 3) {
                IPCWindowRequest(name: .moveColumn, windowId: $0, direction: .left)
            }
        ]

        for scenario in scenarios {
            let fixture = try await makeFlushLeftFixture()
            let before = try XCTUnwrap(fixture.frame(of: fixture.focused), scenario.name)
            let signature = fixture.columnSignature()
            let target = fixture.windows[scenario.targetIndex]

            XCTAssertEqual(fixture.router.handle(scenario.request(opaqueId(target))), .executed, scenario.name)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertNotEqual(fixture.columnSignature(), signature, scenario.name)
            assertFocusUnchanged(fixture, scenario.name)
            XCTAssertEqual(fixture.frame(of: fixture.focused), before, scenario.name)
        }
    }

    func testFiveThirdWidthColumnsKeepTheFlushFocusedColumnWhenANeighbourGrows() async throws {
        let requests: [(Int, (String) -> IPCWindowRequest)] = [
            (1, { IPCWindowRequest(name: .toggleContainerFullPrimarySpan, windowId: $0) }),
            (3, { IPCWindowRequest(name: .setContainerPrimarySpan, windowId: $0, change: .setProportion(90)) })
        ]
        for (targetIndex, request) in requests {
            let fixture = try await makeFlushLeftFixture(columnCount: 5)
            let before = try XCTUnwrap(fixture.frame(of: fixture.focused))

            XCTAssertEqual(fixture.router.handle(request(opaqueId(fixture.windows[targetIndex]))), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            assertFocusUnchanged(fixture)
            XCTAssertEqual(fixture.frame(of: fixture.focused), before)
        }
    }

    func testSecondarySpanActionsOnABackgroundWindowKeepFocusAndTheFocusedFrame() async throws {
        let requests: [(String) -> IPCWindowRequest] = [
            { IPCWindowRequest(name: .setWindowSecondarySpan, windowId: $0, change: .setProportion(50)) },
            { IPCWindowRequest(name: .cycleWindowSecondarySpan, windowId: $0, cycle: .backward) },
            { IPCWindowRequest(name: .resetWindowSecondarySpan, windowId: $0) }
        ]
        let fixture = try await makeFlushLeftFixture()
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))

        for request in requests {
            XCTAssertEqual(fixture.router.handle(request(opaqueId(fixture.windows[3]))), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            assertFocusUnchanged(fixture)
            XCTAssertEqual(fixture.frame(of: fixture.focused), before)
        }
    }

    func testTargetingTheFocusedWindowMatchesTheFocusedCommand() async throws {
        let targeted = try await makeFlushLeftFixture()
        let focused = try await makeFlushLeftFixture()

        XCTAssertEqual(
            targeted.router.handle(
                IPCWindowRequest(name: .toggleContainerFullPrimarySpan, windowId: opaqueId(targeted.focused))
            ),
            .executed
        )
        XCTAssertTrue(focused.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())
        await WindowAdmissionTestSupport.drainLayoutRefreshes(targeted.controller)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(focused.controller)

        XCTAssertEqual(targeted.columnSignature(), focused.columnSignature())
        XCTAssertEqual(targeted.viewport.viewOffset, focused.viewport.viewOffset)
        XCTAssertEqual(targeted.viewport.activeColumnIndex, focused.viewport.activeColumnIndex)
        XCTAssertEqual(targeted.frame(of: targeted.focused), focused.frame(of: focused.focused))
        assertFocusUnchanged(targeted)
    }

    func testFloatingAndScratchpadReleaseOfBackgroundWindowsKeepFocusAndTheFocusedFrame() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let floated = fixture.windows[1]
        let released = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(512_400), windowId: 512_401),
            pid: 512_400,
            windowId: 512_401,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        _ = manager.setScratchpadMembership(released, to: try XCTUnwrap(ScratchpadIndex(1)))

        let steps: [IPCWindowRequest] = [
            IPCWindowRequest(name: .toggleFloating, windowId: opaqueId(floated)),
            IPCWindowRequest(name: .toggleFloating, windowId: opaqueId(floated)),
            IPCWindowRequest(
                name: .assignToScratchpad,
                windowId: IPCWindowOpaqueID.encode(
                    pid: released.pid,
                    windowId: released.windowId,
                    sessionToken: "test"
                ),
                scratchpadIndex: 1
            )
        ]
        for step in steps {
            XCTAssertEqual(fixture.router.handle(step), .executed, "\(step.name)")
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            assertFocusUnchanged(fixture, "\(step.name)")
            XCTAssertEqual(fixture.frame(of: fixture.focused), before, "\(step.name)")
        }
        XCTAssertNil(manager.scratchpadIndex(for: released))
    }

    func testScratchpadHideOfABackgroundColumnKeepsFocusAndTheFocusedFrame() async throws {
        let fixture = try await makeFlushLeftFixture()
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let assigned = fixture.windows[3]
        fixture.controller.axManager.confirmFrameWrite(
            for: assigned.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(name: .assignToScratchpad, windowId: opaqueId(assigned), scratchpadIndex: 2)
            ),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadIndex(for: assigned.id), 2)
        XCTAssertNil(fixture.engine.findNode(for: assigned, in: fixture.niriWorkspaceId))
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testQuietArrivalTilesWithoutTakingSelectionWhileANormalArrivalDoes() async throws {
        for arrivesQuietly in [true, false] {
            let fixture = try await makeFlushLeftFixture()
            let manager = fixture.controller.workspaceManager
            let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
            let token = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(512_100), windowId: 512_101),
                pid: 512_100,
                windowId: 512_101,
                to: fixture.niriWorkspaceId,
                mode: .floating
            )

            retile(token, quietly: arrivesQuietly, fixture)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            let arrived = try XCTUnwrap(fixture.engine.findNode(for: token, in: fixture.niriWorkspaceId))
            XCTAssertTrue(manager.quietArrivalTokens.isEmpty)
            if arrivesQuietly {
                assertFocusUnchanged(fixture)
                XCTAssertEqual(fixture.frame(of: fixture.focused), before)
            } else {
                XCTAssertEqual(fixture.viewport.selectedNodeId, arrived.id)
            }
        }
    }

    func testQuietRetileOfAHiddenAppWindowJoinsTheLayoutWhenTheAppUnhides() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(512_500), windowId: 512_501),
            pid: 512_500,
            windowId: 512_501,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        manager.setAppHidden(true, pid: token.pid, source: .ax)

        retile(token, quietly: true, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let summary = fixture.engine.columnSummary(in: fixture.niriWorkspaceId, state: fixture.viewport, geometry: nil)
        XCTAssertNil(summary.columnIndexByToken[token])
        XCTAssertTrue(manager.quietArrivalTokens.isEmpty)
        assertFocusUnchanged(fixture)

        manager.setAppHidden(false, pid: token.pid, source: .ax)
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let unhiddenSummary = fixture.engine.columnSummary(
            in: fixture.niriWorkspaceId,
            state: fixture.viewport,
            geometry: nil
        )
        XCTAssertNotNil(unhiddenSummary.columnIndexByToken[token])
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testAssigningAHiddenScratchpadMemberToItsSlotReleasesItQuietly() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let member = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(512_600), windowId: 512_601),
            pid: 512_600,
            windowId: 512_601,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        fixture.controller.axManager.confirmFrameWrite(
            for: member.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let request = IPCWindowRequest(
            name: .assignToScratchpad,
            windowId: IPCWindowOpaqueID.encode(pid: member.pid, windowId: member.windowId, sessionToken: "test"),
            scratchpadIndex: 3
        )

        XCTAssertEqual(fixture.router.handle(request), .executed)
        XCTAssertEqual(manager.hiddenState(for: member)?.isScratchpad, true)

        XCTAssertEqual(fixture.router.handle(request), .executed)
        try completeReveal(member, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertNil(manager.scratchpadIndex(for: member))
        XCTAssertNil(manager.hiddenState(for: member))
        XCTAssertEqual(manager.manualLayoutOverride(for: member), .forceTile)
        assertFocusUnchanged(fixture)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testReleasingAScratchpadWindowHiddenFromAnotherWorkspaceAddsItsOwnColumnAfterFocus() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        for windowId in [512_702, 512_703] {
            _ = try addWindow(
                pid: 512_700, windowId: windowId, to: fixture.otherNiriWorkspaceId, controller: fixture.controller
            )
        }
        let released = try addWindow(
            pid: 512_700, windowId: 512_701, to: fixture.otherNiriWorkspaceId, controller: fixture.controller
        )
        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.otherNiriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let focusedColumnIndex = try XCTUnwrap(
            fixture.engine.persistedPlacement(for: fixture.focused.id, in: fixture.niriWorkspaceId)?.columnIndex
        )
        XCTAssertEqual(manager.restoreIntent(for: released.id)?.niriPlacement?.columnIndex, focusedColumnIndex)
        fixture.controller.axManager.confirmFrameWrite(
            for: released.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let request = IPCWindowRequest(name: .assignToScratchpad, windowId: opaqueId(released), scratchpadIndex: 2)

        XCTAssertEqual(fixture.router.handle(request), .executed)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(manager.hiddenState(for: released.id)?.isScratchpad, true)
        XCTAssertEqual(manager.restoreIntent(for: released.id)?.niriPlacement?.columnIndex, focusedColumnIndex)

        XCTAssertEqual(fixture.router.handle(request), .executed)
        try completeReveal(released.id, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(manager.workspace(for: released.id), fixture.niriWorkspaceId)
        retile(released.id, quietly: true, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        try assertOwnColumnRightAfterFocus(released.id, fixture)
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testQuietRetileIgnoresAStaleRestoredPlacementInTheFocusedColumn() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let retiled = try addWindow(
            pid: 512_800, windowId: 512_801, to: fixture.niriWorkspaceId, controller: fixture.controller
        )
        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try storeStalePlacement(for: retiled.id, inColumnOf: fixture.focused, fixture)
        XCTAssertTrue(fixture.controller.transitionWindowMode(
            for: retiled.id,
            to: .floating,
            applyFloatingFrame: false
        ))
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertNil(fixture.engine.findNode(for: retiled, in: fixture.niriWorkspaceId))
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))

        retile(retiled.id, quietly: true, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        try assertOwnColumnRightAfterFocus(retiled.id, fixture)
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
        XCTAssertEqual(manager.restoreIntent(for: retiled.id)?.niriPlacement?.columnIndex, 3)
    }

    func testFloatingAColumnBeforeTheCenteredFocusKeepsTheFocusedFrame() async throws {
        let fixture = try await makeCenteredFixture()
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let target = fixture.windows[1]

        let floated = fixture.controller.niriLayoutHandler.preservingFocusedColumnAnchor(for: target.id) {
            fixture.controller.transitionWindowMode(for: target.id, to: .floating, applyFloatingFrame: false)
        }
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertTrue(floated)
        XCTAssertEqual(fixture.controller.workspaceManager.entry(for: target.id)?.mode, .floating)
        XCTAssertNil(fixture.engine.findNode(for: target, in: fixture.niriWorkspaceId))
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testHidingAColumnBeforeTheCenteredFocusInAScratchpadKeepsTheFocusedFrame() async throws {
        let fixture = try await makeCenteredFixture()
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let target = fixture.windows[1]
        fixture.controller.axManager.confirmFrameWrite(
            for: target.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(name: .assignToScratchpad, windowId: opaqueId(target), scratchpadIndex: 4)
            ),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.hiddenState(for: target.id)?.isScratchpad, true)
        XCTAssertNil(fixture.engine.findNode(for: target, in: fixture.niriWorkspaceId))
        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
    }

    func testLeftoverQuietTokenDoesNotSilenceALaterNormalRetile() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(512_900), windowId: 512_901),
            pid: 512_900,
            windowId: 512_901,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        manager.quietArrivalTokens.insert(token)

        XCTAssertEqual(fixture.controller.toggleWindowFloating(token), .executed)
        XCTAssertFalse(manager.quietArrivalTokens.contains(token))
        retile(token, quietly: false, fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let arrived = try XCTUnwrap(fixture.engine.findNode(for: token, in: fixture.niriWorkspaceId))
        XCTAssertEqual(fixture.viewport.selectedNodeId, arrived.id)
    }

    func testMovingAWindowToAnotherWorkspaceDropsItsQuietToken() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let token = fixture.windows[1].id
        manager.quietArrivalTokens.insert(token)

        fixture.controller.reassignManagedWindow(token, to: fixture.otherNiriWorkspaceId)

        XCTAssertFalse(manager.quietArrivalTokens.contains(token))
    }

    func testQuietToggleOnNiriDoesNotSwallowAnUnrelatedArrivalsActivation() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let floating = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(513_000), windowId: 513_001),
            pid: 513_000,
            windowId: 513_001,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        let arrival = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(513_100), windowId: 513_101),
            pid: 513_100,
            windowId: 513_101,
            to: fixture.niriWorkspaceId
        )

        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .toggleFloating,
                    windowId: IPCWindowOpaqueID.encode(
                        pid: floating.pid,
                        windowId: floating.windowId,
                        sessionToken: "test"
                    )
                )
            ),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let arrivedNode = try XCTUnwrap(fixture.engine.findNode(for: arrival, in: fixture.niriWorkspaceId))
        XCTAssertEqual(fixture.viewport.selectedNodeId, arrivedNode.id)
        XCTAssertTrue(
            fixture.focusRecorder.focusedTokens.contains(arrival)
                || fixture.controller.intentLedger.activeManagedRequest?.token == arrival
        )
    }

    func testRejectedTargetsReportWhyNothingChanged() async throws {
        let fixture = try await makeFlushLeftFixture()
        let manager = fixture.controller.workspaceManager
        let floating = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(512_200), windowId: 512_201),
            pid: 512_200,
            windowId: 512_201,
            to: fixture.niriWorkspaceId,
            mode: .floating
        )
        let dwindleWindow = try addWindow(
            pid: 512_300, windowId: 512_301, to: fixture.dwindleWorkspaceId, controller: fixture.controller
        )
        let target = opaqueId(fixture.windows[1])

        XCTAssertEqual(
            fixture.router.handle(IPCWindowRequest(name: .toggleColumnTabbed, windowId: "garbage")),
            .invalidArguments
        )
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .toggleColumnTabbed,
                    windowId: IPCWindowOpaqueID.encode(
                        pid: fixture.windows[1].id.pid,
                        windowId: fixture.windows[1].id.windowId,
                        sessionToken: "previous"
                    )
                )
            ),
            .staleWindowId
        )
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .toggleColumnTabbed,
                    windowId: IPCWindowOpaqueID.encode(pid: 512_999, windowId: 1, sessionToken: "test")
                )
            ),
            .notFound
        )
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .toggleContainerFullPrimarySpan,
                    windowId: IPCWindowOpaqueID.encode(
                        pid: floating.pid,
                        windowId: floating.windowId,
                        sessionToken: "test"
                    )
                )
            ),
            .noChange
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWindowRequest(name: .toggleColumnTabbed, windowId: opaqueId(dwindleWindow))),
            .ignoredLayoutMismatch
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWindowRequest(name: .moveColumnToIndex, windowId: target)),
            .invalidArguments
        )
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(name: .assignToScratchpad, windowId: target, scratchpadIndex: 0)
            ),
            .invalidArguments
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWindowRequest(name: .moveColumnToFirst, windowId: opaqueId(fixture.windows[0]))),
            .noChange
        )
        assertFocusUnchanged(fixture)
    }

    func testShrinkingABackgroundColumnOnlyAppliesTheContentEdgeClamp() async throws {
        let fixture = try await makeFlushLeftFixture(columnCount: 5)
        let before = try XCTUnwrap(fixture.frame(of: fixture.focused))

        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .setContainerPrimarySpan,
                    windowId: opaqueId(fixture.windows[3]),
                    change: .setProportion(10)
                )
            ),
            .executed
        )
        XCTAssertEqual(fixture.frame(of: fixture.focused), before)
        var expected = fixture.viewport
        let context = NiriInteractionContext(
            workspaceId: fixture.niriWorkspaceId,
            motion: .disabled,
            workingFrame: fixture.controller.niriWorkingFrame(for: fixture.monitor),
            gaps: fixture.controller.innerGap(for: fixture.monitor),
            orientation: .horizontal
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.niriWorkspaceId) {
            XCTAssertTrue(fixture.engine.correctViewportAfterColumnRemoval(
                context: context,
                state: &expected,
                preservesCenteredView: true
            ))
        }
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertNotEqual(fixture.frame(of: fixture.focused), before)
        XCTAssertEqual(fixture.viewport.viewOffset, expected.viewOffset, accuracy: 0.5)
        assertFocusUnchanged(fixture)
    }

    func testCollapsingToOneTiledWindowUsesTheStandardSingleWindowFrame() async throws {
        let fixture = try await makeFixture(columnCount: 2, focusedIndex: 0)
        let single = try await makeFixture(columnCount: 1, focusedIndex: 0)
        let removed = fixture.windows[1]
        fixture.controller.axManager.confirmFrameWrite(
            for: removed.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(name: .assignToScratchpad, windowId: opaqueId(removed), scratchpadIndex: 3)
            ),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        assertFocusUnchanged(fixture)
        XCTAssertEqual(fixture.frame(of: fixture.focused), single.frame(of: single.focused))
    }

    private func assertFocusUnchanged(
        _ fixture: Fixture,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let focusedNode = fixture.engine.findNode(for: fixture.focused, in: fixture.niriWorkspaceId)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty, message, file: file, line: line)
        XCTAssertEqual(
            fixture.controller.workspaceManager.selectedManagedToken,
            fixture.focused.id,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(fixture.viewport.selectedNodeId, focusedNode?.id, message, file: file, line: line)
    }

    private func storeStalePlacement(
        for token: WindowToken,
        inColumnOf anchor: WindowHandle,
        _ fixture: Fixture
    ) throws {
        let manager = fixture.controller.workspaceManager
        var placements = fixture.engine.persistedPlacements(in: fixture.niriWorkspaceId)
        let anchorPlacement = try XCTUnwrap(placements[anchor.id])
        placements[token] = PersistedNiriPlacement(
            columnIndex: anchorPlacement.columnIndex,
            tileIndex: 1,
            column: anchorPlacement.column,
            window: anchorPlacement.window
        )
        manager.setNiriRestorePlacements(placements)
        XCTAssertEqual(manager.restoreIntent(for: token)?.niriPlacement?.columnIndex, anchorPlacement.columnIndex)
    }

    private func assertOwnColumnRightAfterFocus(
        _ token: WindowToken,
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let columns = fixture.engine.columns(in: fixture.niriWorkspaceId)
        let focusedIndex = try XCTUnwrap(
            columns.firstIndex { column in column.windowNodes.contains { $0.token == fixture.focused.id } },
            file: file,
            line: line
        )
        XCTAssertEqual(columns[focusedIndex].windowNodes.map(\.token), [fixture.focused.id], file: file, line: line)
        XCTAssertEqual(columns[focusedIndex + 1].windowNodes.map(\.token), [token], file: file, line: line)
    }

    private func completeReveal(_ token: WindowToken, _ fixture: Fixture) throws {
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(forWindowId: token.windowId)
        )
        let revealFrame = CGRect(x: 120, y: 80, width: 900, height: 620)
        fixture.controller.layoutRefreshController.completePendingRevealTransaction(
            with: AXFrameApplyResult(
                pid: entry.pid,
                windowId: entry.windowId,
                expectedWindow: entry.axRef,
                targetFrame: revealFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    observedFrame: revealFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            ),
            transactionId: transactionId
        )
    }

    private func retile(_ token: WindowToken, quietly: Bool, _ fixture: Fixture) {
        let manager = fixture.controller.workspaceManager
        if quietly {
            manager.quietArrivalTokens.insert(token)
        }
        XCTAssertTrue(fixture.controller.transitionWindowMode(for: token, to: .tiling, applyFloatingFrame: false))
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
    }

    private func opaqueId(_ handle: WindowHandle) -> String {
        IPCWindowOpaqueID.encode(pid: handle.id.pid, windowId: handle.id.windowId, sessionToken: "test")
    }

    private func makeCenteredFixture() async throws -> Fixture {
        let fixture = try await makeFixture(columnCount: 7, focusedIndex: 3)
        let focusedNode = try XCTUnwrap(fixture.engine.findNode(for: fixture.focused, in: fixture.niriWorkspaceId))
        let focusedColumn = try XCTUnwrap(fixture.engine.column(of: focusedNode))
        let workingWidth = fixture.controller.niriWorkingFrame(for: fixture.monitor).width
        let centeredOffset = -(workingWidth - focusedColumn.cachedWidth) / 2
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.niriWorkspaceId) { state in
            state.jumpOffset(to: centeredOffset)
        }
        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        fixture.focusRecorder.focusedTokens.removeAll()

        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let focusedFrame = try XCTUnwrap(fixture.frame(of: fixture.focused))
        XCTAssertEqual(fixture.viewport.viewOffset, centeredOffset, accuracy: 0.5)
        XCTAssertGreaterThan(focusedFrame.minX, fixture.monitor.frame.minX + gap * 4)
        XCTAssertLessThan(focusedFrame.maxX, fixture.monitor.frame.maxX - gap * 4)
        return fixture
    }

    private func makeFlushLeftFixture(columnCount: Int = 7) async throws -> Fixture {
        let fixture = try await makeFixture(columnCount: columnCount, focusedIndex: 2)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.niriWorkspaceId) { state in
            state.jumpOffset(to: -gap)
        }
        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.niriWorkspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        fixture.focusRecorder.focusedTokens.removeAll()

        let focusedFrame = try XCTUnwrap(fixture.frame(of: fixture.focused))
        let leftFrame = try XCTUnwrap(fixture.frame(of: fixture.windows[1]))
        let rightFrame = try XCTUnwrap(fixture.frame(of: fixture.windows[3]))
        XCTAssertLessThan(focusedFrame.minX, leftFrame.maxX + gap * 3)
        XCTAssertLessThanOrEqual(leftFrame.maxX, fixture.monitor.frame.minX + 1)
        XCTAssertGreaterThan(rightFrame.minX, focusedFrame.maxX)
        return fixture
    }

    private func makeFixture(columnCount: Int, focusedIndex: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetedWindowActionIPCIntegrationTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.workspaces.defaultLayoutType = .niri
        settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle),
            WorkspaceConfiguration(name: "3", monitorAssignment: .main, layoutType: .niri)
        ]

        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 512_000),
            displayId: 512_000,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Targeted Window Action Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        niriEngine.updateConfiguration(centerFocusedColumn: .never)
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine

        let niriWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let dwindleWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
        )
        let otherNiriWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "3", createIfMissing: false)
        )
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(niriWorkspaceId, on: monitor.id))
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let windows = try (0 ..< columnCount).map { index in
            try addWindow(pid: 512_001, windowId: index + 1, to: niriWorkspaceId, controller: controller)
        }
        controller.workspaceManager.withEngineMutationScope(in: niriWorkspaceId) {
            for column in niriEngine.columns(in: niriWorkspaceId) {
                column.width = .proportion(1.0 / 3.0)
            }
        }
        let fixture = Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            niriWorkspaceId: niriWorkspaceId,
            dwindleWorkspaceId: dwindleWorkspaceId,
            otherNiriWorkspaceId: otherNiriWorkspaceId,
            monitor: monitor,
            focusRecorder: focusRecorder,
            windows: windows,
            focused: windows[focusedIndex]
        )
        try select(fixture.focused, fixture)
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [niriWorkspaceId])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        focusRecorder.focusedTokens.removeAll()
        return fixture
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> WindowHandle {
        let manager = controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        manager.withEngineMutationScope(in: workspaceId) {
            switch manager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return try XCTUnwrap(manager.handle(for: token))
    }

    private func select(_ handle: WindowHandle, _ fixture: Fixture) throws {
        let manager = fixture.controller.workspaceManager
        let node = try XCTUnwrap(fixture.engine.findNode(for: handle, in: fixture.niriWorkspaceId))
        manager.withEngineMutationScope(in: fixture.niriWorkspaceId) {
            fixture.engine.activateWindow(node.id, in: fixture.niriWorkspaceId)
        }
        _ = manager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: handle.id,
            in: fixture.niriWorkspaceId,
            onMonitor: fixture.monitor.id
        )
        _ = manager.setManagedFocus(handle.id, in: fixture.niriWorkspaceId, onMonitor: fixture.monitor.id)
    }
}
