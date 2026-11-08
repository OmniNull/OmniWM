// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriFreeStyleStackTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let tokens: [WindowToken]
        var state: ViewportState
        var motion = MotionSnapshot.disabled

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: motion, workingFrame: frame, gaps: gap, orientation: .horizontal)
        }

        var hintHeight: CGFloat {
            max(frame.height * 0.05, 40)
        }

        var singleWindowHintHeight: CGFloat {
            max(frame.height * 0.15, 40)
        }

        var move: LiveColumnMove? {
            engine.liveColumnMove
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func stripColumn(_ column: NiriContainer) -> LiveColumnMove.StripColumn {
            engine.liveColumnStrip(context: context, state: state).first { $0.column === column }!
        }

        func span(of index: Int) -> LiveColumnMove.WindowSpan {
            engine.liveWindowSpans(in: column(index), context: context).first { $0.window === window(index) }!
        }

        func height(of index: Int) -> CGFloat {
            let span = span(of: index)
            return span.maxY - span.minY
        }

        func centre(of index: Int, upper: Bool) -> CGPoint {
            let span = span(of: index)
            let quarter = (span.maxY - span.minY) / 4
            return CGPoint(x: stripColumn(column(index)).midX, y: upper ? span.maxY - quarter : span.minY + quarter)
        }

        func side(of index: Int, leading: Bool) -> CGPoint {
            let placed = stripColumn(column(index))
            let span = span(of: index)
            let x = leading ? placed.minX + placed.width / 6 : placed.maxX - placed.width / 6
            return CGPoint(x: x, y: (span.minY + span.maxY) / 2)
        }

        mutating func begin(_ index: Int) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window(index).id,
                windowToken: tokens[index],
                context: context,
                state: &state
            )
        }

        mutating func move(
            to cursor: CGPoint,
            windowMidX: CGFloat? = nil,
            slowed: Bool = false,
            at time: TimeInterval
        ) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveUpdate(
                cursor: cursor,
                windowMidX: windowMidX,
                at: time,
                slowed: slowed,
                context: context,
                state: &state
            )
            if step == .changed {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func setStackMode(_ held: Bool, at cursor: CGPoint) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveStackModeChanged(
                held: held,
                cursor: cursor,
                context: context,
                state: &state
            )
            if step == .changed {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func openHint(over index: Int, upper: Bool) {
            _ = move(to: centre(of: index, upper: upper), at: 1)
            _ = move(to: centre(of: index, upper: upper), at: 2)
        }

        mutating func stack(_ index: Int, onto target: Int) {
            let moved = window(index)
            let column = column(index)
            moved.detach()
            column.remove()
            engine.attachTransferredWindow(
                moved,
                stackedWith: window(target),
                after: true,
                in: workspaceId,
                state: &state
            )
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            )
        }

        func gapBetween(_ near: NiriContainer, _ far: NiriContainer, trailing: Bool) -> CGFloat {
            trailing ? stripColumn(far).minX - stripColumn(near).maxX : stripColumn(near).minX - stripColumn(far).maxX
        }

        func frames(at time: TimeInterval) -> [WindowToken: CGRect] {
            engine.calculateLayoutWithVisibility(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: .horizontal,
                animationTime: time
            ).frames
        }

        mutating func end(stacking: Bool = false) -> Bool {
            engine.liveColumnMoveEnd(stacking: stacking, context: context, state: &state)
        }

        mutating func finish() -> Bool {
            engine.liveStackDropFinish(context: context, state: &state)
        }
    }

    private func makeFixture(widths: [CGFloat] = Array(repeating: 1.0 / 3.0, count: 5)) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.moveConfiguration.liveHoverDelay = 0
        engine.applyMacOSFusion(.init(enabled: true, edgePeekShare: nil))
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 96), displayId: 96, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Free-style stacking"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 961, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[1], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = 1
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }

    private func makeTabbed(_ fixture: inout Fixture, stacking index: Int, onto target: Int) -> NiriContainer {
        fixture.stack(index, onto: target)
        let tabs = fixture.column(target)
        tabs.displayMode = .tabbed
        fixture.engine.activateWindow(fixture.window(target).id, in: fixture.workspaceId)
        fixture.engine.updateTabbedColumnVisibility(column: tabs)
        return tabs
    }

    func testATabbedColumnJoinsAPlainColumnWithAllItsWindowsAndUndoBringsItBack() throws {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil))
        let columnCount = fixture.engine.columns(in: fixture.workspaceId).count
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move?.isWholeColumn, true)

        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        let target = fixture.column(3)
        XCTAssertEqual(target.windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[0], fixture.tokens[3]])
        XCTAssertFalse(target.isTabbed)
        XCTAssertEqual(fixture.height(of: 0), fixture.height(of: 3), accuracy: 0.5)
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, columnCount - 1)

        fixture.engine.recordLayoutChange(in: fixture.workspaceId, since: before)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspaceId, focused: nil))
        let restored = fixture.column(1)
        XCTAssertEqual(restored.windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[0]])
        XCTAssertTrue(restored.isTabbed)
        XCTAssertEqual(restored.activeTileIdx, 0)
        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[3]])

        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspaceId, focused: nil))
        XCTAssertEqual(
            fixture.column(3).windowNodes.map(\.token),
            [fixture.tokens[1], fixture.tokens[0], fixture.tokens[3]]
        )
    }

    func testATabbedColumnJoinsATabbedColumnAsTabsAndItsShownTabIsShown() throws {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        _ = makeTabbed(&fixture, stacking: 4, onto: 3)
        let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil))
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        let target = fixture.column(3)
        XCTAssertTrue(target.isTabbed)
        XCTAssertEqual(Set(target.windowNodes.map(\.token)), Set([0, 1, 3, 4].map { fixture.tokens[$0] }))
        let order = target.windowNodes.map(\.token)
        let shown = try XCTUnwrap(order.firstIndex(of: fixture.tokens[1]))
        XCTAssertEqual(order[shown + 1], fixture.tokens[0])
        XCTAssertTrue(fixture.engine.projectedActiveWindow(in: target, workspaceId: fixture.workspaceId) === fixture
            .window(1))
        XCTAssertTrue(fixture.window(0).isHiddenInTabbedMode)

        fixture.engine.recordLayoutChange(in: fixture.workspaceId, since: before)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspaceId, focused: nil))
        XCTAssertEqual(fixture.column(1).windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[0]])
        XCTAssertTrue(fixture.column(1).isTabbed)
        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[3], fixture.tokens[4]])
    }

    func testATabbedColumnsWindowsStayInTheStripThroughTheDropUndoAndRedo() throws {
        for single in [true, false] {
            var fixture = makeFixture()
            if single {
                let column = fixture.column(1)
                column.displayMode = .tabbed
                fixture.engine.updateTabbedColumnVisibility(column: column)
            } else {
                _ = makeTabbed(&fixture, stacking: 0, onto: 1)
            }
            func check(_ label: String) {
                let inTree = Set(fixture.engine.root(for: fixture.workspaceId)!.allWindows.map(\.token))
                for token in fixture.tokens {
                    guard let node = fixture.engine.findNode(for: token, in: fixture.workspaceId) else { continue }
                    XCTAssertTrue(inTree.contains(token), "\(single) \(label) \(token)")
                    XCTAssertNotNil(node.parent, "\(single) \(label) \(token)")
                }
            }
            let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil))
            XCTAssertTrue(fixture.begin(1))
            fixture.openHint(over: 3, upper: false)
            check("hint")
            if !single {
                XCTAssertNil(fixture.frames(at: 3)[fixture.tokens[0]], "the held tab is laid out")
            }
            XCTAssertTrue(fixture.end())
            check("end")
            XCTAssertTrue(fixture.finish())
            check("finish")
            fixture.engine.recordLayoutChange(in: fixture.workspaceId, since: before)
            _ = fixture.engine.stepLayoutHistory(.undo, in: fixture.workspaceId, focused: nil)
            check("undo")
            _ = fixture.engine.stepLayoutHistory(.redo, in: fixture.workspaceId, focused: nil)
            check("redo")
        }
    }

    func testATabbedColumnCarriedToAnotherStripWhileItsHintIsOpenTakesItsOwnColumn() throws {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        let hinted = fixture.column(3)

        let otherWorkspaceId = WorkspaceDescriptor.ID()
        let otherFrame = CGRect(x: 1_500, y: 0, width: 1_500, height: 900)
        fixture.engine.syncWorkspaceAssignments(
            [
                (workspaceId: fixture.workspaceId, monitor: Monitor(
                    id: Monitor.ID(displayId: 96), displayId: 96, frame: fixture.frame, visibleFrame: fixture.frame,
                    hasNotch: false, name: "Free-style stacking"
                )),
                (workspaceId: otherWorkspaceId, monitor: Monitor(
                    id: Monitor.ID(displayId: 97), displayId: 97, frame: otherFrame, visibleFrame: otherFrame,
                    hasNotch: false, name: "Other strip"
                ))
            ],
            orientations: [Monitor.ID(displayId: 96): .horizontal, Monitor.ID(displayId: 97): .horizontal]
        )
        let resident = WindowToken(pid: 961, windowId: 50)
        _ = fixture.engine.addWindow(token: resident, to: otherWorkspaceId, afterSelection: nil)
        fixture.engine.resolvePrimaryContainerSpans(
            in: otherWorkspaceId, workingFrame: otherFrame, gaps: fixture.gap, orientation: .horizontal
        )
        let target = NiriInteractionContext(
            workspaceId: otherWorkspaceId,
            motion: .disabled,
            workingFrame: otherFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        var targetState = ViewportState()

        let carried = fixture.engine.liveColumnMoveCarry(
            cursor: CGPoint(x: otherFrame.maxX - 100, y: otherFrame.midY),
            windowWidth: nil,
            from: fixture.context,
            sourceState: &fixture.state,
            to: target,
            targetState: &targetState
        )

        XCTAssertEqual(Set(carried), [fixture.tokens[1], fixture.tokens[0]])
        let arrived = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[1], in: otherWorkspaceId))
        XCTAssertTrue(arrived.parent === fixture.engine.findNode(for: fixture.tokens[0], in: otherWorkspaceId)?.parent)
        XCTAssertTrue(fixture.engine.columns(in: otherWorkspaceId).contains { $0 === arrived.parent })
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).contains { $0 === hinted })
        XCTAssertEqual(hinted.windowNodes.map(\.token), [fixture.tokens[3]])
        XCTAssertEqual(targetState.selectedNodeId, arrived.id)
    }

    func testATabbedColumnOfOneWindowStacksAsAPlainWindow() {
        var fixture = makeFixture()
        let single = fixture.column(1)
        single.displayMode = .tabbed
        fixture.engine.updateTabbedColumnVisibility(column: single)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move?.isWholeColumn, true)

        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[3]])
        XCTAssertFalse(fixture.column(3).isTabbed)
    }

    func testATabbedColumnWhoseWindowsDoNotFitTogetherIsNotHinted() {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        let tall = WindowSizeConstraints(
            minSize: CGSize(width: 100, height: fixture.frame.height * 0.35),
            maxSize: .zero,
            isFixed: false
        )
        for index in [0, 1, 3] {
            fixture.window(index).constraints = tall
        }
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: false)

        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
    }

    func testHoldingTheStackModifierStacksATabbedColumnToo() {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        XCTAssertTrue(fixture.begin(1))
        let target = fixture.centre(of: 3, upper: false)
        _ = fixture.move(to: target, at: 1)

        _ = fixture.setStackMode(true, at: target)
        _ = fixture.move(to: target, at: 2)
        XCTAssertNotNil(fixture.move?.landing)
        XCTAssertTrue(fixture.end(stacking: true))
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(
            Set(fixture.column(3).windowNodes.map(\.token)),
            Set([0, 1, 3].map { fixture.tokens[$0] })
        )
    }

    func testClosingTheHintPutsTheTabbedColumnBackWhole() {
        var fixture = makeFixture()
        _ = makeTabbed(&fixture, stacking: 0, onto: 1)
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertNil(fixture.frames(at: 3)[fixture.tokens[0]])

        let side = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: side, at: 3)
        _ = fixture.move(to: side, at: 4)

        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
        let home = fixture.window(1).parent as? NiriContainer
        XCTAssertTrue(fixture.window(0).parent === home)
        XCTAssertEqual(home?.windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[0]])
        XCTAssertEqual(home?.isTabbed, true)
        XCTAssertEqual(home?.activeTileIdx, 0)
    }

    func testTheCentreOpensATallerHintOverAWindowAloneInItsColumn() {
        for upper in [true, false] {
            var fixture = makeFixture()
            XCTAssertTrue(fixture.begin(1))
            let target = fixture.centre(of: 3, upper: upper)
            _ = fixture.move(to: target, at: 1)

            XCTAssertEqual(fixture.move(to: target, at: 1), .hovering(until: 1 + 0.2))
            XCTAssertNil(fixture.move?.landing)
            XCTAssertEqual(fixture.move(to: target, at: 1.25), .changed)

            XCTAssertEqual(fixture.move?.landingIsHint, true)
            XCTAssertEqual(fixture.move?.landing?.above, upper)
            XCTAssertTrue(fixture.window(1).parent === fixture.column(3))
            XCTAssertEqual(fixture.height(of: 1), fixture.singleWindowHintHeight, accuracy: 0.5)
            XCTAssertEqual(
                fixture.height(of: 3),
                fixture.frame.height - 3 * fixture.gap - fixture.singleWindowHintHeight,
                accuracy: 0.5
            )
        }
    }

    func testMovesWithinTheCentreDontRestartItsDelayAndLeavingDoes() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let target = fixture.centre(of: 3, upper: true)
        _ = fixture.move(to: target, at: 1)
        XCTAssertEqual(fixture.move(to: target, at: 1), .hovering(until: 1 + 0.2))
        let nudged = CGPoint(x: target.x + 10, y: target.y)
        XCTAssertEqual(fixture.move(to: nudged, at: 1.1), .hovering(until: 1 + 0.2))

        _ = fixture.move(to: fixture.side(of: 3, leading: false), at: 1.12)
        XCTAssertNil(fixture.move?.centreWait)
        _ = fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state)

        var again = makeFixture()
        XCTAssertTrue(again.begin(1))
        let centre = again.centre(of: 3, upper: true)
        _ = again.move(to: centre, at: 1)
        _ = again.move(to: again.side(of: 3, leading: true), at: 1.05)
        XCTAssertEqual(again.move(to: again.centre(of: 3, upper: true), at: 1.2), .hovering(until: 1.2 + 0.2))
    }

    func testTheSideThirdsKeepTheSwapRules() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.move(to: fixture.side(of: 3, leading: false), at: 1), .changed)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertFalse(fixture.move?.landingIsHint ?? true)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testAWindowNarrowerThanTheCentreWidthHasNoCentre() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 280.0 / 1_500, 0.3])
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1)
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 2)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testTheHintTakesItsRoomOnlyFromTheWindowNextToIt() {
        var fixture = makeFixture()
        fixture.stack(4, onto: 3)
        fixture.stack(0, onto: 4)
        let heights = (top: fixture.height(of: 0), middle: fixture.height(of: 4), bottom: fixture.height(of: 3))
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 0, upper: true)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.height(of: 0), heights.top - fixture.hintHeight - fixture.gap, accuracy: 0.5)
        XCTAssertEqual(fixture.height(of: 4), heights.middle, accuracy: 0.5)
        XCTAssertEqual(fixture.height(of: 3), heights.bottom, accuracy: 0.5)
    }

    func testAMinimumHeightTallerThanTheDisplayDoesNotBlockTheHint() {
        var fixture = makeFixture()
        fixture.window(3).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 100, height: fixture.frame.height * 2),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: false)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())
        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[3]])
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)
    }

    func testAGuessedMinimumHeightDoesNotBlockTheHint() {
        var fixture = makeFixture()
        fixture.window(3).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 100, height: fixture.frame.height * 0.9),
            maxSize: .zero,
            isFixed: false
        )
        let guessed = fixture.tokens[3]
        fixture.engine.reportedMinimumSize = { token in
            token == guessed ? CGSize(width: 100, height: 200) : nil
        }
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: false)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
    }

    func testEveryWindowCountsAsAtLeastTheFloorHeight() {
        var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 9))
        let tiny = WindowSizeConstraints(minSize: CGSize(width: 1, height: 1), maxSize: .zero, isFixed: false)
        for index in 0 ..< 9 {
            fixture.window(index).constraints = tiny
        }
        for index in 3 ..< 8 {
            fixture.stack(index, onto: 0)
        }
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 0, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        _ = fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state)

        fixture.stack(8, onto: 0)
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 0, upper: false)
        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
    }

    func testMinimumHeightsThatCannotShareTheDisplayStillBlockTheHint() {
        var fixture = makeFixture()
        let tall = WindowSizeConstraints(
            minSize: CGSize(width: 100, height: fixture.frame.height * 0.6),
            maxSize: .zero,
            isFixed: false
        )
        fixture.window(1).constraints = tall
        fixture.window(3).constraints = tall
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: false)

        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
    }

    func testAStackDropKeepsTheWindowsBeforeTheDraggedOneWhereTheyWere() {
        var fixture = makeFixture()
        let left = fixture.stripColumn(fixture.column(1)).minX
        XCTAssertTrue(fixture.begin(2))
        let target = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: target, at: 1)
        _ = fixture.move(to: target, at: 2)
        fixture.openHint(over: 3, upper: false)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertTrue(fixture.window(2).parent === fixture.column(3))
        XCTAssertEqual(fixture.stripColumn(fixture.column(1)).minX, left, accuracy: 0.5)
    }

    func testAStackDropAfterAnEdgeHopAtTheStripStartLeavesNoSpaceBeforeIt() {
        var fixture = makeFixture(widths: [0.74, 0.62])
        let first = fixture.column(0)
        fixture.state.jumpOffset(to: fixture.stripColumn(first).minX + 500)
        XCTAssertLessThan(fixture.stripColumn(first).minX, fixture.frame.minX)
        XCTAssertTrue(fixture.begin(1))

        XCTAssertNotNil(fixture.engine.liveColumnMoveHop(
            towardTrailingEdge: false,
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        XCTAssertGreaterThan(fixture.stripColumn(first).minX, fixture.frame.minX + fixture.gap + 0.5)
        fixture.openHint(over: 0, upper: true)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertTrue(fixture.window(1).parent === first)
        XCTAssertEqual(fixture.stripColumn(first).minX, fixture.frame.minX + fixture.gap, accuracy: 0.5)
    }

    func testAStackDropThatLeavesAStripThatFitsCentresIt() throws {
        var fixture = makeFixture(widths: [0.3, 0.3])
        fixture.engine.alwaysCenterSingleColumn = true
        let pair = fixture.stripColumn(fixture.column(1)).maxX - fixture.stripColumn(fixture.column(0)).minX
        fixture.state.jumpOffset(
            to: fixture.state.viewOffset + fixture.stripColumn(fixture.column(0)).minX
                - (fixture.frame.midX - pair / 2)
        )
        XCTAssertTrue(fixture.begin(0))
        fixture.openHint(over: 1, upper: true)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        let stack = fixture.stripColumn(fixture.column(1))
        XCTAssertTrue(fixture.window(0).parent === fixture.column(1))
        XCTAssertEqual(stack.minX + stack.maxX, fixture.frame.minX + fixture.frame.maxX, accuracy: 1)
    }

    func testReleasingOverTheHintStacksAndTheColumnTakesItsFinalShares() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: false)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[3]])
        XCTAssertTrue(fixture.column(3).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)
    }

    func testLettingGoBeforeTheCentreDelayIsASwap() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1)

        XCTAssertTrue(fixture.end())

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertEqual(fixture.column(1).windowNodes.count, 1)
    }

    func testAnImmediateUpdateOpensNoHint() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.engine.liveColumnMoveUpdate(
            cursor: fixture.centre(of: 3, upper: true),
            at: 5,
            immediate: true,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertNil(fixture.move?.landing)
    }

    func testTheModifierTurnsTheHintIntoTheFullGapAndBack() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let cursor = fixture.centre(of: 3, upper: true)

        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)

        XCTAssertEqual(fixture.setStackMode(false, at: cursor), .changed)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.height(of: 1), fixture.singleWindowHintHeight, accuracy: 0.5)
    }

    func testReleasingTheModifierOverASideThirdClosesTheGap() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.side(of: 3, leading: true)), .changed)
        XCTAssertNotNil(fixture.move?.landing)

        XCTAssertEqual(fixture.setStackMode(false, at: fixture.side(of: 3, leading: true)), .changed)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testTheHintHoldsAShortWayPastTheCentre() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let placed = fixture.stripColumn(fixture.column(3))
        let y = fixture.centre(of: 3, upper: true).y

        _ = fixture.move(to: CGPoint(x: placed.minX + placed.width / 3 - 10, y: y), at: 3)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        _ = fixture.move(to: CGPoint(x: placed.minX + placed.width / 3 - 30, y: y), at: 3.1)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertTrue(fixture.window(1).parent !== fixture.column(3))
    }

    func testTheEdgeScrollClosesTheHint() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.engine.liveColumnMoveCloseLandingForEdgeScroll(
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertTrue(fixture.column(3).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
    }

    func testCancellingWithAHintOpenRestoresTheColumn() {
        var fixture = makeFixture()
        let height = fixture.height(of: 3)
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertNil(fixture.window(3).liveSpanOverride)
        XCTAssertNil(fixture.window(1).liveSpanOverride)
        XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        XCTAssertEqual(fixture.height(of: 3), height, accuracy: 0.5)
    }

    func testADragCutOffWithAHintOpenLeavesNoHintBehind() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        fixture.engine.cancelInteractions(for: [fixture.window(1).id], in: fixture.workspaceId)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        XCTAssertTrue(fixture.column(1).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
        XCTAssertGreaterThanOrEqual(fixture.column(1).cachedWidth, narrow + 150 - 0.5)
    }

    func testTheCentreAloneDoesntStopTheEdgeScroll() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move(to: fixture.side(of: 3, leading: false), at: 1), .changed)
        let placed = fixture.stripColumn(fixture.column(3))
        let centre = CGPoint(x: placed.midX + 5, y: fixture.side(of: 3, leading: false).y)

        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: centre,
            strip: fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state),
            context: fixture.context
        ))
    }

    func testASideThirdWaitsItsDelayAgainAfterTheCentre() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(1))
        let side = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: side, at: 1)
        XCTAssertEqual(fixture.move(to: side, at: 1), .hovering(until: 1.12))
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1.05)

        XCTAssertEqual(fixture.move(to: side, at: 1.3), .hovering(until: 1.3 + 0.12))
    }

    func testUndoAfterAWideningDropRestoresTheStack() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        let before = fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil)!
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())
        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow + 150, accuracy: 0.5)

        XCTAssertTrue(fixture.engine.restoreLayoutSnapshot(before, in: fixture.workspaceId))

        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow, accuracy: 0.5)
    }

    func testWithoutCentreStackingTheCentreNeverStacks() {
        var fixture = makeFixture()
        fixture.engine.stacksOnWindowCentres = false
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: true)

        XCTAssertNil(fixture.move?.landing)
    }

    func testTheGapLeftBehindClosesWithTheWindowAndStaysClosedOnceClosed() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)

        var widths: [CGFloat] = []
        for step in 1 ... 14 {
            _ = fixture.move(to: CGPoint(x: start + CGFloat(step) * 40, y: y), at: 1)
            widths.append(fixture.stripColumn(home).width)
        }

        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertEqual(widths.last ?? .nan, -fixture.gap, accuracy: 0.5)
        let left = fixture.stripColumn(fixture.column(0))
        let right = fixture.stripColumn(fixture.column(2))
        XCTAssertEqual(right.minX - left.maxX, fixture.gap, accuracy: 0.5)
        XCTAssertTrue(zip(widths, widths.dropFirst()).allSatisfy { $0 - $1 <= 40.5 })

        for x in [start + 200, start] {
            _ = fixture.move(to: CGPoint(x: x, y: y), at: 1)
            XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5, "\(x)")
            XCTAssertEqual(fixture.stripColumn(fixture.column(2)).minX, right.minX, accuracy: 0.5, "\(x)")
        }
        XCTAssertGreaterThan(full, 0)
    }

    func testAPartlyClosedPlaceOpensAgainOnTheWayBack() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)

        _ = fixture.move(to: CGPoint(x: start + 200, y: y), at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, full - 200, accuracy: 0.5)
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)

        XCTAssertEqual(fixture.stripColumn(home).width, full, accuracy: 0.5)
    }

    func testAClosedPlaceOpensAsAGapWhereItWasAndTheWindowLandsBackThere() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)
        _ = fixture.move(to: CGPoint(x: start + full + 2 * fixture.gap, y: y), at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
        let neighbour = fixture.stripColumn(fixture.column(2))
        let nearThird = CGPoint(x: neighbour.minX + 40, y: y)

        XCTAssertNotEqual(fixture.move(to: nearThird, at: 1.1), .changed)
        XCTAssertNil(fixture.move?.dropSpaceId)
        XCTAssertEqual(fixture.move(to: nearThird, slowed: true, at: 1.2), .changed)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let dropSpace = columns.firstIndex { $0.isLiveDropSpace }
        let homeIndex = columns.firstIndex { $0 === home }
        XCTAssertNotNil(dropSpace)
        XCTAssertEqual(abs((dropSpace ?? 0) - (homeIndex ?? 0)), 1)
        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
        XCTAssertEqual(fixture.stripColumn(fixture.column(2)).minX, neighbour.minX, accuracy: 0.5)
        XCTAssertNotEqual(fixture.move(to: CGPoint(x: neighbour.minX + 10, y: y), slowed: true, at: 1.3), .changed)

        XCTAssertTrue(fixture.end())
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), order)
        XCTAssertEqual(fixture.stripColumn(home).width, full, accuracy: 0.5)
    }

    func testAClosedPlaceAtTheStripEndOpensAsAGapPastTheLastWindow() {
        var fixture = makeFixture(widths: Array(repeating: 0.2, count: 4))
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        let home = fixture.column(3)
        let placed = fixture.stripColumn(home)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(3))
        _ = fixture.move(to: CGPoint(x: placed.midX, y: y), at: 1)
        _ = fixture.move(to: CGPoint(x: placed.midX - placed.width - 2 * fixture.gap, y: y), at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
        let last = fixture.stripColumn(fixture.column(2))
        let past = CGPoint(x: min(last.maxX + 60, fixture.frame.maxX - 1), y: y)

        _ = fixture.move(to: past, at: 1.1)
        XCTAssertEqual(fixture.move(to: past, slowed: true, at: 1.2), .changed)

        let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
        XCTAssertEqual(strip.last?.column.isLiveDropSpace, true)
        XCTAssertTrue(strip.last?.contains(x: past.x) == true)
        XCTAssertLessThan(fixture.stripColumn(fixture.column(2)).minX, last.minX - 0.5)

        XCTAssertTrue(fixture.end())
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), order)
    }

    func testEveryLandingIsADropSpaceAndTheHomeSpotStaysPut() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)

        _ = fixture.move(to: fixture.side(of: 3, leading: false), at: 1)

        XCTAssertNotNil(fixture.move?.dropSpaceId)
        let columns = fixture.engine.columns(in: fixture.workspaceId).filter { !$0.isLiveDropSpace }.map(\.id)
        XCTAssertEqual(columns, order)
    }

    func testLettingGoWithNoLandingPutsTheWindowBackAtItsFullWidth() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: fixture.frame.midY), at: 1)
        _ = fixture.move(to: CGPoint(x: start + full + 60, y: fixture.frame.midY), at: 1)
        XCTAssertLessThan(fixture.stripColumn(home).width, 0)

        XCTAssertTrue(fixture.end())

        XCTAssertEqual(fixture.stripColumn(fixture.column(1)).width, full, accuracy: 0.5)
        XCTAssertEqual(fixture.column(1).windowNodes.map(\.token), [fixture.tokens[1]])
    }

    func testTheWindowUnderTheDraggedOneStaysStillAsItsDropSpaceOpens() {
        for leading in [true, false] {
            var fixture = makeFixture(widths: Array(repeating: 0.25, count: 6))
            let before = fixture.stripColumn(fixture.column(3))
            XCTAssertLessThan(before.maxX + 100, fixture.frame.maxX)
            let side = fixture.side(of: 3, leading: leading)
            XCTAssertTrue(fixture.begin(1))

            _ = fixture.move(to: side, at: 1)
            _ = fixture.move(to: side, at: 1)

            XCTAssertNotNil(fixture.move?.dropSpaceId, "\(leading)")
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).minX, before.minX, accuracy: 0.5, "\(leading)")
        }
    }

    func testTheWindowBesideTheHomeUsesTheThirdsLikeAnyOther() {
        var fixture = makeFixture()
        let first = fixture.stripColumn(fixture.column(0))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + first.minX - (fixture.frame.minX + fixture.gap))
        let neighbour = fixture.stripColumn(fixture.column(0))
        XCTAssertEqual(neighbour.minX, fixture.frame.minX + fixture.gap, accuracy: 0.5)
        let nearThird = CGPoint(x: neighbour.maxX - 100, y: fixture.frame.midY)
        XCTAssertTrue(fixture.begin(1))

        for time in [1.0, 1.0, 1.1, 1.2, 1.5] {
            _ = fixture.move(to: nearThird, slowed: true, at: time)
        }

        XCTAssertNil(fixture.move?.dropSpaceId)
        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.stripColumn(fixture.column(0)).minX, neighbour.minX, accuracy: 0.5)

        let farThird = CGPoint(x: neighbour.minX + 60, y: fixture.frame.midY)
        _ = fixture.move(to: farThird, slowed: true, at: 1.6)
        _ = fixture.move(to: farThird, slowed: true, at: 1.7)

        let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
        XCTAssertNotNil(fixture.move?.dropSpaceId)
        XCTAssertEqual(strip.first?.column.isLiveDropSpace, true)
        let pulled = fixture.stripColumn(fixture.column(0))
        XCTAssertLessThan(farThird.x, pulled.minX + pulled.width / 3)
    }

    func testComingBackFromTheMiddleOfTheWindowBesideTheHomeOpensNoGapOnItsFarSide() {
        var fixture = makeFixture()
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        let neighbour = fixture.stripColumn(fixture.column(2))
        XCTAssertTrue(neighbour.isFullyVisible(in: fixture.frame))
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 2, upper: true)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        let nearThird = CGPoint(x: neighbour.minX + 60, y: fixture.frame.midY)
        for time in [2.1, 2.2, 2.4, 3.0] {
            _ = fixture.move(to: nearThird, slowed: true, at: time)
        }

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let homeIndex = columns.firstIndex { $0.id == order[1] } ?? 0
        let farSide = columns.firstIndex { $0.id == order[2] }.map { $0 + 1 } ?? 0
        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
        XCTAssertFalse(columns.indices.contains(farSide) && columns[farSide].isLiveDropSpace)
        if let dropSpace = columns.firstIndex(where: { $0.isLiveDropSpace }) {
            XCTAssertEqual(abs(dropSpace - homeIndex), 1)
        }
        XCTAssertTrue(fixture.end())
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), order)
    }

    func testAtTheStripEndTheStripPullsEvenWithRoom() {
        var fixture = makeFixture(widths: Array(repeating: 0.25, count: 3))
        let last = fixture.column(2)
        let before = fixture.stripColumn(last)
        XCTAssertLessThan(before.maxX + 200, fixture.frame.maxX)
        let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap
        let side = fixture.side(of: 2, leading: false)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: side, at: 1)
        _ = fixture.move(to: side, at: 1)

        let dropSpace = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
            .first { $0.column.isLiveDropSpace }
        XCTAssertEqual(fixture.stripColumn(last).minX, before.minX - shift, accuracy: 0.5)
        XCTAssertEqual(dropSpace?.maxX ?? 0, before.maxX, accuracy: 0.5)
        for time in [1.1, 1.2] {
            XCTAssertNotEqual(fixture.move(to: side, at: time), .changed)
        }
    }

    func testComingBackToAStripEndDoesNotPullTheStripAgain() {
        for (home, end, outward) in [(2, 0, true), (1, 3, false)] {
            var fixture = makeFixture(widths: Array(repeating: 0.2, count: 4))
            let last = fixture.column(end)
            if outward {
                let first = fixture.stripColumn(last)
                fixture.state.jumpOffset(to: fixture.state.viewOffset + first.minX - (fixture.frame.minX + fixture.gap))
            }
            let before = fixture.stripColumn(last)
            XCTAssertGreaterThanOrEqual(before.minX, fixture.frame.minX, "\(end)")
            XCTAssertLessThanOrEqual(before.maxX, fixture.frame.maxX, "\(end)")
            let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap
            let direction: CGFloat = outward ? 1 : -1
            let outer = fixture.side(of: end, leading: outward)
            let inner = fixture.side(of: end, leading: !outward)
            XCTAssertTrue(fixture.begin(home))

            _ = fixture.move(to: outer, at: 1)
            _ = fixture.move(to: outer, at: 1)
            let pulled = fixture.stripColumn(last)
            XCTAssertEqual(pulled.minX, before.minX + direction * shift, accuracy: 0.5, "\(end)")

            for round in 0 ..< 2 {
                _ = fixture.move(to: inner, at: 1)
                _ = fixture.move(to: inner, at: 1)
                let between = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
                XCTAssertNotNil(fixture.move?.dropSpaceId, "\(end) \(round)")
                XCTAssertTrue((outward ? between.first : between.last)?.column === last, "\(end) \(round)")
                _ = fixture.move(to: outer, at: 1)
                _ = fixture.move(to: outer, at: 1)

                let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
                XCTAssertEqual((outward ? strip.first : strip.last)?.column.isLiveDropSpace, true, "\(end) \(round)")
                XCTAssertEqual(fixture.stripColumn(last).minX, pulled.minX, accuracy: 0.5, "\(end) \(round)")
            }
        }
    }

    func testEdgeHopsJumpToTheEdgeWindowThenPassOffScreenWindowsOneByOne() throws {
        for trailing in [true, false] {
            var fixture = makeFixture(widths: Array(repeating: 0.45, count: 7))
            let start = trailing ? 0 : 6
            if !trailing {
                let last = fixture.stripColumn(fixture.column(6))
                fixture.state.jumpOffset(to: fixture.state.viewOffset + last.maxX - (fixture.frame.maxX - fixture.gap))
            }
            XCTAssertTrue(fixture.begin(start))
            var previous = start
            while true {
                let onScreen = Set((0 ..< 7).filter { index in
                    let placed = fixture.stripColumn(fixture.column(index))
                    return placed.maxX > fixture.frame.minX + 0.5 && placed.minX < fixture.frame.maxX - 0.5
                })
                guard let passed = fixture.engine.liveColumnMoveHop(
                    towardTrailingEdge: trailing,
                    context: fixture.context,
                    state: &fixture.state
                ) else { break }
                fixture.engine.liveColumnMoveSettled()
                let index = try XCTUnwrap((0 ..< 7).first { fixture.column($0) === passed })
                let between = trailing ? Array((previous + 1) ..< index) : Array((index + 1) ..< previous)
                for skipped in between {
                    XCTAssertTrue(onScreen.contains(skipped), "\(trailing): skipped off-screen \(skipped)")
                }
                let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
                let gap = try XCTUnwrap(strip.first { $0.column.isLiveDropSpace })
                XCTAssertGreaterThanOrEqual(gap.minX, fixture.frame.minX - 0.5, "\(trailing) \(index)")
                XCTAssertLessThanOrEqual(gap.maxX, fixture.frame.maxX + 0.5, "\(trailing) \(index)")
                previous = index
            }
            XCTAssertEqual(previous, trailing ? 6 : 0, "\(trailing)")
        }
    }

    func testEdgeHopsPassAColumnWhoseWindowIsHiddenAndEndAtTheEdge() throws {
        for (trailing, hidden) in [(true, 3), (false, 3), (true, 1), (true, 6)] {
            var fixture = makeFixture(widths: Array(repeating: 0.45, count: 7))
            fixture.engine.setProjectionExclusions([fixture.tokens[hidden]], in: fixture.workspaceId)
            let start = trailing ? 0 : 6
            if !trailing {
                let last = fixture.stripColumn(fixture.column(6))
                fixture.state.jumpOffset(to: fixture.state.viewOffset + last.maxX - (fixture.frame.maxX - fixture.gap))
            }
            XCTAssertTrue(fixture.begin(start))
            let shown = (0 ..< 7).filter { $0 != hidden && $0 != start }
            var previous = start
            var hops = 0
            while hops < 10 {
                let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
                let onScreen = Set(shown.filter { index in
                    guard let placed = strip.first(where: { $0.column === fixture.column(index) }) else { return false }
                    return placed.maxX > fixture.frame.minX + 0.5 && placed.minX < fixture.frame.maxX - 0.5
                })
                guard let passed = fixture.engine.liveColumnMoveHop(
                    towardTrailingEdge: trailing,
                    context: fixture.context,
                    state: &fixture.state
                ) else { break }
                hops += 1
                fixture.engine.liveColumnMoveSettled()
                let label = "\(trailing) hidden \(hidden) hop \(hops)"
                XCTAssertFalse(passed === fixture.column(hidden), label)
                let index = try XCTUnwrap((0 ..< 7).first { fixture.column($0) === passed }, label)
                let between = (trailing ? Array((previous + 1) ..< index) : Array((index + 1) ..< previous))
                    .filter { $0 != hidden }
                for skipped in between {
                    XCTAssertTrue(onScreen.contains(skipped), "\(label): skipped off-screen \(skipped)")
                }
                let after = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
                let gap = try XCTUnwrap(after.first { $0.column.isLiveDropSpace }, label)
                XCTAssertGreaterThanOrEqual(gap.minX, fixture.frame.minX - 0.5, label)
                XCTAssertLessThanOrEqual(gap.maxX, fixture.frame.maxX + 0.5, label)
                let beyond = after.filter { placed in
                    !placed.column.isLiveDropSpace && !placed.column.isLiveHomeSpot
                        && (trailing ? placed.minX > gap.minX : placed.maxX < gap.maxX)
                }
                for placed in beyond {
                    let fullyShown = placed.minX >= fixture.frame.minX - 0.5 && placed.maxX <= fixture.frame.maxX + 0.5
                    XCTAssertFalse(fullyShown, "\(label): a window past the gap is fully on screen")
                }
                previous = index
            }
            XCTAssertEqual(previous, trailing ? (hidden == 6 ? 5 : 6) : 0, "\(trailing) hidden \(hidden)")
        }
    }

    func testWithTheWindowsPlaceFarBeyondTheEdgeTheFirstHopStartsFromTheScreen() throws {
        var fixture = makeFixture(widths: Array(repeating: 0.45, count: 9))
        XCTAssertTrue(fixture.begin(8))
        fixture.state
            .jumpOffset(to: fixture.state.viewOffset - fixture.stripColumn(fixture.column(0)).minX + fixture.gap)
        XCTAssertGreaterThan(fixture.stripColumn(fixture.column(8)).minX, fixture.frame.maxX)
        let onScreen = (0 ..< 8).filter { index in
            let placed = fixture.stripColumn(fixture.column(index))
            return placed.maxX > fixture.frame.minX + 0.5 && placed.minX < fixture.frame.maxX - 0.5
        }

        let passed = fixture.engine.liveColumnMoveHop(
            towardTrailingEdge: true,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertTrue(passed === fixture.column(try XCTUnwrap(onScreen.last)))
        let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
        let gap = try XCTUnwrap(strip.first { $0.column.isLiveDropSpace })
        XCTAssertLessThanOrEqual(gap.maxX, fixture.frame.maxX + 0.5)
        XCTAssertGreaterThan(fixture.stripColumn(fixture.column(8)).minX, fixture.frame.maxX)
    }

    func testTheFirstEdgeHopPassesEveryWindowOnScreenAtOnce() throws {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(0))
        let visible = (1 ... 4).filter { index in
            let placed = fixture.stripColumn(fixture.column(index))
            return placed.maxX > fixture.frame.minX + 0.5 && placed.minX < fixture.frame.maxX - 0.5
        }
        XCTAssertGreaterThan(visible.count, 1)

        let passed = fixture.engine.liveColumnMoveHop(
            towardTrailingEdge: true,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertTrue(passed === fixture.column(try XCTUnwrap(visible.last)))
    }

    func testAnEdgeHopDoesNotRunInStackMode() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.setStackMode(true, at: fixture.centre(of: 2, upper: false))
        XCTAssertNil(fixture.engine.liveColumnMoveHop(
            towardTrailingEdge: true,
            context: fixture.context,
            state: &fixture.state
        ))
    }

    func testInTheEdgeZoneAStripEndSlidesTheDropSpaceWhollyIntoView() throws {
        for inZone in [true, false] {
            var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 0.9])
            let last = fixture.stripColumn(fixture.column(3))
            fixture.state.jumpOffset(to: fixture.state.viewOffset + last.minX - (fixture.frame.maxX - 300))
            let before = fixture.stripColumn(fixture.column(3))
            XCTAssertGreaterThan(before.maxX, fixture.frame.maxX + 500)
            let span = fixture.span(of: 3)
            let edge = CGPoint(x: fixture.frame.maxX - 2, y: (span.minY + span.maxY) / 2)
            XCTAssertTrue(fixture.begin(1))
            fixture.engine.liveColumnMovePointerInEdgeZone(inZone)

            _ = fixture.move(to: edge, at: 1)
            _ = fixture.move(to: edge, at: 1)

            let strip = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
            XCTAssertEqual(strip.last?.column.isLiveDropSpace, true, "\(inZone)")
            let landing = try XCTUnwrap(strip.last)
            if inZone {
                XCTAssertLessThanOrEqual(landing.maxX, fixture.frame.maxX + 0.5)
                XCTAssertGreaterThanOrEqual(landing.minX, fixture.frame.maxX - 2 * landing.width)
            } else {
                XCTAssertGreaterThan(landing.maxX, fixture.frame.maxX + 100)
            }
        }
    }

    func testAtTheStripEndTheStripIsPulledToShowTheDropSpace() {
        var fixture = makeFixture()
        let last = fixture.stripColumn(fixture.column(4))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + last.maxX - (fixture.frame.maxX - fixture.gap))
        let before = fixture.stripColumn(fixture.column(4))
        XCTAssertEqual(before.maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        let side = fixture.side(of: 4, leading: false)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: side, at: 1)
        _ = fixture.move(to: side, at: 1)

        let dropSpace = fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state)
            .first { $0.column.isLiveDropSpace }
        XCTAssertEqual(dropSpace?.maxX ?? 0, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        let shift = fixture.engine.liveDropSpaceWidth(context: fixture.context) + fixture.gap
        XCTAssertEqual(fixture.stripColumn(fixture.column(4)).minX, before.minX - shift, accuracy: 0.5)
    }

    func testOpeningTheHintClosesAnOpenDropSpace() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let side = fixture.side(of: 3, leading: true)
        _ = fixture.move(to: side, at: 1)
        _ = fixture.move(to: side, at: 1)
        XCTAssertNotNil(fixture.move?.dropSpaceId)

        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1.1)
        XCTAssertEqual(fixture.move(to: fixture.centre(of: 3, upper: true), at: 1.35), .changed)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertNil(fixture.move?.dropSpaceId)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
    }

    func testAPointerThatSlowsDownOpensTheDropSpaceAtOnce() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.2
        XCTAssertTrue(fixture.begin(1))
        let side = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: side, at: 1)
        XCTAssertEqual(fixture.move(to: side, at: 1), .hovering(until: 1 + 0.2))
        XCTAssertNil(fixture.move?.dropSpaceId)

        XCTAssertEqual(fixture.move(to: side, slowed: true, at: 1.06), .changed)

        XCTAssertNotNil(fixture.move?.dropSpaceId)
    }

    func testAPointerStillMovingWaitsTheWholeDelay() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.2
        XCTAssertTrue(fixture.begin(1))
        let side = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: side, at: 1)

        XCTAssertEqual(fixture.move(to: side, at: 1.1), .hovering(until: 1 + 0.2))
        XCTAssertNil(fixture.move?.dropSpaceId)
        XCTAssertEqual(fixture.move(to: side, at: 1.2), .changed)
        XCTAssertNotNil(fixture.move?.dropSpaceId)
    }

    func testAPointerThatSlowsDownOpensTheCentreHintAtOnce() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let target = fixture.centre(of: 3, upper: true)
        _ = fixture.move(to: target, at: 1)
        XCTAssertEqual(fixture.move(to: target, at: 1), .hovering(until: 1 + 0.2))

        XCTAssertEqual(fixture.move(to: target, slowed: true, at: 1.06), .changed)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.move?.landing?.above, true)
    }

    func testAHintOpenWhileTheWindowStillCoversItsPlaceSettles() {
        var fixture = makeFixture()
        let home = fixture.column(1)
        let placed = fixture.stripColumn(home)
        let halfOff = placed.midX + placed.width / 2
        XCTAssertTrue(fixture.begin(1))
        let target = fixture.centre(of: 3, upper: true)
        _ = fixture.move(to: target, windowMidX: halfOff, at: 1)
        _ = fixture.move(to: target, windowMidX: halfOff, at: 1)
        XCTAssertEqual(fixture.move(to: target, windowMidX: halfOff, at: 1.25), .changed)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        XCTAssertNotEqual(fixture.move(to: target, windowMidX: halfOff, at: 1.3), .changed)
        XCTAssertEqual(fixture.stripColumn(home).width, placed.width / 2, accuracy: 0.5)
    }

    func testAClosedPlaceStaysClosedWhileThePointerRests() {
        for outward in [-1.0, 1.0] {
            var fixture = makeFixture(widths: Array(repeating: 1.0 / 3.0, count: 3))
            fixture.engine.moveConfiguration.liveHoverDelay = 10
            fixture.engine.moveConfiguration.liveCentreStackDelay = 10
            let home = fixture.column(1)
            let placed = fixture.stripColumn(home)
            XCTAssertTrue(fixture.begin(1))
            let away = CGPoint(x: placed.midX + outward * (placed.width + 2 * fixture.gap), y: fixture.frame.midY)
            _ = fixture.move(to: away, at: 1)
            XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5, "\(outward)")

            for _ in 0 ..< 4 {
                XCTAssertNotEqual(fixture.move(to: away, at: 1), .changed, "\(outward)")
            }

            XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5, "\(outward)")
        }
    }

    func testPastAStripEndThePlaceStaysAndNothingMoves() {
        for (index, outward) in [(0, -1.0), (4, 1.0)] {
            var fixture = makeFixture()
            fixture.engine.moveConfiguration.liveHoverDelay = 10
            fixture.engine.moveConfiguration.liveCentreStackDelay = 10
            let home = fixture.column(index)
            let placed = fixture.stripColumn(home)
            let other = fixture.column(index == 0 ? 1 : 3)
            let otherBefore = fixture.stripColumn(other)
            XCTAssertTrue(fixture.begin(index))

            _ = fixture.move(to: CGPoint(x: placed.midX + outward * 300, y: fixture.frame.midY), at: 1)
            _ = fixture.move(to: CGPoint(x: placed.midX + outward * 600, y: fixture.frame.midY), at: 1)

            XCTAssertEqual(fixture.stripColumn(home).width, placed.width, accuracy: 0.5, "\(index)")
            XCTAssertEqual(fixture.stripColumn(other).minX, otherBefore.minX, accuracy: 0.5, "\(index)")

            _ = fixture.move(to: CGPoint(x: placed.midX - outward * 300, y: fixture.frame.midY), at: 1)
            XCTAssertLessThan(fixture.stripColumn(home).width, placed.width - 100, "\(index)")
        }
    }

    func testAQuickFlickClosesTheGapOnTheFirstUpdate() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let placed = fixture.stripColumn(home)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: CGPoint(x: placed.midX + placed.width + fixture.gap + 60, y: fixture.frame.midY), at: 1)

        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
    }

    func testTheGapFollowsTheWindowItselfNotTheReferencePoint() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let placed = fixture.stripColumn(home)
        let overHome = CGPoint(x: placed.midX, y: fixture.frame.midY)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: overHome, windowMidX: placed.midX + placed.width / 2, at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, placed.width / 2, accuracy: 0.5)

        _ = fixture.move(to: overHome, windowMidX: placed.midX + placed.width + fixture.gap, at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
    }

    func testThePlaceStaysAsWideAsTheWindowCoversItWhenScrolledOffScreen() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        XCTAssertTrue(fixture.begin(1))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + fixture.stripColumn(home).maxX + 40)
        let placed = fixture.stripColumn(home)
        XCTAssertLessThanOrEqual(placed.maxX, fixture.frame.minX)

        _ = fixture.move(
            to: CGPoint(x: fixture.frame.minX + 20, y: fixture.frame.midY),
            windowMidX: placed.midX + placed.width / 4,
            at: 1
        )

        XCTAssertEqual(fixture.stripColumn(home).width, placed.width * 3 / 4, accuracy: 0.5)
    }

    func testOnlyTheWindowsOwnPlaceClosesThatWay() throws {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let move = try XCTUnwrap(fixture.move)
        XCTAssertTrue(fixture.engine.isClosingOrigin(move))
        var leavingAStack = move
        leavingAStack.inStack = true
        XCTAssertFalse(fixture.engine.isClosingOrigin(leavingAStack))
    }

    func testAWindowLeavingAStackKeepsItsNarrowLandingGap() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(3))
        XCTAssertFalse(try fixture.engine.isClosingOrigin(XCTUnwrap(fixture.move)))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: y), at: 1)
        let left = try XCTUnwrap(fixture.move)
        XCTAssertFalse(left.inStack)
        XCTAssertFalse(fixture.engine.isClosingOrigin(left))
        let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: left))
        XCTAssertFalse(home === stack)

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 400, y: y), at: 1)
        XCTAssertGreaterThan(fixture.stripColumn(home).width, 0)
    }

    func testAWindowLeavesItsStackOnceFortyPercentOfItIsOutside() throws {
        for trailing in [true, false] {
            var fixture = makeFixture()
            fixture.engine.moveConfiguration.liveHoverDelay = 10
            fixture.engine.moveConfiguration.liveCentreStackDelay = 10
            fixture.stack(3, onto: 2)
            let stack = fixture.column(2)
            let placed = fixture.stripColumn(stack)
            XCTAssertTrue(placed.isFullyVisible(in: fixture.frame), "\(trailing)")
            let inset = placed.width * 0.1
            let edge = trailing ? placed.maxX - inset : placed.minX + inset
            let outward: CGFloat = trailing ? 1 : -1
            let y = fixture.frame.midY
            XCTAssertTrue(fixture.begin(3))

            _ = fixture.move(to: CGPoint(x: edge - outward * 5, y: y), at: 1)
            XCTAssertEqual(fixture.move?.inStack, true, "\(trailing)")
            _ = fixture.move(to: CGPoint(x: edge + outward * 5, y: y), at: 1)

            let left = try XCTUnwrap(fixture.move)
            XCTAssertFalse(left.inStack, "\(trailing)")
            let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: left))
            let columns = fixture.engine.columns(in: fixture.workspaceId)
            let stackIndex = try XCTUnwrap(columns.firstIndex { $0 === stack })
            XCTAssertTrue(columns[stackIndex + (trailing ? 1 : -1)] === home, "\(trailing)")
            XCTAssertEqual(fixture.stripColumn(stack).minX, placed.minX, accuracy: 0.5, "\(trailing)")
        }
    }

    func testAnEarlyLeaveAtTheScreenEdgeShowsTheGapOnlyUpToTheEdge() throws {
        var fixture = makeFixture(widths: Array(repeating: 0.8, count: 4))
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        fixture.stack(2, onto: 1)
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).last?.windowNodes.first?.token,
            fixture.tokens[3]
        )
        let stack = fixture.column(1)
        let last = fixture.stripColumn(stack)
        fixture.state.jumpOffset(to: fixture.state.viewOffset + last.maxX - (fixture.frame.maxX - fixture.gap))
        let placed = fixture.stripColumn(stack)
        XCTAssertEqual(placed.maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(2))

        _ = fixture.move(to: CGPoint(x: placed.maxX - placed.width * 0.1 + 5, y: y), at: 1)

        let left = try XCTUnwrap(fixture.move)
        XCTAssertFalse(left.inStack)
        let home = fixture.stripColumn(try XCTUnwrap(fixture.engine.liveDraggedColumn(for: left)))
        XCTAssertEqual(home.maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
        XCTAssertEqual(fixture.stripColumn(stack).maxX, placed.maxX - home.width - fixture.gap, accuracy: 0.5)
    }

    func testTheGapBesideAStackClosesWhileAHintHoldsTheWindowPulledOutOfIt() throws {
        for (trailing, tabbed) in [(true, false), (false, false), (true, true)] {
            let label = "trailing=\(trailing) tabbed=\(tabbed)"
            var fixture = makeFixture()
            fixture.engine.moveConfiguration.liveHoverDelay = 10
            if !trailing {
                fixture.state.jumpOffset(to: fixture.state.viewOffset + 400)
            }
            try pullOutOfStack(&fixture, trailing: trailing, tabbed: tabbed)
            let stack = fixture.column(2)
            let beyond = fixture.column(trailing ? 4 : 1)
            let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: XCTUnwrap(fixture.move)))
            XCTAssertTrue(home.isLiveHomeSpot, label)
            let open = fixture.stripColumn(home).width
            XCTAssertGreaterThan(open, 0, label)
            let stackMinX = fixture.stripColumn(stack).minX

            fixture.openHint(over: 2, upper: true)

            XCTAssertEqual(fixture.move?.landingIsHint, true, label)
            XCTAssertEqual(fixture.stripColumn(stack).minX, stackMinX, accuracy: 0.5, label)
            XCTAssertEqual(
                fixture.gapBetween(stack, beyond, trailing: trailing), fixture.gap, accuracy: 0.5, label
            )

            _ = fixture.move(to: fixture.side(of: 2, leading: trailing), at: 3)

            XCTAssertNotEqual(fixture.move?.landingIsHint, true, label)
            XCTAssertEqual(fixture.stripColumn(home).width, open, accuracy: 0.5, label)
            XCTAssertEqual(fixture.stripColumn(stack).minX, stackMinX, accuracy: 0.5, label)
            XCTAssertEqual(
                fixture.gapBetween(stack, beyond, trailing: trailing), open + 2 * fixture.gap, accuracy: 0.5, label
            )
        }
    }

    func testTheGapBesideAStackKeepsTheDropSpaceWidthUnderTheStackModifier() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        try pullOutOfStack(&fixture, trailing: true, tabbed: false)
        let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: XCTUnwrap(fixture.move)))
        let open = fixture.stripColumn(home).width
        fixture.openHint(over: 2, upper: true)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.centre(of: 2, upper: true)), .changed)

        XCTAssertNotEqual(fixture.move?.landingIsHint, true)
        XCTAssertNotNil(fixture.move?.landing)
        XCTAssertEqual(fixture.stripColumn(home).width, open, accuracy: 0.5)
    }

    func testReleasingOverTheHintStacksTheWindowWithNothingElseMoving() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        try pullOutOfStack(&fixture, trailing: true, tabbed: false)
        let stack = fixture.column(2)
        let beyond = fixture.column(4)
        fixture.openHint(over: 2, upper: true)
        let stackMinX = fixture.stripColumn(stack).minX
        let beyondMinX = fixture.stripColumn(beyond).minX

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertTrue(fixture.column(3) === stack)
        XCTAssertEqual(fixture.stripColumn(stack).minX, stackMinX, accuracy: 0.5)
        XCTAssertEqual(fixture.stripColumn(beyond).minX, beyondMinX, accuracy: 0.5)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveHomeSpot })
    }

    private func pullOutOfStack(_ fixture: inout Fixture, trailing: Bool, tabbed: Bool) throws {
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        if tabbed {
            stack.displayMode = .tabbed
            fixture.engine.updateTabbedColumnVisibility(column: stack)
        }
        let pulled = fixture.window(3)
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: pulled.id,
            windowToken: pulled.token,
            pullsTab: tabbed,
            context: fixture.context,
            state: &fixture.state
        ))
        let placed = fixture.stripColumn(stack)
        let x = trailing ? placed.maxX + 20 : placed.minX - 20
        _ = fixture.move(to: CGPoint(x: x, y: fixture.frame.midY), at: 1)
        XCTAssertNotEqual(try XCTUnwrap(fixture.move).inStack, true)
    }

    func testATabPulledOutKeepsItsNarrowLandingGap() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        fixture.stack(3, onto: 2)
        let tabs = fixture.column(2)
        tabs.displayMode = .tabbed
        fixture.engine.updateTabbedColumnVisibility(column: tabs)
        let pulled = fixture.window(3)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: pulled.id,
            windowToken: pulled.token,
            pullsTab: true,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertFalse(try fixture.engine.isClosingOrigin(XCTUnwrap(fixture.move)))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(tabs).maxX + 20, y: y), at: 1)
        let pulledOut = try XCTUnwrap(fixture.move)
        XCTAssertFalse(fixture.engine.isClosingOrigin(pulledOut))
        let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: pulledOut))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(tabs).maxX + 400, y: y), at: 1)
        XCTAssertGreaterThan(fixture.stripColumn(home).width, 0)
    }

    func testMacOSFusionTurnsCentreStackingOnAndOff() {
        let engine = NiriLayoutEngine()
        engine.applyMacOSFusion(.init(enabled: true, edgePeekShare: nil))
        XCTAssertTrue(engine.stacksOnWindowCentres)
        XCTAssertTrue(engine.animatesLearnedMinimumWidths)
        engine.applyMacOSFusion(.init(enabled: false, edgePeekShare: nil))
        XCTAssertFalse(engine.stacksOnWindowCentres)
        XCTAssertFalse(engine.animatesLearnedMinimumWidths)
    }

    func testANarrowStackTakesAWiderWindowAndWidensOnlyOnTheDrop() {
        for withModifier in [false, true] {
            var fixture = makeFixture()
            let narrow = fixture.stripColumn(fixture.column(3)).width
            let minimum = narrow + 150
            fixture.window(1).constraints = WindowSizeConstraints(
                minSize: CGSize(width: minimum, height: 1),
                maxSize: .zero,
                isFixed: false
            )
            XCTAssertTrue(fixture.begin(1))
            if withModifier {
                XCTAssertEqual(fixture.setStackMode(true, at: fixture.centre(of: 3, upper: true)), .changed)
            } else {
                fixture.openHint(over: 3, upper: true)
            }
            XCTAssertNotNil(fixture.move?.landing, "\(withModifier)")
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow, accuracy: 0.5, "\(withModifier)")

            XCTAssertTrue(fixture.end(stacking: withModifier))
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, minimum, accuracy: 0.5, "\(withModifier)")
            XCTAssertTrue(fixture.finish())
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, minimum, accuracy: 0.5, "\(withModifier)")
            XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        }
    }

    func testAStackWidensTowardTheSideTheWindowCameFrom() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let rightEdge = fixture.stripColumn(fixture.column(3)).maxX

        XCTAssertTrue(fixture.end())

        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).maxX, rightEdge, accuracy: 0.5)
    }

    func testWithAnimationsTheStackSpringsOutFromItsOldWidth() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.end())

        let column = fixture.column(3)
        XCTAssertTrue(column.hasWidthAnimationRunning)
        XCTAssertEqual(column.cachedWidth, narrow, accuracy: 0.5)
        XCTAssertEqual(column.targetWidth ?? 0, narrow + 150, accuracy: 0.5)
    }

    func testADropFromPartlyOffScreenStartsWhereTheWindowWasAndEachEdgeMovesOneWay() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let placed = fixture.stripColumn(fixture.column(3))
        let release = CGRect(x: placed.minX - 100, y: -300, width: placed.width, height: 876)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: release,
            context: fixture.context,
            state: &fixture.state
        ))

        let now = CACurrentMediaTime()
        let samples = (0 ... 12).compactMap { step in
            fixture.frames(at: now + Double(step) * 0.05)[fixture.tokens[1]]
        }
        XCTAssertEqual(samples.first?.minY ?? -1, fixture.frame.minY, accuracy: 1)
        XCTAssertEqual(samples.first?.maxY ?? -1, release.maxY, accuracy: 1)
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.minY, earlier.minY - 0.5)
            XCTAssertGreaterThanOrEqual(later.maxY, earlier.maxY - 0.5)
        }
    }

    func testWhileTheStackSpringsOutTheWiderWindowStaysOffTheStillNeighbour() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        let minimum = narrow + 150
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: minimum, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.end())

        let now = CACurrentMediaTime()
        for step in 0 ... 12 {
            let frames = fixture.frames(at: now + Double(step) * 0.05)
            guard let dropped = frames[fixture.tokens[1]], let neighbour = frames[fixture.tokens[4]] else {
                return XCTFail("no frames at step \(step)")
            }
            XCTAssertGreaterThanOrEqual(dropped.width, minimum - 0.5, "step \(step)")
            XCTAssertLessThanOrEqual(dropped.maxX, neighbour.minX - fixture.gap + 0.5, "step \(step)")
        }
    }

    func testAStackWideEnoughForTheWindowKeepsItsWidth() {
        var fixture = makeFixture()
        let width = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: width - 100, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, width, accuracy: 0.5)
    }

    func testALearnedMinimumWidensItsColumnWithAnAnimation() {
        for animates in [true, false] {
            let fixture = makeFixture()
            fixture.engine.animatesLearnedMinimumWidths = animates
            let column = fixture.column(3)
            let width = column.cachedWidth

            fixture.engine.updateWindowConstraints(
                for: fixture.tokens[3],
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: width + 200, height: 1),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: fixture.workspaceId,
                motion: .enabled
            )

            XCTAssertEqual(column.hasWidthAnimationRunning, animates)
            XCTAssertEqual(animates ? column.targetWidth ?? 0 : column.cachedWidth, width + 200, accuracy: 0.5)
        }
    }
}
