// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriMinimumSizeResizeTests: XCTestCase {
    func testShrinkingPastTheMinimumDoesNotBankSteps() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let engine = NiriLayoutEngine(visibleContainerCount: 3)
            engine.defaultContainerPrimarySpan = nil
            let workspaceId = WorkspaceDescriptor.ID()
            let frame = CGRect(x: 0, y: 0, width: 1200, height: 1200)
            let monitor = Monitor(
                id: Monitor.ID(displayId: 843), displayId: 843,
                frame: frame, visibleFrame: frame, hasNotch: false, name: "Minimum size resize"
            )
            engine.syncWorkspaceAssignments(
                [(workspaceId: workspaceId, monitor: monitor)], orientations: [monitor.id: orientation]
            )
            let window = engine.addWindow(
                token: WindowToken(pid: 843, windowId: 1),
                to: workspaceId,
                afterSelection: nil
            )
            _ = engine.addWindow(token: WindowToken(pid: 843, windowId: 2), to: workspaceId, afterSelection: nil)
            engine.updateWindowConstraints(
                for: window.token,
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: 500, height: 500),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: workspaceId,
                motion: .disabled
            )
            var state = ViewportState(selectedNodeId: window.id)
            let context = NiriInteractionContext(
                workspaceId: workspaceId, motion: .disabled,
                workingFrame: frame, gaps: 0, orientation: orientation
            )
            func shownSpan() -> CGFloat {
                _ = engine.calculateLayout(
                    state: state, workspaceId: workspaceId, monitorFrame: frame,
                    gaps: (0, 0), orientation: orientation
                )
                let column = try? XCTUnwrap(engine.columns(in: workspaceId).first)
                return (orientation == .horizontal ? column?.cachedWidth : column?.cachedHeight) ?? -1
            }
            _ = shownSpan()

            for _ in 0 ..< 5 {
                engine.setWindowPrimarySpan(window, change: .adjustProportion(-10), context: context, state: &state)
                _ = shownSpan()
            }
            XCTAssertEqual(shownSpan(), 500, accuracy: 0.000001)

            engine.setWindowPrimarySpan(window, change: .adjustProportion(10), context: context, state: &state)

            XCTAssertEqual(shownSpan(), 620, accuracy: 0.000001)
        }
    }
}
