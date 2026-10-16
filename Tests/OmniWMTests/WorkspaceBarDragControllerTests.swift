// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarDragControllerTests: XCTestCase {
    private let source = WorkspaceDescriptor.ID()
    private let destination = WorkspaceDescriptor.ID()
    private let token = WindowToken(pid: 40, windowId: 1)

    private func makeController(commits: @escaping (WorkspaceBarDropAction) -> Bool) -> WorkspaceBarDragController {
        let controller = WorkspaceBarDragController()
        let geometry = WorkspaceBarDropGeometry(workspaces: [
            .init(
                id: source,
                name: "1",
                layout: .niri,
                hitFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                icons: [],
                columnCount: 1
            ),
            .init(
                id: destination,
                name: "2",
                layout: .niri,
                hitFrame: CGRect(x: 200, y: 0, width: 100, height: 24),
                icons: [],
                columnCount: 0
            )
        ])
        controller.geometryProvider = { geometry }
        controller.commit = { action, _ in commits(action) }
        return controller
    }

    private var dragSource: WorkspaceBarDragSource {
        WorkspaceBarDragSource(tokens: [token], workspaceId: source, isFloating: false)
    }

    func testDropOnAnotherWorkspaceCommitsAndKeepsPresentationUntilTheBarsUpdate() {
        var committed: [WorkspaceBarDropAction] = []
        let controller = makeController { committed.append($0)
            return true
        }

        controller.begin(source: dragSource, icon: nil, at: CGPoint(x: 50, y: 10))
        XCTAssertEqual(controller.presentation.sourceTokens, [token])
        controller.update(at: CGPoint(x: 250, y: 10))
        XCTAssertEqual(controller.presentation.highlights, [.workspace(destination)])
        XCTAssertTrue(controller.end(at: CGPoint(x: 250, y: 10)))

        XCTAssertEqual(committed, [.moveToWorkspace(destination)])
        XCTAssertFalse(controller.isDragging)
        XCTAssertEqual(controller.presentation.sourceTokens, [token])
        controller.barsDidUpdate()
        XCTAssertTrue(controller.presentation.sourceTokens.isEmpty)
        XCTAssertTrue(controller.presentation.highlights.isEmpty)
    }

    func testDropOutsideTheBarsCancelsWithoutCommitting() {
        var committed: [WorkspaceBarDropAction] = []
        let controller = makeController { committed.append($0)
            return true
        }

        controller.begin(source: dragSource, icon: nil, at: CGPoint(x: 50, y: 10))
        XCTAssertFalse(controller.end(at: CGPoint(x: 150, y: 400)))

        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(controller.presentation.sourceTokens.isEmpty)
    }

    func testFailedCommitClearsThePresentationImmediately() {
        let controller = makeController { _ in false }

        controller.begin(source: dragSource, icon: nil, at: CGPoint(x: 50, y: 10))
        XCTAssertFalse(controller.end(at: CGPoint(x: 250, y: 10)))

        XCTAssertTrue(controller.presentation.sourceTokens.isEmpty)
        XCTAssertTrue(controller.presentation.highlights.isEmpty)
    }

    func testBarUpdateThatInvalidatesTheSourceCancelsTheDrag() {
        var committed: [WorkspaceBarDropAction] = []
        let controller = makeController { committed.append($0)
            return true
        }
        var sourceIsValid = true
        controller.sourceIsValid = { _ in sourceIsValid }

        controller.begin(source: dragSource, icon: nil, at: CGPoint(x: 50, y: 10))
        controller.barsDidUpdate()
        XCTAssertTrue(controller.isDragging)
        sourceIsValid = false
        controller.barsDidUpdate()

        XCTAssertFalse(controller.isDragging)
        XCTAssertFalse(controller.end(at: CGPoint(x: 250, y: 10)))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(controller.presentation.sourceTokens.isEmpty)
    }

    func testWorkspacesDragGapsKeepDropTargetsAndWidth() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let windows = (1 ... 3).map { index in
            ShellBarItem(
                id: "ow_\(index)", bundle: "com.apple.finder", name: "Finder", focused: false, count: 1, hidden: 0,
                windows: [ShellBarWindow(id: "ow_\(index)", title: "W", focused: false, hidden: false)]
            )
        }
        var bar = ShellBarData()
        bar.workspaces = [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: windows)]
        func layout() throws -> (size: CGSize, targets: [String: CGRect]) {
            widget.render(bar)
            let frames = widget.surface.targetFrames()
            let origin = try XCTUnwrap(frames.first { widget.text.string($0.target) == "workspace 1" }).frame.origin
            return (widget.surface.size, Dictionary(uniqueKeysWithValues: frames.map {
                (widget.text.string($0.target), $0.frame.offsetBy(dx: -origin.x, dy: -origin.y))
            }))
        }

        let resting = try layout()
        XCTAssertEqual(Set(resting.targets.keys), ["workspace 1", "window ow_1", "window ow_2", "window ow_3"])
        bar.drag = ShellBarDrag(
            sources: ["ow_1"],
            workspaces: ["1"],
            gaps: [ShellBarDrag.Gap(workspace: "1", before: 2)]
        )
        let dragging = try layout()
        XCTAssertEqual(dragging.targets, resting.targets)
        XCTAssertEqual(dragging.size.width, resting.size.width, accuracy: 0.5)
    }
}
