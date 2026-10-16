// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewRibbonBehaviorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testWallpaperCoversCardsBeyondBothDesktopEdgesWithoutChangingProjection() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: -500, y: 100, width: 200, height: 500),
            CGRect(x: 1100, y: 100, width: 200, height: 500)
        ])
        let layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let renderer = makeRenderer(layout)
        let wallpaper = try XCTUnwrap(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper)

        XCTAssertLessThan(wallpaper.frame.minX, section.visibleFrame.minX)
        XCTAssertGreaterThan(wallpaper.frame.maxX, section.visibleFrame.maxX)
        XCTAssertLessThan(wallpaper.frame.width, section.ribbonFrame.width)
        XCTAssertEqual(section.visibleFrame.width, 425)
        XCTAssertEqual(section.contentScale, 0.425)
        XCTAssertEqual(OverviewRenderGeometry.restAnchor(for: section)?.overviewBounds, section.visibleFrame)
        XCTAssertEqual(wallpaper.contentsGravity, .resizeAspectFill)
        XCTAssertTrue(wallpaper.masksToBounds)
        try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
    }

    func testWallpaperFollowsPanAndShrinksAfterColumnsAreRemoved() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: -500, y: 100, width: 200, height: 500),
            CGRect(x: 1100, y: 100, width: 200, height: 500)
        ])
        var layout = makeLayout(fixture)
        let baseline = try XCTUnwrap(layout.workspaceSections.first)
        let renderer = makeRenderer(layout)
        let wallpaper = try XCTUnwrap(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper)
        let initialFrame = wallpaper.frame

        XCTAssertTrue(layout.panStrip(fixture.workspaceId, by: 60))
        updateRenderer(renderer, layout: layout)
        XCTAssertEqual(wallpaper.frame.minX - initialFrame.minX, 60, accuracy: 0.0001)
        XCTAssertEqual(wallpaper.frame.maxX - initialFrame.maxX, 60, accuracy: 0.0001)
        try assertBackgroundCoversVisibleContent(layout, renderer: renderer)

        let remaining = Fixture(
            workspaceId: fixture.workspaceId,
            handles: [fixture.handles[0]],
            windows: fixture.windows.filter { $0.key == fixture.handles[0] },
            snapshot: NiriOverviewWorkspaceSnapshot(
                workspaceId: fixture.workspaceId,
                columns: Array(fixture.snapshot.columns.prefix(1)),
                strip: fixture.snapshot.strip
            )
        )
        let reduced = makeLayout(remaining, pans: layout.stripPanByWorkspace)
        updateRenderer(renderer, layout: reduced)
        XCTAssertTrue(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper === wallpaper)
        XCTAssertLessThan(wallpaper.frame.width, initialFrame.width)
        XCTAssertEqual(wallpaper.frame.maxX, baseline.visibleFrame.maxX)
        XCTAssertEqual(reduced.workspaceSections.first?.visibleFrame, baseline.visibleFrame)
        XCTAssertEqual(reduced.workspaceSections.first?.contentScale, baseline.contentScale)
        try assertBackgroundCoversVisibleContent(reduced, renderer: renderer)
    }

    func testWallpaperIncludesColumnChromeWhenCardsAreViewportAnchored() throws {
        let fixture = makeFixture(frames: [CGRect(x: 100, y: 100, width: 700, height: 500)])
        let column = try XCTUnwrap(fixture.snapshot.columns.first)
        var tile = try XCTUnwrap(column.tiles.first)
        tile.isViewportAnchored = true
        let anchored = Fixture(
            workspaceId: fixture.workspaceId, handles: fixture.handles, windows: fixture.windows,
            snapshot: NiriOverviewWorkspaceSnapshot(
                workspaceId: fixture.workspaceId,
                columns: [NiriOverviewColumnSnapshot(
                    index: column.index, widthWeight: column.widthWeight, preferredWidth: column.preferredWidth,
                    tiles: [tile], stripFrame: CGRect(x: -900, y: 0, width: 1000, height: 800)
                )],
                strip: fixture.snapshot.strip
            )
        )
        let layout = makeLayout(anchored)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let renderer = makeRenderer(layout)
        XCTAssertTrue(section.visibleFrame.contains(try XCTUnwrap(layout.allWindows.first).overviewFrame))
        let wallpaper = try XCTUnwrap(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper)
        let clip = try XCTUnwrap(wallpaper.superlayer)
        XCTAssertLessThan(wallpaper.frame.minX, section.ribbonFrame.minX)
        XCTAssertEqual(wallpaper.frame.intersection(clip.bounds).minX, section.ribbonFrame.minX)
        try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
    }

    func testWallpaperResolutionUsesUnclippedWidthWithinCacheLimit() throws {
        let cases: [(CGFloat, Int)] = [(2000, 2048), (10000, 4096)]
        for (distance, expectedSize) in cases {
            let fixture = makeFixture(frames: [
                CGRect(x: -distance, y: 100, width: 400, height: 500),
                CGRect(x: distance, y: 100, width: 400, height: 500)
            ])
            var layout = makeLayout(fixture)
            layout.replaceWorkspaceSections(layout.workspaceSections.map { section in
                var section = section
                section.displayId = 991
                return section
            })
            let renderer = OverviewLayerRenderer()
            var requestedDisplays: [CGDirectDisplayID] = []
            var requestedSizes: [Int] = []
            renderer.wallpaperForDisplay = { displayId, size in
                requestedDisplays.append(displayId)
                requestedSizes.append(size)
                return nil
            }
            updateRenderer(renderer, layout: layout)

            XCTAssertEqual(requestedDisplays, [991])
            XCTAssertEqual(requestedSizes, [expectedSize])
            try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
        }
    }

    func testSearchAndTabPreviewKeepExpandedWallpaperBounds() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: -400, y: 100, width: 400, height: 500),
            CGRect(x: -400, y: 100, width: 1600, height: 500)
        ], tabbed: true)
        var layout = makeLayout(fixture)
        let renderer = makeRenderer(layout)
        let wallpaper = try XCTUnwrap(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper)
        let baseline = wallpaper.frame
        let section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertGreaterThan(baseline.maxX, section.visibleFrame.maxX)

        layout.revealTab(fixture.handles[1])
        updateRenderer(renderer, layout: layout)
        XCTAssertEqual(wallpaper.frame, baseline)
        try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
        for query in ["Window 1", "Window 2", "Missing"] {
            let filtered = makeLayout(fixture, query: query)
            updateRenderer(renderer, layout: filtered)
            XCTAssertEqual(wallpaper.frame, baseline)
            try assertBackgroundCoversVisibleContent(filtered, renderer: renderer)
        }
    }

    func testVerticalPanKeepsWallpaperHeightAndWorkspaceSpacing() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: -350, y: -900, width: 1400, height: 300),
            CGRect(x: -350, y: 300, width: 1400, height: 300),
            CGRect(x: -350, y: 1500, width: 1400, height: 300)
        ], orientation: .vertical)
        var layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let contentHeight = layout.totalContentHeight
        let renderer = makeRenderer(layout)
        let wallpaper = try XCTUnwrap(renderer.ribbonLayers[fixture.workspaceId]?.wallpaper)
        let baseline = wallpaper.frame
        XCTAssertGreaterThan(baseline.width, section.visibleFrame.width)
        XCTAssertEqual(baseline.height, section.visibleFrame.height)

        XCTAssertTrue(layout.panStrip(fixture.workspaceId, by: 100 * section.contentScale))
        updateRenderer(renderer, layout: layout)
        XCTAssertEqual(wallpaper.frame, baseline)
        XCTAssertEqual(layout.workspaceSections.first?.sectionFrame, section.sectionFrame)
        XCTAssertEqual(layout.totalContentHeight, contentHeight)
        try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
    }

    func testEmptyFloatingAndDwindleWorkspacesKeepDesktopSizedWallpaper() throws {
        let empty = makeFixture(frames: [])
        let floating = makeFixture(
            frames: [], floatingFrame: CGRect(x: -1000, y: 100, width: 3000, height: 500)
        )
        let grouped = makeFixture(frames: Array(repeating: CGRect(x: 50, y: 100, width: 900, height: 500), count: 2))
        let dwindle = OverviewLayoutCalculator(screenFrame: screen, scale: 1).calculateLayout(
            workspaces: [OverviewWorkspaceLayoutItem(id: grouped.workspaceId, name: "Dwindle", isActive: true)],
            windows: grouped.windows,
            dwindleGroupsByWorkspace: [grouped.workspaceId: [OverviewDwindleGroup(
                id: DwindleTileId(), windowHandles: grouped.handles, activeHandle: grouped.handles[0]
            )]],
            searchQuery: ""
        )
        for layout in [makeLayout(empty), makeLayout(floating), dwindle] {
            let section = try XCTUnwrap(layout.workspaceSections.first)
            let renderer = makeRenderer(layout)
            XCTAssertEqual(renderer.ribbonLayers[section.workspaceId]?.wallpaper.frame, section.visibleFrame)
            XCTAssertEqual(renderer.ribbonLayers[section.workspaceId]?.shade.frame, section.visibleFrame)
            try assertBackgroundCoversVisibleContent(layout, renderer: renderer)
        }
    }

    func testShortStripClippedAtLeadingEdgeCanPanWhileFloatingCardStaysFixed() throws {
        let fixture = makeFixture(
            frames: [CGRect(x: -700, y: 100, width: 200, height: 500)],
            floatingFrame: CGRect(x: 200, y: 150, width: 250, height: 200)
        )
        var layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let tile = try XCTUnwrap(layout.window(for: fixture.handles[0]))
        let floating = try XCTUnwrap(layout.window(for: fixture.handles[1]))
        XCTAssertLessThan(tile.overviewFrame.minX, section.ribbonFrame.minX)
        XCTAssertLessThan(tile.overviewFrame.width, section.ribbonFrame.width)
        XCTAssertTrue(layout.panStrip(fixture.workspaceId, by: section.ribbonFrame.minX - tile.overviewFrame.minX))
        XCTAssertEqual(layout.window(for: tile.handle)?.overviewFrame.minX, section.ribbonFrame.minX)
        XCTAssertEqual(layout.window(for: floating.handle)?.overviewFrame, floating.overviewFrame)
        XCTAssertFalse(floating.isTiled)
    }

    func testPendingPanUsesDesktopUnitsAcrossZoomChanges() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: -1200, y: 100, width: 400, height: 500),
            CGRect(x: 1200, y: 100, width: 400, height: 500)
        ])
        var original = makeLayout(fixture)
        let section = try XCTUnwrap(original.workspaceSections.first)
        let desktopPan: CGFloat = 80
        XCTAssertTrue(original.panStrip(fixture.workspaceId, by: desktopPan * section.contentScale))
        XCTAssertEqual(try XCTUnwrap(original.stripPanByWorkspace[fixture.workspaceId]), desktopPan, accuracy: 0.0001)
        let baseline = makeLayout(fixture, zoom: 1.4)
        let rebuilt = makeLayout(fixture, zoom: 1.4, pans: original.stripPanByWorkspace)
        let newScale = try XCTUnwrap(rebuilt.workspaceSections.first).contentScale
        for handle in fixture.handles {
            let before = try XCTUnwrap(baseline.window(for: handle))
            let after = try XCTUnwrap(rebuilt.window(for: handle))
            XCTAssertEqual(
                after.overviewFrame.minX - before.overviewFrame.minX,
                desktopPan * newScale,
                accuracy: 0.0001
            )
            XCTAssertEqual(after.overviewFrame.size, before.overviewFrame.size)
        }
        XCTAssertEqual(try XCTUnwrap(rebuilt.stripPanByWorkspace[fixture.workspaceId]), desktopPan, accuracy: 0.0001)
    }

    func testFloatingPreviewUsesUnparkedFrameWithoutChangingOriginalAnimationFrame() throws {
        let parked = CGRect(x: -20000, y: 100, width: 400, height: 300)
        let visible = CGRect(x: 100, y: 200, width: 400, height: 300)
        let fixture = makeFixture(
            frames: [CGRect(x: 500, y: 100, width: 400, height: 500)],
            floatingFrame: parked
        )
        let floating = fixture.handles[1]
        var windows = fixture.windows
        windows[floating]?.floatingPreviewFrame = visible
        let projections: [[WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot]] = [
            [:], [fixture.workspaceId: fixture.snapshot]
        ]
        for snapshots in projections {
            let layout = OverviewLayoutCalculator(screenFrame: screen, scale: 1).calculateLayout(
                workspaces: [OverviewWorkspaceLayoutItem(id: fixture.workspaceId, name: "Workspace", isActive: true)],
                windows: windows, niriSnapshotsByWorkspace: snapshots, searchQuery: ""
            )
            let section = try XCTUnwrap(layout.workspaceSections.first)
            let item = try XCTUnwrap(layout.window(for: floating))
            XCTAssertEqual(item.originalFrame, parked)
            XCTAssertEqual(item.overviewFrame, CGRect(
                x: section.visibleFrame.minX + visible.minX * section.contentScale,
                y: section.visibleFrame.minY + visible.minY * section.contentScale,
                width: visible.width * section.contentScale,
                height: visible.height * section.contentScale
            ))
            XCTAssertTrue(section.visibleFrame.contains(item.overviewFrame))
        }
    }

    func testVerticalStripPansAlongYAndClipsOverflowChrome() throws {
        let fixture = makeFixture(frames: [
            CGRect(x: 100, y: -900, width: 600, height: 300),
            CGRect(x: 100, y: 300, width: 600, height: 300),
            CGRect(x: 100, y: 1500, width: 600, height: 300)
        ], orientation: .vertical)
        var layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertEqual(section.hiddenColumnsBefore, 1)
        XCTAssertEqual(section.hiddenColumnsAfter, 1)
        let pills = layout.overflowPills(for: section)
        XCTAssertEqual(pills.map(\.orientation), [.vertical, .vertical])
        XCTAssertEqual(pills.first?.frame.minY, section.ribbonFrame.minY)
        XCTAssertEqual(pills.last?.frame.maxY, section.ribbonFrame.maxY)
        let before = try XCTUnwrap(layout.window(for: fixture.handles[1])).overviewFrame
        let delta = 100 * section.contentScale
        XCTAssertTrue(layout.panStrip(fixture.workspaceId, by: delta))
        let after = try XCTUnwrap(layout.window(for: fixture.handles[1])).overviewFrame
        XCTAssertEqual(after.minX, before.minX)
        XCTAssertEqual(after.minY - before.minY, delta, accuracy: 0.0001)

        let renderer = makeRenderer(layout)
        let columns = descendants(of: renderer.root).filter {
            $0.backgroundColor == OverviewRenderStyle.Colors.columnBackground
        }
        XCTAssertFalse(columns.isEmpty)
        for column in columns {
            let clip = try XCTUnwrap(column.superlayer)
            XCTAssertTrue(clip.masksToBounds)
            XCTAssertEqual(clip.frame, section.ribbonFrame)
        }
        XCTAssertTrue(columns.contains { column in
            guard let clip = column.superlayer else { return false }
            return !clip.bounds.contains(column.frame)
        })
    }

    func testTabControlsRevealOneMemberWithoutChangingItsGeometry() throws {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 500)
        let fixture = makeFixture(frames: [frame, frame], tabbed: true)
        var layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertEqual(layout.allWindows.filter(\.isDisplayed).map(\.handle), [fixture.handles[0]])
        let next = try XCTUnwrap(layout.tabControls(for: section).last)
        XCTAssertTrue(next.nextHandle === fixture.handles[1])
        let originalFrame = layout.window(for: fixture.handles[0])?.overviewFrame
        layout.revealTab(try XCTUnwrap(next.nextHandle))
        XCTAssertEqual(layout.allWindows.filter(\.isDisplayed).map(\.handle), [fixture.handles[1]])
        XCTAssertEqual(layout.window(for: fixture.handles[1])?.overviewFrame, originalFrame)
        let renderer = makeRenderer(layout)
        XCTAssertEqual(renderer.windowLayers[fixture.handles[0]]?.root.isHidden, true)
        XCTAssertEqual(renderer.windowLayers[fixture.handles[1]]?.root.isHidden, false)
    }

    func testSearchRevealsMatchingInactiveTab() throws {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 500)
        let fixture = makeFixture(frames: [frame, frame], tabbed: true)
        let layout = makeLayout(fixture, query: "Window 2")
        let matching = try XCTUnwrap(layout.window(for: fixture.handles[1]))
        XCTAssertTrue(matching.matchesSearch)
        XCTAssertTrue(matching.isDisplayed)
        XCTAssertEqual(layout.window(for: fixture.handles[0])?.isDisplayed, false)
        let point = CGPoint(x: matching.overviewFrame.midX, y: matching.overviewFrame.midY)
        XCTAssertTrue(layout.windowAt(point: point)?.handle === matching.handle)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertTrue(layout.tabControls(for: section).isEmpty)
    }

    func testTabControlsOnlyCycleMatchingMembersDuringSearch() throws {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 500)
        let fixture = makeFixture(frames: Array(repeating: frame, count: 12), tabbed: true)
        var layout = makeLayout(fixture, query: "Window 1")
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let controls = layout.tabControls(for: section)
        let control = try XCTUnwrap(controls.first)
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual([control.previousHandle, control.nextHandle], [nil, fixture.handles[9]])
        for handle in [control.previousHandle, control.nextHandle].compactMap({ $0 }) {
            XCTAssertTrue(try XCTUnwrap(layout.window(for: handle)).matchesSearch)
            layout.revealTab(handle)
            XCTAssertTrue(try XCTUnwrap(layout.window(for: handle)).isDisplayed)
        }
    }

    func testSearchUpdatesCachedTabControlsWhenActiveCardStaysTheSame() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 500)
        let fixture = makeFixture(frames: [frame, frame], tabbed: true)
        let renderer = makeRenderer(makeLayout(fixture))
        XCTAssertTrue(descendants(of: renderer.root)
            .contains { ($0 as? CATextLayer)?.string as? String == "1 / 2" })
        let filtered = makeLayout(fixture, query: "Window 1")
        let state = OverviewRenderState(
            searchQuery: "Window 1", selectedWindowHandle: nil, hoveredWindowHandle: nil, closeButtonHovered: false,
            progress: 1, bounds: screen, palette: .default
        )
        renderer.updateLayout(filtered, state: state, caretAnimated: false)
        renderer.updatePresentation(filtered, state: state)
        XCTAssertFalse(descendants(of: renderer.root)
            .contains { ($0 as? CATextLayer)?.string as? String == "1 / 2" })
    }

    func testCombinedTabControlHasSeparateStepAndPickerTargets() throws {
        let fixture = makeFixture(
            frames: Array(repeating: CGRect(x: 100, y: 100, width: 600, height: 500), count: 4),
            tabbed: true
        )
        var layout = makeLayout(fixture)
        layout.revealTab(fixture.handles[1])
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let control = try XCTUnwrap(layout.tabControls(for: section).first)
        XCTAssertEqual(control.positionLabel, "2 / 4")
        XCTAssertEqual(
            control.steppedHandle(at: CGPoint(x: control.frame.minX + 8, y: control.frame.midY)),
            fixture.handles[0]
        )
        XCTAssertNil(control.steppedHandle(at: CGPoint(x: control.frame.midX, y: control.frame.midY)))
        XCTAssertEqual(
            control.steppedHandle(at: CGPoint(x: control.frame.maxX - 8, y: control.frame.midY)),
            fixture.handles[2]
        )
        let renderer = makeRenderer(layout)
        XCTAssertTrue(renderer.tabControlLayers[control.handle]?.superlayer === renderer.windowLayers[control.handle]?
            .root)
    }

    func testTabPickerUsesMatchingTitlesAndCheckedPreviewWithoutActivating() throws {
        _ = NSApplication.shared
        let fixture = makeFixture(
            frames: Array(repeating: CGRect(x: 100, y: 100, width: 600, height: 500), count: 12),
            tabbed: true
        )
        let layout = makeLayout(fixture, query: "Window 1")
        let members = layout.tabMembers(for: fixture.handles[0])
        var selected: [WindowHandle] = []
        let picker = OverviewTabPicker(handle: fixture.handles[0], members: members) { selected.append($0) }
        XCTAssertEqual(picker.menu.items.map(\.title), ["Window 1", "Window 10", "Window 11", "Window 12"])
        XCTAssertEqual(picker.menu.items.map(\.state), [.on, .off, .off, .off])
        picker.menu.performActionForItem(at: 1)
        XCTAssertEqual(selected, [fixture.handles[9]])
        XCTAssertEqual(layout.searchResultCount, 4)
        XCTAssertEqual(layout.searchFeedback(query: "Window 1"), "4 results")
    }

    func testRenderedChevronCentersSelectTabsAtEveryControlWidth() throws {
        for count in [2, 12] {
            for width: CGFloat in [100, 128] {
                for activeIndex in [0, count - 1] {
                    let fixture = makeFixture(
                        frames: Array(repeating: CGRect(x: 100, y: 100, width: 600, height: 500), count: count),
                        tabbed: true
                    )
                    var layout = makeLayout(fixture)
                    layout.revealTab(fixture.handles[activeIndex])
                    layout.scrollOffset = 35
                    layout.replaceWorkspaceSections(layout.workspaceSections.map { section in
                        var section = section
                        for index in section.windows.indices {
                            section.windows[index].overviewFrame.size.width = width
                        }
                        return section
                    })
                    let (view, panel) = makeView(layout)
                    defer { panel.close() }
                    let handle = fixture.handles[activeIndex]
                    let control = try XCTUnwrap(view.layerRenderer.tabControlLayers[handle])
                    var selected: [WindowHandle] = []
                    view.onTabSelected = { selected.append($0) }
                    for symbol in ["‹", "›"] {
                        let text = try XCTUnwrap(control.sublayers?.compactMap { $0 as? CATextLayer }
                            .first { $0.string as? String == symbol })
                        let point = text.convert(
                            CGPoint(x: text.bounds.midX, y: text.bounds.midY),
                            to: view.layerRenderer.root
                        )
                        let hit = try XCTUnwrap(view.layerRenderer.tabControl(at: point, layout: layout))
                        XCTAssertEqual(
                            hit.steppedHandle(at: point),
                            symbol == "‹"
                                ? (activeIndex > 0 ? fixture.handles[activeIndex - 1] : nil)
                                : (activeIndex + 1 < count ? fixture.handles[activeIndex + 1] : nil)
                        )
                        XCTAssertEqual(text.opacity, hit.isEnabled(symbol == "‹" ? .previous : .next) ? 1 : 0.35)
                        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: panel))
                    }
                    XCTAssertEqual(selected, [fixture.handles[activeIndex == 0 ? 1 : count - 2]])
                    XCTAssertFalse(view.isTabPickerOpen)
                    let countText = try XCTUnwrap(control.sublayers?.compactMap { $0 as? CATextLayer }
                        .first { $0.string as? String == "\(activeIndex + 1) / \(count)" })
                    let point = countText.convert(
                        CGPoint(x: countText.bounds.midX, y: countText.bounds.midY),
                        to: view.layerRenderer.root
                    )
                    XCTAssertNil(try XCTUnwrap(view.layerRenderer.tabControl(at: point, layout: layout))
                        .steppedHandle(at: point))
                }
            }
        }
    }

    func testSearchFeedbackIncludesNoMatchStateAndLeavesRibbonGeometryStable() {
        let fixture = makeFixture(frames: [CGRect(x: 100, y: 100, width: 600, height: 500)])
        let before = makeLayout(fixture)
        let filtered = makeLayout(fixture, query: "Missing")
        XCTAssertEqual(filtered.searchResultCount, 0)
        XCTAssertEqual(filtered.searchFeedback(query: "Missing"), "No matching windows")
        XCTAssertEqual(before.searchFeedback(query: ""), "1 window")
        XCTAssertEqual(before.workspaceSections.map(\.visibleFrame), filtered.workspaceSections.map(\.visibleFrame))
        XCTAssertEqual(before.searchBarFrame, filtered.searchBarFrame)
        XCTAssertEqual(before.searchClearFrame, filtered.searchClearFrame)
    }

    func testModelAndRendererRejectHitsOutsideTiledAndFloatingClips() throws {
        let fixture = makeFixture(
            frames: [CGRect(x: -700, y: 100, width: 400, height: 500)],
            floatingFrame: CGRect(x: -200, y: 100, width: 300, height: 200)
        )
        let layout = makeLayout(fixture)
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let renderer = makeRenderer(layout)
        for handle in fixture.handles {
            let item = try XCTUnwrap(layout.window(for: handle))
            let clip = section.clipFrame(for: item)
            let outside = CGPoint(x: clip.minX - 5, y: item.overviewFrame.midY)
            let inside = CGPoint(x: clip.minX + 5, y: item.overviewFrame.midY)
            XCTAssertTrue(item.overviewFrame.contains(outside))
            XCTAssertNil(layout.windowHit(at: outside))
            XCTAssertNil(renderer.windowHit(at: outside, layout: layout))
            XCTAssertTrue(layout.windowHit(at: inside)?.window.handle === handle)
            XCTAssertTrue(renderer.windowHit(at: inside, layout: layout)?.window.handle === handle)
            let mask = try XCTUnwrap(renderer.windowLayers[handle]?.root.mask)
            XCTAssertEqual(mask.frame, clip.offsetBy(dx: -item.overviewFrame.minX, dy: -item.overviewFrame.minY))
        }
    }

    func testRightMousePanDoesNotArmWindowDragOrActivateCard() throws {
        let fixture = makeFixture(frames: [CGRect(x: 100, y: 100, width: 600, height: 500)])
        let layout = makeLayout(fixture)
        let (view, panel) = makeView(layout)
        defer { panel.close() }
        let frame = try XCTUnwrap(layout.window(for: fixture.handles[0])).overviewFrame
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x + 35, y: start.y + 8)
        final class PanRecorder {
            var deltas: [CGFloat] = []
        }
        let recorder = PanRecorder()
        var unintendedCallbacks = 0
        view.onStripPan = { _, delta in recorder.deltas.append(delta) }
        view.onWindowSelected = { _ in unintendedCallbacks += 1 }
        view.onDragBegin = { _, _ in unintendedCallbacks += 1 }
        view.onDragEnd = { _ in unintendedCallbacks += 1 }
        view.onDismiss = { unintendedCallbacks += 1 }
        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: start, in: panel))
        view.rightMouseDragged(with: try mouseEvent(.rightMouseDragged, at: end, in: panel))
        view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: end, in: panel))
        view.rightMouseDragged(with: try mouseEvent(.rightMouseDragged, at: start, in: panel))
        XCTAssertEqual(recorder.deltas, [35])
        XCTAssertEqual(unintendedCallbacks, 0)
    }

    func testNewWorkspaceTargetDispatchesClickAndDropWithoutAddingAWorkspaceToLayout() throws {
        let fixture = makeFixture(frames: [])
        let monitorId = Monitor.ID(displayId: 99)
        var layout = makeLayout(fixture, monitorId: monitorId)
        let target = try XCTUnwrap(layout.newWorkspaceTarget)
        layout.scrollOffset = target.frame.midY - screen.midY
        let point = CGPoint(x: target.frame.midX, y: screen.midY)
        XCTAssertEqual(layout.workspaceSections.map(\.workspaceId), [fixture.workspaceId])
        XCTAssertEqual(layout.resolveDragTarget(at: point, draggedHandle: nil), .newWorkspace(monitorId: monitorId))
        let (view, panel) = makeView(layout)
        defer { panel.close() }
        var creates = 0
        var unrelated = 0
        view.onNewWorkspace = { creates += 1 }
        view.onWorkspaceSelected = { _ in unrelated += 1 }
        view.onWindowSelected = { _ in unrelated += 1 }
        view.onDismiss = { unrelated += 1 }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: panel))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: panel))
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(unrelated, 0)
        XCTAssertEqual(view.layout.workspaceSections.map(\.workspaceId), [fixture.workspaceId])
    }

    private struct Fixture {
        let workspaceId: WorkspaceDescriptor.ID
        let handles: [WindowHandle]
        let windows: [WindowHandle: OverviewWindowLayoutData]
        let snapshot: NiriOverviewWorkspaceSnapshot
    }

    private func makeFixture(
        frames: [CGRect],
        floatingFrame: CGRect? = nil,
        orientation: Monitor.Orientation = .horizontal,
        tabbed: Bool = false
    ) -> Fixture {
        let workspaceId = UUID()
        let allFrames = frames + (floatingFrame.map { [$0] } ?? [])
        let handles = allFrames.indices.map { WindowHandle(id: WindowToken(pid: 2, windowId: $0 + 1)) }
        let windows = Dictionary(uniqueKeysWithValues: zip(handles, allFrames).map { handle, frame in
            (handle, OverviewWindowLayoutData(
                token: handle.id, workspaceId: workspaceId,
                title: "Window \(handle.id.windowId)", appName: "App", appIcon: nil, frame: frame
            ))
        })
        let groups = tabbed && !frames.isEmpty ? [Array(frames.indices)] : frames.indices.map { [$0] }
        let columns = groups.enumerated().map { index, indices in
            NiriOverviewColumnSnapshot(
                index: index, widthWeight: 1, preferredWidth: frames[indices[0]].width,
                tiles: indices.map {
                    NiriOverviewTileSnapshot(
                        token: handles[$0].id,
                        preferredHeight: frames[$0].height,
                        stripFrame: frames[$0]
                    )
                },
                stripFrame: frames[indices[0]], isTabbed: tabbed, activeToken: handles[indices[0]].id
            )
        }
        return Fixture(
            workspaceId: workspaceId, handles: handles, windows: windows,
            snapshot: NiriOverviewWorkspaceSnapshot(
                workspaceId: workspaceId, columns: columns,
                strip: NiriOverviewStripGeometry(workingFrame: screen, secondaryGap: 20, orientation: orientation)
            )
        )
    }

    private func makeLayout(
        _ fixture: Fixture,
        zoom: CGFloat = 1,
        query: String = "",
        pans: [WorkspaceDescriptor.ID: CGFloat] = [:],
        monitorId: Monitor.ID? = nil
    ) -> OverviewLayout {
        OverviewLayoutCalculator(screenFrame: screen, scale: zoom).calculateLayout(
            workspaces: [OverviewWorkspaceLayoutItem(id: fixture.workspaceId, name: "Workspace", isActive: true)],
            windows: fixture.windows, niriSnapshotsByWorkspace: [fixture.workspaceId: fixture.snapshot],
            searchQuery: query, stripPans: pans, monitorId: monitorId
        )
    }

    private func makeRenderer(_ layout: OverviewLayout) -> OverviewLayerRenderer {
        let renderer = OverviewLayerRenderer()
        updateRenderer(renderer, layout: layout)
        return renderer
    }

    private func updateRenderer(_ renderer: OverviewLayerRenderer, layout: OverviewLayout) {
        let state = OverviewRenderState(
            searchQuery: "", selectedWindowHandle: nil, hoveredWindowHandle: nil, closeButtonHovered: false,
            progress: 1, bounds: screen, palette: .default
        )
        renderer.updateLayout(layout, state: state, caretAnimated: false, update: .immediate)
        renderer.updatePresentation(layout, state: state)
    }

    private func assertBackgroundCoversVisibleContent(
        _ layout: OverviewLayout,
        renderer: OverviewLayerRenderer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for section in layout.workspaceSections {
            let layers = try XCTUnwrap(renderer.ribbonLayers[section.workspaceId], file: file, line: line)
            let clip = try XCTUnwrap(layers.wallpaper.superlayer, file: file, line: line)
            XCTAssertTrue(layers.shade.superlayer === clip, file: file, line: line)
            XCTAssertTrue(clip.masksToBounds, file: file, line: line)
            XCTAssertEqual(clip.frame, section.ribbonFrame, file: file, line: line)
            XCTAssertEqual(clip.bounds, section.ribbonFrame, file: file, line: line)
            XCTAssertEqual(layers.wallpaper.frame, layers.shade.frame, file: file, line: line)
            let visibleBackground = layers.wallpaper.frame.intersection(clip.bounds)
            XCTAssertTrue(section.ribbonFrame.contains(visibleBackground), file: file, line: line)
            for window in section.windows where window.isDisplayed {
                let visible = window.overviewFrame.intersection(section.clipFrame(for: window))
                if !visible.isNull, !visible.isEmpty {
                    XCTAssertTrue(visibleBackground.contains(visible), file: file, line: line)
                }
            }
            for column in layout.niriColumnsByWorkspace[section.workspaceId] ?? [] {
                let visible = column.frame.intersection(section.ribbonFrame)
                if !visible.isNull, !visible.isEmpty {
                    XCTAssertTrue(visibleBackground.contains(visible), file: file, line: line)
                }
            }
        }
    }

    private func descendants(of layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).flatMap { [$0] + descendants(of: $0) }
    }

    private func makeView(_ layout: OverviewLayout) -> (OverviewView, NSPanel) {
        let view = OverviewView(frame: screen)
        let panel = NSPanel(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        return (view, panel)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }
}
