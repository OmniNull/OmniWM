// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowTabRailPresentationTests: XCTestCase {
    func testBothLayoutRailsCarryDeclaredPresentationAndRetainIconRows() throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedPresentationFixture(layout: layout)
            defer { fixture.close() }
            let entries = try [fixture.add(fixture.notes), fixture.add(fixture.timer)]
            let info = try groupedRail(entries, fixture: fixture)
            let view = TabRailView(
                frame: fixture.management.sourceMonitor.visibleFrame,
                motionPolicy: fixture.controller.motionPolicy, appInfoCache: fixture.controller.appInfoCache
            )
            view.update(tabs: info.tabs, activeVisualIndex: info.activeVisualIndex, style: .appIcons)
            let icons = try XCTUnwrap(presentationSubviews(TabRailIconView.self, in: view).first)
            XCTAssertEqual(info.tabs.count, entries.count)
            XCTAssertEqual(icons.rows.count, entries.count)
            for (tab, row) in zip(info.tabs, icons.rows) {
                let metadata = try XCTUnwrap(entries.first { $0.token == tab.token }?.target.hostedMetadata)
                XCTAssertEqual(tab.appName, metadata.title)
                XCTAssertEqual(tab.title, metadata.title)
                try assertHostedSymbol(tab.icon, named: metadata.icon)
                try assertHostedSymbol(row.imageView.image, named: metadata.icon)
            }
            let rows = icons.rows
            view.update(tabs: info.tabs, activeVisualIndex: info.activeVisualIndex, style: .appIcons)
            XCTAssertEqual(icons.rows.map(ObjectIdentifier.init), rows.map(ObjectIdentifier.init))
        }
    }

    func testExternalRailRetainsProcessNameIconAndReplacementTitle() throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedPresentationFixture(layout: layout)
            defer { fixture.close() }
            let hosted = try fixture.add(fixture.notes)
            let external = try fixture.addExternal()
            _ = fixture.controller.appInfoCache.info(for: external.pid)
            let info = try groupedRail([hosted, external], fixture: fixture)
            let tab = try XCTUnwrap(info.tabs.first { $0.token == external.token })
            XCTAssertEqual(tab.appName, NSRunningApplication.current.localizedName)
            XCTAssertEqual(tab.title, fixture.externalTitle)
            XCTAssertEqual(tab.icon?.tiffRepresentation, NSRunningApplication.current.icon?.tiffRepresentation)
        }
    }

    private func groupedRail(
        _ entries: [WindowState], fixture: HostedPresentationFixture
    ) throws -> TabRailInfo {
        let world = fixture.world
        let workspace = fixture.workspace
        switch world.activeLayoutKind(for: workspace) {
        case .niri:
            let engine = try XCTUnwrap(fixture.controller.niriEngine)
            let nodes = world.withEngineMutationScope {
                entries.map { engine.addWindow(token: $0.token, to: workspace, afterSelection: nil) }
            }
            let first = try XCTUnwrap(nodes.first)
            let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspace))
            let sources = try nodes.dropFirst().map { node in
                (node, try XCTUnwrap(engine.findColumn(containing: node, in: workspace)))
            }
            world.withEngineMutationScope {
                for (node, source) in sources {
                    engine.moveWindowToColumn(node, from: source, to: column, in: workspace)
                    source.remove()
                }
                column.displayMode = .tabbed
                engine.updateTabbedColumnVisibility(column: column)
            }
            return try XCTUnwrap(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first)
        case .dwindle:
            let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
            world.withEngineMutationScope {
                for entry in entries {
                    _ = engine.addWindow(token: entry.token, to: workspace, activeWindowFrame: nil)
                }
                _ = engine.calculateLayout(for: workspace, screen: fixture.management.sourceMonitor.visibleFrame)
                XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
                _ = engine.calculateLayout(for: workspace, screen: fixture.management.sourceMonitor.visibleFrame)
            }
            return try XCTUnwrap(fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().first)
        }
    }
}
