// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewSelectionUXTests: XCTestCase {
    func testReturnActivatesSelectedEmptyWorkspaceWithoutCreatingOne() async throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let originalCatalog = manager.workspaces
        fixture.projection.selection = .workspace(fixture.workspaceIds[1])

        XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(kVK_Return)))

        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitors[0].id)?.id, fixture.workspaceIds[1])
        XCTAssertEqual(manager.workspaces, originalCatalog)
        guard case .closed = fixture.overview.state else { return XCTFail("Expected completed workspace close") }
        await settle(fixture.controller)
    }

    func testReturnOnCreationTargetCreatesAndActivatesGloballyUniqueWorkspace() async throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let originalIDs = Set(manager.workspaces.map(\.id))
        fixture.projection.selection = .newWorkspace(fixture.monitors[0].id)

        XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(kVK_Return)))

        let created = try XCTUnwrap(manager.workspaces.first { !originalIDs.contains($0.id) })
        XCTAssertEqual(created.name, "5")
        XCTAssertEqual(manager.workspaces.count, originalIDs.count + 1)
        XCTAssertEqual(manager.monitorId(for: created.id), fixture.monitors[0].id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitors[0].id)?.id, created.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitors[1].id)?.id, fixture.workspaceIds[3])
        guard case .closed = fixture.overview.state else { return XCTFail("Expected completed creation close") }
        await settle(fixture.controller)
    }

    func testEscapeCancelsEmptyAndCreationSelectionWithoutAllocatingOrSwitching() throws {
        for createsWorkspace in [false, true] {
            let fixture = try makeFixture()
            let manager = fixture.controller.workspaceManager
            let catalog = manager.workspaces
            let visible = manager.activeVisibleWorkspaceMap()
            fixture.projection.selection = createsWorkspace
                ? .newWorkspace(fixture.monitors[0].id)
                : .workspace(fixture.workspaceIds[1])
            let dismissal = fixture.input.selectionDismissal()
            XCTAssertEqual(dismissal.reason, .cancel)
            XCTAssertNil(dismissal.targetWindow)

            XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(kVK_Escape)))

            XCTAssertEqual(manager.workspaces, catalog)
            XCTAssertEqual(manager.activeVisibleWorkspaceMap(), visible)
            guard case .closed = fixture.overview.state else { return XCTFail("Expected completed cancel close") }
        }
    }

    func testSearchWithNoMatchesClearsCreationSelectionAndReturnDoesNothing() throws {
        let fixture = try makeFixture(localWindowCount: 2, remoteWindowCount: 1)
        let manager = fixture.controller.workspaceManager
        let catalog = manager.workspaces
        let visible = manager.activeVisibleWorkspaceMap()
        fixture.projection.selection = .newWorkspace(fixture.monitors[0].id)
        fixture.input.updateSearchQuery("No document has this title")
        XCTAssertNil(fixture.projection.selection)
        let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitors[0].id])
        XCTAssertEqual(layout.searchResultCount, 0)
        XCTAssertEqual(layout.searchFeedback(query: fixture.input.searchQuery), "No matching windows")
        XCTAssertEqual(layout.workspaceSections.filter(\.isEmpty).count, 2)
        XCTAssertNotNil(layout.newWorkspaceTarget)

        fixture.input.cycleSelection(forward: true)
        fixture.input.navigateSelection(.down)
        XCTAssertNil(fixture.projection.selection)
        XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(kVK_Return)))

        XCTAssertEqual(manager.workspaces, catalog)
        XCTAssertEqual(manager.activeVisibleWorkspaceMap(), visible)
        guard case .open = fixture.overview.state else { return XCTFail("Search with no results must remain open") }
    }

    func testSearchCountsAndTraversalStayOnInteractionMonitor() throws {
        let fixture = try makeFixture(localWindowCount: 3, remoteWindowCount: 2)
        fixture.input.updateSearchQuery("Document")
        let local = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitors[0].id])
        let remote = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitors[1].id])
        XCTAssertEqual(local.searchResultCount, 3)
        XCTAssertEqual(remote.searchResultCount, 2)
        XCTAssertEqual(local.searchFeedback(query: "Document"), "3 results")
        XCTAssertEqual(remote.searchFeedback(query: "Document"), "2 results")
        XCTAssertEqual(Set(local.allWindows.map(\.handle)), Set(fixture.localHandles))
        XCTAssertEqual(Set(remote.allWindows.map(\.handle)), Set(fixture.remoteHandles))

        for _ in 0 ..< 5 {
            fixture.input.cycleSelection(forward: true, on: fixture.monitors[1].id)
            let handle = try XCTUnwrap(fixture.projection.selectedWindowHandle)
            XCTAssertTrue(fixture.remoteHandles.contains(handle))
            XCTAssertEqual(fixture.projection.activeInteractionMonitorId, fixture.monitors[1].id)
        }
        fixture.input.cycleSelection(forward: true, on: fixture.monitors[0].id)
        XCTAssertTrue(fixture.localHandles.contains(try XCTUnwrap(fixture.projection.selectedWindowHandle)))
    }

    func testArrowsAndTabTraverseEmptyRibbonsAndCreationTarget() throws {
        let fixture = try makeFixture(localWindowCount: 1)
        let monitorId = fixture.monitors[0].id
        let handle = try XCTUnwrap(fixture.localHandles.first)
        fixture.projection.selection = .window(handle)
        fixture.input.navigateSelection(.down, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .workspace(fixture.workspaceIds[1]))
        fixture.input.navigateSelection(.left, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .workspace(fixture.workspaceIds[1]))
        fixture.input.navigateSelection(.down, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .workspace(fixture.workspaceIds[2]))
        fixture.input.navigateSelection(.down, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .newWorkspace(monitorId))
        fixture.input.cycleSelection(forward: true, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .newWorkspace(monitorId))
        fixture.input.cycleSelection(forward: false, on: monitorId)
        XCTAssertEqual(fixture.projection.selection, .workspace(fixture.workspaceIds[2]))
    }

    func testHideEmptyWorkspacesFiltersOverviewSectionsAndSelection() throws {
        let fixture = try makeFixture(localWindowCount: 1, remoteWindowCount: 1)
        let monitorId = fixture.monitors[0].id
        let remoteMonitorId = fixture.monitors[1].id
        let original = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        XCTAssertEqual(original.workspaceSections.map(\.workspaceId), Array(fixture.workspaceIds.prefix(3)))
        XCTAssertTrue(OverviewNavigation.selections(in: original, searching: false).contains(
            .workspace(fixture.workspaceIds[1])
        ))

        fixture.projection.selection = .workspace(fixture.workspaceIds[1])
        fixture.controller.settings.workspaceBar.hideEmptyWorkspaces = true
        refreshWorkspaceSections(fixture)

        let hidden = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        XCTAssertEqual(hidden.workspaceSections.map(\.workspaceId), [fixture.workspaceIds[0]])
        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[remoteMonitorId]?.workspaceSections.map(\.workspaceId),
            [fixture.workspaceIds[3]]
        )
        XCTAssertEqual(fixture.projection.selection, .window(try XCTUnwrap(fixture.localHandles.first)))
        XCTAssertEqual(
            OverviewNavigation.selections(in: hidden, searching: false),
            [.window(try XCTUnwrap(fixture.localHandles.first)), .newWorkspace(monitorId)]
        )
        XCTAssertEqual(hidden.newWorkspaceTarget?.monitorId, monitorId)

        fixture.controller.settings.workspaceBar.hideEmptyWorkspaces = false
        refreshWorkspaceSections(fixture)

        let restored = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        XCTAssertEqual(restored.workspaceSections.map(\.workspaceId), Array(fixture.workspaceIds.prefix(3)))
        XCTAssertTrue(OverviewNavigation.selections(in: restored, searching: false).contains(
            .workspace(fixture.workspaceIds[2])
        ))
    }

    func testHideEmptyWorkspacesRetainsActiveEmptyWorkspace() throws {
        let fixture = try makeFixture(localWindowCount: 1)
        let manager = fixture.controller.workspaceManager
        let monitorId = fixture.monitors[0].id
        let emptyWorkspaceId = fixture.workspaceIds[1]
        fixture.controller.settings.workspaceBar.hideEmptyWorkspaces = true
        XCTAssertTrue(manager.setActiveWorkspace(emptyWorkspaceId, on: monitorId))
        refreshWorkspaceSections(fixture)

        let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        XCTAssertEqual(layout.workspaceSections.map(\.workspaceId), [fixture.workspaceIds[0], emptyWorkspaceId])
        let activeSection = try XCTUnwrap(layout.workspaceSections.last)
        XCTAssertTrue(activeSection.isActive)
        XCTAssertTrue(activeSection.isEmpty)
        XCTAssertTrue(OverviewNavigation.selections(in: layout, searching: false).contains(
            .workspace(emptyWorkspaceId)
        ))
        XCTAssertEqual(layout.newWorkspaceTarget?.monitorId, monitorId)

        fixture.projection.selection = .workspace(emptyWorkspaceId)
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspaceIds[0], on: monitorId))
        refreshWorkspaceSections(fixture)

        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[monitorId]?.workspaceSections.map(\.workspaceId),
            [fixture.workspaceIds[0]]
        )
        XCTAssertEqual(fixture.projection.selection, .window(try XCTUnwrap(fixture.localHandles.first)))
    }

    func testHideEmptyWorkspacesRespectsMonitorOverride() throws {
        let fixture = try makeFixture(localWindowCount: 1)
        let settings = fixture.controller.settings.workspaceBar
        let monitor = fixture.monitors[0]
        settings.hideEmptyWorkspaces = true
        settings.update(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                hideEmptyWorkspaces: false
            ),
            for: monitor
        )
        refreshWorkspaceSections(fixture)

        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[monitor.id]?.workspaceSections.map(\.workspaceId),
            Array(fixture.workspaceIds.prefix(3))
        )
        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[fixture.monitors[1].id]?.workspaceSections.map(\.workspaceId),
            [fixture.workspaceIds[3]]
        )

        settings.update(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                hideEmptyWorkspaces: true
            ),
            for: monitor
        )
        refreshWorkspaceSections(fixture)

        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[monitor.id]?.workspaceSections.map(\.workspaceId),
            [fixture.workspaceIds[0]]
        )
    }

    func testHideEmptyWorkspacesRefreshesOpenOverviewWhenToggled() throws {
        let fixture = try makeFixture(localWindowCount: 1)
        let controller = fixture.controller
        controller.toggleOverview()
        defer { controller.windowActionHandler.releaseOverviewController() }

        XCTAssertTrue(controller.isOverviewOpen())
        let panel = try XCTUnwrap(controller.ownedWindowRegistry.visibleWindows(kind: .overview)
            .compactMap { $0 as? OverviewWindow }
            .first { $0.monitorId == fixture.monitors[0].id })
        let view = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? OverviewView }.first)
        XCTAssertEqual(view.layout.workspaceSections.map(\.workspaceId), Array(fixture.workspaceIds.prefix(3)))

        controller.settings.workspaceBar.hideEmptyWorkspaces = true
        controller.updateWorkspaceBarSettings()

        XCTAssertTrue(controller.isOverviewOpen())
        XCTAssertEqual(view.layout.workspaceSections.map(\.workspaceId), [fixture.workspaceIds[0]])

        controller.settings.workspaceBar.hideEmptyWorkspaces = false
        controller.updateWorkspaceBarSettings()

        XCTAssertEqual(view.layout.workspaceSections.map(\.workspaceId), Array(fixture.workspaceIds.prefix(3)))
    }

    func testTypingAndClearingPreserveRibbonsStackOffsetAndStripPan() throws {
        let fixture = try makeFixture(localWindowCount: 5, remoteWindowCount: 2)
        let monitorId = fixture.monitors[0].id
        XCTAssertTrue(fixture.projection.panStrip(fixture.workspaceIds[0], by: -200, on: monitorId))
        fixture.projection.adjustScrollOffset(by: -175, on: monitorId)
        let before = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        XCTAssertNotEqual(before.scrollOffset, 0)
        XCTAssertNotEqual(before.stripPanByWorkspace[fixture.workspaceIds[0]], 0)
        let last = try XCTUnwrap(fixture.localHandles.last)
        for query in ["Document \(last.id.windowId)", "No matching title", ""] {
            fixture.input.updateSearchQuery(query)
            let after = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
            XCTAssertEqual(after.scrollOffset, before.scrollOffset)
            XCTAssertEqual(after.stripPanByWorkspace, before.stripPanByWorkspace)
            XCTAssertEqual(after.workspaceSections.map(\.workspaceId), before.workspaceSections.map(\.workspaceId))
            XCTAssertEqual(after.workspaceSections.map(\.visibleFrame), before.workspaceSections.map(\.visibleFrame))
            XCTAssertEqual(after.workspaceSections.map(\.ribbonFrame), before.workspaceSections.map(\.ribbonFrame))
            XCTAssertEqual(after.searchBarFrame, before.searchBarFrame)
            XCTAssertEqual(after.newWorkspaceTarget?.frame, before.newWorkspaceTarget?.frame)
            XCTAssertEqual(after.allWindows.map(\.overviewFrame), before.allWindows.map(\.overviewFrame))
        }
    }

    func testScrollSpeedAndDirectionApplyToBothAxesAndPreservePreciseInput() throws {
        for precise in [false, true] {
            for inverted in [false, true] {
                for speed in [0.05, 1.0, 2.0] {
                    let fixture = try makeFixture(localWindowCount: 8)
                    let projection = fixture.projection
                    let monitorId = fixture.monitors[0].id
                    let workspaceId = fixture.workspaceIds[0]
                    fixture.controller.settings.overview.invertScrollDirection = inverted
                    fixture.controller.settings.overview.mouseScrollSpeed = speed
                    projection.adjustScrollOffset(by: -175, on: monitorId)
                    let section = try XCTUnwrap(projection.layoutsByMonitor[monitorId]?.workspaceSections.first)
                    let content = section.windows.reduce(CGRect.null) { $0.union($1.overviewFrame) }
                    XCTAssertTrue(projection.panStrip(
                        workspaceId,
                        by: section.ribbonFrame.midX - content.midX,
                        on: monitorId
                    ))
                    let before = try XCTUnwrap(projection.layoutsByMonitor[monitorId])
                    let remote = try XCTUnwrap(projection.layoutsByMonitor[fixture.monitors[1].id])
                    let expected = (precise ? 3.5 : 40 * speed) * (inverted ? -1.0 : 1.0)
                    fixture.input.handleScroll(.init(
                        deltaX: 0, deltaY: 1, modifiers: [], isPrecise: precise, location: .zero
                    ), on: monitorId)
                    let vertical = try XCTUnwrap(projection.layoutsByMonitor[monitorId])
                    XCTAssertEqual(vertical.scrollOffset - before.scrollOffset, expected)
                    XCTAssertTrue(
                        vertical.stripPanRange(for: workspaceId).contains(expected),
                        "range \(vertical.stripPanRange(for: workspaceId)), expected \(expected), before \(before.stripPanRange(for: workspaceId))"
                    )
                    let ribbon = try XCTUnwrap(vertical.workspaceSections.first?.ribbonFrame)
                    let location = CGPoint(x: ribbon.midX, y: ribbon.midY - vertical.scrollOffset)
                    fixture.input.handleScroll(.init(
                        deltaX: 1, deltaY: 0, modifiers: [], isPrecise: precise, location: location
                    ), on: monitorId)
                    let horizontal = try XCTUnwrap(projection.layoutsByMonitor[monitorId])
                    XCTAssertEqual(
                        try XCTUnwrap(horizontal.allWindows.first).overviewFrame.minX
                            - XCTUnwrap(before.allWindows.first).overviewFrame.minX, expected
                    )
                    XCTAssertEqual(horizontal.scrollOffset, vertical.scrollOffset)
                    XCTAssertEqual(
                        projection.layoutsByMonitor[fixture.monitors[1].id]?.scrollOffset,
                        remote.scrollOffset
                    )
                    XCTAssertEqual(
                        projection.layoutsByMonitor[fixture.monitors[1].id]?.stripPanByWorkspace,
                        remote.stripPanByWorkspace
                    )
                }
            }
        }
    }

    func testScrollBoundsZoomAndDirectDragScrollIgnoreWheelPreferences() throws {
        let fixture = try makeFixture(localWindowCount: 5)
        let projection = fixture.projection
        let monitorId = fixture.monitors[0].id
        fixture.controller.settings.overview.invertScrollDirection = true
        fixture.controller.settings.overview.mouseScrollSpeed = 2
        projection.adjustScrollOffset(by: -100, on: monitorId)
        XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.scrollOffset, -100)
        for delta: CGFloat in [-10000, 10000] {
            fixture.input.handleScroll(.init(
                deltaX: 0, deltaY: delta, modifiers: [], isPrecise: false, location: .zero
            ), on: monitorId)
            let layout = try XCTUnwrap(projection.layoutsByMonitor[monitorId])
            let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
                layout: layout,
                screenFrame: fixture.monitors[0].frame
            )
            XCTAssertEqual(layout.scrollOffset, delta < 0 ? bounds.upperBound : bounds.lowerBound)
            let ribbon = try XCTUnwrap(layout.workspaceSections.first?.ribbonFrame)
            let location = CGPoint(x: ribbon.midX, y: ribbon.midY - layout.scrollOffset)
            fixture.input.handleScroll(.init(
                deltaX: delta, deltaY: 0, modifiers: [], isPrecise: false, location: location
            ), on: monitorId)
            let before = projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace
            fixture.input.handleScroll(.init(
                deltaX: delta, deltaY: 0, modifiers: [], isPrecise: false, location: location
            ), on: monitorId)
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace, before)
        }
        for precise in [false, true] {
            projection.scale = 1
            fixture.input.handleScroll(.init(
                deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: precise, location: .zero
            ), on: monitorId)
            XCTAssertEqual(projection.scale, 1.05)
        }
    }

    func testEndpointInputLeavesSelectionAndViewportUnchanged() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeFixture(localWindowCount: 5, orientation: orientation)
            let projection = fixture.projection
            let monitorId = fixture.monitors[0].id
            let first = try XCTUnwrap(fixture.localHandles.first)
            projection.selection = .window(first)
            projection.adjustScrollOffset(by: -175, on: monitorId)
            XCTAssertTrue(projection.panStrip(fixture.workspaceIds[0], by: -200, on: monitorId))
            let before = try XCTUnwrap(projection.layoutsByMonitor[monitorId])
            fixture.input.cycleSelection(forward: false, on: monitorId)
            XCTAssertEqual(fixture.input.handleHotkeyCommand(.focus(.left)), .handled)
            XCTAssertEqual(projection.selection, .window(first))
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.scrollOffset, before.scrollOffset)
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace, before.stripPanByWorkspace)
            projection.selection = .newWorkspace(monitorId)
            fixture.input.cycleSelection(forward: true, on: monitorId)
            fixture.input.navigateSelection(.down, on: monitorId)
            XCTAssertEqual(projection.selection, .newWorkspace(monitorId))
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.scrollOffset, before.scrollOffset)
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace, before.stripPanByWorkspace)
            fixture.input.updateSearchQuery("Document")
            let last = try XCTUnwrap(fixture.localHandles.last)
            projection.selection = .window(last)
            fixture.input.cycleSelection(forward: true, on: monitorId)
            XCTAssertEqual(
                fixture.input.handleHotkeyCommand(.focus(.right)),
                .handled
            )
            XCTAssertEqual(projection.selection, .window(last))
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.scrollOffset, before.scrollOffset)
            XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace, before.stripPanByWorkspace)
            let windows = try XCTUnwrap(projection.layoutsByMonitor[monitorId]).allWindows
            for direction in [Direction.up, .down] {
                let endpoint = try XCTUnwrap(windows.max {
                    direction == .up
                        ? $0.overviewFrame.midY < $1.overviewFrame.midY
                        : $0.overviewFrame.midY > $1.overviewFrame.midY
                })
                projection.selection = .window(endpoint.handle)
                XCTAssertEqual(fixture.input.handleHotkeyCommand(.focus(direction)), .handled)
                XCTAssertEqual(projection.selection, .window(endpoint.handle))
                XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.scrollOffset, before.scrollOffset)
                XCTAssertEqual(projection.layoutsByMonitor[monitorId]?.stripPanByWorkspace, before.stripPanByWorkspace)
            }
        }
    }

    func testWheelRetargetsAndEndpointInputDoesNotRestartOrAffectOtherMonitor() throws {
        let fixture = try makeFixture(localWindowCount: 8, remoteWindowCount: 8)
        let views = try makeViews(in: fixture)
        defer { fixture.windowSession.closeWindows() }
        let local = views[0].layerRenderer
        let monitorId = fixture.monitors[0].id
        let before = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId]?.scrollOffset)
        let wheel = OverviewScrollInput.Event(
            deltaX: 0, deltaY: -1, modifiers: [], isPrecise: false, location: .zero
        )
        fixture.input.handleScroll(wheel, on: monitorId)
        fixture.input.handleScroll(wheel, on: monitorId)
        XCTAssertEqual(fixture.projection.layoutsByMonitor[monitorId]?.scrollOffset, before - 80)
        let motion = try XCTUnwrap(local.content.animation(forKey: "overview.position") as? CABasicAnimation)
        fixture.input.handleScroll(
            .init(deltaX: 0, deltaY: 0, modifiers: [], isPrecise: true, location: .zero),
            on: fixture.monitors[1].id
        )
        XCTAssertEqual(local.content.animation(forKey: "overview.position")?.beginTime, motion.beginTime)

        let endpoint = OverviewScrollInput.Event(
            deltaX: 0, deltaY: -10000, modifiers: [], isPrecise: false, location: .zero
        )
        fixture.input.handleScroll(endpoint, on: monitorId)
        let endpointMotion = try XCTUnwrap(local.content.animation(forKey: "overview.position"))
        fixture.input.handleScroll(endpoint, on: monitorId)
        fixture.input.handleScroll(
            .init(deltaX: 0, deltaY: 0, modifiers: [], isPrecise: false, location: .zero),
            on: monitorId
        )
        XCTAssertEqual(local.content.animation(forKey: "overview.position")?.beginTime, endpointMotion.beginTime)
        fixture.input.handleScroll(
            .init(deltaX: 0, deltaY: 1, modifiers: [], isPrecise: true, location: .zero),
            on: monitorId
        )
        XCTAssertNil(local.content.animation(forKey: "overview.position"))
        fixture.input.handleScroll(.init(
            deltaX: 0, deltaY: 1, modifiers: [], isPrecise: false, location: .zero
        ), on: monitorId)
        XCTAssertNotNil(local.content.animation(forKey: "overview.position"))
        fixture.input.handleScroll(.init(
            deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: false, location: .zero
        ), on: fixture.monitors[1].id)
        XCTAssertFalse(local.isReflowing)
        XCTAssertNil(local.content.animation(forKey: "overview.position"))
    }

    func testPillPagingAnimatesBothOrientationsAndZoomCancelsEasing() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeFixture(localWindowCount: 8, orientation: orientation)
            let views = try makeViews(in: fixture)
            defer { fixture.windowSession.closeWindows() }
            let monitorId = fixture.monitors[0].id
            let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
            let section = try XCTUnwrap(layout.workspaceSections.first)
            let pill = try XCTUnwrap(layout.overflowPills(for: section).first)
            fixture.input.pageStrip(pill, on: monitorId)
            let renderer = views[0].layerRenderer
            XCTAssertTrue(renderer.isReflowing)
            XCTAssertTrue(renderer.windowLayers.values
                .contains { $0.root.animation(forKey: "overview.position") != nil })
            fixture.input.handleScroll(.init(
                deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: false, location: .zero
            ), on: monitorId)
            XCTAssertFalse(renderer.isReflowing)
        }
    }

    func testKeyboardRevealUsesPillSpringWithoutRestartingUnchangedViewports() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for route in 0 ... 2 {
                let fixture = try makeFixture(localWindowCount: 8, remoteWindowCount: 8, orientation: orientation)
                fixture.input.updateSearchQuery("Document")
                let monitorId = fixture.monitors[0].id
                fixture.projection.selection = .window(fixture.localHandles[0])
                fixture.projection.revealSelectedWindow(on: monitorId)
                let views = try makeViews(in: fixture)
                defer { fixture.windowSession.closeWindows() }
                let remoteId = fixture.monitors[1].id
                let remoteLayout = try XCTUnwrap(fixture.projection.layoutsByMonitor[remoteId])
                let section = try XCTUnwrap(remoteLayout.workspaceSections.first)
                fixture.input.pageStrip(try XCTUnwrap(remoteLayout.overflowPills(for: section).first), on: remoteId)
                let remoteCard = try XCTUnwrap(views[1].layerRenderer.windowLayers.values.first {
                    $0.root.animation(forKey: "overview.position") != nil
                })
                let remoteStart = try XCTUnwrap(remoteCard.root.animation(forKey: "overview.position")).beginTime
                fixture.projection.activeInteractionMonitorId = monitorId

                for handle in fixture.localHandles.dropFirst() {
                    switch route {
                    case 0:
                        XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(kVK_Tab)))
                    case 1:
                        XCTAssertTrue(fixture.input.handleKeyDown(try keyEvent(
                            orientation == .horizontal ? kVK_RightArrow : kVK_UpArrow
                        )))
                    default:
                        XCTAssertEqual(fixture.input.handleHotkeyCommand(.focus(
                            orientation == .horizontal ? .right : .up
                        )), .handled)
                    }
                    XCTAssertEqual(
                        fixture.projection.selectedWindowHandle?.windowId, handle.windowId,
                        "\(orientation), route \(route)"
                    )
                }

                let card = try XCTUnwrap(views[0].layerRenderer.windowLayers.values.first {
                    $0.root.animation(forKey: "overview.position") != nil
                })
                let spring = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
                let frequency = CGFloat(2 * Double.pi / OverviewNativeTransition.response)
                XCTAssertEqual(spring.stiffness, frequency * frequency)
                XCTAssertEqual(spring.damping, 2 * sqrt(spring.stiffness * spring.mass))
                fixture.input.cycleSelection(forward: true, on: monitorId)
                XCTAssertEqual(card.root.animation(forKey: "overview.position")?.beginTime, spring.beginTime)
                fixture.input.cycleSelection(forward: false, on: monitorId)
                XCTAssertEqual(fixture.projection.selection, .window(fixture.localHandles[6]))
                XCTAssertEqual(card.root.animation(forKey: "overview.position")?.beginTime, spring.beginTime)
                XCTAssertEqual(remoteCard.root.animation(forKey: "overview.position")?.beginTime, remoteStart)
            }
        }
    }

    func testKeyboardWorkspaceRevealAnimatesOnlyWhenMotionIsEnabled() throws {
        for animationsEnabled in [true, false] {
            let fixture = try makeFixture(localWindowCount: 1)
            let views = try makeViews(in: fixture)
            defer { fixture.windowSession.closeWindows() }
            fixture.controller.motionPolicy.animationsEnabled = animationsEnabled
            let monitorId = fixture.monitors[0].id
            fixture.projection.selection = .window(fixture.localHandles[0])
            fixture.projection.revealSelectedWindow(on: monitorId)
            fixture.windowSession.updateWindowDisplays(state: .open, update: .immediate)
            let initialOffset = fixture.projection.layoutsByMonitor[monitorId]?.scrollOffset

            for _ in 0 ..< 3 { fixture.input.cycleSelection(forward: true, on: monitorId) }

            XCTAssertEqual(fixture.projection.selection, .newWorkspace(monitorId))
            XCTAssertNotEqual(fixture.projection.layoutsByMonitor[monitorId]?.scrollOffset, initialOffset)
            XCTAssertEqual(
                views[0].layerRenderer.content.animation(forKey: "overview.position") != nil,
                animationsEnabled
            )
        }
    }

    private func makeViews(in fixture: Fixture) throws -> [OverviewView] {
        fixture.controller.motionPolicy.animationsEnabled = true
        fixture.windowSession.createWindows(controller: fixture.overview, monitors: fixture.monitors, palette: .default)
        fixture.windowSession.updateWindowDisplays(state: .open, update: .immediate)
        return try fixture.monitors.map { monitor in
            fixture.projection.activeInteractionMonitorId = monitor.id
            let panel = try XCTUnwrap(fixture.windowSession.primaryOverviewWindow())
            let view = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? OverviewView }.first)
            view.updateLayer()
            return view
        }
    }

    private struct Fixture {
        let controller: WMController
        let overview: OverviewController
        let snapshot: OverviewSnapshot
        let projection: OverviewViewportProjection
        let input: OverviewInputHandler
        let windowSession: OverviewWindowSession
        let monitors: [Monitor]
        let workspaceIds: [WorkspaceDescriptor.ID]
        let localHandles: [WindowHandle]
        let remoteHandles: [WindowHandle]
    }

    private func makeFixture(
        localWindowCount: Int = 0,
        remoteWindowCount: Int = 0,
        orientation: Monitor.Orientation = .horizontal
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewSelectionUX-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        let monitors = (0 ... 1).map { index in
            let displayId = CGDirectDisplayID(98_300 + index)
            let width = orientation == .horizontal ? 1600 : 900
            let height = orientation == .horizontal ? 900 : 1600
            let frame = CGRect(x: index * width, y: 0, width: width, height: height)
            return Monitor(
                id: .init(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
                hasNotch: false, name: "Selection UX \(index)"
            )
        }
        settings.workspaces.configurations = (0 ... 3).map { index in
            WorkspaceConfiguration(
                name: String(index + 1),
                monitorAssignment: .specificDisplay(OutputId(from: monitors[index == 3 ? 1 : 0])),
                layoutType: .niri
            )
        }
        for monitor in monitors {
            settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(monitorName: monitor.name, orientation: orientation), for: monitor
            )
        }
        let controller = WMController(settings: settings, windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
        ))
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange(monitors)
        manager.applySettings()
        let workspaceIds = try (1 ... 4).map { try XCTUnwrap(manager.workspaceId(named: String($0))) }
        XCTAssertTrue(manager.setActiveWorkspace(workspaceIds[0], on: monitors[0].id))
        XCTAssertTrue(manager.setActiveWorkspace(workspaceIds[3], on: monitors[1].id))
        _ = manager.setInteractionMonitor(monitors[0].id)
        let engine = NiriLayoutEngine()
        controller.niriEngine = engine
        controller.syncMonitorsToNiriEngine()
        let localHandles = addWindows(localWindowCount, to: workspaceIds[0], startingAt: 98_310, controller: controller)
        let remoteHandles = addWindows(
            remoteWindowCount,
            to: workspaceIds[3],
            startingAt: 98_330,
            controller: controller
        )
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        var environment = OverviewEnvironment()
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.addLocalEventMonitor = { _, _ in nil }
        environment.notificationCenter = NotificationCenter()
        environment.schedulePostCloseHandoff = { $0() }
        environment.windowTitle = { "Document \($0.windowId)" }
        environment.windowFrame = { _ in CGRect(x: 100, y: 100, width: 800, height: 600) }
        let overview = OverviewController(
            wmController: controller, motionPolicy: controller.motionPolicy, environment: environment
        )
        overview.onActivateWorkspace = controller.workspaceNavigationHandler.activateOverviewWorkspace
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let snapshot = OverviewSnapshot(
            wmController: controller, facts: OverviewWindowFacts(wmController: controller, environment: environment)
        )
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: 1)
        projection.activeInteractionMonitorId = monitors[0].id
        projection.rebuildProjectedLayouts()
        let windowSession = OverviewWindowSession(
            projection: projection, ownedWindowRegistry: .shared, motionPolicy: controller.motionPolicy
        )
        let input = OverviewInputHandler(projection: projection, windowSession: windowSession, snapshot: snapshot)
        input.connect(controller: overview)
        return Fixture(
            controller: controller, overview: overview, snapshot: snapshot, projection: projection, input: input,
            windowSession: windowSession,
            monitors: monitors, workspaceIds: workspaceIds, localHandles: localHandles, remoteHandles: remoteHandles
        )
    }

    private func refreshWorkspaceSections(_ fixture: Fixture) {
        fixture.snapshot.refresh(affectedWorkspaceIds: [])
        fixture.projection.rebuildProjectedLayouts()
    }

    private func addWindows(
        _ count: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        startingAt seed: Int,
        controller: WMController
    ) -> [WindowHandle] {
        let manager = controller.workspaceManager
        var lastNode: NiriWindow?
        return (0 ..< count).compactMap { offset in
            let number = seed + offset
            let token = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid_t(number)), windowId: number),
                pid: pid_t(number), windowId: number, to: workspaceId
            )
            lastNode = manager.withEngineMutationScope {
                controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: lastNode?.id)
            }
            return manager.handle(for: token)
        }
    }

    private func keyEvent(_ code: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
        ))
    }

    private func settle(_ controller: WMController) async {
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }
}
