// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ObservedSizePackingHintTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]
        let frames: [WindowToken: CGRect]
    }

    private let workingHeight: CGFloat = 1564
    private let columnHeight: CGFloat = 1558

    func testDirectionalMovesWithoutLearnedEvidence() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        NiriLayoutTrace.shared.beginCapture()
        defer { NiriLayoutTrace.shared.endCapture() }

        XCTAssertEqual(fixture.controller.niriLayoutHandler.moveWindow(direction: .right), .atWorkspaceEdge)
        XCTAssertEqual(fixture.controller.niriLayoutHandler.moveWindow(direction: .left), .movedWithinWorkspace)
        XCTAssertEqual(fixture.controller.niriEngine?.columns(in: fixture.workspaceId).count, 1)

        let trace = NiriLayoutTrace.shared.dump()
        XCTAssertTrue(trace
            .contains("move ws=\(fixture.workspaceId.uuidString) right win=709202 outcome=atWorkspaceEdge"))
        XCTAssertTrue(trace
            .contains("move ws=\(fixture.workspaceId.uuidString) left win=709202 outcome=movedWithinWorkspace"))
    }

    func testDirectionalMoveSwapsColumnsWhenStackingDisabled() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        fixture.controller.settings.niri.moveWindowStacksIntoColumn = false
        let engine = try XCTUnwrap(fixture.controller.niriEngine)

        XCTAssertEqual(fixture.controller.niriLayoutHandler.moveWindow(direction: .left), .movedWithinWorkspace)
        XCTAssertEqual(
            engine.columns(in: fixture.workspaceId).map { $0.windowNodes.map(\.token) },
            [[fixture.tokens[1]], [fixture.tokens[0]]]
        )
        XCTAssertEqual(fixture.controller.niriLayoutHandler.moveWindow(direction: .left), .atWorkspaceEdge)
    }

    func testBoundedHeightGrowthBecomesHintAndKeepsStackedMoveFeasible() throws {
        for learnedCount in 1 ... 2 {
            let fixture = try makeFixture()
            defer { cleanup(fixture) }
            let controller = fixture.controller
            let engine = try XCTUnwrap(controller.niriEngine)
            for token in fixture.tokens.suffix(learnedCount) {
                try learnBoundedHeightGrowth(for: token, in: fixture)
            }

            let frames = try rebuild(fixture)
            for token in fixture.tokens.suffix(learnedCount) {
                let evidence = try XCTUnwrap(controller.workspaceManager.observedSizeEvidence(for: token))
                XCTAssertEqual(evidence.minSize, CGSize(width: 1, height: 1))
                XCTAssertEqual(
                    evidence.hints.height,
                    ObservedAxisHint(requested: columnHeight, observed: workingHeight)
                )
                XCTAssertNil(evidence.hints.width)
                let node = try XCTUnwrap(engine.findNode(for: token, in: fixture.workspaceId))
                XCTAssertEqual(node.constraints.minSize.height, 100)
                XCTAssertEqual(node.packingHints, evidence.hints)
                XCTAssertEqual(try XCTUnwrap(frames[token]).height, columnHeight, accuracy: 0.01)
                let window = try XCTUnwrap(controller.workspaceManager.entry(for: token)).axRef
                XCTAssertNil(WindowAdmissionTestSupport.frameRequest(
                    controller.axManager.frameLedger,
                    pid: token.pid,
                    window: window,
                    frame: try XCTUnwrap(frames[token])
                ))
            }

            XCTAssertEqual(controller.niriLayoutHandler.moveWindow(direction: .right), .atWorkspaceEdge)
            XCTAssertEqual(controller.niriLayoutHandler.moveWindow(direction: .left), .movedWithinWorkspace)
            XCTAssertEqual(engine.columns(in: fixture.workspaceId).count, 1)

            let stacked = try rebuild(fixture)
            let first = try XCTUnwrap(stacked[fixture.tokens[0]])
            let second = try XCTUnwrap(stacked[fixture.tokens[1]])
            XCTAssertEqual(first.height + second.height + 3 * 3, workingHeight, accuracy: 0.01)
            XCTAssertFalse(first.intersects(second))
        }
    }

    func testVerifiedSmallerWriteRelaxesOnlyContradictedEvidence() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = fixture.controller
        let token = try XCTUnwrap(fixture.tokens.last)
        let seeded = ObservedSizeEvidence(
            minSize: CGSize(width: 1, height: workingHeight),
            hints: ObservedPackingHints(
                width: ObservedAxisHint(requested: 1000, observed: 1010),
                height: ObservedAxisHint(requested: columnHeight, observed: workingHeight)
            )
        )
        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(seeded, for: token))
        _ = try rebuild(fixture)
        XCTAssertEqual(controller.niriLayoutHandler.moveWindow(direction: .left), .blocked)

        try confirmFullWrite(for: token, in: fixture)

        XCTAssertEqual(
            controller.workspaceManager.observedSizeEvidence(for: token),
            ObservedSizeEvidence(hints: ObservedPackingHints(width: ObservedAxisHint(requested: 1000, observed: 1010)))
        )
        XCTAssertEqual(controller.axManager.lastAppliedFrame(for: token.windowId)?.height, columnHeight)
        _ = try rebuild(fixture)
        XCTAssertEqual(controller.niriLayoutHandler.moveWindow(direction: .left), .movedWithinWorkspace)
    }

    func testPositionOnlyUnverifiedAndStaleIdentityWritesDoNotRelax() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = fixture.controller
        let token = try XCTUnwrap(fixture.tokens.last)
        let seeded = ObservedSizeEvidence(minSize: CGSize(width: 1, height: workingHeight))
        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(seeded, for: token))
        let target = try XCTUnwrap(fixture.frames[token])
        let window = try XCTUnwrap(controller.workspaceManager.entry(for: token)).axRef
        let stale = AXWindowRef(element: AXUIElementCreateApplication(token.pid + 50), windowId: token.windowId)

        for (label, expectedWindow, components, observed) in [
            ("position-only", window, AXFrameComponents.position, Optional(target)),
            ("unverified", window, AXFrameComponents.all, nil),
            ("stale-identity", stale, AXFrameComponents.all, Optional(target))
        ] {
            let result = AXFrameApplyResult(
                requestId: 1,
                pid: token.pid,
                windowId: token.windowId,
                expectedWindow: expectedWindow,
                targetFrame: target,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    observedFrame: observed,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: components
                )
            )
            controller.relaxObservedSizeEvidence(afterVerifiedWrite: result)
            XCTAssertEqual(controller.workspaceManager.observedSizeEvidence(for: token), seeded, label)
        }
    }

    func testEligibleHintRaisesStackedFloorAndIneligibleHintDoesNot() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = fixture.controller
        XCTAssertEqual(controller.niriLayoutHandler.moveWindow(direction: .left), .movedWithinWorkspace)
        let hinted = fixture.tokens[1]
        let other = fixture.tokens[0]
        let usable = workingHeight - 3 * 3

        var frames = try rebuild(fixture)
        XCTAssertEqual(try XCTUnwrap(frames[hinted]).height, usable / 2, accuracy: 0.01)

        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(hints: ObservedPackingHints(height: ObservedAxisHint(requested: 770, observed: 780))),
            for: hinted
        ))
        frames = try rebuild(fixture)
        XCTAssertEqual(try XCTUnwrap(frames[hinted]).height, 780, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(frames[other]).height, usable - 780, accuracy: 0.01)

        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(hints: ObservedPackingHints(height: ObservedAxisHint(requested: 800, observed: 810))),
            for: hinted
        ))
        frames = try rebuild(fixture)
        XCTAssertEqual(try XCTUnwrap(frames[hinted]).height, usable / 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(frames[other]).height, usable / 2, accuracy: 0.01)
    }

    func testDiscardedWidthHintResetsCachedColumnWidth() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = fixture.controller
        let token = fixture.tokens[1]
        let initialWidth = try XCTUnwrap(fixture.frames[token]).width

        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(hints: ObservedPackingHints(width: ObservedAxisHint(
                requested: initialWidth,
                observed: initialWidth + 8
            ))),
            for: token
        ))
        var frames = try rebuild(fixture)
        XCTAssertEqual(try XCTUnwrap(frames[token]).width, initialWidth + 8, accuracy: 0.01)

        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(ObservedSizeEvidence(), for: token))
        frames = try rebuild(fixture)
        XCTAssertEqual(try XCTUnwrap(frames[token]).width, initialWidth, accuracy: 0.01)
    }

    func testDiagnosticsReportListsObservedSizing() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = fixture.controller
        var report = RuntimeDiagnosticsReport.build(controller, traceLimit: 10)
        XCTAssertTrue(report.contains("== Observed Sizing ==\nnone"))

        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(
                minSize: CGSize(width: 520, height: 1),
                hints: ObservedPackingHints(height: ObservedAxisHint(requested: columnHeight, observed: workingHeight))
            ),
            for: fixture.tokens[1]
        ))
        report = RuntimeDiagnosticsReport.build(controller, traceLimit: 10)
        XCTAssertTrue(report.contains("== Observed Sizing ==\nwin=709202 minSize=520.0x1.0 heightHint=1558.0→1564.0"))
    }

    private func learnBoundedHeightGrowth(for token: WindowToken, in fixture: Fixture) throws {
        let controller = fixture.controller
        let axManager = controller.axManager
        let window = try XCTUnwrap(controller.workspaceManager.entry(for: token)).axRef
        let target = try XCTUnwrap(fixture.frames[token])
        let observed = CGRect(x: target.minX, y: target.minY - 6, width: target.width, height: target.height + 6)
        let first = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            axManager.frameLedger, pid: token.pid, window: window, frame: target
        ))
        axManager.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: first, observed: observed)
        ])
        XCTAssertNotNil(axManager.cancelPendingFrameRetry(for: token.windowId))
        XCTAssertNil(controller.workspaceManager.observedSizeEvidence(for: token))
        let retry = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            axManager.frameLedger, pid: token.pid, window: window, frame: target, isRetry: true
        ))
        axManager.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: retry, observed: observed)
        ])
        XCTAssertEqual(axManager.lastAppliedFrame(for: token.windowId), observed)
    }

    private func confirmFullWrite(for token: WindowToken, in fixture: Fixture) throws {
        let axManager = fixture.controller.axManager
        let window = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token)).axRef
        let target = try XCTUnwrap(fixture.frames[token])
        axManager.forceApplyNextFrame(for: token.windowId)
        let request = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            axManager.frameLedger, pid: token.pid, window: window, frame: target
        ))
        axManager.handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: request)])
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMObservedSizePackingHintTests")
        controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen = true
        controller.motionPolicy.animationsEnabled = false
        controller.settings.animationsEnabled = false
        controller.settings.focus.crossesMonitorAtEdge = false
        controller.settings.focus.moveCrossesMonitorAtEdge = false
        controller.settings.gaps.size = 2
        controller.settings.gaps.outerGapLeft = 0
        controller.settings.gaps.outerGapRight = 0
        controller.settings.gaps.outerGapTop = 0
        controller.settings.gaps.outerGapBottom = 0
        controller.settings.borders.enabled = true
        controller.settings.borders.width = 3
        controller.settings.workspaceBar.reserveLayoutSpace = false
        controller.settings.niri.infiniteLoop = false
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(name: "6", monitorAssignment: .secondary, layoutType: .niri)
        ]
        controller.workspaceManager.applySettings()
        let primary = Monitor(
            id: .init(displayId: 709_001), displayId: 709_001,
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            hasNotch: false, name: "Issue709 Primary"
        )
        let secondary = Monitor(
            id: .init(displayId: 709_002), displayId: 709_002,
            frame: CGRect(x: -291, y: 1117, width: 2560, height: 1600),
            visibleFrame: CGRect(x: -291, y: 1117, width: 2560, height: 1570),
            hasNotch: false, name: "Issue709 Secondary"
        )
        let manager = controller.workspaceManager
        controller.settings.monitors.ranking = [primary, secondary].map(OutputId.init(from:))
        manager.applyMonitorConfigurationChange([primary, secondary])
        manager.applySettings()
        manager.setGaps(to: 2)
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "6", createIfMissing: true))
        manager.assignWorkspaceToMonitor(workspaceId, monitorId: secondary.id)
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: secondary.id))
        _ = manager.setInteractionMonitor(secondary.id)
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        XCTAssertEqual(manager.monitor(for: workspaceId)?.id, secondary.id)
        XCTAssertEqual(controller.activeWorkspace()?.id, workspaceId)
        XCTAssertTrue(secondary.neighborAxes(among: [primary, secondary]).vertical)
        XCTAssertEqual(controller.insetWorkingFrame(for: secondary).height, workingHeight)
        XCTAssertEqual(controller.innerGap(for: secondary), 3)
        let tokens = [WindowToken(pid: 709_101, windowId: 709_201), WindowToken(pid: 709_102, windowId: 709_202)]
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            manager.setCachedConstraints(
                WindowSizeConstraints(minSize: CGSize(width: 100, height: 100), maxSize: .zero, isFixed: false),
                for: token
            )
        }
        controller.axManager.onStableSizeClamp = { [weak controller] result in
            controller?.adoptObservedMinimumAfterStableSizeClamp(result)
        }
        controller.axManager.onFrameApplySucceeded = { [weak controller] result in
            controller?.serviceLifecycleManager.handleFrameApplySucceeded(result)
        }
        let initial = Fixture(
            controller: controller,
            workspaceId: workspaceId,
            monitor: secondary,
            tokens: tokens,
            frames: [:]
        )
        let frames = try rebuild(initial)
        let selected = try XCTUnwrap(engine.findNode(for: tokens[1], in: workspaceId))
        manager.withEngineMutationScope(in: workspaceId) { engine.activateWindow(selected.id, in: workspaceId) }
        _ = manager.commitWorkspaceSelection(
            nodeId: selected.id,
            focusedToken: tokens[1],
            in: workspaceId,
            onMonitor: secondary.id
        )
        XCTAssertEqual(try XCTUnwrap(frames[tokens[0]]), CGRect(x: -285, y: 1123, width: 1272.5, height: columnHeight))
        XCTAssertEqual(try XCTUnwrap(frames[tokens[1]]), CGRect(x: 990.5, y: 1123, width: 1272.5, height: columnHeight))
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)
        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            monitor: secondary,
            tokens: tokens,
            frames: frames
        )
    }

    private func rebuild(_ fixture: Fixture) throws -> [WindowToken: CGRect] {
        let plan = try XCTUnwrap(fixture.controller.workspaceManager.withEngineMutationScope {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId]).first
        })
        return Dictionary(uniqueKeysWithValues: plan.diff.frameChanges.map { ($0.token, $0.frame) })
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.controller.layoutRefreshController.resetState()
        fixture.controller.axManager.cleanup()
        fixture.controller.surfaceReconciler.cleanup()
    }
}

final class NiriPackingHintSpanTests: XCTestCase {
    private func column(withHints hints: ObservedPackingHints) -> NiriContainer {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = engine.addWindow(token: WindowToken(pid: 1, windowId: 1), to: workspaceId, afterSelection: nil)
        window.packingHints = hints
        return engine.columns(in: workspaceId)[0]
    }

    func testEligibleWidthHintRaisesColumnWidthWithinLimit() {
        let column = column(withHints: ObservedPackingHints(width: ObservedAxisHint(requested: 795, observed: 801)))
        XCTAssertEqual(column.resolvedWidthPixels(.proportion(0.5), availableSpan: 1600, gaps: 3, contentInset: 0), 801)
        XCTAssertEqual(column.resolvedWidthPixels(.fixed(700), availableSpan: 1600, gaps: 3, contentInset: 0), 700)
        XCTAssertEqual(column.resolvedWidthPixels(.fixed(796), availableSpan: 802, gaps: 3, contentInset: 0), 796)
    }

    func testHintChangeKeepsInFlightWidthAnimationTarget() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let column = engine.columns(in: workspaceId)[0]
        column.cachedWidth = 960
        column.cachedHeight = 500
        column.targetWidth = 800

        engine.updateWindowConstraints(
            for: token,
            constraints: .unconstrained,
            packingHints: ObservedPackingHints(width: ObservedAxisHint(requested: 1000, observed: 1006)),
            in: workspaceId,
            motion: .disabled
        )

        XCTAssertEqual(column.cachedWidth, 960)
        XCTAssertEqual(column.targetWidth, 800)
        XCTAssertEqual(column.cachedHeight, 0)

        column.targetWidth = nil
        engine.updateWindowConstraints(
            for: token,
            constraints: .unconstrained,
            packingHints: .none,
            in: workspaceId,
            motion: .disabled
        )

        XCTAssertEqual(column.cachedWidth, 0)
    }

    func testEligibleHeightHintRaisesColumnHeightForVerticalOrientation() {
        let column = column(withHints: ObservedPackingHints(height: ObservedAxisHint(requested: 795, observed: 801)))
        XCTAssertEqual(column.resolvedHeightPixels(.proportion(0.5), availableSpan: 1600, gaps: 3), 801)
        XCTAssertEqual(column.resolvedHeightPixels(.fixed(700), availableSpan: 1600, gaps: 3), 700)
        XCTAssertEqual(
            column.resolvedWidthPixels(.proportion(0.5), availableSpan: 1600, gaps: 3, contentInset: 0),
            795.5
        )
    }
}
