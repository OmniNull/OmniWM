// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

final class WindowModelTests: XCTestCase {
    func testUpsertInstallsAndUpdatesLifetimeAuthorityAtomically() throws {
        let model = WindowModel()
        let workspaceId = WorkspaceDescriptor(name: "workspace").id
        let token = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_000), windowId: 467_000),
            pid: 467_000,
            windowId: 467_000,
            workspace: workspaceId,
            lifetimeAuthority: .directLifecycle
        )

        XCTAssertEqual(model.entry(for: token)?.lifetimeAuthority, .directLifecycle)

        _ = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_000), windowId: 467_000),
            pid: 467_000,
            windowId: 467_000,
            workspace: workspaceId,
            lifetimeAuthority: .axTopLevelInventory
        )

        XCTAssertEqual(model.entry(for: token)?.lifetimeAuthority, .axTopLevelInventory)
    }

    func testNestedIndexesRemainCoherentAcrossRemovalMoveModeAndRekey() throws {
        let model = WindowModel()
        let firstWorkspace = WorkspaceDescriptor(name: "first").id
        let secondWorkspace = WorkspaceDescriptor(name: "second").id
        let pid: pid_t = 467_050
        let tokens = (1 ... 3).map { windowId in
            model.upsert(
                window: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                workspace: firstWorkspace
            )
        }

        XCTAssertEqual(model.windowCount(in: firstWorkspace), 3)
        XCTAssertEqual(model.removeWindow(key: tokens[1])?.token, tokens[1])
        XCTAssertEqual(model.windows(in: firstWorkspace).map(\.token), [tokens[0], tokens[2]])

        model.updateWorkspace(for: tokens[2], workspace: secondWorkspace)
        model.setMode(.floating, for: tokens[2])
        XCTAssertEqual(model.windowCount(in: firstWorkspace), 1)
        XCTAssertEqual(model.windowCount(in: secondWorkspace), 1)
        XCTAssertEqual(model.windows(in: secondWorkspace, mode: .floating).map(\.token), [tokens[2]])
        XCTAssertTrue(model.windows(in: secondWorkspace, mode: .tiling).isEmpty)

        let rekeyedToken = WindowToken(pid: pid + 1, windowId: 4)
        let handle = try XCTUnwrap(model.handle(for: tokens[2]))
        XCTAssertNotNil(
            model.rekeyWindow(
                from: tokens[2],
                to: rekeyedToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(rekeyedToken.pid),
                    windowId: rekeyedToken.windowId
                )
            )
        )

        XCTAssertEqual(model.windows(in: secondWorkspace).map(\.token), [rekeyedToken])
        XCTAssertEqual(model.entries(forPid: pid + 1).map(\.token), [rekeyedToken])
        XCTAssertFalse(model.entries(forPid: pid).contains { $0.token == tokens[2] })
        XCTAssertTrue(model.handle(for: rekeyedToken) === handle)
    }

    func testUpsertPreservesExistingEntryWhenPidConflictsForSameWindowId() throws {
        let model = WindowModel()
        let existingWorkspaceId = WorkspaceDescriptor(name: "existing").id
        let proposedWorkspaceId = WorkspaceDescriptor(name: "proposed").id
        let windowId = 467_001
        let existingPid: pid_t = 467_101
        let proposedPid: pid_t = 467_102
        let existingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(existingPid),
            windowId: windowId
        )
        let existingRuleEffects = ManagedWindowRuleEffects(
            minWidth: 640,
            minHeight: 480
        )
        let existingAdmissionHints = ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.5)
        let existingToken = model.upsert(
            window: existingAXRef,
            pid: existingPid,
            windowId: windowId,
            workspace: existingWorkspaceId,
            mode: .floating,
            ruleEffects: existingRuleEffects,
            admissionHints: existingAdmissionHints
        )
        let existingHandle = try XCTUnwrap(model.handle(for: existingToken))
        let existingConstraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: .zero,
            isFixed: false
        )
        model.setCachedConstraints(existingConstraints, for: existingToken)

        let returnedToken = model.upsert(
            window: AXWindowRef(
                element: AXUIElementCreateApplication(proposedPid),
                windowId: windowId
            ),
            pid: proposedPid,
            windowId: windowId,
            workspace: proposedWorkspaceId,
            mode: .tiling
        )

        XCTAssertEqual(returnedToken, existingToken)
        XCTAssertEqual(model.allEntries().count, 1)
        XCTAssertEqual(model.entry(forWindowId: windowId)?.token, existingToken)
        XCTAssertNil(model.entry(for: WindowToken(pid: proposedPid, windowId: windowId)))
        XCTAssertEqual(model.entries(forPid: existingPid).map(\.token), [existingToken])
        XCTAssertTrue(model.entries(forPid: proposedPid).isEmpty)
        XCTAssertEqual(model.windows(in: existingWorkspaceId).map(\.token), [existingToken])
        XCTAssertTrue(model.windows(in: proposedWorkspaceId).isEmpty)
        XCTAssertEqual(model.mode(for: existingToken), .floating)
        XCTAssertEqual(model.entry(for: existingToken)?.ruleEffects, existingRuleEffects)
        XCTAssertEqual(model.admissionHints(for: existingToken), existingAdmissionHints)
        XCTAssertEqual(model.cachedConstraints(for: existingToken), existingConstraints.normalized())
        XCTAssertTrue(model.handle(for: existingToken) === existingHandle)

        var retainedAXPid: pid_t = 0
        let retainedAXRef = try XCTUnwrap(model.entry(for: existingToken)?.axRef)
        XCTAssertEqual(AXUIElementGetPid(retainedAXRef.element, &retainedAXPid), .success)
        XCTAssertEqual(retainedAXPid, existingPid)

        XCTAssertEqual(model.removeWindow(key: existingToken)?.token, existingToken)
        XCTAssertNil(model.entry(forWindowId: windowId))
        XCTAssertTrue(model.entries(forPid: existingPid).isEmpty)
        XCTAssertTrue(model.windows(in: existingWorkspaceId).isEmpty)
    }

    func testRekeyPreservesObservedSizeEvidenceOnlyForSameAXIncarnation() throws {
        let pid: pid_t = 467_210
        let sourceWindowId = 467_021
        let originalElement = AXUIElementCreateApplication(pid)
        let sameIncarnationElement = AXUIElementCreateApplication(pid)
        let replacementElement = AXUIElementCreateApplication(pid + 1)
        XCTAssertTrue(CFEqual(originalElement, sameIncarnationElement))
        XCTAssertFalse(CFEqual(originalElement, replacementElement))
        let evidence = ObservedSizeEvidence(
            minSize: CGSize(width: 520, height: 620),
            hints: ObservedPackingHints(
                width: ObservedAxisHint(requested: 500, observed: 506),
                height: ObservedAxisHint(requested: 600, observed: 606)
            )
        )
        let scenarios: [(
            name: String,
            destinationWindowId: Int,
            element: AXUIElement,
            expectedEvidence: ObservedSizeEvidence?,
            expectedSourceEvidence: ObservedSizeEvidence?
        )] = [
            ("same token, same AX", 467_021, sameIncarnationElement, evidence, evidence),
            ("changed token, same AX", 467_022, sameIncarnationElement, evidence, nil),
            ("same token, replaced AX", 467_021, replacementElement, nil, nil),
            ("changed token, replaced AX", 467_022, replacementElement, nil, nil)
        ]
        for scenario in scenarios {
            let model = WindowModel()
            let workspaceId = WorkspaceDescriptor(name: scenario.name).id
            let sourceToken = model.upsert(
                window: AXWindowRef(element: originalElement, windowId: sourceWindowId),
                pid: pid,
                windowId: sourceWindowId,
                workspace: workspaceId
            )
            let handle = try XCTUnwrap(model.handle(for: sourceToken))
            XCTAssertTrue(model.setObservedSizeEvidence(evidence, for: sourceToken), scenario.name)
            let constraints = WindowSizeConstraints.fixed(size: CGSize(width: 640, height: 480))
            model.setCachedConstraints(constraints, for: sourceToken)
            XCTAssertEqual(
                model.cachedConstraints(for: sourceToken, maxAge: .greatestFiniteMagnitude),
                constraints.normalized(),
                scenario.name
            )
            let destinationToken = WindowToken(pid: pid, windowId: scenario.destinationWindowId)
            let destinationRef = AXWindowRef(
                element: scenario.element,
                windowId: scenario.destinationWindowId
            )

            let rekeyed = try XCTUnwrap(model.rekeyWindow(
                from: sourceToken,
                to: destinationToken,
                newAXRef: destinationRef
            ))

            XCTAssertEqual(model.observedSizeEvidence(for: destinationToken), scenario.expectedEvidence, scenario.name)
            XCTAssertEqual(model.observedSizeEvidence(for: sourceToken), scenario.expectedSourceEvidence, scenario.name)
            XCTAssertNil(model.cachedConstraints(for: sourceToken, maxAge: .greatestFiniteMagnitude), scenario.name)
            XCTAssertNil(
                model.cachedConstraints(for: destinationToken, maxAge: .greatestFiniteMagnitude),
                scenario.name
            )
            XCTAssertEqual(rekeyed.token, destinationToken, scenario.name)
            let rekeyedReference = try XCTUnwrap(rekeyed.axRef, scenario.name)
            XCTAssertEqual(rekeyedReference.windowId, destinationToken.windowId, scenario.name)
            XCTAssertTrue(CFEqual(rekeyedReference.element, scenario.element), scenario.name)
            XCTAssertEqual(model.allEntries().map(\.token), [destinationToken], scenario.name)
            XCTAssertEqual(model.windows(in: workspaceId).map(\.token), [destinationToken], scenario.name)
            XCTAssertEqual(model.tokens(in: workspaceId, mode: .tiling), [destinationToken], scenario.name)
            XCTAssertEqual(model.entries(forPid: pid).map(\.token), [destinationToken], scenario.name)
            XCTAssertEqual(model.entry(forWindowId: destinationToken.windowId)?.token, destinationToken, scenario.name)
            XCTAssertTrue(model.handle(for: destinationToken) === handle, scenario.name)
            XCTAssertEqual(handle.id, destinationToken, scenario.name)
            XCTAssertEqual(model.entry(for: handle)?.token, destinationToken, scenario.name)
        }
    }

    func testRekeyRejectsWindowIdOwnedByAnotherToken() throws {
        let model = WindowModel()
        let workspaceId = WorkspaceDescriptor(name: "workspace").id
        let sourceToken = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_201), windowId: 467_011),
            pid: 467_201,
            windowId: 467_011,
            workspace: workspaceId
        )
        let existingToken = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_202), windowId: 467_012),
            pid: 467_202,
            windowId: 467_012,
            workspace: workspaceId
        )
        let sourceHandle = try XCTUnwrap(model.handle(for: sourceToken))
        let existingHandle = try XCTUnwrap(model.handle(for: existingToken))
        let proposedToken = WindowToken(pid: 467_203, windowId: existingToken.windowId)

        let result = model.rekeyWindow(
            from: sourceToken,
            to: proposedToken,
            newAXRef: AXWindowRef(
                element: AXUIElementCreateApplication(proposedToken.pid),
                windowId: proposedToken.windowId
            )
        )

        XCTAssertNil(result)
        XCTAssertEqual(Set(model.allEntries().map(\.token)), [sourceToken, existingToken])
        XCTAssertEqual(model.entry(forWindowId: sourceToken.windowId)?.token, sourceToken)
        XCTAssertEqual(model.entry(forWindowId: existingToken.windowId)?.token, existingToken)
        XCTAssertNil(model.entry(for: proposedToken))
        XCTAssertTrue(model.handle(for: sourceToken) === sourceHandle)
        XCTAssertTrue(model.handle(for: existingToken) === existingHandle)
        XCTAssertEqual(Set(model.windows(in: workspaceId).map(\.token)), [sourceToken, existingToken])
    }

    @MainActor
    func testLayoutSnapshotVisitorPreservesSharedEntriesAndReadsIndependentFacts() {
        let model = WindowModel()
        let queries = WindowModel.ReadView(model: model)
        let workspaceId = WorkspaceDescriptor(name: "layout").id
        let otherWorkspaceId = WorkspaceDescriptor(name: "other").id
        let pid: pid_t = 467_310
        var tiledTokens: [WindowToken] = []
        for index in 0 ..< 4 {
            let token = model.upsert(
                window: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_310 + index),
                pid: pid,
                windowId: 467_310 + index,
                workspace: index == 3 ? otherWorkspaceId : workspaceId,
                mode: index == 1 ? .floating : .tiling
            )
            if index == 0 || index == 2 {
                tiledTokens.append(token)
            }
        }
        let constraints = WindowSizeConstraints.fixed(size: CGSize(width: 640, height: 480))
        for token in tiledTokens {
            model.setCachedConstraints(constraints, for: token)
        }
        let retainedEntries = model.entries
        var visited: [WindowToken] = []

        queries.forEachWindowForLayoutSnapshot(in: workspaceId, mode: .tiling) { entry in
            visited.append(entry.token)
            XCTAssertEqual(
                queries.cachedConstraints(for: entry.token, maxAge: .greatestFiniteMagnitude),
                constraints.normalized()
            )
            XCTAssertNil(queries.observedSizeEvidence(for: entry.token))
        }

        XCTAssertEqual(visited, tiledTokens)
        XCTAssertEqual(model.entries, retainedEntries)
        model.setMode(.floating, for: tiledTokens[0])
        XCTAssertEqual(model.mode(for: tiledTokens[0]), .floating)
        XCTAssertEqual(retainedEntries[tiledTokens[0]]?.mode, .tiling)
    }

    @MainActor
    func testGeneralWindowVisitorAllowsEntryQueriesInItsCallback() {
        let model = WindowModel()
        let queries = WindowModel.ReadView(model: model)
        let workspaceId = WorkspaceDescriptor(name: "floating").id
        let token = model.upsert(
            window: AXWindowRef(element: AXUIElementCreateApplication(467_320), windowId: 467_320),
            pid: 467_320,
            windowId: 467_320,
            workspace: workspaceId,
            mode: .floating
        )
        var visited: [WindowToken] = []

        queries.forEachWindow(in: workspaceId, mode: .floating) { entry in
            visited.append(entry.token)
            XCTAssertEqual(queries.entry(for: entry.token)?.token, entry.token)
            XCTAssertEqual(queries.isHiddenInCorner(entry.token), entry.hiddenState != nil)
        }

        XCTAssertEqual(visited, [token])
    }
}
