// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ScratchpadRuleAdmissionTests: XCTestCase {
    private static let bundleId = "org.example.scratchpad-rule"
    private static let windowServerFrame = CGRect(x: 240, y: 180, width: 800, height: 600)

    func testLiveCreatedMemberOfHiddenSlotParksAsFloatingWithoutReflowingTiles() throws {
        for previousFocusAdopted in [false, true] {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let tiled = addTilingWindow(WindowToken(pid: 975_001, windowId: 975_101), to: fixture)
            if previousFocusAdopted {
                focus(tiled, in: fixture)
            }
            let tiledBefore = manager.tiledEntries(in: fixture.workspaceId).map(\.token)
            let token = WindowToken(pid: 975_002, windowId: 975_102)
            fixture.focusRecorder.frontmostPID = token.pid
            fixture.focusRecorder.frontmostToken = WindowToken(pid: token.pid, windowId: 975_199)

            try liveCreate(token, in: fixture)

            let entry = try XCTUnwrap(manager.entry(for: token))
            XCTAssertEqual(entry.mode, .floating)
            XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat)
            XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
            XCTAssertNil(manager.revealedScratchpadIndex())
            XCTAssertEqual(manager.tiledEntries(in: fixture.workspaceId).map(\.token), tiledBefore)
            XCTAssertEqual(manager.selectedManagedToken, previousFocusAdopted ? tiled : nil)
            XCTAssertFalse(fixture.focusRecorder.focusedWindowIds.contains(UInt32(token.windowId)))
        }
    }

    func testLiveCreatedMemberThatCountsAsFocusedRevealsItsSlotWithoutParking() throws {
        enum FocusSignal: CaseIterable {
            case observedFocusEvent
            case focusedActivation
            case frontmostFocusedWindow
        }
        for signal in FocusSignal.allCases {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let token = WindowToken(pid: 975_011, windowId: 975_111)
            switch signal {
            case .observedFocusEvent:
                manager.recordExternalFocus(pid: token.pid, windowId: token.windowId)
            case .focusedActivation:
                break
            case .frontmostFocusedWindow:
                fixture.focusRecorder.frontmostPID = token.pid
                fixture.focusRecorder.frontmostToken = token
            }
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            try liveCreate(token, in: fixture, countsAsFocused: signal == .focusedActivation)
            try completeScratchpadFronting(in: fixture)

            XCTAssertEqual(manager.scratchpadIndex(for: token), 1, "\(signal)")
            XCTAssertEqual(manager.revealedScratchpadIndex(), 1, "\(signal)")
            XCTAssertNil(manager.hiddenState(for: token), "\(signal)")
            XCTAssertEqual(manager.entry(for: token)?.mode, .floating, "\(signal)")
            XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat, "\(signal)")
            XCTAssertEqual(manager.selectedManagedToken, token, "\(signal)")
            XCTAssertEqual(hiddenTransitions(of: token, in: manager), 0, "\(signal)")
            XCTAssertEqual(parkIntents(of: token), 0, "\(signal)")
        }
    }

    func testMemberJoiningARevealedSlotStaysWherePlacementPutIt() throws {
        for keepsRevealedMember in [true, false] {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let revealedMember = WindowToken(pid: 975_021, windowId: 975_121)
            try liveCreate(revealedMember, in: fixture)
            XCTAssertEqual(fixture.controller.toggleScratchpad(1, on: fixture.monitor.id), .executed)
            try completeReveal(revealedMember, in: fixture)
            if !keepsRevealedMember {
                fixture.controller.axEventHandler.handleRemoved(token: revealedMember)
                XCTAssertTrue(manager.scratchpadMembers(in: 1).isEmpty)
            }
            XCTAssertEqual(manager.revealedScratchpadIndex(), 1)
            let token = WindowToken(pid: 975_022, windowId: 975_122)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            let candidate = try liveCreate(token, in: fixture)

            XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
            XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat)
            XCTAssertNil(manager.hiddenState(for: token))
            XCTAssertEqual(manager.revealedScratchpadIndex(), 1)
            XCTAssertEqual(manager.workspace(for: token), fixture.workspaceId)
            XCTAssertEqual(manager.floatingState(for: token)?.lastFrame, candidate.observedFrame)
            XCTAssertNil(fixture.controller.layoutRefreshController
                .pendingRevealTransactionId(forWindowId: token.windowId))
            XCTAssertEqual(hiddenTransitions(of: token, in: manager), 0)
            XCTAssertEqual(parkIntents(of: token), 0)
        }
    }

    func testFullRescanParksAMatchingWindowWhetherOrNotItHoldsFocus() throws {
        for arrivingHoldsFocus in [false, true] {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let tiled = addTilingWindow(WindowToken(pid: 975_031, windowId: 975_131), to: fixture)
            focus(tiled, in: fixture)
            let token = WindowToken(pid: 975_032, windowId: 975_132)
            if arrivingHoldsFocus {
                manager.recordExternalFocus(pid: token.pid, windowId: token.windowId)
                XCTAssertEqual(manager.nativeFocusOwner.externalToken, token)
            }

            rescan(token, in: fixture)

            let entry = try XCTUnwrap(manager.entry(for: token))
            XCTAssertEqual(entry.mode, .floating)
            XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat)
            XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
            XCTAssertNil(manager.revealedScratchpadIndex())
            XCTAssertEqual(manager.tiledEntries(in: fixture.workspaceId).map(\.token), [tiled])
            XCTAssertNotEqual(manager.selectedManagedToken, token)
            XCTAssertEqual(manager.pendingFocusedToken ?? manager.selectedManagedToken, tiled)
        }
    }

    func testStartupParkingOfTheFocusedWindowFocusesADisplayableNonMemberOrNothing() throws {
        for hasNonMember in [true, false] {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let nonMember = hasNonMember
                ? addTilingWindow(WindowToken(pid: 975_041, windowId: 975_141), to: fixture, title: "Plain")
                : nil
            let token = WindowToken(pid: 975_042, windowId: 975_142)
            manager.recordExternalFocus(pid: token.pid, windowId: token.windowId)

            rescan(token, in: fixture)

            XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
            if let nonMember {
                XCTAssertEqual(manager.pendingFocusedToken ?? manager.selectedManagedToken, nonMember)
            } else {
                XCTAssertNil(manager.selectedManagedToken)
                XCTAssertNil(manager.pendingFocusedToken)
            }
        }
    }

    func testAutomaticReevaluationAdmitsAnUntrackedMatchingWindowIntoItsSlot() async throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
        let manager = fixture.controller.workspaceManager
        let tiled = addTilingWindow(WindowToken(pid: 975_051, windowId: 975_151), to: fixture, title: "Plain")
        let token = WindowToken(pid: 975_052, windowId: 975_152)
        fixture.book.facts[token] = facts(for: token)

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(token)])

        XCTAssertTrue(outcome.evaluatedAnyWindow)
        XCTAssertEqual(manager.entry(for: token)?.mode, .floating)
        XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat)
        XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
        XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
        XCTAssertEqual(manager.tiledEntries(in: fixture.workspaceId).map(\.token), [tiled])
    }

    func testAutomaticReevaluationNeverChangesMembershipOfManagedWindows() async throws {
        let fixture = try makeFixture(rules: [])
        let manager = fixture.controller.workspaceManager
        let tiled = addTilingWindow(WindowToken(pid: 975_061, windowId: 975_161), to: fixture)
        fixture.controller.windowRuleEngine.rebuild(rules: [Self.rule(title: "Notes", scratchpad: 1)])
        let member = WindowToken(pid: 975_062, windowId: 975_162)
        let released = WindowToken(pid: 975_063, windowId: 975_163)
        try liveCreate(member, in: fixture)
        try liveCreate(released, in: fixture)
        XCTAssertEqual(fixture.controller.unassignScratchpadWindows([released], on: fixture.monitor.id), .executed)
        try completeReveal(released, in: fixture)
        XCTAssertNil(manager.scratchpadIndex(for: released))
        XCTAssertEqual(manager.manualLayoutOverride(for: released), .forceTile)
        fixture.book.facts[member] = facts(for: member, title: "Inbox")
        fixture.book.facts[released] = facts(for: released, title: "Notes 2")

        await fixture.controller.reevaluateWindowRules(for: [.window(member), .window(released), .window(tiled)])

        XCTAssertEqual(manager.scratchpadIndex(for: member), 1)
        XCTAssertEqual(manager.entry(for: member)?.mode, .floating)
        XCTAssertEqual(manager.manualLayoutOverride(for: member), .forceFloat)
        XCTAssertEqual(manager.hiddenState(for: member)?.isScratchpad, true)
        XCTAssertNil(manager.scratchpadIndex(for: released))
        XCTAssertEqual(manager.entry(for: released)?.mode, .tiling)
        XCTAssertEqual(manager.manualLayoutOverride(for: released), .forceTile)
        XCTAssertNil(manager.scratchpadIndex(for: tiled))
        XCTAssertEqual(manager.entry(for: tiled)?.mode, .tiling)
        XCTAssertNil(manager.manualLayoutOverride(for: tiled))

        fixture.controller.windowRuleEngine.rebuild(rules: [])
        await fixture.controller.reevaluateWindowRules(for: [.window(member)])

        XCTAssertEqual(manager.scratchpadIndex(for: member), 1)
        XCTAssertEqual(manager.entry(for: member)?.mode, .floating)
    }

    func testEveryMatchingWindowJoinsEvenWhenItsAppAlreadyHasTrackedWindows() throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 2)])
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 975_071
        let tracked = addTilingWindow(WindowToken(pid: pid, windowId: 975_171), to: fixture, title: "Plain")
        let first = WindowToken(pid: pid, windowId: 975_172)
        let second = WindowToken(pid: pid, windowId: 975_173)

        try liveCreate(first, in: fixture)
        try liveCreate(second, in: fixture)

        XCTAssertEqual(manager.scratchpadMembers(in: 2), [first, second])
        XCTAssertNil(manager.scratchpadIndex(for: tracked))
    }

    func testTrackedParentChildFollowsItsParentsSlot() throws {
        let fixture = try makeFixture(rules: [Self.rule(title: "Parent", scratchpad: 3)])
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 975_081
        let memberParent = WindowToken(pid: pid, windowId: 975_181)
        let plainParent = addTilingWindow(WindowToken(pid: pid, windowId: 975_182), to: fixture, title: "Plain")
        try liveCreate(memberParent, in: fixture, title: "Parent")
        XCTAssertEqual(manager.scratchpadIndex(for: memberParent), 3)

        let followingChild = WindowToken(pid: pid, windowId: 975_183)
        let orphanedChild = WindowToken(pid: pid, windowId: 975_184)
        let plainChild = WindowToken(pid: pid, windowId: 975_185)
        fixture.book.decisions[followingChild] = Self.childDecision(scratchpad: 1)
        fixture.book.decisions[orphanedChild] = Self.childDecision(scratchpad: 1)
        fixture.book.decisions[plainChild] = Self.childDecision(scratchpad: nil)
        try liveCreate(followingChild, in: fixture, facts: childFacts(for: followingChild, parent: memberParent))
        try liveCreate(orphanedChild, in: fixture, facts: childFacts(for: orphanedChild, parent: plainParent))
        try liveCreate(plainChild, in: fixture, facts: childFacts(for: plainChild, parent: memberParent))

        XCTAssertEqual(manager.scratchpadIndex(for: followingChild), 3)
        XCTAssertEqual(manager.hiddenState(for: followingChild)?.isScratchpad, true)
        XCTAssertTrue(manager.scratchpadMembers(in: 1).isEmpty)
        for child in [orphanedChild, plainChild] {
            XCTAssertNotNil(manager.entry(for: child))
            XCTAssertNil(manager.scratchpadIndex(for: child))
            XCTAssertNil(manager.manualLayoutOverride(for: child))
            XCTAssertNil(manager.hiddenState(for: child))
        }
    }

    func testMemberAdmittedWhileNotDisplayableParksOnceItBecomesDisplayable() throws {
        enum Suppression: CaseIterable {
            case minimized
            case appHidden
        }
        for suppression in Suppression.allCases {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let token = WindowToken(pid: 975_091, windowId: 975_191)
            if suppression == .appHidden {
                _ = manager.setAppHidden(true, pid: token.pid, source: .ax)
            }
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            try liveCreate(token, in: fixture, isMinimized: suppression == .minimized)

            XCTAssertEqual(manager.scratchpadIndex(for: token), 1, "\(suppression)")
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true, "\(suppression)")
            XCTAssertTrue(manager.isWindowSuppressedByMacOS(token), "\(suppression)")
            XCTAssertEqual(parkIntents(of: token), 0, "\(suppression)")

            switch suppression {
            case .minimized:
                let axRef = try XCTUnwrap(manager.entry(for: token)?.axRef)
                fixture.controller.axEventHandler.handleWindowMinimized(pid: token.pid, axRef: axRef, minimized: false)
            case .appHidden:
                _ = manager.setAppHidden(false, pid: token.pid, source: .ax)
                fixture.controller.reconcileScratchpadMembersAfterAppUnhide(pid: token.pid)
            }

            XCTAssertFalse(manager.isWindowSuppressedByMacOS(token), "\(suppression)")
            XCTAssertEqual(manager.scratchpadIndex(for: token), 1, "\(suppression)")
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true, "\(suppression)")
            XCTAssertGreaterThan(parkIntents(of: token), 0, "\(suppression)")
        }
    }

    func testAdmissionJoinWithoutGeometryLeavesTheWindowOutOfTheSlot() throws {
        let fixture = try makeFixture(rules: [])
        let manager = fixture.controller.workspaceManager
        let token = WindowToken(pid: 975_095, windowId: 975_195)
        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: fixture.workspaceId,
            mode: .floating
        )

        fixture.controller.joinScratchpadOnAdmission(
            token,
            ScratchpadAdmission(index: 1, fallbackMode: .tiling),
            observedFrame: nil,
            arrival: .quiet(previousFocusToken: nil)
        )

        XCTAssertNil(manager.scratchpadIndex(for: token))
        XCTAssertNil(manager.manualLayoutOverride(for: token))
        XCTAssertNil(manager.hiddenState(for: token))
        XCTAssertEqual(manager.entry(for: token)?.mode, .tiling)
    }

    func testExplicitRuleApplyIsIdempotentForParkedAndVisibleMembers() async throws {
        for visible in [false, true] {
            let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
            let manager = fixture.controller.workspaceManager
            let token = WindowToken(pid: 975_111, windowId: 975_211)
            try liveCreate(token, in: fixture)
            if visible {
                XCTAssertEqual(fixture.controller.toggleScratchpad(1, on: fixture.monitor.id), .executed)
                try completeReveal(token, in: fixture)
            }
            let before = memberSnapshot(token, in: manager)
            XCTAssertEqual(before.index, 1)
            XCTAssertEqual(before.hiddenState == nil, visible)

            for _ in 0 ..< 2 {
                await fixture.controller.reevaluateWindowRules(for: [.window(token)], context: .explicitRuleApply)
                XCTAssertEqual(memberSnapshot(token, in: manager), before, "visible=\(visible)")
            }
        }
    }

    func testExplicitRuleApplyMovesAMemberOfAnotherSlotIntoTheRuleSlot() async throws {
        for targetRevealed in [false, true] {
            let fixture = try makeFixture(rules: [
                Self.rule(title: "Alpha", scratchpad: 1),
                Self.rule(title: "Beta", scratchpad: 2)
            ])
            let manager = fixture.controller.workspaceManager
            let anchor = WindowToken(pid: 975_121, windowId: 975_221)
            let token = WindowToken(pid: 975_122, windowId: 975_222)
            try liveCreate(anchor, in: fixture, title: "Alpha")
            if targetRevealed {
                XCTAssertEqual(fixture.controller.toggleScratchpad(1, on: fixture.monitor.id), .executed)
                try completeReveal(anchor, in: fixture)
            }
            try liveCreate(token, in: fixture, title: "Beta")
            XCTAssertEqual(manager.scratchpadIndex(for: token), 2)
            XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
            fixture.controller.windowRuleEngine.rebuild(rules: [
                Self.rule(title: "Alpha", scratchpad: 1),
                Self.rule(title: "Beta", scratchpad: 1)
            ])

            await fixture.controller.reevaluateWindowRules(for: [.window(token)], context: .explicitRuleApply)

            XCTAssertEqual(manager.scratchpadIndex(for: token), 1, "targetRevealed=\(targetRevealed)")
            XCTAssertTrue(manager.scratchpadMembers(in: 2).isEmpty)
            if targetRevealed {
                try completeReveal(token, in: fixture, completeFronting: false)
                XCTAssertNil(manager.hiddenState(for: token))
                XCTAssertEqual(manager.revealedScratchpadIndex(), 1)
            } else {
                XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
                XCTAssertNil(manager.revealedScratchpadIndex())
            }
        }
    }

    func testExplicitRuleApplyReplacesForceTileWithForceFloat() async throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
        let manager = fixture.controller.workspaceManager
        let token = WindowToken(pid: 975_131, windowId: 975_231)
        try liveCreate(token, in: fixture)
        XCTAssertEqual(fixture.controller.unassignScratchpadWindows([token], on: fixture.monitor.id), .executed)
        try completeReveal(token, in: fixture)
        XCTAssertNil(manager.scratchpadIndex(for: token))
        XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceTile)
        XCTAssertEqual(manager.entry(for: token)?.mode, .tiling)

        await fixture.controller.reevaluateWindowRules(for: [.window(token)], context: .explicitRuleApply)

        XCTAssertEqual(manager.scratchpadIndex(for: token), 1)
        XCTAssertEqual(manager.manualLayoutOverride(for: token), .forceFloat)
        XCTAssertEqual(manager.entry(for: token)?.mode, .floating)
        XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
    }

    func testExplicitRuleApplyMovesAMemberToAWinningWorkspaceDestination() async throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
        let manager = fixture.controller.workspaceManager
        let destination = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        let token = WindowToken(pid: 975_141, windowId: 975_241)
        try liveCreate(token, in: fixture)
        XCTAssertEqual(manager.hiddenState(for: token)?.isScratchpad, true)
        fixture.controller.windowRuleEngine.rebuild(rules: [Self.rule(workspace: "2")])

        await fixture.controller.reevaluateWindowRules(for: [.window(token)], context: .explicitRuleApply)

        XCTAssertNil(manager.scratchpadIndex(for: token))
        XCTAssertTrue(manager.scratchpadMembers(in: 1).isEmpty)
        XCTAssertNotEqual(manager.hiddenState(for: token)?.isScratchpad, true)
        XCTAssertNil(manager.manualLayoutOverride(for: token))
        XCTAssertEqual(manager.workspace(for: token), destination)
        XCTAssertEqual(manager.entry(for: token)?.mode, .tiling)
    }

    func testExplicitRuleApplyWithoutDestinationLeavesMembershipAlone() async throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 1)])
        let manager = fixture.controller.workspaceManager
        let token = WindowToken(pid: 975_151, windowId: 975_251)
        try liveCreate(token, in: fixture)
        let before = memberSnapshot(token, in: manager)
        fixture.controller.windowRuleEngine.rebuild(rules: [])

        await fixture.controller.reevaluateWindowRules(for: [.window(token)], context: .explicitRuleApply)

        XCTAssertEqual(memberSnapshot(token, in: manager), before)
        XCTAssertEqual(before.index, 1)
    }

    func testFullRescanStructuralReplacementKeepsItsSlot() throws {
        let fixture = try makeFixture(rules: [Self.rule(scratchpad: 2)])
        let manager = fixture.controller.workspaceManager
        let oldToken = WindowToken(pid: 975_161, windowId: 975_261)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 975_262)
        try liveCreate(oldToken, in: fixture)
        XCTAssertEqual(manager.scratchpadIndex(for: oldToken), 2)
        let handle = try XCTUnwrap(manager.handle(for: oldToken))
        fixture.controller.windowRuleEngine.rebuild(rules: [Self.rule(scratchpad: 1)])

        rescan(newToken, in: fixture)

        XCTAssertNil(manager.entry(for: oldToken))
        XCTAssertTrue(manager.handle(for: newToken) === handle)
        XCTAssertEqual(manager.scratchpadIndex(for: newToken), 2)
        XCTAssertTrue(manager.scratchpadMembers(in: 1).isEmpty)
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let focusRecorder: FocusRecorder
        let book: EvaluationBook
    }

    private struct MemberSnapshot: Equatable {
        let index: ScratchpadIndex?
        let hiddenState: HiddenState?
        let mode: TrackedWindowMode?
        let manualOverride: ManualWindowOverride?
        let workspaceId: WorkspaceDescriptor.ID?
        let revealedIndex: ScratchpadIndex?
    }

    private final class FocusRecorder {
        var focusedWindowIds: [UInt32] = []
        var frontmostPID: pid_t?
        var frontmostToken: WindowToken?
    }

    private final class EvaluationBook {
        var facts: [WindowToken: WindowRuleFacts] = [:]
        var decisions: [WindowToken: WindowDecision] = [:]

        func windowInfo(_ windowId: UInt32) -> WindowServerInfo? {
            facts.values.lazy.compactMap(\.windowServer).first { $0.id == windowId }
        }
    }

    private static func rule(title: String? = nil, scratchpad: Int? = nil, workspace: String? = nil) -> AppRule {
        AppRule(bundleId: bundleId, titleSubstring: title, assignToWorkspace: workspace, scratchpad: scratchpad)
    }

    private static func childDecision(scratchpad: ScratchpadIndex?) -> WindowDecision {
        WindowDecision(
            disposition: .floating,
            source: .userRule(UUID()),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: ManagedWindowAdmissionHints(scratchpad: scratchpad),
            ruleProvenance: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func makeFixture(rules: [AppRule]) throws -> Fixture {
        let focusRecorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMScratchpadRuleAdmissionTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.frontmostPID = pid
                    focusRecorder.focusedWindowIds.append(windowId)
                },
                raiseWindow: { _ in }
            )
        )
        let book = EvaluationBook()
        controller.scheduleScratchpadStackingContinuation = { $0() }
        controller.axEventHandler.frontmostApplicationPIDProvider = { focusRecorder.frontmostPID }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { focusRecorder.frontmostToken }
        controller.axEventHandler.visibleWindowInfoProvider = { [] }
        controller.axEventHandler.windowInfoProvider = { book.windowInfo($0) }
        controller.axEventHandler.windowInfoBatchProvider = { windowIds in
            Dictionary(uniqueKeysWithValues: windowIds.compactMap { id in book.windowInfo(id).map { (id, $0) } })
        }
        controller.axWindowRefLookupForTests = { token in
            book.facts[token] == nil ? nil : WindowAdmissionTestSupport.axRef(for: token)
        }
        controller.windowDispositionEvaluationForTests = { [weak controller] token in
            guard let controller, let facts = book.facts[token] else { return nil }
            let manualOverride = controller.workspaceManager.manualLayoutOverride(for: token)
            let baseDecision = book.decisions[token]
                ?? controller.windowRuleEngine.decision(for: facts, token: token, appFullscreen: false)
            return WMController.WindowDecisionEvaluation(
                token: token,
                facts: facts,
                decision: WindowRuleEngine.applyingManualOverride(baseDecision, manualOverride: manualOverride),
                appFullscreen: false,
                manualOverride: manualOverride,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: ScreenCoordinateSpace.toAppKit(rect: facts.windowServer?.frame ?? .zero)
                )
            )
        }
        controller.windowRuleEngine.rebuild(rules: rules)
        let monitor = Monitor(
            id: .init(displayId: 975_901),
            displayId: 975_901,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "ScratchpadRuleAdmission"
        )
        controller.layoutRefreshController.fastFrameProvider = { _, _ in
            CGRect(x: 120, y: 80, width: 900, height: 620)
        }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        return Fixture(
            controller: controller,
            monitor: monitor,
            workspaceId: workspaceId,
            focusRecorder: focusRecorder,
            book: book
        )
    }

    private func facts(for token: WindowToken, title: String = "Notes") -> WindowRuleFacts {
        windowFacts(for: token, title: title, subrole: kAXStandardWindowSubrole as String, parentId: 0)
    }

    private func childFacts(for token: WindowToken, parent: WindowToken) -> WindowRuleFacts {
        windowFacts(for: token, title: "Dialog", subrole: kAXDialogSubrole as String, parentId: UInt32(parent.windowId))
    }

    private func windowFacts(
        for token: WindowToken,
        title: String,
        subrole: String,
        parentId: UInt32
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Scratchpad Rule",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: subrole,
                title: title,
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: Self.bundleId,
                attributeFetchSucceeded: true
            ),
            sizeConstraints: .unconstrained,
            windowServer: WindowServerInfo(
                id: UInt32(token.windowId),
                pid: token.pid,
                level: 0,
                frame: Self.windowServerFrame,
                parentId: parentId
            )
        )
    }

    @discardableResult
    private func liveCreate(
        _ token: WindowToken,
        in fixture: Fixture,
        title: String = "Notes",
        facts explicitFacts: WindowRuleFacts? = nil,
        isMinimized: Bool = false,
        countsAsFocused: Bool = false
    ) throws -> AXEventHandler.PreparedCreate {
        let facts = explicitFacts ?? self.facts(for: token, title: title)
        fixture.book.facts[token] = facts
        let outcome = fixture.controller.axEventHandler.prepareCreateCandidate(
            windowId: UInt32(token.windowId),
            windowInfo: facts.windowServer,
            fallbackToken: token,
            fallbackAXRef: WindowAdmissionTestSupport.axRef(for: token)
        )
        let prepared: AXEventHandler.PreparedCreate? = if case let .prepared(candidate) = outcome {
            candidate
        } else {
            nil
        }
        var candidate = try XCTUnwrap(prepared, "Expected a prepared create, got \(outcome)")
        candidate.isMinimized = isMinimized
        fixture.controller.axEventHandler.trackPreparedCreate(candidate, countsAsFocused: countsAsFocused)
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: token))
        return candidate
    }

    @discardableResult
    private func addTilingWindow(
        _ token: WindowToken,
        to fixture: Fixture,
        title: String = "Notes"
    ) -> WindowToken {
        fixture.book.facts[token] = facts(for: token, title: title)
        return fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: fixture.workspaceId,
            mode: .tiling
        )
    }

    private func focus(_ token: WindowToken, in fixture: Fixture) {
        let manager = fixture.controller.workspaceManager
        _ = manager.cancelCurrentManagedFocusRequest()
        XCTAssertTrue(
            manager.setManagedFocus(
                token,
                in: manager.workspace(for: token) ?? fixture.workspaceId,
                onMonitor: fixture.monitor.id
            )
        )
    }

    private func rescan(_ token: WindowToken, in fixture: Fixture, title: String = "Notes") {
        let facts = self.facts(for: token, title: title)
        fixture.book.facts[token] = facts
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let windowServerInfo = facts.windowServer
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: axRef,
                axPid: token.pid,
                role: facts.ax.role,
                subrole: facts.ax.subrole,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: ScreenCoordinateSpace.toAppKit(rect: Self.windowServerFrame)
                ),
                fullscreenAttribute: false,
                minimizedAttribute: false,
                decisionEvidence: AXWindowDecisionEvidence(facts: facts.ax, sizeConstraints: .unconstrained)
            ),
            logicalPID: token.pid,
            windowServerInfo: windowServerInfo,
            windowServerOwnerPID: windowServerInfo?.pid,
            enumerationRoute: .persistent
        )
        var progress = FullRescanProgress(affectedWorkspaceIds: [])
        fixture.controller.layoutRefreshController.reconcileFullRescanCandidate(
            candidate,
            context: FullRescanMutationContext(
                controller: fixture.controller,
                enumerationSnapshot: AXManager.FullRescanEnumerationSnapshot(
                    windows: [candidate],
                    successfullyEnumeratedPIDs: [token.pid],
                    failedPIDs: [],
                    authoritativeTargetPIDs: [token.pid],
                    exactWindowIds: nil,
                    identityAliasesByWindowId: [
                        token.windowId: .init(pids: [token.pid], axRefs: [axRef])
                    ],
                    windowServerInfoByWindowId: windowServerInfo.map { [token.windowId: $0] } ?? [:]
                ),
                scope: .all,
                focusedWorkspaceId: fixture.workspaceId,
                screenFrames: []
            ),
            progress: &progress
        )
    }

    private func memberSnapshot(_ token: WindowToken, in manager: WorkspaceManager) -> MemberSnapshot {
        MemberSnapshot(
            index: manager.scratchpadIndex(for: token),
            hiddenState: manager.hiddenState(for: token),
            mode: manager.entry(for: token)?.mode,
            manualOverride: manager.manualLayoutOverride(for: token),
            workspaceId: manager.workspace(for: token),
            revealedIndex: manager.revealedScratchpadIndex()
        )
    }

    private func hiddenTransitions(of token: WindowToken, in manager: WorkspaceManager) -> Int {
        manager.reconcileTraceDump().split(separator: "\n").filter { line in
            line.contains("hidden_state_changed token=\(token) ") && line.contains("hidden=true")
        }.count
    }

    private func parkIntents(of token: WindowToken) -> Int {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter { line in
            line.contains("win=\(token.windowId) ") && line.contains("event=outcome=sls-park-intent/")
        }.count
    }

    private func completeReveal(
        _ token: WindowToken,
        in fixture: Fixture,
        completeFronting: Bool = true
    ) throws {
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        let reference = try XCTUnwrap(entry.axRef)
        let transactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(forWindowId: token.windowId)
        )
        let targetFrame = CGRect(x: 120, y: 80, width: 900, height: 620)
        fixture.controller.layoutRefreshController.completePendingRevealTransaction(
            with: AXFrameApplyResult(
                pid: entry.pid,
                windowId: entry.windowId,
                expectedWindow: reference,
                targetFrame: targetFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    observedFrame: targetFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            ),
            transactionId: transactionId
        )
        if completeFronting {
            try completeScratchpadFronting(in: fixture)
        }
    }

    private func completeScratchpadFronting(in fixture: Fixture) throws {
        for _ in 0 ..< 32 {
            guard let request = fixture.controller.intentLedger.activeManagedRequest else { return }
            let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: request.token))
            fixture.controller.axEventHandler.handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: true,
                appFullscreen: false,
                source: .workspaceDidActivateApplication,
                activeRequestId: request.requestId
            )
        }
        XCTFail("Scratchpad fronting did not settle")
    }
}
