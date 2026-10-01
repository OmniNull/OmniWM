// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriTabbedHitTestTests: XCTestCase {
    func testMoveTargetPrefersActiveWindowOfTabbedColumn() throws {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        _ = engine.addWindow(token: WindowToken(pid: 1, windowId: 1), to: workspace, afterSelection: nil)
        let column = try XCTUnwrap(engine.columns(in: workspace).first)
        for id in 2 ... 3 {
            let node = engine.addWindow(
                token: WindowToken(pid: pid_t(id), windowId: id),
                to: workspace,
                afterSelection: nil
            )
            var state = ViewportState()
            XCTAssertTrue(engine.consumeWindow(
                node,
                into: column,
                enteringFrom: .right,
                context: .init(
                    workspaceId: workspace,
                    motion: .disabled,
                    workingFrame: screen,
                    gaps: 0,
                    orientation: .horizontal
                ),
                state: &state
            ))
        }
        column.isFullWidth = true
        engine.setColumnDisplay(.tabbed, for: column, in: workspace, motion: .disabled, orientation: .horizontal)
        column.setActiveTileIdx(2)
        let active = column.windowNodes[2]
        var state = ViewportState()
        state.selectedNodeId = active.id
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspace,
            monitorFrame: screen,
            screenFrame: screen,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )

        let target = engine.hitTestMoveTarget(
            point: CGPoint(x: 300, y: 400),
            excludingWindowId: NodeId(),
            orientation: .horizontal,
            in: workspace
        )

        guard case let .window(nodeId, _, _)? = target else {
            return XCTFail("expected a window target")
        }
        XCTAssertEqual(nodeId, active.id)
    }
}
