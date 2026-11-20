// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriLayoutHistoryTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func order() -> [[WindowToken]] {
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        }

        func snapshot() -> NiriLayoutSnapshot {
            engine.layoutSnapshot(in: workspaceId, focused: nil)!
        }

        func columns(_ indices: [[Int]]) -> [[WindowToken]] {
            indices.map { $0.map { tokens[$0] } }
        }

        @discardableResult
        func change(_ body: () -> Void) -> NiriLayoutSnapshot {
            let before = snapshot()
            body()
            engine.recordLayoutChange(in: workspaceId, since: before)
            return before
        }

        func undo() -> Bool {
            engine.stepLayoutHistory(.undo, in: workspaceId, focused: nil) != nil
        }

        func redo() -> Bool {
            engine.stepLayoutHistory(.redo, in: workspaceId, focused: nil) != nil
        }

        func moveColumn(_ index: Int, to position: Int) {
            engine.root(for: workspaceId)!.insertChild(column(index), at: position)
        }

        func stack(_ index: Int, onto target: Int) {
            let source = column(index)
            let destination = column(target)
            destination.insertChild(window(index), at: destination.windowNodes.count)
            if source.windowNodes.isEmpty { source.remove() }
        }
    }

    private func makeFixture(
        count: Int = 4,
        engine: NiriLayoutEngine = NiriLayoutEngine(),
        displayId: UInt32 = 95,
        pid: pid_t = 951
    ) -> Fixture {
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Layout history"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = (0 ..< count).map { WindowToken(pid: pid, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: 12, orientation: .horizontal)
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens)
    }

    func testUndoBringsBackTheOrderTheStacksTheWidthsAndTheTabs() {
        let fixture = makeFixture()
        let before = fixture.change {
            fixture.moveColumn(3, to: 0)
            fixture.stack(1, onto: 2)
            fixture.column(0).width = .fixed(640)
            let stacked = fixture.column(2)
            stacked.displayMode = .tabbed
            stacked.setActiveTileIdx(1)
            fixture.engine.updateTabbedColumnVisibility(column: stacked)
        }
        XCTAssertEqual(fixture.order(), fixture.columns([[3], [0], [2, 1]]))

        XCTAssertTrue(fixture.undo())

        XCTAssertEqual(fixture.order(), fixture.columns([[0], [1], [2], [3]]))
        XCTAssertTrue(fixture.snapshot().hasSameLayout(as: before))
        XCTAssertEqual(fixture.column(2).displayMode, .normal)
        XCTAssertFalse(fixture.window(1).isHiddenInTabbedMode)
    }

    func testRedoPutsBackWhatUndoTookAndANewChangeClearsIt() {
        let fixture = makeFixture()
        fixture.change { fixture.moveColumn(3, to: 0) }
        let moved = fixture.order()

        XCTAssertTrue(fixture.undo())
        XCTAssertTrue(fixture.redo())
        XCTAssertEqual(fixture.order(), moved)
        XCTAssertFalse(fixture.redo())

        XCTAssertTrue(fixture.undo())
        fixture.change { fixture.stack(1, onto: 0) }
        XCTAssertFalse(fixture.redo())
    }

    func testOnlyRealChangesAreRecorded() {
        let fixture = makeFixture()
        fixture.change {}
        fixture.change {
            fixture.moveColumn(3, to: 0)
            fixture.moveColumn(0, to: 0)
            fixture.moveColumn(3, to: 3)
        }

        XCTAssertFalse(fixture.undo())
    }

    func testTheHistoryKeepsTheLastTwentyChanges() {
        let fixture = makeFixture()
        for step in 0 ..< NiriLayoutHistory.limit + 5 {
            fixture.change { fixture.column(0).width = .fixed(400 + CGFloat(step)) }
        }

        var undone = 0
        while fixture.undo() {
            undone += 1
        }

        XCTAssertEqual(undone, NiriLayoutHistory.limit)
        XCTAssertEqual(fixture.column(0).width, .fixed(404))
    }

    func testAClosedWindowIsLeftOutAndANewOneKeepsItsPlace() {
        let fixture = makeFixture(count: 3)
        fixture.change { fixture.moveColumn(2, to: 0) }
        let closing = fixture.column(1)
        closing.remove()
        let opened = WindowToken(pid: 951, windowId: 99)
        _ = fixture.engine.addWindow(token: opened, to: fixture.workspaceId, afterSelection: nil)
        let afterClosing = fixture.engine.columns(in: fixture.workspaceId)
        XCTAssertEqual(afterClosing.map { $0.windowNodes.first?.token }, [fixture.tokens[2], fixture.tokens[0], opened])

        XCTAssertTrue(fixture.undo())

        XCTAssertEqual(fixture.order(), [[fixture.tokens[0]], [opened], [fixture.tokens[2]]])
    }

    func testAChangeWithNoWindowsLeftIsSkipped() {
        let fixture = makeFixture(count: 3)
        fixture.change { fixture.moveColumn(2, to: 0) }
        fixture.change { fixture.column(1).width = .fixed(500) }
        fixture.engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId)?.remove()
        for column in fixture.engine.columns(in: fixture.workspaceId) where column.windowNodes.isEmpty {
            column.remove()
        }

        XCTAssertTrue(fixture.undo())

        XCTAssertEqual(fixture.order(), fixture.columns([[0], [2]]))
    }

    func testEachWorkspaceKeepsItsOwnHistory() {
        let engine = NiriLayoutEngine()
        let first = makeFixture(count: 2, engine: engine, displayId: 95, pid: 951)
        let second = makeFixture(count: 2, engine: engine, displayId: 96, pid: 952)
        first.change { first.moveColumn(1, to: 0) }

        XCTAssertFalse(second.undo())
        XCTAssertTrue(first.undo())
        XCTAssertEqual(first.order(), first.columns([[0], [1]]))
    }

    func testNothingIsRecordedWhileALiveDragHoldsPlaceholders() {
        let fixture = makeFixture(count: 2)
        let dropSpace = NiriContainer()
        dropSpace.isLiveDropSpace = true
        fixture.engine.root(for: fixture.workspaceId)!.insertChild(dropSpace, at: 1)

        XCTAssertNil(fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil))
    }
}
