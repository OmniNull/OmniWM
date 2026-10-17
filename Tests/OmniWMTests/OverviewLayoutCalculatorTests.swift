// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewLayoutCalculatorTests: XCTestCase {
    /// Checks fixed notch clearance and content spacing for empty and typed searches at each zoom limit and default.
    func testNotchedDisplayKeepsSearchAndContentBelowSafeAreaAtEveryZoom() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let safeAreaInset: CGFloat = 32
        let workspace = OverviewWorkspaceLayoutItem(id: UUID(), name: "Main", isActive: true)

        for scale: CGFloat in [0.5, 1, 1.5] {
            for query in ["", "Safari"] {
                let layout = OverviewLayoutCalculator(
                    screenFrame: viewport,
                    scale: scale,
                    topSafeAreaInset: safeAreaInset
                ).calculateLayout(workspaces: [workspace], windows: [:], searchQuery: query)
                let section = try XCTUnwrap(layout.workspaceSections.first)

                XCTAssertEqual(
                    layout.searchBarFrame.maxY,
                    viewport.maxY - safeAreaInset - OverviewLayoutMetrics.searchBarPadding * scale
                )
                XCTAssertLessThan(section.labelFrame.maxY, layout.searchBarFrame.minY)
                XCTAssertEqual(layout.viewportFrame, viewport)
                XCTAssertEqual(
                    OverviewLayoutCalculator.visibleContentFrame(layout: layout, screenFrame: viewport).maxY,
                    layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * scale
                )
            }
        }
    }

    /// Checks that projection forwards each monitor's notch height without scaling it or using the global origin.
    func testProjectionUsesEachMonitorsNotchHeightForSearchPosition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        let monitors = [CGFloat(0), 32].enumerated().map { index, notchHeight in
            let displayId = CGDirectDisplayID(93_001 + index)
            let frame = CGRect(x: index * 1512, y: 200, width: 1512, height: 982)
            return Monitor(
                id: .init(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
                hasNotch: notchHeight > 0, notchHeight: notchHeight, name: "Projection Test \(index)"
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange(monitors)
        let snapshot = OverviewSnapshot(
            wmController: controller,
            facts: OverviewWindowFacts(wmController: controller, environment: OverviewEnvironment())
        )
        let scale: CGFloat = 1.25
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: scale)

        projection.rebuildProjectedLayouts()

        for monitor in monitors {
            let layout = try XCTUnwrap(projection.layoutsByMonitor[monitor.id])
            XCTAssertEqual(
                layout.searchBarFrame.maxY,
                monitor.frame.height - monitor.notchHeight - OverviewLayoutMetrics.searchBarPadding * scale
            )
        }
    }

    func testGenericFallbackProjectsMonitorLocalFramesAtUniformStripScale() throws {
        let (layout, handles) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first)

        XCTAssertEqual(layout.searchBarFrame, CGRect(x: 50, y: 620, width: 500, height: 55))
        XCTAssertEqual(layout.viewportFrame, CGRect(x: -200, y: -100, width: 1000, height: 800))
        XCTAssertEqual(section.name, "Generic")
        XCTAssertTrue(section.isActive)
        XCTAssertEqual(section.labelFrame, CGRect(x: -170, y: 555, width: 940, height: 40))
        assertFrame(section.visibleFrame, CGRect(x: 40.625, y: 120, width: 518.75, height: 415))
        assertFrame(section.ribbonFrame, CGRect(x: -170, y: 120, width: 940, height: 415))
        XCTAssertEqual(section.gridFrame, section.ribbonFrame)
        assertFrame(section.sectionFrame, CGRect(x: -200, y: 120, width: 1000, height: 455))
        XCTAssertEqual(section.windows.map(\.handle), Array(handles.prefix(2)))
        for window in section.windows {
            assertFrame(
                window.overviewFrame,
                CGRect(
                    x: 40.625 + window.originalFrame.minX * 0.51875,
                    y: 120 + window.originalFrame.minY * 0.51875,
                    width: window.originalFrame.width * 0.51875,
                    height: window.originalFrame.height * 0.51875
                )
            )
        }
        XCTAssertEqual(section.windows.first?.originalFrame, CGRect(x: -640.25, y: 25.5, width: 300, height: 200))
    }

    func testNiriColumnsKeepRealStripGeometryAndDropZoneCoordinates() throws {
        let (layout, handles) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first { $0.name == "Niri" })
        let columns = try XCTUnwrap(layout.niriColumnsByWorkspace[section.workspaceId])
        let dropZones = try XCTUnwrap(layout.niriColumnDropZonesByWorkspace[section.workspaceId])

        XCTAssertFalse(section.isActive)
        assertFrame(section.labelFrame, CGRect(x: -170, y: 60, width: 940, height: 40))
        assertFrame(section.visibleFrame, CGRect(x: 40.625, y: -375, width: 518.75, height: 415))
        assertFrame(section.sectionFrame, CGRect(x: -200, y: -375, width: 1000, height: 455))
        XCTAssertEqual(columns.map(\.columnIndex), [3, 8])
        assertFrames(columns.map(\.frame), [
            CGRect(x: 40.625, y: -375, width: 103.75, height: 415),
            CGRect(x: 152.675, y: -375, width: 103.75, height: 415)
        ])
        XCTAssertEqual(columns.map(\.windowHandles), [[handles[2], handles[3]], [handles[4]]])
        assertFrames(section.windows.map(\.overviewFrame), [
            CGRect(x: 40.625, y: -9.28125, width: 103.75, height: 49.28125),
            CGRect(x: 40.625, y: -66.8625, width: 103.75, height: 49.28125),
            CGRect(x: 152.675, y: -11.875, width: 103.75, height: 51.875)
        ])
        XCTAssertEqual(dropZones.map(\.insertIndex), [3, 8, 9])
        assertFrames(dropZones.map(\.frame), [
            CGRect(x: 20.625, y: -375, width: 20, height: 415),
            CGRect(x: 144.375, y: -375, width: 8.3, height: 415),
            CGRect(x: 256.425, y: -375, width: 20, height: 415)
        ])
        XCTAssertEqual(section.hiddenColumnsBefore, 0)
        XCTAssertEqual(section.hiddenColumnsAfter, 0)
    }

    func testNiriStripFramesProjectAtTheirRealPositions() throws {
        let workspaceId = WorkspaceDescriptor.ID()
        let handles = (1 ... 2).map { WindowHandle(id: WindowToken(pid: 9, windowId: $0)) }
        let layout = makeStripLayout(
            workspaceId: workspaceId, handles: handles,
            frames: [
                CGRect(x: -380, y: 40, width: 400, height: 700),
                CGRect(x: 40, y: 40, width: 600, height: 700)
            ],
            workingFrame: CGRect(x: 20, y: 40, width: 960, height: 700)
        )
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let columns = try XCTUnwrap(layout.niriColumnsByWorkspace[workspaceId])

        XCTAssertEqual(section.visibleFrame.width, 425)
        assertFrame(columns[0].frame, CGRect(
            x: section.visibleFrame.minX - 380 * 0.425,
            y: section.visibleFrame.minY + 40 * 0.425,
            width: 400 * 0.425,
            height: 700 * 0.425
        ))
        assertFrame(columns[1].frame, CGRect(
            x: section.visibleFrame.minX + 40 * 0.425,
            y: section.visibleFrame.minY + 40 * 0.425,
            width: 600 * 0.425,
            height: 700 * 0.425
        ))
        XCTAssertEqual(section.windows.map(\.overviewFrame), columns.map(\.frame))
    }

    func testEmptyWorkspacesKeepFullHeightRibbonsThatAcceptDrops() throws {
        let (layout, _) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first { $0.name == "Empty" })

        XCTAssertTrue(section.isEmpty)
        XCTAssertEqual(layout.workspaceSections.count, 3)
        assertFrame(section.visibleFrame, CGRect(x: 40.625, y: -870, width: 518.75, height: 415))
        XCTAssertEqual(section.visibleFrame.size, layout.workspaceSections.first?.visibleFrame.size)
        assertFrame(section.sectionFrame, CGRect(x: -200, y: -870, width: 1000, height: 455))
        let point = CGPoint(x: section.visibleFrame.midX, y: section.visibleFrame.midY)
        XCTAssertEqual(layout.ribbonSection(at: point)?.workspaceId, section.workspaceId)
        XCTAssertEqual(
            layout.resolveDragTarget(at: point, draggedHandle: nil),
            .workspaceMove(workspaceId: section.workspaceId)
        )
        XCTAssertNotNil(OverviewRenderGeometry.restAnchor(for: section))
    }

    func testStripPanIsClampedToRibbonAndCountsOverflowColumns() throws {
        let workspaceId = WorkspaceDescriptor.ID()
        let handles = (1 ... 6).map { WindowHandle(id: WindowToken(pid: 11, windowId: $0)) }
        let frames = handles.indices.map {
            CGRect(x: CGFloat($0) * 820 - 1_640, y: 0, width: 800, height: 700)
        }
        var layout = makeStripLayout(workspaceId: workspaceId, handles: handles, frames: frames)
        var section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertEqual(section.hiddenColumnsBefore, 1)
        XCTAssertEqual(section.hiddenColumnsAfter, 2)
        XCTAssertEqual(layout.overflowPills(for: section).map(\.edge), [.leading, .trailing])
        XCTAssertEqual(layout.overflowPills(for: section).map(\.count), [1, 2])
        XCTAssertNil(layout.windowHit(at: CGPoint(x: section.ribbonFrame.minX - 200, y: section.ribbonFrame.midY)))

        let range = layout.stripPanRange(for: workspaceId)
        XCTAssertEqual(range, -697 ... 433.5)
        XCTAssertTrue(layout.panStrip(workspaceId, by: 10_000))
        XCTAssertEqual(layout.stripPanByWorkspace[workspaceId], 1020)
        section = try XCTUnwrap(layout.workspaceSections.first)
        XCTAssertEqual(section.hiddenColumnsBefore, 0)
        XCTAssertEqual(section.windows.first?.overviewFrame.minX, section.ribbonFrame.minX)
        XCTAssertFalse(layout.panStrip(workspaceId, by: 1))

        let rebuilt = makeStripLayout(
            workspaceId: workspaceId, handles: handles, frames: frames,
            stripPans: layout.stripPanByWorkspace
        )
        XCTAssertEqual(rebuilt.workspaceSections.first?.windows.first?.overviewFrame.minX, section.ribbonFrame.minX)
        XCTAssertEqual(rebuilt.stripPanRevealing(handles[0]), 0)
        XCTAssertLessThan(rebuilt.stripPanRevealing(handles[5]), 0)
    }

    func testDragAutoScrollVelocityOnlyInsideEdgeBands() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            OverviewLayoutCalculator.dragAutoScrollVelocity(pointerY: 400, viewportFrame: viewport, scale: 1),
            0
        )
        XCTAssertGreaterThan(
            OverviewLayoutCalculator.dragAutoScrollVelocity(pointerY: 790, viewportFrame: viewport, scale: 1),
            0
        )
        XCTAssertLessThan(
            OverviewLayoutCalculator.dragAutoScrollVelocity(pointerY: 10, viewportFrame: viewport, scale: 1),
            0
        )
        XCTAssertEqual(
            abs(OverviewLayoutCalculator.dragAutoScrollVelocity(pointerY: 800, viewportFrame: viewport, scale: 1)),
            1_400
        )
    }

    func testMixedProjectionPreservesHandleIdentitySearchAndContentBounds() {
        let (layout, handles) = makeMixedLayout()

        XCTAssertEqual(layout.workspaceSections.count, 3)
        XCTAssertEqual(layout.scale, 1.25)
        XCTAssertEqual(layout.totalContentHeight, 1515, accuracy: 1e-10)
        XCTAssertEqual(layout.allWindows.map(\.matchesSearch), [false, true, true, false, false])
        for (window, handle) in zip(layout.allWindows, handles) {
            XCTAssertTrue(window.handle === handle)
        }
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
            layout: layout,
            screenFrame: CGRect(x: -200, y: -100, width: 1000, height: 800)
        )
        XCTAssertEqual(bounds.lowerBound, -820, accuracy: 1e-10)
        XCTAssertEqual(bounds.upperBound, 0)
    }

    func testGenericRestAnchorInvertsProjectedFrames() throws {
        let (layout, _) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first)
        let anchor = try XCTUnwrap(OverviewRenderGeometry.restAnchor(for: section))

        for window in section.windows {
            assertFrame(
                OverviewRenderGeometry.restFrame(for: window.overviewFrame, anchor: anchor),
                window.originalFrame
            )
        }
    }

    func testNiriRestAnchorPreservesRealFramesAndProjectsOtherSections() throws {
        var (layout, _) = makeMixedLayout()
        let section = try XCTUnwrap(layout.workspaceSections.first { $0.name == "Niri" })
        let anchor = try XCTUnwrap(OverviewRenderGeometry.restAnchor(for: section))

        layout.settleRestFrames(anchorWorkspaceId: section.workspaceId)

        XCTAssertEqual(layout.anchorWorkspaceId, section.workspaceId)
        for window in layout.allWindows {
            let expected = window.workspaceId == section.workspaceId
                ? window.originalFrame
                : OverviewRenderGeometry.restFrame(for: window.overviewFrame, anchor: anchor)
            assertFrame(window.interpolatedFrame(progress: 0), expected)
            assertFrame(window.interpolatedFrame(progress: 1), window.overviewFrame)
            XCTAssertEqual(
                window.interpolatedFrame(progress: 0.5).midY,
                (expected.midY + window.overviewFrame.midY) / 2,
                accuracy: 0.001
            )
            if window.workspaceId == section.workspaceId {
                XCTAssertNil(window.restFrame)
            } else {
                XCTAssertNotEqual(window.restFrame, window.originalFrame)
            }
        }
    }

    func testMissingAndEmptyRestAnchorsClearPreviousProjection() throws {
        var (layout, _) = makeMixedLayout()
        let workspaceId = try XCTUnwrap(layout.workspaceSections.first?.workspaceId)
        layout.settleRestFrames(anchorWorkspaceId: workspaceId)
        XCTAssertTrue(layout.allWindows.contains { $0.restFrame != nil })

        for anchorId in [nil, WorkspaceDescriptor.ID()] {
            layout.settleRestFrames(anchorWorkspaceId: anchorId)
            XCTAssertTrue(layout.allWindows.allSatisfy { $0.restFrame == nil })
            XCTAssertTrue(layout.allWindows.allSatisfy { $0.interpolatedFrame(progress: 0) == $0.originalFrame })
        }
        var empty = try XCTUnwrap(layout.workspaceSections.first)
        empty.windows = []
        XCTAssertNotNil(OverviewRenderGeometry.restAnchor(for: empty))
        empty.visibleFrame = .zero
        XCTAssertNil(OverviewRenderGeometry.restAnchor(for: empty))
    }

    func testDegenerateRestAnchorUsesOriginalFrames() throws {
        var (layout, _) = makeMixedLayout()
        var section = try XCTUnwrap(layout.workspaceSections.first)
        let window = try XCTUnwrap(section.windows.first)
        section.windows = [OverviewWindowItem(
            handle: window.handle,
            windowId: window.windowId,
            workspaceId: window.workspaceId,
            title: window.title,
            appName: window.appName,
            appIcon: nil,
            originalFrame: .zero,
            overviewFrame: window.overviewFrame,
            matchesSearch: true
        )]
        section.visibleFrame = .zero
        layout.replaceWorkspaceSections([section] + layout.workspaceSections.dropFirst())
        layout.settleRestFrames(anchorWorkspaceId: section.workspaceId)

        XCTAssertNil(OverviewRenderGeometry.restAnchor(for: section))
        XCTAssertTrue(layout.allWindows.allSatisfy { $0.restFrame == nil })
    }
}

extension OverviewLayoutCalculatorTests {
    private func assertFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func assertFrames(
        _ actual: [CGRect],
        _ expected: [CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            assertFrame(lhs, rhs, file: file, line: line)
        }
    }

    private func makeStripLayout(
        workspaceId: WorkspaceDescriptor.ID,
        handles: [WindowHandle],
        frames: [CGRect],
        workingFrame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 700),
        stripPans: [WorkspaceDescriptor.ID: CGFloat] = [:]
    ) -> OverviewLayout {
        let windows = Dictionary(uniqueKeysWithValues: handles.map { handle in
            (handle, OverviewWindowLayoutData(
                token: handle.id, workspaceId: workspaceId, title: "Window", appName: "App", appIcon: nil,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)
            ))
        })
        let snapshot = NiriOverviewWorkspaceSnapshot(
            workspaceId: workspaceId,
            columns: zip(handles, frames).enumerated().map { index, member in
                let (handle, frame) = member
                return NiriOverviewColumnSnapshot(
                    index: index, widthWeight: 1, preferredWidth: frame.width,
                    tiles: [NiriOverviewTileSnapshot(
                        token: handle.id,
                        preferredHeight: frame.height,
                        stripFrame: frame
                    )],
                    stripFrame: frame
                )
            },
            strip: NiriOverviewStripGeometry(workingFrame: workingFrame, secondaryGap: 20)
        )
        return OverviewLayoutCalculator(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)
            .calculateLayout(
                workspaces: [OverviewWorkspaceLayoutItem(id: workspaceId, name: "Strip", isActive: true)],
                windows: windows, niriSnapshotsByWorkspace: [workspaceId: snapshot],
                searchQuery: "", stripPans: stripPans
            )
    }

    private func makeMixedLayout() -> (OverviewLayout, [WindowHandle]) {
        let generic = WorkspaceDescriptor.ID()
        let niri = WorkspaceDescriptor.ID()
        let handles = (1 ... 5).map { WindowHandle(id: WindowToken(pid: 7, windowId: $0)) }
        let frames = [
            CGRect(x: -640.25, y: 25.5, width: 300, height: 200),
            CGRect(x: -340.25, y: 25.5, width: 300, height: 200),
            CGRect(x: 0, y: 0, width: 200, height: 95),
            CGRect(x: 0, y: 0, width: 200, height: 95),
            CGRect(x: 0, y: 0, width: 100, height: 100)
        ]
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for (index, handle) in handles.enumerated() {
            windows[handle] = OverviewWindowLayoutData(
                token: handle.id,
                workspaceId: index < 2 ? generic : niri,
                title: index == 1 ? "TERMINAL" : "Window \(index)",
                appName: index == 2 ? "Terminal" : "Editor",
                appIcon: nil,
                frame: frames[index]
            )
        }
        let layout = OverviewLayoutCalculator(
            screenFrame: CGRect(x: -200, y: -100, width: 1000, height: 800),
            scale: 1.25
        ).calculateLayout(
            workspaces: [
                OverviewWorkspaceLayoutItem(id: generic, name: "Generic", isActive: true),
                OverviewWorkspaceLayoutItem(id: niri, name: "Niri", isActive: false),
                OverviewWorkspaceLayoutItem(id: WorkspaceDescriptor.ID(), name: "Empty", isActive: false)
            ],
            windows: windows,
            niriSnapshotsByWorkspace: [
                generic: NiriOverviewWorkspaceSnapshot(workspaceId: generic, columns: []),
                niri: makeMixedNiriSnapshot(workspaceId: niri, handles: handles)
            ],
            searchQuery: "terminal"
        )
        return (layout, handles)
    }

    private func makeMixedNiriSnapshot(
        workspaceId: WorkspaceDescriptor.ID,
        handles: [WindowHandle]
    ) -> NiriOverviewWorkspaceSnapshot {
        NiriOverviewWorkspaceSnapshot(workspaceId: workspaceId, columns: [
            NiriOverviewColumnSnapshot(index: 3, widthWeight: 4, preferredWidth: 200, tiles: [
                NiriOverviewTileSnapshot(
                    token: handles[2].id,
                    preferredHeight: 95,
                    stripFrame: CGRect(x: 0, y: 705, width: 200, height: 95)
                ),
                NiriOverviewTileSnapshot(
                    token: handles[3].id,
                    preferredHeight: 95,
                    stripFrame: CGRect(x: 0, y: 594, width: 200, height: 95)
                )
            ], stripFrame: CGRect(x: 0, y: 0, width: 200, height: 800)),
            NiriOverviewColumnSnapshot(index: 8, widthWeight: 1, preferredWidth: nil, tiles: [
                NiriOverviewTileSnapshot(
                    token: handles[4].id,
                    preferredHeight: 100,
                    stripFrame: CGRect(x: 216, y: 700, width: 200, height: 100)
                )
            ], stripFrame: CGRect(x: 216, y: 0, width: 200, height: 800))
        ])
    }
}
