// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewViewportCommitTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let primary: Monitor
        let secondary: Monitor
        let workspaces: [WorkspaceDescriptor.ID]
        let tokens: [[WindowToken]]
    }

    func testCommitPreservesSelectionAndAppliesOnlyActiveWorkspaceFrames() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let initial = manager.niriViewportState(for: fixture.workspaces[0])
        let inactive = try XCTUnwrap(engine.findNode(for: fixture.tokens[2][0], in: fixture.workspaces[2]))
        XCTAssertNil(inactive.frame)

        let committed = fixture.controller.niriLayoutHandler.commitOverviewPans([
            fixture.workspaces[0]: -1400,
            fixture.workspaces[2]: 275
        ])

        XCTAssertEqual(committed, [fixture.workspaces[0], fixture.workspaces[2]])
        let state = manager.niriViewportState(for: fixture.workspaces[0])
        XCTAssertEqual(state.viewOffset, 1400)
        XCTAssertEqual(state.selectedNodeId, initial.selectedNodeId)
        XCTAssertEqual(state.activeColumnIndex, initial.activeColumnIndex)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[2]).viewOffset, -275)
        XCTAssertNotNil(engine.findNode(for: fixture.tokens[0][0], in: fixture.workspaces[0])?.renderedFrame)
        XCTAssertNil(inactive.frame)
        XCTAssertNil(inactive.renderedFrame)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
    }

    func testCommittedPansTranslateHorizontalAndVerticalSnapshotsInDesktopUnits() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.niriLayoutHandler
        let primaryBefore = try XCTUnwrap(handler.overviewSnapshot(for: fixture.workspaces[0]))
        let secondaryBefore = try XCTUnwrap(handler.overviewSnapshot(for: fixture.workspaces[1]))
        XCTAssertEqual(secondaryBefore.strip?.orientation, .vertical)

        handler.commitOverviewPans([fixture.workspaces[0]: -120, fixture.workspaces[1]: 185])

        let primaryAfter = try XCTUnwrap(handler.overviewSnapshot(for: fixture.workspaces[0]))
        let secondaryAfter = try XCTUnwrap(handler.overviewSnapshot(for: fixture.workspaces[1]))
        let firstBefore = try XCTUnwrap(primaryBefore.columns.first?.tiles.first?.stripFrame)
        let firstAfter = try XCTUnwrap(primaryAfter.columns.first?.tiles.first?.stripFrame)
        let secondBefore = try XCTUnwrap(secondaryBefore.columns.first?.tiles.first?.stripFrame)
        let secondAfter = try XCTUnwrap(secondaryAfter.columns.first?.tiles.first?.stripFrame)
        XCTAssertEqual(firstAfter, firstBefore.offsetBy(dx: -120, dy: 0))
        XCTAssertEqual(secondAfter, secondBefore.offsetBy(dx: 0, dy: 185))
    }

    func testCommitCancelsMotionAndItsDisplayRegistration() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let workspaceId = fixture.workspaces[0]
        var state = manager.niriViewportState(for: workspaceId)
        state.springOffset(to: 300)
        XCTAssertTrue(manager.applySessionPatch(.init(
            workspaceId: workspaceId, viewportState: state, plannedSeq: manager.worldSeq
        )))
        XCTAssertTrue(manager.animationDriver.hasMotion(in: workspaceId))
        _ = fixture.controller.niriLayoutHandler.registerScrollAnimation(workspaceId, on: fixture.primary.displayId)

        fixture.controller.niriLayoutHandler.commitOverviewPans([workspaceId: 25])

        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 275)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: workspaceId))
    }

    func testOverviewSelectionAndDeferredNavigationPreserveOtherMonitorPan() async throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let workspaceId = fixture.workspaces[0]
        let otherWorkspaceId = fixture.workspaces[1]
        let handler = fixture.controller.windowActionHandler
        fixture.controller.niriLayoutHandler.commitOverviewPans([
            workspaceId: -1400,
            otherWorkspaceId: -1100
        ])
        let token = try XCTUnwrap(fixture.tokens[0].last)
        let target = try XCTUnwrap(manager.handle(for: token))

        handler.prepareOverviewSelection(handle: target, workspaceId: workspaceId)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        let selectionOffset = manager.niriViewportState(for: workspaceId).viewOffset
        XCTAssertNotEqual(selectionOffset, 1400)
        XCTAssertEqual(manager.niriViewportState(for: otherWorkspaceId).viewOffset, 1100)
        XCTAssertTrue(handler.navigateToWindowInternal(
            token: token, workspaceId: workspaceId, affectedWorkspaces: [workspaceId]
        ))
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }

        XCTAssertEqual(manager.niriViewportState(for: otherWorkspaceId).viewOffset, 1100)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.secondary.id)?.id, otherWorkspaceId)
        XCTAssertEqual(
            manager.niriViewportState(for: workspaceId).selectedNodeId,
            fixture.controller.niriEngine?.findNode(for: token, in: workspaceId)?.id
        )
    }

    func testOverviewWorkspaceActivationPreservesOtherMonitorPan() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        controller.niriLayoutHandler.commitOverviewPans([
            fixture.workspaces[0]: -1400,
            fixture.workspaces[1]: -1100
        ])
        let destination = try XCTUnwrap(controller.workspaceNavigationHandler.createOverviewWorkspace(
            on: fixture.primary.id
        ))

        XCTAssertTrue(controller.workspaceNavigationHandler.activateOverviewWorkspace(destination.id))
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }

        XCTAssertEqual(manager.activeWorkspace(on: fixture.primary.id)?.id, destination.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.secondary.id)?.id, fixture.workspaces[1])
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[1]).viewOffset, 1100)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[0]).viewOffset, 1400)
    }

    func testInvalidOrEmptyPansDoNotChangeViewportState() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let initial = fixture.workspaces.map { manager.niriViewportState(for: $0) }
        let seq = manager.worldSeq
        let committed = fixture.controller.niriLayoutHandler.commitOverviewPans([
            fixture.workspaces[0]: .nan,
            fixture.workspaces[1]: .infinity,
            fixture.workspaces[2]: 0,
            WorkspaceDescriptor.ID(): 50
        ])
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(fixture.workspaces.map { manager.niriViewportState(for: $0) }, initial)
        XCTAssertEqual(manager.worldSeq, seq)
    }

    func testCompletedSelectionCloseCommitsPansBeforePreparationAndPreservesOtherMonitor() async throws {
        let fixture = try makeFixture(windowCount: 8)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        var handoffs: [@MainActor () -> Void] = []
        let overview = makeOverview(fixture) { handoffs.append($0) }
        let target = try XCTUnwrap(manager.handle(for: fixture.tokens[1][0]))
        var expectedOffsets: [CGFloat] = []
        var prepared = 0
        var activated = 0
        overview.onPrepareActivation = { handle, workspaceId in
            prepared += 1
            XCTAssertEqual(handle, target)
            XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[0]).viewOffset, expectedOffsets[0])
            XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[1]).viewOffset, expectedOffsets[1])
            controller.windowActionHandler.prepareOverviewSelection(handle: handle, workspaceId: workspaceId)
        }
        overview.onActivateWindow = { handle, workspaceId in
            activated += 1
            XCTAssertTrue(controller.windowActionHandler.navigateToWindowInternal(
                token: handle.id, workspaceId: workspaceId, affectedWorkspaces: [workspaceId]
            ))
        }
        overview.open()
        expectedOffsets = [
            try panToEnd(overview, fixture: fixture, workspaceIndex: 0),
            try panToEnd(overview, fixture: fixture, workspaceIndex: 1)
        ]
        XCTAssertEqual(overview.selectedWindowHandle, target)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[0]).viewOffset, 0)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[1]).viewOffset, 0)

        overview.input.dismissToSelection(animated: true)

        guard case .closed = overview.state else { return XCTFail("Expected completed close") }
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(activated, 0)
        XCTAssertEqual(handoffs.count, 1)
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        let selectedOffset = manager.niriViewportState(for: fixture.workspaces[1]).viewOffset
        XCTAssertNotEqual(selectedOffset, expectedOffsets[1])
        handoffs.removeFirst()()
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }

        XCTAssertEqual(activated, 1)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[0]).viewOffset, expectedOffsets[0])
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[1]).viewOffset, selectedOffset)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.workspaces[1]).selectedNodeId,
            controller.niriEngine?.findNode(for: target.id, in: fixture.workspaces[1])?.id
        )
        let settledSeq = manager.worldSeq
        overview.commitOverviewPans()
        XCTAssertEqual(manager.worldSeq, settledSeq)
    }

    func testCompletedWorkspaceCloseDoesNotRecreatePanForOldSelection() async throws {
        let fixture = try makeFixture(windowCount: 8)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let overview = makeOverview(fixture)
        let destination = try XCTUnwrap(controller.workspaceNavigationHandler.createOverviewWorkspace(
            on: fixture.primary.id
        ))
        overview.onActivateWorkspace = controller.workspaceNavigationHandler.activateOverviewWorkspace
        overview.open()
        let otherOffset = try panToEnd(overview, fixture: fixture, workspaceIndex: 1)
        let previousOffset = try panToEnd(overview, fixture: fixture, workspaceIndex: 0)
        let oldSelection = try XCTUnwrap(overview.selectedWindowHandle)
        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let section = try XCTUnwrap(view.layout.workspaceSections.first { $0.workspaceId == fixture.workspaces[0] })
        let selected = try XCTUnwrap(section.windows.first { $0.handle === oldSelection })
        XCTAssertFalse(selected.overviewFrame.intersects(section.ribbonFrame))

        overview.activateWorkspace(destination.id)

        guard case .closed = overview.state else { return XCTFail("Expected completed workspace close") }
        while let task = controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        XCTAssertEqual(manager.activeWorkspace(on: fixture.primary.id)?.id, destination.id)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[0]).viewOffset, previousOffset)
        XCTAssertEqual(manager.niriViewportState(for: fixture.workspaces[1]).viewOffset, otherOffset)
        let settledSeq = manager.worldSeq
        overview.commitOverviewPans()
        XCTAssertEqual(manager.worldSeq, settledSeq)
    }

    private func makeOverview(
        _ fixture: Fixture,
        scheduleHandoff: @escaping (@escaping @MainActor () -> Void) -> Void = { $0() }
    ) -> OverviewController {
        var environment = OverviewEnvironment()
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.addLocalEventMonitor = { _, _ in nil }
        environment.notificationCenter = NotificationCenter()
        environment.windowTitle = { _ in "Window" }
        environment.windowFrame = { _ in CGRect(x: 10, y: 10, width: 500, height: 400) }
        environment.schedulePostCloseHandoff = scheduleHandoff
        return OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            previewCapture: OverviewThumbnailCapture(hasCaptureAccess: { false })
        )
    }

    private func panToEnd(
        _ overview: OverviewController,
        fixture: Fixture,
        workspaceIndex: Int
    ) throws -> CGFloat {
        let monitor = workspaceIndex == 1 ? fixture.secondary : fixture.primary
        let workspaceId = fixture.workspaces[workspaceIndex]
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[workspaceIndex][0]))
        overview.input.selectTab(handle, on: monitor.id)
        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let section = try XCTUnwrap(view.layout.workspaceSections.first { $0.workspaceId == workspaceId })
        let point = CGPoint(x: section.ribbonFrame.midX, y: section.ribbonFrame.midY - view.layout.scrollOffset)
        overview.input.panStrip(at: point, by: -10000, on: monitor.id)
        let pan = try XCTUnwrap(view.layout.stripPanByWorkspace[workspaceId])
        XCTAssertLessThan(pan, 0)
        return -pan
    }

    private func makeFixture(windowCount: Int = 4) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewViewportCommitTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings, windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
        ))
        controller.motionPolicy.animationsEnabled = false
        let primary = monitor(displayId: 98_701, frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        let secondary = monitor(displayId: 98_702, frame: CGRect(x: 1280, y: 100, width: 900, height: 1400))
        settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: secondary)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(name: "3", monitorAssignment: .main, layoutType: .niri)
        ]
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([primary, secondary])
        manager.applySettings()
        let workspaces = try ["1", "2", "3"].map { try XCTUnwrap(manager.workspaceId(for: $0, createIfMissing: true)) }
        for (index, workspaceId) in workspaces.enumerated() {
            manager.assignWorkspaceToMonitor(workspaceId, monitorId: index == 1 ? secondary.id : primary.id)
        }
        XCTAssertTrue(manager.setActiveWorkspace(workspaces[0], on: primary.id))
        XCTAssertTrue(manager.setActiveWorkspace(workspaces[1], on: secondary.id))
        _ = manager.setInteractionMonitor(primary.id)
        let engine = NiriLayoutEngine()
        controller.niriEngine = engine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let tokens = workspaces.enumerated().map { workspaceIndex, workspaceId in
            var lastNode: NiriWindow?
            let tokens = (0 ..< windowCount).map { windowIndex in
                let number = 98_800 + workspaceIndex * 10 + windowIndex
                let token = manager.addWindow(
                    AXWindowRef(element: AXUIElementCreateApplication(pid_t(number)), windowId: number),
                    pid: pid_t(number), windowId: number, to: workspaceId
                )
                lastNode = manager.withEngineMutationScope {
                    engine.addWindow(token: token, to: workspaceId, afterSelection: lastNode?.id)
                }
                return token
            }
            let firstNode = engine.findNode(for: tokens[0], in: workspaceId)
            _ = manager.applySessionPatch(.init(
                workspaceId: workspaceId, viewportState: ViewportState(selectedNodeId: firstNode?.id),
                rememberedFocusToken: tokens[0], plannedSeq: manager.worldSeq
            ))
            return tokens
        }
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        return Fixture(
            controller: controller,
            primary: primary,
            secondary: secondary,
            workspaces: workspaces,
            tokens: tokens
        )
    }

    private func monitor(displayId: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Overview \(displayId)"
        )
    }
}
