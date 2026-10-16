// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class TabRailStyleLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private struct NiriFixture {
        let engine: NiriLayoutEngine
        let workspace: WorkspaceDescriptor.ID
        let column: NiriContainer
    }

    func testNiriStyleChangeClampsBoundsWithoutChangingSizePreference() throws {
        let fixture = makeNiriGroup()
        let engine = fixture.engine
        let workspace = fixture.workspace
        let column = fixture.column
        let window = try XCTUnwrap(column.windowNodes.first)
        window.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 1),
            maxSize: CGSize(width: 600, height: 0),
            isFixed: false
        )
        column.width = .fixed(410)
        column.cachedWidth = 410
        column.hasManualSingleWindowWidthOverride = true
        let selectedIndex = column.activeTileIdx

        engine.updateTabIndicatorWidth(28, motion: .disabled)

        XCTAssertEqual(column.cachedWidth, 428)
        XCTAssertEqual(column.width, .fixed(410))
        XCTAssertTrue(column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(column.activeTileIdx, selectedIndex)
        XCTAssertEqual(engine.columns(in: workspace).count, 1)

        column.width = .fixed(628)
        column.cachedWidth = 628
        engine.updateTabIndicatorWidth(10, motion: .disabled)

        XCTAssertEqual(column.cachedWidth, 610)
        XCTAssertEqual(column.width, .fixed(628))
    }

    func testNiriStyleChangeRetargetsWidthAnimationWithinNewBounds() throws {
        let fixture = makeNiriGroup()
        let engine = fixture.engine
        let column = fixture.column
        let window = try XCTUnwrap(column.windowNodes.first)
        window.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 1),
            maxSize: CGSize(width: 600, height: 0),
            isFixed: false
        )
        column.cachedWidth = 410
        column.animateWidthTo(newWidth: 410, clock: nil, config: .niriWindowMovement, animated: true)

        engine.updateTabIndicatorWidth(28, motion: .enabled)

        XCTAssertEqual(column.cachedWidth, 428)
        XCTAssertEqual(column.targetWidth, 428)
        XCTAssertEqual(column.widthAnimation?.from, 428)
        XCTAssertEqual(column.widthAnimation?.target, 428)

        engine.updateTabIndicatorWidth(10, motion: .disabled)
        column.cachedWidth = 410
        column.animateWidthTo(newWidth: 500, clock: nil, config: .niriWindowMovement, animated: true)
        engine.updateTabIndicatorWidth(28, motion: .enabled)
        XCTAssertEqual(column.cachedWidth, 428)
        XCTAssertEqual(column.targetWidth, 500)
        XCTAssertEqual(column.widthAnimation?.from, 428)
        XCTAssertEqual(column.widthAnimation?.target, 500)

        column.cachedWidth = 628
        column.animateWidthTo(newWidth: 628, clock: nil, config: .niriWindowMovement, animated: true)
        engine.updateTabIndicatorWidth(10, motion: .disabled)

        XCTAssertEqual(column.cachedWidth, 610)
        XCTAssertNil(column.targetWidth)
        XCTAssertNil(column.widthAnimation)
    }

    func testNiriStyleChangeCancelsOnlyAffectedResize() throws {
        let fixture = makeNiriGroup()
        let engine = fixture.engine
        let workspace = fixture.workspace
        let column = fixture.column
        let activeWindow = try XCTUnwrap(engine.projectedActiveWindow(in: column, workspaceId: workspace))
        XCTAssertTrue(engine.interactiveResizeBegin(
            windowId: activeWindow.id,
            edges: .right,
            startLocation: .zero,
            in: workspace,
            orientation: .horizontal
        ))

        engine.updateTabIndicatorWidth(28, motion: .disabled)

        XCTAssertNil(engine.interactiveResize)
        column.displayMode = .normal
        XCTAssertTrue(engine.interactiveResizeBegin(
            windowId: activeWindow.id,
            edges: .right,
            startLocation: .zero,
            in: workspace,
            orientation: .horizontal
        ))
        engine.updateTabIndicatorWidth(10, motion: .disabled)
        XCTAssertNotNil(engine.interactiveResize)
    }

    func testNiriBothOrientationsReserveIconWidthAndKeepSingletonProjectionFullWidth() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = makeNiriGroup()
            let engine = fixture.engine
            let workspace = fixture.workspace
            let column = fixture.column
            let activeWindow = try XCTUnwrap(engine.projectedActiveWindow(in: column, workspaceId: workspace))
            let otherWindow = try XCTUnwrap(column.windowNodes.first { $0 !== activeWindow })
            let compactFrame =
                try XCTUnwrap(layout(engine, workspace: workspace, orientation: orientation)[activeWindow.token])
            let compactColumnFrame = try XCTUnwrap(column.frame)

            engine.updateTabIndicatorWidth(28, motion: .disabled)
            let iconFrame =
                try XCTUnwrap(layout(engine, workspace: workspace, orientation: orientation)[activeWindow.token])
            let iconColumnFrame = try XCTUnwrap(column.frame)

            XCTAssertEqual(iconColumnFrame, compactColumnFrame)
            XCTAssertEqual(iconFrame.minX - compactFrame.minX, 18, accuracy: 0.001)
            XCTAssertEqual(compactFrame.width - iconFrame.width, 18, accuracy: 0.001)
            XCTAssertEqual(iconFrame.height, compactFrame.height, accuracy: 0.001)

            engine.setProjectionExclusions([otherWindow.token], in: workspace)
            let singletonFrame =
                try XCTUnwrap(layout(engine, workspace: workspace, orientation: orientation)[activeWindow.token])
            XCTAssertEqual(singletonFrame, column.frame)
            XCTAssertEqual(column.windowNodes.count, 2)
        }
    }

    func testDwindleIconWidthAppliesToContentAndMinimumOnce() throws {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        let tile = try XCTUnwrap(engine.root(for: workspace)?.tile)
        engine.updateWindowConstraints(
            for: first,
            constraints: WindowSizeConstraints(minSize: CGSize(width: 400, height: 300), maxSize: .zero, isFixed: false)
        )

        for width: CGFloat in [10, 28, 10] {
            engine.tabRailWidth = width
            let frame = try XCTUnwrap(engine.calculateLayout(for: workspace, screen: screen)[second])
            XCTAssertEqual(frame.minX, width)
            XCTAssertEqual(frame.width, screen.width - width)
            XCTAssertEqual(engine.minimumSize(for: tile, excluding: []), CGSize(width: 400 + width, height: 300))
            XCTAssertEqual(engine.minimumSize(for: tile, excluding: [second]), CGSize(width: 400, height: 300))
            XCTAssertEqual(
                engine.contentFrame(for: tile, member: tile.members[0], tileFrame: screen, excludedTokens: [second]),
                screen
            )
        }
    }

    @MainActor
    func testControllerToggleAndReloadUpdateBothEngines() throws {
        let settings = makeSettings()
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        let controller = WMController(settings: settings)
        defer { controller.layoutRefreshController.resetState() }
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niri = try XCTUnwrap(controller.niriEngine)
        let dwindle = try XCTUnwrap(controller.dwindleEngine)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: screen,
            visibleFrame: screen,
            hasNotch: false,
            name: "Display"
        )
        XCTAssertEqual(niri.renderStyle.tabIndicatorWidth, 10)
        XCTAssertEqual(dwindle.tabRailWidth, 10)

        for enabled in [true, false] {
            controller.layoutRefreshController.resetState()
            controller.setTabRailAppIcons(enabled)
            let expectedWidth: CGFloat = enabled ? 28 : 10
            XCTAssertEqual(settings.tabRailAppIcons, enabled)
            XCTAssertEqual(controller.tabRailStyle.reservedWidth, expectedWidth)
            XCTAssertEqual(niri.renderStyle.tabIndicatorWidth, expectedWidth)
            XCTAssertEqual(dwindle.tabRailWidth, expectedWidth)
            XCTAssertEqual(
                controller.dwindleLayoutHandler.geometryContext(
                    monitor: monitor,
                    settings: controller.resolvedDwindleSettings(for: monitor)
                )?.tabRailWidth,
                expectedWidth
            )
            XCTAssertEqual(controller.layoutRefreshController.layoutState.activeRefresh?.kind, .relayout)
            XCTAssertEqual(controller.layoutRefreshController.layoutState.activeRefresh?.reason, .layoutConfigChanged)
        }

        settings.quakeTerminal.enabled = false
        for enabled in [true, false] {
            var exported = settings.toExport()
            exported.tabRailAppIcons = enabled
            settings.applyExport(exported)
            controller.layoutRefreshController.resetState()
            controller.applyPersistedSettings(settings, startServices: false)
            XCTAssertEqual(niri.renderStyle.tabIndicatorWidth, enabled ? 28 : 10)
            XCTAssertEqual(dwindle.tabRailWidth, enabled ? 28 : 10)
            XCTAssertNotNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        }
    }

    private func makeNiriGroup() -> NiriFixture {
        let engine = NiriLayoutEngine()
        engine.renderStyle.tabIndicatorWidth = 10
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspace = WorkspaceDescriptor.ID()
        _ = engine.addWindow(token: WindowToken(pid: 1, windowId: 1), to: workspace, afterSelection: nil)
        let column = engine.columns(in: workspace)[0]
        let second = engine.addWindow(token: WindowToken(pid: 2, windowId: 2), to: workspace, afterSelection: nil)
        var state = ViewportState()
        XCTAssertTrue(engine.consumeWindow(
            second,
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
        column.displayMode = .tabbed
        column.width = .fixed(500)
        column.cachedWidth = 500
        column.height = .fixed(400)
        column.cachedHeight = 400
        return NiriFixture(engine: engine, workspace: workspace, column: column)
    }

    private func layout(
        _ engine: NiriLayoutEngine,
        workspace: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: ViewportState(),
            workspaceId: workspace,
            monitorFrame: screen,
            gaps: (horizontal: 0, vertical: 0),
            orientation: orientation
        )
    }

    @MainActor
    private func makeSettings() -> SettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTabRailStyleTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
    }
}
