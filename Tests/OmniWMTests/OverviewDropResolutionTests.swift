// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewDropResolutionTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()
    private let sourceWorkspaceId = WorkspaceDescriptor.ID()
    private let handle = WindowHandle(id: WindowToken(pid: 492_100, windowId: 71))
    private let monitor = Monitor(
        id: .init(displayId: 92_100), displayId: 92_100,
        frame: CGRect(x: -1600, y: -300, width: 1600, height: 1000),
        visibleFrame: CGRect(x: -1580, y: -280, width: 1560, height: 960),
        hasNotch: false, name: "Portrait ASUS"
    )

    func testFloatingPlacementUsesDesktopProjectionAtEveryZoomAndStackOffset() throws {
        for scale: CGFloat in [0.5, 1, 1.5] {
            var layout = makeLayout(scale: scale)
            layout.scrollOffset = -45
            let section = try XCTUnwrap(layout.workspaceSections.first)
            let size = CGSize(width: 500, height: 320)
            let desktopCenter = CGPoint(x: 870, y: 510)
            let point = CGPoint(
                x: section.visibleFrame.minX + desktopCenter.x * section.contentScale,
                y: section.visibleFrame.minY + desktopCenter.y * section.contentScale - layout.scrollOffset
            )
            let result = layout.resolveDrop(
                at: point, draggedHandle: handle, sourceWorkspaceId: sourceWorkspaceId,
                floatingSize: size, monitor: monitor
            )
            guard case let .floatingPlacement(destination, frame, preview) = result.target else {
                return XCTFail("Expected floating placement at scale \(scale)")
            }
            XCTAssertEqual(destination, .workspace(workspaceId))
            XCTAssertEqual(frame.minX, -980, accuracy: 0.000000001)
            XCTAssertEqual(frame.minY, 50, accuracy: 0.000000001)
            XCTAssertEqual(frame.size, size)
            XCTAssertEqual(preview.width, size.width * section.contentScale)
            XCTAssertEqual(preview.midX, point.x)
            XCTAssertEqual(preview.midY, point.y + layout.scrollOffset)
            XCTAssertEqual(result.label, "Place floating window")
        }
    }

    func testFloatingDropIgnoresTiledInsertionAndStripPanning() throws {
        var layout = makeLayout()
        var sections = layout.workspaceSections
        let frame = sections[0].visibleFrame
        var window = makeWindow(frame: frame)
        window.isTiled = true
        sections[0].windows = [window]
        layout.replaceWorkspaceSections(sections)
        layout.niriColumnDropZonesByWorkspace[workspaceId] = [
            OverviewColumnDropZone(workspaceId: workspaceId, insertIndex: 0, frame: frame)
        ]
        layout.niriColumnsByWorkspace[workspaceId] = [
            OverviewNiriColumn(workspaceId: workspaceId, columnIndex: 0, frame: frame, windowHandles: [handle])
        ]
        let point = frame.center
        let before = layout.resolveDrop(
            at: point, draggedHandle: handle, sourceWorkspaceId: workspaceId,
            floatingSize: CGSize(width: 400, height: 300), monitor: monitor
        )
        layout.panStrip(workspaceId, by: 75)
        XCTAssertEqual(layout.resolveDrop(
            at: point, draggedHandle: handle, sourceWorkspaceId: workspaceId,
            floatingSize: CGSize(width: 400, height: 300), monitor: monitor
        ), before)
        guard case .floatingPlacement = before.target else { return XCTFail("Floating drop became insertion") }
    }

    func testOversizedFloatingWindowPreservesSizeAndClipsOnlyPreview() throws {
        let layout = makeLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let size = CGSize(width: 2000, height: 1400)
        let result = layout.resolveDrop(
            at: section.visibleFrame.center, draggedHandle: handle, sourceWorkspaceId: sourceWorkspaceId,
            floatingSize: size, monitor: monitor
        )
        guard case let .floatingPlacement(_, frame, preview) = result.target else {
            return XCTFail("Expected floating placement")
        }
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.origin, monitor.visibleFrame.origin)
        XCTAssertTrue(section.visibleFrame.contains(preview))
    }

    func testNewWorkspaceFloatingDropUsesItsDesktopProjection() throws {
        var layout = makeLayout()
        let target = try XCTUnwrap(layout.newWorkspaceTarget)
        layout.scrollOffset = target.frame.midY - 300
        let result = layout.resolveDrop(
            at: CGPoint(x: target.frame.midX, y: 300), draggedHandle: handle,
            sourceWorkspaceId: sourceWorkspaceId, floatingSize: CGSize(width: 500, height: 300), monitor: monitor
        )
        guard case let .floatingPlacement(destination, frame, _) = result.target else {
            return XCTFail("Expected creation and floating placement")
        }
        XCTAssertEqual(destination, .newWorkspace(monitor.id))
        XCTAssertEqual(frame.center, monitor.frame.center)
        XCTAssertEqual(result.label, "Create workspace on Portrait ASUS")
    }

    func testInvalidAreasAndNoOpMoveHaveExplicitFeedback() throws {
        let layout = makeLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let points = [CGPoint(x: 2, y: 999), CGPoint(x: -10, y: 200), section.labelFrame.center]
        for point in points {
            XCTAssertEqual(layout.resolveDrop(
                at: point, draggedHandle: handle, sourceWorkspaceId: sourceWorkspaceId,
                floatingSize: CGSize(width: 500, height: 300), monitor: monitor
            ), .invalid)
        }
        XCTAssertEqual(layout.resolveDrop(
            at: section.visibleFrame.center, draggedHandle: handle, sourceWorkspaceId: workspaceId,
            floatingSize: nil, monitor: monitor
        ), .invalid)
    }

    func testTiledDropLabelsMatchInsertionAxisAndWorkspaceDestination() throws {
        var layout = makeLayout()
        var sections = layout.workspaceSections
        let frame = sections[0].visibleFrame
        sections[0].windows = [makeWindow(frame: frame)]
        layout.replaceWorkspaceSections(sections)
        layout.niriColumnsByWorkspace[workspaceId] = [
            OverviewNiriColumn(workspaceId: workspaceId, columnIndex: 0, frame: frame, windowHandles: [handle])
        ]
        let source = WindowHandle(id: WindowToken(pid: 492_101, windowId: 72))
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            sections[0].orientation = orientation
            layout.replaceWorkspaceSections(sections)
            let point = CGPoint(x: frame.maxX - 3, y: frame.maxY - 3)
            XCTAssertEqual(layout.resolveDrop(
                at: point, draggedHandle: source, sourceWorkspaceId: sourceWorkspaceId,
                floatingSize: nil, monitor: monitor
            ).label, orientation == .horizontal ? "Stack above" : "Stack right")
        }
        layout.niriColumnDropZonesByWorkspace[workspaceId] = [
            OverviewColumnDropZone(workspaceId: workspaceId, insertIndex: 0, frame: frame)
        ]
        XCTAssertEqual(layout.resolveDrop(
            at: frame.center, draggedHandle: source, sourceWorkspaceId: sourceWorkspaceId,
            floatingSize: nil, monitor: monitor
        ).label, "New column")
        layout.niriColumnDropZonesByWorkspace = [:]
        layout.niriColumnsByWorkspace = [:]
        XCTAssertEqual(layout.resolveDrop(
            at: frame.center, draggedHandle: source, sourceWorkspaceId: sourceWorkspaceId,
            floatingSize: nil, monitor: monitor
        ).label, "Move to workspace Design")
    }

    private func makeLayout(scale: CGFloat = 1) -> OverviewLayout {
        OverviewLayoutCalculator(screenFrame: CGRect(origin: .zero, size: monitor.frame.size), scale: scale)
            .calculateLayout(
                workspaces: [.init(id: workspaceId, name: "Design", isActive: true)],
                windows: [:], searchQuery: "", monitorId: monitor.id
            )
    }

    private func makeWindow(frame: CGRect) -> OverviewWindowItem {
        OverviewWindowItem(
            handle: handle, windowId: handle.id.windowId, workspaceId: workspaceId,
            title: "Window", appName: "App", appIcon: nil, originalFrame: frame,
            overviewFrame: frame, matchesSearch: true
        )
    }
}
