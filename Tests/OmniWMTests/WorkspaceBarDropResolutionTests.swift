// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarDropResolutionTests: XCTestCase {
    private let ws1 = WorkspaceDescriptor.ID()
    private let ws2 = WorkspaceDescriptor.ID()
    private let dwindleWorkspace = WorkspaceDescriptor.ID()
    private let a = WindowToken(pid: 1, windowId: 1)
    private let b = WindowToken(pid: 1, windowId: 2)
    private let c = WindowToken(pid: 1, windowId: 3)
    private let d = WindowToken(pid: 1, windowId: 4)
    private let e = WindowToken(pid: 1, windowId: 5)
    private let x = WindowToken(pid: 2, windowId: 1)
    private let y = WindowToken(pid: 2, windowId: 2)

    private func icon(
        _ token: WindowToken,
        minX: CGFloat,
        name: String,
        placement: WorkspaceBarDropGeometry.Placement?
    ) -> WorkspaceBarDropGeometry.Icon {
        .init(tokens: [token], frame: CGRect(x: minX, y: 2, width: 20, height: 20), appName: name, placement: placement)
    }

    private var geometry: WorkspaceBarDropGeometry {
        WorkspaceBarDropGeometry(workspaces: [
            .init(
                id: ws1,
                name: "1",
                layout: .niri,
                hitFrame: CGRect(x: 0, y: 0, width: 110, height: 24),
                icons: [
                    icon(a, minX: 10, name: "A", placement: .init(column: 0, row: 0, columnTileCount: 1)),
                    icon(b, minX: 34, name: "B", placement: .init(column: 1, row: 0, columnTileCount: 2)),
                    icon(c, minX: 58, name: "C", placement: .init(column: 1, row: 1, columnTileCount: 2)),
                    icon(d, minX: 82, name: "D", placement: .init(column: 2, row: 0, columnTileCount: 1))
                ],
                columnCount: 3
            ),
            .init(
                id: ws2,
                name: "2",
                layout: .niri,
                hitFrame: CGRect(x: 2000, y: 0, width: 60, height: 24),
                icons: [icon(e, minX: 2020, name: "E", placement: .init(column: 0, row: 0, columnTileCount: 1))],
                columnCount: 1
            ),
            .init(
                id: dwindleWorkspace,
                name: "3",
                layout: .dwindle,
                hitFrame: CGRect(x: 120, y: 0, width: 80, height: 24),
                icons: [
                    icon(x, minX: 130, name: "X", placement: nil),
                    icon(y, minX: 160, name: "Y", placement: nil)
                ],
                columnCount: 0
            )
        ])
    }

    private func resolve(
        _ tokens: [WindowToken],
        from workspaceId: WorkspaceDescriptor.ID? = nil,
        floating: Bool = false,
        atX pointX: CGFloat
    ) -> WorkspaceBarDropResolution {
        WorkspaceBarDropResolver.resolve(
            source: .init(tokens: tokens, workspaceId: workspaceId ?? ws1, isFloating: floating),
            at: CGPoint(x: pointX, y: 12),
            in: geometry
        )
    }

    func testDroppingASingleColumnInAGapMovesTheWholeColumn() {
        let result = resolve([a], atX: 83)

        XCTAssertEqual(result.action, .niriMoveColumn(ws1, oneBasedIndex: 2))
        XCTAssertEqual(result.highlights, [.workspace(ws1), .gap(ws1, beforeIcon: 3)])
        XCTAssertEqual(result.label, "New column")
        XCTAssertEqual(resolve([d], atX: 5).action, .niriMoveColumn(ws1, oneBasedIndex: 1))
    }

    func testGapsBesideTheSourceColumnAreNoOps() {
        XCTAssertEqual(resolve([a], atX: 5).action, .noOp)
        XCTAssertEqual(resolve([a], atX: 33).action, .noOp)
        XCTAssertEqual(resolve([d], atX: 106).action, .noOp)
    }

    func testDroppingAStackedTileInAGapCreatesANewColumn() {
        XCTAssertEqual(resolve([b], atX: 106).action, .niriNewColumn(ws1, gap: 3))
        XCTAssertEqual(resolve([c], atX: 5).action, .niriNewColumn(ws1, gap: 0))
        XCTAssertEqual(resolve([b], atX: 33).action, .niriNewColumn(ws1, gap: 1))
    }

    func testDroppingOntoAnIconStacksBeforeOrAfterByHalf() {
        let before = resolve([a], atX: 40)
        XCTAssertEqual(before.action, .niriStack(ws1, target: b, position: .before))
        XCTAssertEqual(before.highlights, [.workspace(ws1), .icon(ws1, b)])
        XCTAssertEqual(before.label, "Stack with B")
        XCTAssertEqual(resolve([a], atX: 49).action, .niriStack(ws1, target: b, position: .after))
    }

    func testBoundaryInsideOneColumnStacksBetweenItsTiles() {
        XCTAssertEqual(resolve([a], atX: 56).action, .niriStack(ws1, target: c, position: .before))
        XCTAssertEqual(resolve([d], atX: 60).action, .niriStack(ws1, target: c, position: .before))
    }

    func testStackingThatLeavesTheTileInPlaceIsANoOp() {
        XCTAssertEqual(resolve([b], atX: 64).action, .noOp)
        XCTAssertEqual(resolve([c], atX: 49).action, .noOp)
        XCTAssertEqual(resolve([b], atX: 72).action, .niriStack(ws1, target: c, position: .after))
        XCTAssertEqual(resolve([a], atX: 20).action, .noOp)
    }

    func testDwindleDropsSwapWithTheIconUnderThePointer() {
        let swap = resolve([x], from: dwindleWorkspace, atX: 170)
        XCTAssertEqual(swap.action, .dwindleSwap(dwindleWorkspace, target: y))
        XCTAssertEqual(swap.label, "Swap with Y")
        XCTAssertEqual(resolve([x], from: dwindleWorkspace, atX: 140).action, .noOp)
        XCTAssertEqual(resolve([x], from: dwindleWorkspace, atX: 155).action, .noOp)
    }

    func testDroppingOnAnotherWorkspaceMovesThere() {
        let other = resolve([a], atX: 2050)
        XCTAssertEqual(other.action, .moveToWorkspace(ws2))
        XCTAssertEqual(other.label, "Move to 2")
        XCTAssertEqual(other.highlights, [.workspace(ws2)])
        XCTAssertEqual(resolve([x, y], from: dwindleWorkspace, atX: 40).action, .moveToWorkspace(ws1))
        XCTAssertEqual(resolve([a], floating: true, atX: 150).action, .moveToWorkspace(dwindleWorkspace))
    }

    func testFloatingAndGroupedSourcesCannotBeReorderedInPlace() {
        XCTAssertEqual(resolve([a], floating: true, atX: 83).action, .noOp)
        XCTAssertEqual(resolve([b, c], atX: 83).action, .noOp)
    }

    func testTrailingGapTargetsTheEndOfTheWorkspaceAfterUnpositionedColumns() {
        let hidden = WindowToken(pid: 3, windowId: 1)
        var workspaces = geometry.workspaces
        let base = workspaces[0]
        workspaces[0] = .init(
            id: base.id,
            name: base.name,
            layout: base.layout,
            hitFrame: CGRect(x: 0, y: 0, width: 140, height: 24),
            icons: base.icons + [icon(hidden, minX: 110, name: "Hidden", placement: nil)],
            columnCount: 4
        )
        let result = WorkspaceBarDropResolver.resolve(
            source: .init(tokens: [a], workspaceId: ws1, isFloating: false),
            at: CGPoint(x: 106, y: 12),
            in: WorkspaceBarDropGeometry(workspaces: workspaces)
        )

        XCTAssertEqual(result.action, .niriMoveColumn(ws1, oneBasedIndex: 4))
    }

    func testDropsOutsideEveryWorkspaceCancel() {
        let result = resolve([a], atX: 500)
        XCTAssertEqual(result.action, .cancel)
        XCTAssertEqual(result.label, "Can’t drop here")
        XCTAssertTrue(result.highlights.isEmpty)
    }
}
