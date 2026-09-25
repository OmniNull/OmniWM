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

    func testReflowLeavesHitRegionsAndMeasuredWidthUnchanged() throws {
        let workspaceId = WorkspaceDescriptor.ID()
        let windows = (1 ... 3).map { index in
            let token = WindowToken(pid: 41, windowId: index)
            let handle = WindowHandle(id: token)
            return WorkspaceBarWindowItem(
                id: token,
                handle: handle,
                windowId: index,
                appName: "App \(index)",
                bundleId: nil,
                icon: nil,
                isFocused: false,
                windowCount: 1,
                hiddenWindowCount: 0,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: token,
                        handle: handle,
                        windowId: index,
                        title: "Window \(index)",
                        isFocused: false,
                        isAppHidden: false
                    )
                ]
            )
        }
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [
                    WorkspaceBarItem(
                        id: workspaceId,
                        name: "1",
                        rawName: "1",
                        isFocused: true,
                        tiledWindows: windows,
                        floatingWindows: []
                    )
                ],
                scratchpads: []
            ),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        let interaction = WorkspaceBarIslandInteraction()
        let presentation = WorkspaceBarDragPresentation()
        let hostingView = NSHostingView(rootView: WorkspaceBarView(
            model: WorkspaceBarModel(snapshot: snapshot),
            motionPolicy: MotionPolicy(animationsEnabled: false),
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: { _ in },
            interaction: interaction,
            dragPresentation: presentation
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.frame = CGRect(x: 0, y: 0, width: 300, height: 28)
        hostingView.layoutSubtreeIfNeeded()
        let restingFrames = try relativeFrames(interaction, workspaceId: workspaceId)
        let restingWidth = hostingView.fittingSize.width
        XCTAssertEqual(restingFrames.count, 4)

        presentation.sourceTokens = [windows[0].id]
        presentation.highlights = [.workspace(workspaceId), .gap(workspaceId, beforeIcon: 1)]
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(try relativeFrames(interaction, workspaceId: workspaceId), restingFrames)
        XCTAssertEqual(hostingView.fittingSize.width, restingWidth, accuracy: 0.5)
    }

    private func relativeFrames(
        _ interaction: WorkspaceBarIslandInteraction,
        workspaceId: WorkspaceDescriptor.ID
    ) throws -> [WorkspaceBarHitTarget: CGRect] {
        let origin = try XCTUnwrap(interaction.frames[.workspace(workspaceId)]).origin
        return interaction.frames.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
    }
}
