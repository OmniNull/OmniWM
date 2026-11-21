// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriLayoutHistoryControllerTests: XCTestCase {
    @MainActor private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]

        var engine: NiriLayoutEngine {
            controller.niriEngine!
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func stack(_ index: Int, onto target: Int) {
            let source = column(index)
            let destination = column(target)
            destination.insertChild(window(index), at: destination.windowNodes.count)
            if source.windowNodes.isEmpty { source.remove() }
        }

        func frames(at time: TimeInterval) -> [WindowToken: CGRect] {
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            let frames = NiriOperationContext(
                controller: controller,
                engine: engine,
                motion: controller.motionPolicy.snapshot(),
                wsId: workspaceId,
                windowNode: window(0),
                monitor: monitor,
                orientation: .horizontal,
                workingFrame: controller.niriWorkingFrame(for: monitor),
                gaps: controller.innerGap(for: monitor)
            ).predictedFrames(state: state, at: time)
            return frames.filter { token, _ in !window(tokens.firstIndex(of: token)!).isHiddenInTabbedMode }
        }

        func settle() -> [WindowToken: CGRect] {
            let now = CACurrentMediaTime()
            let drawn = frames(at: now)
            for token in tokens {
                window(tokens.firstIndex(of: token)!).renderedFrame = drawn[token] ?? window(
                    tokens.firstIndex(of: token)!
                ).frame
            }
            return drawn
        }

        func mutate(_ body: () -> Void) {
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) { body() }
        }

        func change(_ body: () -> Void) {
            let start = controller.niriLayoutHandler.layoutChangeStart(in: workspaceId)
            body()
            controller.niriLayoutHandler.recordLayoutChange(since: start)
        }

        func changeAcrossWorkspaces(_ body: () -> Void) {
            let start = controller.niriLayoutHandler.layoutChangeStartCoveringEveryNiriWorkspace(in: workspaceId)
            body()
            controller.niriLayoutHandler.recordLayoutChange(since: start)
        }

        func focus(_ index: Int) {
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: window(index).id,
                focusedToken: tokens[index],
                in: workspaceId,
                onMonitor: monitor.id
            )
            _ = controller.workspaceManager.confirmManagedFocus(
                tokens[index],
                in: workspaceId,
                onMonitor: monitor.id,
                activateWorkspaceOnMonitor: true
            )
        }
    }

    private func makeFixture(
        pid: pid_t,
        workspaceNames: [String] = ["1"],
        secondDisplay: Bool = false
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriLayoutHistoryControllerTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let monitor = Monitor(
            id: .init(displayId: 83_411),
            displayId: 83_411,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Undo animation"
        )
        let second = Monitor(
            id: .init(displayId: 83_412),
            displayId: 83_412,
            frame: frame.offsetBy(dx: frame.width, dy: 0),
            visibleFrame: frame.offsetBy(dx: frame.width, dy: 0),
            hasNotch: false,
            name: "Undo animation, second"
        )
        controller.settings.workspaces.configurations = workspaceNames.enumerated().map { index, name in
            WorkspaceConfiguration(
                name: name,
                monitorAssignment: .specificDisplay(OutputId(from: secondDisplay && index > 0 ? second : monitor)),
                layoutType: .niri
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange(secondDisplay ? [monitor, second] : [monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (0 ..< 3).map { WindowToken(pid: pid, windowId: Int(pid) + 100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        var previous: NodeId?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous).id
        }
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(400)
            column.cachedWidth = 0
        }
        controller.motionPolicy.animationsEnabled = true
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        let blocker = WindowAdmissionTestSupport.parkedTask()
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        addTeardownBlock { @MainActor [controller] in
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
        }
        return Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
    }

    private func assertFrames(
        _ actual: [WindowToken: CGRect],
        match expected: [WindowToken: CGRect],
        _ message: String,
        widthAllowance: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (token, frame) in expected {
            guard let other = actual[token] else {
                XCTFail("\(message): no frame for window \(token.windowId)", file: file, line: line)
                continue
            }
            for (a, b, allowance) in [
                (frame.minX, other.minX, 0), (frame.minY, other.minY, 0),
                (frame.width, other.width, widthAllowance), (frame.height, other.height, 0)
            ] {
                XCTAssertEqual(
                    a, b, accuracy: 1.5 + allowance,
                    "\(message): \(token.windowId) \(frame) vs \(other)", file: file, line: line
                )
            }
        }
    }

    private func checkUndo(
        _ name: String,
        pid: pid_t,
        tabRailAppears: Bool = false,
        setup: (Fixture) -> Void = { _ in },
        change: (Fixture) -> Void
    ) throws {
        let fixture = try makeFixture(pid: pid)
        fixture.mutate { setup(fixture) }
        let original = fixture.settle()
        fixture.change { fixture.mutate { change(fixture) } }
        let drawn = fixture.settle()
        XCTAssertNotEqual(drawn, original, "\(name): the change moved nothing")

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo), name)

        let start = CACurrentMediaTime()
        assertFrames(
            fixture.frames(at: start),
            match: drawn,
            "\(name): jumped at the first frame",
            widthAllowance: tabRailAppears ? fixture.engine.renderStyle.tabIndicatorWidth : 0
        )
        let end = start + 10
        _ = fixture.engine.tickAllColumnAnimations(in: fixture.workspaceId, at: end)
        _ = fixture.engine.tickAllWindowAnimations(in: fixture.workspaceId, at: end)
        assertFrames(fixture.frames(at: end), match: original, "\(name): landed in the wrong place")
    }

    private func order(_ fixture: Fixture, in workspaceId: WorkspaceDescriptor.ID) -> [[WindowToken]] {
        fixture.engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
    }

    private func moveWindow(_ fixture: Fixture, _ index: Int, to workspaceId: WorkspaceDescriptor.ID) throws {
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[index]))
        let navigation = fixture.controller.workspaceNavigationHandler
        fixture.changeAcrossWorkspaces {
            if let mutation = navigation.moveWindow(handle: handle, toWorkspaceId: workspaceId).mutation {
                navigation.finishWorkspaceMove(mutation, focusPolicy: .retainCurrent)
            }
        }
    }

    func testMovesToAnotherWorkspaceOrDisplayAreRecorded() {
        for command: HotkeyCommand in [
            .workspace(.moveTo(1)), .workspace(.moveUp), .workspace(.moveDown), .workspace(.moveToSlot(1)),
            .workspace(.moveToMonitor(.right)), .column(.moveToWorkspace(1)), .column(.moveToWorkspaceUp),
            .column(.moveToWorkspaceDown)
        ] {
            XCTAssertEqual(CommandHandler.layoutChangeCoverage(of: command), .everyNiriWorkspace, "\(command)")
        }
        XCTAssertNil(CommandHandler.layoutChangeCoverage(of: .workspace(.switchTo(1))))
    }

    func testUndoWhereTheWindowLeftBringsItBackToItsPlaceAndWidth() throws {
        let fixture = try makeFixture(pid: 834_221, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        fixture.mutate { fixture.column(1).width = .fixed(640) }
        let before = order(fixture, in: fixture.workspaceId)
        try moveWindow(fixture, 1, to: other)
        XCTAssertEqual(order(fixture, in: other), [[fixture.tokens[1]]])
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspaceId)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertEqual(fixture.column(1).width, .fixed(640))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), fixture.workspaceId)
        XCTAssertTrue(order(fixture, in: other).isEmpty)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), other)
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), [[fixture.tokens[0]], [fixture.tokens[2]]])
    }

    func testSettledFramesAreWhereEveryAnimationEndsHoweverLongItRuns() throws {
        let fixture = try makeFixture(pid: 834_232)
        let window = fixture.window(1)
        let token = fixture.tokens[1]
        let now = CACurrentMediaTime()
        let resting = try XCTUnwrap(fixture.frames(at: now)[token])
        let slow = SpringConfig(dampingRatio: 1, stiffness: 1, epsilon: 0.0001)
        window.animateHeightFrom(delta: 200, clock: nil, config: slow, animated: true)
        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let operation = NiriOperationContext(
            controller: fixture.controller,
            engine: fixture.engine,
            motion: fixture.controller.motionPolicy.snapshot(),
            wsId: fixture.workspaceId,
            windowNode: fixture.window(0),
            monitor: fixture.monitor,
            orientation: .horizontal,
            workingFrame: fixture.controller.niriWorkingFrame(for: fixture.monitor),
            gaps: fixture.controller.innerGap(for: fixture.monitor)
        )

        XCTAssertNotEqual(try XCTUnwrap(fixture.frames(at: now)[token]), resting)
        XCTAssertEqual(try XCTUnwrap(operation.settledFrames(state: state)[token]), resting)
    }

    func testAWorkspaceSwitchedToDwindleAndBackKeepsItsArrangementAndHistory() throws {
        let fixture = try makeFixture(pid: 834_233)
        let original = order(fixture, in: fixture.workspaceId)
        fixture.change { fixture.stack(2, onto: 0) }
        let stacked = order(fixture, in: fixture.workspaceId)
        XCTAssertNotEqual(stacked, original)
        fixture.controller.enableDwindleLayout()

        XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.dwindle, forWorkspaceNamed: "1"))
        fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [fixture.workspaceId])
        }

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), stacked)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspaceId))

        XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: "1"))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), stacked)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspaceId))
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), original)
    }

    func testUndoAndRedoDoNothingWhileTheMouseResizesAWindow() throws {
        let fixture = try makeFixture(pid: 834_229, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 1, to: other)
        let handler = fixture.controller.niriLayoutHandler

        fixture.controller.mouseEventHandler.state.isResizing = true
        XCTAssertFalse(handler.stepLayoutHistory(.undo))
        fixture.controller.mouseEventHandler.state.isResizing = false

        XCTAssertTrue(fixture.engine.interactiveResizeBegin(
            windowId: fixture.window(0).id,
            edges: .right,
            startLocation: .zero,
            in: fixture.workspaceId,
            orientation: .horizontal
        ))
        XCTAssertFalse(handler.stepLayoutHistory(.undo))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), other)
        fixture.engine.interactiveResize = nil

        XCTAssertTrue(handler.stepLayoutHistory(.undo))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), fixture.workspaceId)
    }

    func testUndoWhereTheWindowArrivedSendsItBackToItsPlace() throws {
        let fixture = try makeFixture(pid: 834_222, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        let before = order(fixture, in: fixture.workspaceId)
        try moveWindow(fixture, 0, to: other)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, other)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertTrue(order(fixture, in: other).isEmpty)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))

        XCTAssertEqual(order(fixture, in: other), [[fixture.tokens[0]]])
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), [[fixture.tokens[1]], [fixture.tokens[2]]])
    }

    func testUndoWhereTheWindowArrivedLeavesLaterChangesWhereItCameFrom() throws {
        let fixture = try makeFixture(pid: 834_230, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        fixture.mutate { fixture.column(1).width = .fixed(640) }
        let before = order(fixture, in: fixture.workspaceId)
        try moveWindow(fixture, 1, to: other)
        fixture.mutate { fixture.column(2).width = .fixed(500) }
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertEqual(fixture.column(1).width, .fixed(640))
        XCTAssertEqual(fixture.column(2).width, .fixed(500))
        XCTAssertTrue(order(fixture, in: other).isEmpty)

        _ = fixture.controller.workspaceManager.focusWorkspace(named: "1")
        fixture.mutate { fixture.column(0).width = .fixed(700) }
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))

        XCTAssertEqual(order(fixture, in: other), [[fixture.tokens[1]]])
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), [[fixture.tokens[0]], [fixture.tokens[2]]])
        XCTAssertEqual(fixture.column(0).width, .fixed(700))
        XCTAssertEqual(fixture.column(2).width, .fixed(500))
    }

    func testUndoWhereTheWindowLeftThenRedoLeavesLaterChangesWhereItWent() throws {
        let fixture = try makeFixture(pid: 834_231, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 0, to: other)
        try moveWindow(fixture, 1, to: other)
        let arrived = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: other)?
            .parent as? NiriContainer)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), fixture.workspaceId)
        fixture.controller.workspaceManager.withEngineMutationScope(in: other) { arrived.width = .fixed(520) }

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.tokens[1]), other)
        let kept = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: other)?.parent as? NiriContainer)
        XCTAssertEqual(kept.width, .fixed(520))
    }

    func testUndoOnTheOtherDisplaySendsTheWindowBackAndFocusesItThere() throws {
        let fixture = try makeFixture(pid: 834_223, workspaceNames: ["1", "2"], secondDisplay: true)
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        let before = order(fixture, in: fixture.workspaceId)
        try moveWindow(fixture, 1, to: other)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, other)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fixture.tokens[1])
    }

    func testUndoActsOnTheFocusedWindowsDisplayNotThePointers() throws {
        let fixture = try makeFixture(pid: 834_227, workspaceNames: ["1", "2"], secondDisplay: true)
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        let otherMonitor = try XCTUnwrap(fixture.controller.workspaceManager.monitor(for: other))
        let before = order(fixture, in: fixture.workspaceId)
        fixture.change { fixture.mutate { fixture.stack(1, onto: 0) } }
        XCTAssertNotEqual(order(fixture, in: fixture.workspaceId), before)
        _ = fixture.controller.workspaceManager.setManagedFocus(
            fixture.tokens[0],
            in: fixture.workspaceId,
            onMonitor: otherMonitor.id
        )
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, other)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
    }

    func testUndoingASwapAcrossDisplaysPutsBothWindowsBack() throws {
        let fixture = try makeFixture(pid: 834_225, workspaceNames: ["1", "2"], secondDisplay: true)
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 2, to: other)
        fixture.engine.clearLayoutHistory(in: fixture.workspaceId)
        fixture.engine.clearLayoutHistory(in: other)
        let here = order(fixture, in: fixture.workspaceId)
        let there = order(fixture, in: other)
        let navigation = fixture.controller.workspaceNavigationHandler
        let first = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[0]))
        let third = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[2]))
        fixture.changeAcrossWorkspaces {
            for (handle, target) in [(first, other), (third, fixture.workspaceId)] {
                if let mutation = navigation.moveWindow(handle: handle, toWorkspaceId: target).mutation {
                    navigation.finishWorkspaceMove(mutation, focusPolicy: .retainCurrent)
                }
            }
        }
        XCTAssertEqual(order(fixture, in: other), [[fixture.tokens[0]]])

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(order(fixture, in: fixture.workspaceId), here)
        XCTAssertEqual(order(fixture, in: other), there)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspaceId)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fixture.tokens[0])
    }

    func testUndoToAWorkspaceNotShownLeavesFocusWhereItIs() throws {
        let fixture = try makeFixture(pid: 834_224, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 1, to: other)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))

        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, other)
        XCTAssertNotEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fixture.tokens[1])
    }

    func testAChangeInsideAWorkspaceCapturesThatWorkspaceAlone() throws {
        let fixture = try makeFixture(pid: 834_240, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 2, to: other)
        fixture.engine.clearLayoutHistory(in: fixture.workspaceId)
        fixture.engine.clearLayoutHistory(in: other)
        let handler = fixture.controller.niriLayoutHandler
        let before = order(fixture, in: fixture.workspaceId)
        let there = order(fixture, in: other)
        XCTAssertFalse(there.isEmpty)

        let start = try XCTUnwrap(handler.layoutChangeStart(in: fixture.workspaceId))
        XCTAssertEqual(Array(start.snapshots.keys), [fixture.workspaceId])
        XCTAssertFalse(start.coversEveryNiriWorkspace)
        fixture.mutate { fixture.stack(1, onto: 0) }
        handler.recordLayoutChange(since: start)

        let after = order(fixture, in: fixture.workspaceId)
        XCTAssertNotEqual(after, before)
        XCTAssertNil(fixture.engine.peekLayoutHistory(.undo, in: other))
        XCTAssertTrue(handler.stepLayoutHistory(.undo, in: fixture.workspaceId))
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertTrue(handler.stepLayoutHistory(.redo, in: fixture.workspaceId))
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), after)
        XCTAssertEqual(order(fixture, in: other), there)
    }

    func testAChangeCoveringEveryWorkspaceLeavesAnUntouchedWorkspaceWithoutAnUndoStep() throws {
        let fixture = try makeFixture(pid: 834_242, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 2, to: other)
        fixture.engine.clearLayoutHistory(in: fixture.workspaceId)
        fixture.engine.clearLayoutHistory(in: other)
        let handler = fixture.controller.niriLayoutHandler
        let before = order(fixture, in: fixture.workspaceId)
        let there = order(fixture, in: other)
        XCTAssertFalse(there.isEmpty)

        let start = try XCTUnwrap(handler.layoutChangeStartCoveringEveryNiriWorkspace(in: fixture.workspaceId))
        XCTAssertEqual(Set(start.snapshots.keys), [fixture.workspaceId, other])
        fixture.mutate { fixture.stack(1, onto: 0) }
        handler.recordLayoutChange(since: start)

        XCTAssertNotEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertNil(fixture.engine.peekLayoutHistory(.undo, in: other))
        XCTAssertTrue(handler.stepLayoutHistory(.undo, in: fixture.workspaceId))
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertEqual(order(fixture, in: other), there)
    }

    func testAWindowArrivingOnAWorkspaceThatAppearedDuringTheChangeIsUndoneFromThere() throws {
        let fixture = try makeFixture(pid: 834_243)
        let controller = fixture.controller
        let handler = controller.niriLayoutHandler
        let before = order(fixture, in: fixture.workspaceId)
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: fixture.tokens[0]))

        let start = try XCTUnwrap(handler.layoutChangeStartCoveringEveryNiriWorkspace(in: fixture.workspaceId))
        XCTAssertEqual(Array(start.snapshots.keys), [fixture.workspaceId])
        XCTAssertTrue(start.coversEveryNiriWorkspace)
        controller.settings.workspaces.configurations.append(
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: fixture.monitor)),
                layoutType: .niri
            )
        )
        controller.workspaceManager.applySettings()
        let other = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        let navigation = controller.workspaceNavigationHandler
        if let mutation = navigation.moveWindow(handle: handle, toWorkspaceId: other).mutation {
            navigation.finishWorkspaceMove(mutation, focusPolicy: .retainCurrent)
        }
        handler.recordLayoutChange(since: start)

        XCTAssertEqual(order(fixture, in: other), [[fixture.tokens[0]]])
        let arrival = try XCTUnwrap(fixture.engine.peekLayoutHistory(.undo, in: other))
        XCTAssertEqual(arrival.away.map(\.workspaceId), [fixture.workspaceId])
        XCTAssertEqual(arrival.away.first?.tokens, [fixture.tokens[0]])
        _ = controller.workspaceManager.focusWorkspace(named: "2")
        XCTAssertTrue(handler.stepLayoutHistory(.undo))
        XCTAssertEqual(order(fixture, in: fixture.workspaceId), before)
        XCTAssertTrue(order(fixture, in: other).isEmpty)
    }

    func testWideningAddsEveryOtherNiriWorkspaceOnceAndKeepsTheFirstSnapshot() throws {
        let fixture = try makeFixture(pid: 834_241, workspaceNames: ["1", "2"])
        let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        try moveWindow(fixture, 2, to: other)
        let handler = fixture.controller.niriLayoutHandler
        let first = order(fixture, in: fixture.workspaceId)
        let start = try XCTUnwrap(handler.layoutChangeStart(in: fixture.workspaceId))
        fixture.mutate { fixture.stack(1, onto: 0) }
        XCTAssertNotEqual(order(fixture, in: fixture.workspaceId), first)

        let wide = try XCTUnwrap(handler.coveringEveryNiriWorkspace(start))

        func orders(_ change: NiriLayoutChangeStart) -> [WorkspaceDescriptor.ID: [[WindowToken]]] {
            change.snapshots.mapValues { $0.columns.map(\.windows) }
        }
        XCTAssertTrue(wide.coversEveryNiriWorkspace)
        XCTAssertEqual(orders(wide), [fixture.workspaceId: first, other: order(fixture, in: other)])
        XCTAssertEqual(wide.startedAt, start.startedAt)
        XCTAssertEqual(wide.userActionCount, start.userActionCount)
        XCTAssertEqual(orders(try XCTUnwrap(handler.coveringEveryNiriWorkspace(wide))), orders(wide))
        XCTAssertEqual(
            orders(try XCTUnwrap(handler.layoutChangeStartCoveringEveryNiriWorkspace(in: other))),
            [fixture.workspaceId: order(fixture, in: fixture.workspaceId), other: order(fixture, in: other)]
        )
    }

    func testACommandThatMovesAWindowToTheWorkspaceBelowIsUndoneFromThere() throws {
        let commands: [HotkeyCommand] = [.workspace(.moveDown), .windowMovement(.downOrToWorkspaceDown)]
        XCTAssertEqual(commands.map(CommandHandler.layoutChangeCoverage), [.everyNiriWorkspace, .ownWorkspace])
        for (index, command) in commands.enumerated() {
            let fixture = try makeFixture(pid: pid_t(834_250 + index), workspaceNames: ["1", "2"])
            let other = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
            try moveWindow(fixture, 1, to: other)
            fixture.engine.clearLayoutHistory(in: fixture.workspaceId)
            fixture.engine.clearLayoutHistory(in: other)
            let moved = fixture.tokens[2]
            fixture.focus(2)
            let here = order(fixture, in: fixture.workspaceId)
            let there = order(fixture, in: other)

            XCTAssertEqual(fixture.controller.commandHandler.performCommand(command), .executed, "\(command)")

            XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: moved), other, "\(command)")
            XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: other), "\(command)")
            XCTAssertEqual(order(fixture, in: other), there, "\(command)")
            XCTAssertEqual(order(fixture, in: fixture.workspaceId), here, "\(command)")
        }
    }

    func testEveryKindOfUndoStartsWhereTheWindowsAreDrawnAndLandsWhereTheyWere() throws {
        try checkUndo("move", pid: 834_211) { fixture in
            fixture.engine.root(for: fixture.workspaceId)!.insertChild(fixture.column(2), at: 0)
        }
        try checkUndo("width", pid: 834_212) { fixture in
            fixture.column(0).width = .fixed(640)
            fixture.column(0).cachedWidth = 0
        }
        try checkUndo("stack", pid: 834_213) { fixture in
            fixture.stack(2, onto: 1)
        }
        try checkUndo("unstack", pid: 834_214, setup: { $0.stack(2, onto: 1) }) { fixture in
            let column = NiriContainer()
            fixture.engine.initializeNewContainerSizing(column, in: fixture.workspaceId)
            column.width = .fixed(400)
            fixture.engine.root(for: fixture.workspaceId)!.insertChild(column, at: 2)
            column.insertChild(fixture.window(2), at: 0)
        }
        try checkUndo("heights", pid: 834_215, setup: { $0.stack(2, onto: 1) }) { fixture in
            fixture.window(1).height = .fixed(300)
        }
        try checkUndo("tabbed", pid: 834_216, tabRailAppears: true, setup: { $0.stack(2, onto: 1) }) { fixture in
            let column = fixture.column(1)
            column.displayMode = .tabbed
            fixture.engine.updateTabbedColumnVisibility(column: column)
        }
        try checkUndo("move and width", pid: 834_217) { fixture in
            fixture.engine.root(for: fixture.workspaceId)!.insertChild(fixture.column(2), at: 0)
            fixture.column(1).width = .fixed(600)
            fixture.column(1).cachedWidth = 0
        }
    }
}
