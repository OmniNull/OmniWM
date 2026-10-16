// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class OverviewDwindleProjectionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testProjectionIncludesEveryGroupMemberWithSharedContentFrame() throws {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertTrue(projection.includes(fixture.second))
        XCTAssertTrue(projection.includes(fixture.standalone))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.second, fixture.standalone])
        let tile = try XCTUnwrap(fixture.engine.tileSnapshot(for: fixture.first, in: fixture.workspaceId))
        let group = try XCTUnwrap(projection.groups.first)
        XCTAssertEqual(group.id, tile.id)
        XCTAssertEqual(group.tokens, tile.members.map(\.token))
        XCTAssertEqual(group.activeToken, fixture.second)
        XCTAssertEqual(projection.frames[fixture.first], tile.contentFrame)
        XCTAssertEqual(projection.frames[fixture.second], tile.contentFrame)
    }

    func testProjectionTracksActiveMemberChangesWithoutUsingParkedFrame() {
        let fixture = makeGroupedFixture()

        XCTAssertEqual(fixture.engine.activateWindowOutcome(fixture.first, in: fixture.workspaceId), .activated)
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)

        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertTrue(projection.includes(fixture.second))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.second, fixture.standalone])
        XCTAssertEqual(projection.groups.first?.activeToken, fixture.first)
        XCTAssertEqual(projection.frames[fixture.first], projection.frames[fixture.second])
    }

    func testProjectionPromotesRemainingMemberAfterActiveMemberRemoval() {
        let fixture = makeGroupedFixture()

        let removed = fixture.engine.syncWindows(
            [fixture.first, fixture.standalone],
            in: fixture.workspaceId,
            focusedToken: fixture.first
        )
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertEqual(removed, [fixture.second])
        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.standalone])
        XCTAssertTrue(projection.groups.isEmpty)
    }

    func testProjectionPromotesEligibleMemberWhenActiveMemberIsIneligible() {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.standalone]
        )

        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertFalse(projection.includes(fixture.second))
        XCTAssertTrue(projection.includes(fixture.standalone))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.standalone])
        XCTAssertTrue(projection.groups.isEmpty)
    }

    func testProjectionExcludesIneligibleInactiveMemberFromGroups() {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.second, fixture.standalone]
        )

        XCTAssertFalse(projection.includes(fixture.first))
        XCTAssertTrue(projection.includes(fixture.second))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.second, fixture.standalone])
        XCTAssertTrue(projection.groups.isEmpty)
    }

    @MainActor
    func testOverviewSearchCachesEveryMemberThroughRefreshZoomAndClear() throws {
        let fixture = try makeOverviewFixture()
        let overview = fixture.overview
        let controller = fixture.controller
        let engine = fixture.engine
        let workspaceId = fixture.workspaceId
        let first = fixture.first
        let second = fixture.second
        let rememberedFocus = controller.workspaceManager.lastFocusedToken(in: workspaceId)
        let originalZoom = controller.settings.overview.zoom
        let firstHandle = try XCTUnwrap(controller.workspaceManager.handle(for: first))

        XCTAssertEqual(overview.selectedWindowHandle?.id, second)
        XCTAssertEqual(fixture.reads.titles, 2)
        XCTAssertEqual(fixture.reads.frames, 0)

        overview.input.updateSearchQuery("Budget")
        XCTAssertTrue(overview.selectedWindowHandle === firstHandle)
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [workspaceId])
        XCTAssertTrue(overview.selectedWindowHandle === firstHandle)
        overview.input.handleScroll(.init(
            deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: false, location: .zero
        ), on: fixture.monitor.id)
        overview.input.updateSearchQuery("")
        XCTAssertTrue(overview.selectedWindowHandle === firstHandle)
        overview.input.selectTab(firstHandle, on: fixture.monitor.id)
        XCTAssertEqual(engine.activeToken(in: workspaceId), second)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), rememberedFocus)
        XCTAssertEqual(fixture.reads.focusCalls, 0)
        XCTAssertEqual(fixture.reads.titles, 2)
        XCTAssertEqual(fixture.reads.frames, 0)

        let removedEntry = try XCTUnwrap(controller.workspaceManager.entry(for: second))
        _ = controller.workspaceManager.removeWindow(pid: second.pid, windowId: second.windowId)
        overview.handleManagedWindowRemoved(removedEntry)
        let removed = controller.workspaceManager.withEngineMutationScope {
            let removed = engine.syncWindows([first], in: workspaceId, focusedToken: first)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            return removed
        }
        XCTAssertEqual(removed, [second])
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [workspaceId], selectedHandle: firstHandle)
        XCTAssertTrue(overview.selectedWindowHandle === firstHandle)
        XCTAssertEqual(fixture.reads.titles, 2)
        overview.dismiss(reason: .cancel, animated: false)
        XCTAssertEqual(controller.settings.overview.zoom, originalZoom + 0.05, accuracy: 0.0001)
    }

    @MainActor
    func testSnapshotRefreshPrunesHiddenMembersAndCollapsedGroups() throws {
        let fixture = try makeOverviewFixture()
        let manager = fixture.controller.workspaceManager
        let snapshot = OverviewSnapshot(
            wmController: fixture.controller,
            facts: OverviewWindowFacts(wmController: fixture.controller, environment: fixture.environment)
        )
        snapshot.build()
        let firstHandle = try XCTUnwrap(manager.handle(for: fixture.first))
        let secondHandle = try XCTUnwrap(manager.handle(for: fixture.second))
        let group = try XCTUnwrap(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId]?.first)
        XCTAssertEqual(Set(group.windowHandles), [firstHandle, secondHandle])
        XCTAssertTrue(group.activeHandle === secondHandle)
        XCTAssertEqual(snapshot.windows[firstHandle]?.frame, snapshot.windows[secondHandle]?.frame)
        let titleReads = fixture.reads.titles

        manager.setAppHidden(true, pid: fixture.second.pid, source: .service)
        snapshot.refresh(affectedWorkspaceIds: [fixture.workspaceId])
        XCTAssertNil(snapshot.windows[secondHandle])
        XCTAssertNotNil(snapshot.windows[firstHandle])
        XCTAssertNil(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId])
        XCTAssertEqual(fixture.reads.titles, titleReads)

        manager.setAppHidden(false, pid: fixture.second.pid, source: .service)
        snapshot.refresh(affectedWorkspaceIds: [fixture.workspaceId])
        XCTAssertEqual(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId]?.first?.windowHandles.count, 2)
        XCTAssertEqual(fixture.reads.titles, titleReads + 1)

        _ = manager.removeWindow(pid: fixture.first.pid, windowId: fixture.first.windowId)
        manager.withEngineMutationScope {
            fixture.engine.removeWindow(token: fixture.first, from: fixture.workspaceId)
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        }
        snapshot.refresh(affectedWorkspaceIds: [fixture.workspaceId])
        XCTAssertNil(snapshot.windows[firstHandle])
        XCTAssertNotNil(snapshot.windows[secondHandle])
        XCTAssertNil(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId])
        XCTAssertEqual(fixture.reads.titles, titleReads + 1)
        XCTAssertEqual(fixture.reads.frames, 0)
    }

    @MainActor
    func testSnapshotRefreshRemovesGroupsWhenWorkspaceChangesLayout() throws {
        let fixture = try makeOverviewFixture()
        let snapshot = OverviewSnapshot(
            wmController: fixture.controller,
            facts: OverviewWindowFacts(wmController: fixture.controller, environment: fixture.environment)
        )
        snapshot.build()
        XCTAssertNotNil(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId])

        fixture.controller.settings.workspaces.configurations = [WorkspaceConfiguration(name: "97", layoutType: .niri)]
        snapshot.refresh(affectedWorkspaceIds: [fixture.workspaceId])

        XCTAssertNil(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId])
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    @MainActor
    func testDwindleSearchCountsAndTraversalRemainMonitorLocal() throws {
        let fixture = try makeOverviewFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let remoteFrame = screen.offsetBy(dx: screen.width, dy: 0)
        let remote = Monitor(
            id: .init(displayId: 92_002), displayId: 92_002, frame: remoteFrame, visibleFrame: remoteFrame,
            hasNotch: false, name: "Overview Dwindle Remote"
        )
        manager.applyMonitorConfigurationChange([fixture.monitor, remote])
        controller.settings.workspaces.configurations.append(WorkspaceConfiguration(
            name: "98", monitorAssignment: .specificDisplay(OutputId(from: remote)), layoutType: .dwindle
        ))
        manager.applySettings()
        let remoteWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "98"))
        manager.assignWorkspaceToMonitor(fixture.workspaceId, monitorId: fixture.monitor.id)
        manager.assignWorkspaceToMonitor(remoteWorkspaceId, monitorId: remote.id)
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspaceId, on: fixture.monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(remoteWorkspaceId, on: remote.id))
        XCTAssertEqual(manager.monitorForWorkspace(fixture.workspaceId)?.id, fixture.monitor.id)
        XCTAssertEqual(manager.monitorForWorkspace(remoteWorkspaceId)?.id, remote.id)
        let tokens = (3 ... 4).map { index in
            let pid = pid_t(92_100 + index)
            let windowId = 92_200 + index
            return manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: remoteWorkspaceId
            )
        }
        manager.withEngineMutationScope {
            for token in tokens {
                _ = fixture.engine.addWindow(token: token, to: remoteWorkspaceId, activeWindowFrame: nil)
            }
            _ = fixture.engine.calculateLayout(for: remoteWorkspaceId, screen: remoteFrame)
            _ = fixture.engine.groupWindow(direction: .left, in: remoteWorkspaceId)
            _ = fixture.engine.calculateLayout(for: remoteWorkspaceId, screen: remoteFrame)
        }
        let snapshot = OverviewSnapshot(
            wmController: controller, facts: OverviewWindowFacts(
                wmController: controller,
                environment: fixture.environment
            )
        )
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: 1)
        projection.activeInteractionMonitorId = fixture.monitor.id
        projection.searchQuery = "Meeting"
        projection.rebuildProjectedLayouts()

        let localLayout = try XCTUnwrap(projection.layoutsByMonitor[fixture.monitor.id])
        let remoteLayout = try XCTUnwrap(projection.layoutsByMonitor[remote.id])
        XCTAssertEqual(localLayout.searchResultCount, 1)
        XCTAssertEqual(remoteLayout.searchResultCount, 2)
        XCTAssertEqual(Set(localLayout.allWindows.map { $0.handle.id }), [fixture.first, fixture.second])
        XCTAssertEqual(Set(remoteLayout.allWindows.map { $0.handle.id }), Set(tokens))
        for _ in 0 ..< 3 {
            _ = projection.performSelectionNavigation(on: remote.id) { layout, selection in
                OverviewNavigation.cycledSelection(in: layout, from: selection, forward: true, searching: true)
            }
            XCTAssertTrue(tokens.contains(try XCTUnwrap(projection.selectedWindowHandle?.id)))
        }
    }

    @MainActor
    func testCancelLeavesPreviewedGroupMemberInactive() throws {
        let fixture = try makeOverviewFixture()
        let overview = fixture.overview
        overview.onPrepareActivation = fixture.controller.windowActionHandler.prepareOverviewSelection
        overview.input.updateSearchQuery("Budget")
        XCTAssertEqual(overview.selectedWindowHandle?.id, fixture.first)

        overview.dismiss(reason: .cancel, animated: false)

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.second)
        XCTAssertEqual(fixture.reads.focusCalls, 0)
        guard case .closed = overview.state else { return XCTFail("Expected canceled overview to close") }
    }

    @MainActor
    func testSelectionActivatesPreviewedMemberOnlyWhenClosing() async throws {
        let fixture = try makeOverviewFixture()
        let overview = fixture.overview
        let target = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.first))
        var activated: [WindowHandle] = []
        overview.onPrepareActivation = fixture.controller.windowActionHandler.prepareOverviewSelection
        overview.onActivateWindow = { handle, _ in activated.append(handle) }
        overview.input.updateSearchQuery("Budget")
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.second)

        overview.input.activateSelectedWindow()

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.first)
        XCTAssertEqual(activated, [target])
        XCTAssertEqual(fixture.reads.focusCalls, 0)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask {
            await task.value
        }
    }

    @MainActor
    func testCloseTargetsInactivePreviewAndReplacesRemovedSelection() throws {
        let fixture = try makeOverviewFixture()
        let manager = fixture.controller.workspaceManager
        let overview = fixture.overview
        let target = try XCTUnwrap(manager.handle(for: fixture.first))
        var closed: [WindowHandle] = []
        overview.onCloseWindow = { handle in
            closed.append(handle)
            return true
        }
        overview.input.updateSearchQuery("Budget")
        XCTAssertTrue(overview.selectedWindowHandle === target)

        overview.input.closeSelectedWindow()

        XCTAssertEqual(closed, [target])
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.second)
        let removedEntry = try XCTUnwrap(manager.entry(for: fixture.first))
        _ = manager.removeWindow(pid: fixture.first.pid, windowId: fixture.first.windowId)
        manager.withEngineMutationScope {
            fixture.engine.removeWindow(token: fixture.first, from: fixture.workspaceId)
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        }
        overview.handleManagedWindowRemoved(removedEntry)

        XCTAssertNil(overview.selectedWindowHandle)
        overview.input.updateSearchQuery("")
        XCTAssertEqual(overview.selectedWindowHandle?.id, fixture.second)
        XCTAssertEqual(fixture.engine.tileSnapshot(for: fixture.second, in: fixture.workspaceId)?.members.count, 1)
        XCTAssertEqual(fixture.reads.titles, 2)
        XCTAssertEqual(fixture.reads.focusCalls, 0)
        guard case .open = overview.state else { return XCTFail("Closing a member must leave Overview open") }
    }

    @MainActor
    func testTransferMovesOnlyInactivePreviewAndRefreshesItsWorkspace() async throws {
        let fixture = try makeOverviewFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let overview = fixture.overview
        controller.settings.workspaces.configurations.append(WorkspaceConfiguration(name: "98", layoutType: .dwindle))
        manager.applySettings()
        let destination = try XCTUnwrap(manager.workspaceId(named: "98"))
        XCTAssertEqual(manager.monitorForWorkspace(destination)?.id, fixture.monitor.id)
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId, destination])
        let target = try XCTUnwrap(manager.handle(for: fixture.first))
        let remaining = try XCTUnwrap(manager.handle(for: fixture.second))
        let snapshot = OverviewSnapshot(
            wmController: controller,
            facts: OverviewWindowFacts(wmController: controller, environment: fixture.environment)
        )
        snapshot.build()
        let titleReads = fixture.reads.titles
        overview.input.updateSearchQuery("Budget")
        XCTAssertTrue(overview.selectedWindowHandle === target)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.second)

        let outcome = overview.executeStructuralHotkey(.workspace(.moveTo(97)), selectedHandle: target)
        let mutation = try XCTUnwrap(outcome?.mutation)
        XCTAssertEqual(mutation.sourceWorkspaceId, fixture.workspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destination)
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask {
            await task.value
        }

        XCTAssertEqual(manager.workspace(for: fixture.first), destination)
        XCTAssertEqual(manager.workspace(for: fixture.second), fixture.workspaceId)
        XCTAssertNil(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
        XCTAssertNotNil(fixture.engine.findNode(for: fixture.first, in: destination))
        XCTAssertEqual(fixture.engine.tileSnapshot(for: fixture.second, in: fixture.workspaceId)?.members.count, 1)
        XCTAssertTrue(overview.selectedWindowHandle === target)
        snapshot.refresh(affectedWorkspaceIds: mutation.affectedWorkspaceIds)
        XCTAssertEqual(snapshot.windows[target]?.workspaceId, destination)
        XCTAssertEqual(snapshot.windows[remaining]?.workspaceId, fixture.workspaceId)
        XCTAssertNil(snapshot.dwindleGroupsByWorkspace[fixture.workspaceId])
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: 1)
        projection.searchQuery = "Budget"
        projection.rebuildProjectedLayouts()
        let layout = try XCTUnwrap(projection.layoutsByMonitor[fixture.monitor.id])
        XCTAssertEqual(layout.searchResultCount, 1)
        XCTAssertEqual(layout.window(for: target)?.workspaceId, destination)
        XCTAssertEqual(fixture.reads.titles, titleReads)
        XCTAssertEqual(fixture.reads.focusCalls, 0)
        guard case .open = overview.state else { return XCTFail("Transferring a member must leave Overview open") }
    }

    @MainActor
    private final class Reads {
        var titles = 0
        var frames = 0
        var focusCalls = 0
    }

    @MainActor
    private struct OverviewFixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let overview: OverviewController
        let environment: OverviewEnvironment
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let first: WindowToken
        let second: WindowToken
        let reads: Reads
    }

    @MainActor
    private func makeOverviewFixture() throws -> OverviewFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewDwindleProjectionTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        let reads = Reads()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in reads.focusCalls += 1 },
                focusSpecificWindow: { _, _, _ in reads.focusCalls += 1 },
                raiseWindow: { _ in reads.focusCalls += 1 }
            )
        )
        controller.settings.workspaces.configurations.append(
            WorkspaceConfiguration(name: "97", layoutType: .dwindle)
        )
        let monitor = Monitor(
            id: .init(displayId: 92_001),
            displayId: 92_001,
            frame: screen,
            visibleFrame: screen,
            hasNotch: false,
            name: "Overview Dwindle"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "97"))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let first = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_101), windowId: 92_201),
            pid: 92_101,
            windowId: 92_201,
            to: workspaceId
        )
        let second = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_102), windowId: 92_202),
            pid: 92_102,
            windowId: 92_202,
            to: workspaceId
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            _ = engine.groupWindow(direction: .left, in: workspaceId)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
        }

        var environment = OverviewEnvironment()
        environment.frontmostApplicationPID = { nil }
        environment.schedulePostCloseHandoff = { $0() }
        environment.windowTitle = { entry in
            reads.titles += 1
            return entry.token == first ? "Budget draft" : "Meeting notes"
        }
        environment.windowFrame = { _ in
            reads.frames += 1
            return .zero
        }
        let overview = OverviewController(
            wmController: controller,
            motionPolicy: controller.motionPolicy,
            environment: environment
        )

        overview.prepareOpenState()

        overview.onAnimationComplete(state: .open)
        return OverviewFixture(
            controller: controller, engine: engine, overview: overview, environment: environment,
            workspaceId: workspaceId, monitor: monitor, first: first, second: second, reads: reads
        )
    }

    private func makeGroupedFixture() -> (
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        first: WindowToken,
        second: WindowToken,
        standalone: WindowToken
    ) {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let standalone = WindowToken(pid: 3, windowId: 3)

        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        _ = engine.groupWindow(direction: .left, in: workspaceId)
        _ = engine.addWindow(token: standalone, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        return (engine, workspaceId, first, second, standalone)
    }
}
