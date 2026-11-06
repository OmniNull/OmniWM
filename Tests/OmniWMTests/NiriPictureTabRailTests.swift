// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriPictureTabRailTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let firstToken = WindowToken(pid: 91_203, windowId: 1001)
    private let secondToken = WindowToken(pid: 91_203, windowId: 1002)

    private struct RailFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let column: NiriContainer
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
    }

    private final class PictureSurface: NiriEdgePictureSurface {
        let windowId: UInt32?
        let isVisibleForCapture = true

        init(windowId: UInt32) {
            self.windowId = windowId
        }

        func update(
            geometry _: NiriEdgePictureGeometry,
            content _: NiriPictureContent,
            activate _: @escaping @MainActor () -> Void
        ) {}
        func setOrderingTarget(_: Int?) {}
        func hide() {}

        func destroy() {}
    }

    func testLiveColumnFrameSurvivesPredictionAndOtherWorkspacePasses() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let second = engine.addWindow(token: secondToken, to: workspaceId, afterSelection: first.id)
        let span = display.height * 3 / 4
        for column in engine.columns(in: workspaceId) {
            column.height = .fixed(span)
            column.cachedHeight = span
        }
        let picturedColumn = try XCTUnwrap(engine.findColumn(containing: second, in: workspaceId))
        let state = ViewportState(activeColumnIndex: 0, selectedNodeId: first.id)
        layout(engine, workspaceId: workspaceId, state: state, recordsPresentationGeometry: true)
        let expected = CGRect(x: display.minX, y: display.minY + span, width: display.width, height: span)
        XCTAssertEqual(picturedColumn.edgeHiddenFrame, expected)
        XCTAssertNotEqual(picturedColumn.renderedFrame, expected)

        let nativeState = ViewportState(activeColumnIndex: 1, selectedNodeId: second.id)
        layout(engine, workspaceId: workspaceId, state: nativeState)
        XCTAssertEqual(picturedColumn.edgeHiddenFrame, expected)
        let otherWorkspace = WorkspaceDescriptor.ID()
        let otherToken = WindowToken(pid: firstToken.pid, windowId: secondToken.windowId + 1)
        let other = engine.addWindow(token: otherToken, to: otherWorkspace, afterSelection: nil)
        layout(engine, workspaceId: otherWorkspace, state: ViewportState(selectedNodeId: other.id))
        XCTAssertEqual(picturedColumn.edgeHiddenFrame, expected)

        layout(engine, workspaceId: workspaceId, state: nativeState, recordsPresentationGeometry: true)
        XCTAssertNil(picturedColumn.edgeHiddenFrame)
    }

    func testSingleAndExcludedColumnsClearPresentationOnlyOnRealPasses() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let node = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let column = try XCTUnwrap(engine.findColumn(containing: node, in: workspaceId))
        let state = ViewportState(selectedNodeId: node.id)
        column.edgeHiddenFrame = display
        layout(engine, workspaceId: workspaceId, state: state)
        XCTAssertEqual(column.edgeHiddenFrame, display)
        layout(engine, workspaceId: workspaceId, state: state, recordsPresentationGeometry: true)
        XCTAssertNil(column.edgeHiddenFrame)

        column.edgeHiddenFrame = display
        layout(engine, workspaceId: workspaceId, state: state, excludedTokens: [firstToken])
        XCTAssertEqual(column.edgeHiddenFrame, display)
        layout(
            engine, workspaceId: workspaceId, state: state, recordsPresentationGeometry: true,
            excludedTokens: [firstToken]
        )
        XCTAssertNil(column.edgeHiddenFrame)
    }

    func testBothRailPassesUseMountedPictureAndPreserveRealTabIdentities() throws {
        let fixture = try railFixture()
        let controller = fixture.controller
        defer { controller.niriEdgePictures.reset() }
        let monitor = controller.layoutRefreshController.buildMonitorSnapshot(
            for: fixture.monitor, orientation: controller.settings.monitors.effectiveOrientation(for: fixture.monitor)
        )
        let liveFrame = display.offsetBy(dx: 0, dy: display.height / 2)
        fixture.column.edgeHiddenFrame = liveFrame
        fixture.column.renderedFrame = liveFrame.offsetBy(dx: -display.width, dy: 0)
        let active = try XCTUnwrap(fixture.engine.projectedActiveWindow(
            in: fixture.column, workspaceId: fixture.workspaceId
        ))
        let geometry = try XCTUnwrap(NiriEdgePictureGeometry(frame: liveFrame, displayFrame: display))
        let picture = NiriEdgePictures.Picture(
            workspaceId: fixture.workspaceId, monitor: monitor, geometry: geometry
        )
        controller.niriEdgePictures.pictures[active.token] = picture
        let pending = try XCTUnwrap(controller.niriLayoutHandler.desiredTabRailInfos().first)
        XCTAssertTrue(pending.visibleTileFrame.isNull)
        XCTAssertNil(pending.orderingWindowId)

        let pictureWindowId = UInt32(secondToken.windowId + 1)
        picture.surface = PictureSurface(windowId: pictureWindowId)
        let info = try XCTUnwrap(controller.niriLayoutHandler.desiredTabRailInfos().first)
        let command = try XCTUnwrap(controller.niriLayoutHandler.niriTabRailGeometryCommands(
            engine: fixture.engine, workspaceId: fixture.workspaceId, monitor: monitor
        ).first)
        for frame in [info.tileFrame, command.tileFrame] { XCTAssertEqual(frame, liveFrame) }
        for frame in [info.visibleTileFrame, command.visibleTileFrame] {
            XCTAssertEqual(frame, liveFrame.intersection(display))
        }
        XCTAssertEqual(info.orderingWindowId, Int(pictureWindowId))
        XCTAssertEqual(command.orderingWindowId, Int(pictureWindowId))
        XCTAssertEqual(info.displayFrame, display)
        XCTAssertEqual(command.displayFrame, display)
        XCTAssertEqual(info.activeWindowId, active.token.windowId)
        XCTAssertEqual(Set(info.tabs.compactMap(\.token)), [firstToken, secondToken])
        XCTAssertEqual(Set(info.tabs.compactMap(\.windowId)), [firstToken.windowId, secondToken.windowId])
    }

    func testRevealingRailKeepsPictureOrderingUntilRetirement() throws {
        let fixture = try railFixture()
        let controller = fixture.controller
        let active = try XCTUnwrap(fixture.engine.projectedActiveWindow(
            in: fixture.column, workspaceId: fixture.workspaceId
        ))
        let pictureWindowId = UInt32(secondToken.windowId + 1)
        let picture = NiriEdgePictures.Picture(
            workspaceId: fixture.workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(
                for: fixture.monitor,
                orientation: controller.settings.monitors.effectiveOrientation(for: fixture.monitor)
            ),
            geometry: try XCTUnwrap(NiriEdgePictureGeometry(frame: display, displayFrame: display))
        )
        picture.surface = PictureSurface(windowId: pictureWindowId)
        controller.niriEdgePictures.pictures[active.token] = picture
        defer { controller.niriEdgePictures.reset() }
        fixture.column.edgeHiddenFrame = nil
        fixture.column.renderedFrame = display
        picture.geometry = try XCTUnwrap(NiriEdgePictureGeometry(frame: display, displayFrame: display))
        picture.revealFrame = display
        let landing = try XCTUnwrap(controller.niriLayoutHandler.desiredTabRailInfos().first)
        XCTAssertEqual(landing.tileFrame, display)
        XCTAssertEqual(landing.orderingWindowId, Int(pictureWindowId))
        controller.niriEdgePictures.pictures.removeValue(forKey: active.token)
        let native = try XCTUnwrap(controller.niriLayoutHandler.desiredTabRailInfos().first)
        XCTAssertEqual(native.tileFrame, display)
        XCTAssertNil(native.orderingWindowId)
        XCTAssertNil(native.displayFrame)
    }

    func testPictureRailPanelClipsToItsDisplayForBothStyles() {
        let tabCount = [firstToken, secondToken].count
        for style in [TabRailStyle.compact, .appIcons] {
            let tile = CGRect(
                x: display.minX, y: display.maxY - display.height / 4,
                width: display.width, height: display.height / 2
            )
            let visibleTile = tile.intersection(display)
            let width = style.hitWidth
            let height = style.fittedHeight(tabCount: tabCount, availableHeight: visibleTile.height)
            let native = CGRect(
                x: visibleTile.minX - (width - style.reservedWidth),
                y: visibleTile.minY + (visibleTile.height - height) / 2, width: width, height: height
            )
            XCTAssertEqual(TabRailPlacement.frame(for: visibleTile, tabCount: tabCount, style: style), native)
            let clipped = TabRailPlacement.frame(
                for: visibleTile, tabCount: tabCount, style: style, displayFrame: display
            )
            XCTAssertEqual(clipped, native.intersection(display))
            XCTAssertTrue(display.contains(clipped))
        }
    }

    private func layout(
        _ engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        recordsPresentationGeometry: Bool = false,
        excludedTokens: Set<WindowToken> = []
    ) {
        var result = LayoutResult(frames: [:], hiddenHandles: [:])
        let monitor = HiddenPlacementMonitorContext(id: .init(displayId: 1), frame: display, visibleFrame: display)
        engine.calculateLayoutInto(
            result: &result, state: state, workspaceId: workspaceId,
            geometry: NiriLayoutGeometry(
                workingArea: WorkingAreaContext(workingFrame: display, viewFrame: display, scale: 1),
                gaps: LayoutGaps(horizontal: 0, vertical: 0), orientation: .vertical
            ),
            animationTime: 0, hiddenPlacementMonitor: monitor, hiddenPlacementMonitors: [monitor],
            isSettled: true, excludedTokens: excludedTokens,
            edgePictures: NiriEdgePictureState(isAvailable: true),
            recordsPresentationGeometry: recordsPresentationGeometry
        )
    }

    private func railFixture() throws -> RailFixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriPictureTabRailTests")
        let monitor = Monitor(
            id: .init(displayId: 20_012), displayId: 20_012, frame: display, visibleFrame: display,
            hasNotch: false, name: "Pictured Rail"
        )
        controller.settings.monitors.updateOrientationSettings(
            .init(monitorName: monitor.name, monitorDisplayId: monitor.displayId, orientation: .vertical), for: monitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let workspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "78", layoutType: .niri, controller: controller
        ))
        for token in [firstToken, secondToken] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let nodes = controller.workspaceManager.withEngineMutationScope {
            let first = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
            let second = engine.addWindow(token: secondToken, to: workspaceId, afterSelection: first.id)
            return (first, second)
        }
        let column = try XCTUnwrap(engine.findColumn(containing: nodes.0, in: workspaceId))
        let source = try XCTUnwrap(engine.findColumn(containing: nodes.1, in: workspaceId))
        controller.workspaceManager.withEngineMutationScope {
            engine.moveWindowToColumn(nodes.1, from: source, to: column, in: workspaceId)
            source.remove()
            column.displayMode = .tabbed
            engine.updateTabbedColumnVisibility(column: column)
        }
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        return RailFixture(
            controller: controller, engine: engine, column: column, workspaceId: workspaceId, monitor: monitor
        )
    }
}
