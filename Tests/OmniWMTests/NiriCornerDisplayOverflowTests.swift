// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriCornerDisplayOverflowTests: XCTestCase {
    private let laptop = Monitor(
        id: Monitor.ID(displayId: 1), displayId: 1,
        frame: CGRect(x: 3360, y: 1890, width: 1512, height: 982),
        visibleFrame: CGRect(x: 3360, y: 1890, width: 1512, height: 949),
        hasNotch: true, name: "Laptop"
    )
    private let gap: CGFloat = 12
    private let stripFrame = CGRect(x: 3368, y: 1898, width: 1496, height: 934).insetBy(dx: -12, dy: -12)

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
    }

    func testAColumnPastAnEdgeThatOnlyMeetsAnotherDisplayAtACornerStaysShowing() throws {
        let fixture = makeFixture(
            neighbour: CGRect(x: 0, y: 0, width: 3360, height: 1890),
            naturalWindowDrag: true
        )

        let layout = layout(fixture, active: 3, offset: -331)

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[2]])
        let frame = try XCTUnwrap(layout.frames[fixture.tokens[2]])
        XCTAssertEqual(frame.maxX - laptop.frame.minX, 316, accuracy: 1)
        XCTAssertEqual(
            fixture.engine.columnSummary(
                in: fixture.workspaceId,
                state: state(fixture, active: 3, offset: -331),
                geometry: geometry
            ).viewport,
            [.before, .before, .intersecting, .intersecting]
        )
    }

    func testThePeekPastACornerEdgeStaysShowing() {
        let fixture = makeFixture(
            neighbour: CGRect(x: 0, y: 0, width: 3360, height: 1890),
            naturalWindowDrag: true
        )

        let layout = layout(fixture, active: 2, offset: -61)

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[1]])
    }

    func testAColumnPastAnEdgeSharedWithAnotherDisplayIsStillHidden() {
        let fixture = makeFixture(
            neighbour: CGRect(x: 0, y: 1500, width: 3360, height: 1890),
            naturalWindowDrag: true
        )

        let layout = layout(fixture, active: 3, offset: -331)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[2]], .left)
    }

    func testWithoutNaturalWindowDragACornerDisplayStillHidesTheColumn() {
        let fixture = makeFixture(
            neighbour: CGRect(x: 0, y: 0, width: 3360, height: 1890),
            naturalWindowDrag: false
        )

        let layout = layout(fixture, active: 3, offset: -331)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[2]], .left)
    }

    private var geometry: NiriSizingGeometry {
        NiriSizingGeometry(workingFrame: stripFrame, gaps: gap, orientation: .horizontal)
    }

    private func state(_ fixture: Fixture, active: Int, offset: CGFloat) -> ViewportState {
        var state = ViewportState(activeColumnIndex: active)
        state.selectedNodeId = fixture.engine.findNode(for: fixture.tokens[active], in: fixture.workspaceId)?.id
        state.jumpOffset(to: offset)
        return state
    }

    private func layout(_ fixture: Fixture, active: Int, offset: CGFloat) -> LayoutResult {
        fixture.engine.calculateCombinedLayoutWithVisibility(
            in: fixture.workspaceId,
            monitor: laptop,
            gaps: LayoutGaps(horizontal: gap, vertical: gap),
            state: state(fixture, active: active, offset: offset),
            workingArea: WorkingAreaContext(workingFrame: stripFrame, viewFrame: laptop.frame, scale: 2),
            isSettled: true
        )
    }

    private func makeFixture(neighbour: CGRect, naturalWindowDrag: Bool) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(
            centerFocusedColumn: .onOverflow,
            naturalWindowDrag: .init(enabled: naturalWindowDrag)
        )
        let other = Monitor(
            id: Monitor.ID(displayId: 2), displayId: 2, frame: neighbour, visibleFrame: neighbour,
            hasNotch: false, name: "Neighbour"
        )
        let workspaceId = WorkspaceDescriptor.ID()
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: laptop), (workspaceId: WorkspaceDescriptor.ID(), monitor: other)],
            orientations: [laptop.id: .horizontal, other.id: .horizontal]
        )
        let tokens = (0 ..< 4).map { WindowToken(pid: 952, windowId: $0 + 1) }
        var previous: NiriWindow?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), [1176, 1176, 1398, 1176] as [CGFloat]) {
            column.width = .fixed(width)
            column.cachedWidth = 0
        }
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens)
    }
}
