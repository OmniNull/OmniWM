// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriAutoShrinkToFitTests: XCTestCase {
    private let monitorFrame = CGRect(x: 0, y: 0, width: 2400, height: 1200)
    private let sidePadding: CGFloat = 200
    private let innerGap: CGFloat = 10

    func testAWideMinimumMakesTheOthersGiveWay() throws {
        let fixture = try makeEvenFixture(windowCount: 4, visibleContainerCount: 4)
        setMinimumWidth(900, for: fixture.tokens[3], fixture: fixture)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)

        let frames = try settledFrames(fixture)

        XCTAssertGreaterThanOrEqual(frames.map(\.width).max() ?? 0, 900)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: try pixel(fixture))
        XCTAssertEqual(frames[3].maxX, monitorFrame.width - sidePadding, accuracy: try pixel(fixture))
    }

    func testARestoredOverflowingRowIsFitted() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.motionPolicy.animationsEnabled = false
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let restored = engine.columns(in: fixture.workspaceId)[1]
        restored.width = .proportion(0.65)
        restored.invalidateCachedPrimarySpan(orientation: .horizontal)
        engine.ensureState(for: fixture.workspaceId).manualWidthColumnCount = nil
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)

        let frames = try settledFrames(fixture)

        let pixel = try pixel(fixture)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: pixel)
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - sidePadding, accuracy: pixel)
    }

    func testOffLeavesTheOverflow() throws {
        let fixture = try makeEvenFixture(windowCount: 4, visibleContainerCount: 4)
        setMinimumWidth(900, for: fixture.tokens[3], fixture: fixture)

        let frames = try settledFrames(fixture)

        XCTAssertGreaterThan(frames[3].maxX, monitorFrame.width - sidePadding + 100)
    }

    func testColumnsThatCannotFitMoveOutOfView() throws {
        let fixture = try makeEvenFixture(windowCount: 3, visibleContainerCount: 3)
        for token in fixture.tokens {
            setMinimumWidth(800, for: token, fixture: fixture)
        }
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)

        let frames = try settledFrames(fixture)

        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: try pixel(fixture))
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - sidePadding, accuracy: try pixel(fixture))
        XCTAssertGreaterThanOrEqual(frames[2].minX, monitorFrame.width - sidePadding)
    }

    func testARefusingNeighbourFitsWithFewerColumnsThanVisibleContainers() throws {
        let fixture = try makeFixture(windowCount: 2, visibleContainerCount: 3)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.setWindowPrimarySpan(
            .setProportion(80),
            target: .window(fixture.handles[0])
        ))
        let refusedWidth = try settledFrames(fixture)[1].width + 200

        learnMinimumWidth(refusedWidth, for: fixture.tokens[1], fixture: fixture)

        let frames = try settledFrames(fixture)
        XCTAssertGreaterThanOrEqual(frames[1].width, refusedWidth)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: try pixel(fixture))
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - sidePadding, accuracy: try pixel(fixture))
    }

    func testARefusalIsFittedInTheLayoutPassThatLearnsIt() throws {
        let fixture = try makeEvenFixture(windowCount: 3, visibleContainerCount: 3)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        _ = try settledFrames(fixture)

        learnMinimumWidth(900, for: fixture.tokens[2], fixture: fixture)
        _ = try layoutFrames(fixture)

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let columns = engine.columns(in: fixture.workspaceId)
        XCTAssertNotNil(columns[1].fittedWidth)
        XCTAssertNotNil(columns[2].fittedWidth)
    }

    func testAResizedWindowThatRefusesFitsWithFewerColumnsThanVisibleContainers() throws {
        let fixture = try makeFixture(windowCount: 2, visibleContainerCount: 3)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        try focusColumn(1, fixture)
        let minimum = try settledFrames(fixture)[1].width - 300
        learnMinimumWidth(minimum, for: fixture.tokens[1], fixture: fixture)

        for _ in 0 ..< 4 {
            XCTAssertTrue(fixture.controller.niriLayoutHandler.setWindowPrimarySpan(
                .adjustProportion(-5),
                target: .window(fixture.handles[1])
            ))
            learnMinimumWidth(minimum, for: fixture.tokens[1], fixture: fixture)
        }

        let frames = try settledFrames(fixture)
        XCTAssertGreaterThanOrEqual(frames[1].width, minimum)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: try pixel(fixture))
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - sidePadding, accuracy: try pixel(fixture))
    }

    func testAVisibleContainerChangeKeepsTheRowOnTheGaps() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 3)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        try focusColumn(1, fixture)
        _ = try settledFrames(fixture)

        setVisibleContainerCount(2, fixture)

        let frames = try settledFrames(fixture)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: try pixel(fixture))
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - sidePadding, accuracy: try pixel(fixture))
        XCTAssertGreaterThanOrEqual(frames[2].minX, monitorFrame.width - sidePadding)
    }

    func testBalancingAfterAVisibleContainerChangeKeepsTheRowOnTheGaps() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        let workingWidth = monitorFrame.width - 2 * sidePadding
        learnMinimumWidth(workingWidth * 0.35, for: fixture.tokens[0], fixture: fixture)
        learnMinimumWidth(workingWidth * 0.37, for: fixture.tokens[1], fixture: fixture)
        fixture.controller.niriLayoutHandler.balanceSizes()
        try focusColumn(1, fixture)
        fixture.controller.settings.niri.visibleContainerCount = 3
        fixture.controller.updateNiriConfig(visibleContainerCount: 3)
        _ = try settledFrames(fixture)

        fixture.controller.niriLayoutHandler.balanceSizes()
        _ = try settledFrames(fixture)

        fixture.controller.niriLayoutHandler.balanceSizes()

        let frames = try settledFrames(fixture)
        let pixel = try pixel(fixture)
        XCTAssertEqual(frames[0].minX, sidePadding, accuracy: pixel)
        XCTAssertEqual(frames[2].maxX, monitorFrame.width - sidePadding, accuracy: pixel)
    }

    func testOffLeavesTheViewWhereItIsAfterAVisibleContainerChange() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 3)
        try focusColumn(1, fixture)
        let focusedBefore = try settledFrames(fixture)[1]

        setVisibleContainerCount(2, fixture)

        XCTAssertEqual(try settledFrames(fixture)[1].minX, focusedBefore.minX, accuracy: try pixel(fixture))
    }

    func testCenteringLeavesTheViewToUpstream() throws {
        var focusedFrames: [CGRect] = []
        for fit in [false, true] {
            let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 3)
            fixture.controller.settings.niri.shrinkToFit = fit
            fixture.controller.updateNiriConfig(shrinkToFit: fit)
            fixture.controller.settings.niri.centerFocusedColumn = .always
            fixture.controller.updateNiriConfig(centerFocusedColumn: .always)
            try focusColumn(1, fixture)
            _ = try settledFrames(fixture)

            setVisibleContainerCount(2, fixture)

            focusedFrames.append(try settledFrames(fixture)[1])
        }
        XCTAssertEqual(focusedFrames[1], focusedFrames[0])
    }

    func testFewerColumnsThatFitAreLeftAlone() throws {
        let fixture = try makeEvenFixture(windowCount: 2, visibleContainerCount: 3)
        let before = try settledFrames(fixture)

        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)

        XCTAssertEqual(try settledFrames(fixture), before)
    }

    func testAFullSpanColumnLeavesItsNeighboursAlone() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        try focusColumn(2, fixture)
        let before = try settledFrames(fixture)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())

        let full = try settledFrames(fixture)
        let workingWidth = monitorFrame.width - 2 * sidePadding
        let neighbourWidths = before.map(\.width).filter { $0 < workingWidth }
        XCTAssertEqual(full.map(\.width).sorted(), (neighbourWidths.prefix(2) + [workingWidth]).sorted())
    }

    func testAFullSpanRoundTripRestoresTheRow() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        try focusColumn(2, fixture)
        let before = try settledFrames(fixture)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())
        _ = try settledFrames(fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())

        XCTAssertEqual(try settledFrames(fixture), before)
    }

    func testAFullSpanRoundTripLeavesTheOtherWidthsAlone() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let first = try XCTUnwrap(engine.columns(in: fixture.workspaceId)[0].windowNodes.first).token
        learnMinimumWidth((monitorFrame.width - 2 * sidePadding) * 0.3, for: first, fixture: fixture)
        try focusColumn(1, fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.setContainerPrimarySpan(.setProportion(75)))
        _ = try settledFrames(fixture)
        let widths = engine.columns(in: fixture.workspaceId).map(\.settledWidth)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())
        _ = try settledFrames(fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())
        _ = try settledFrames(fixture)

        XCTAssertEqual(engine.columns(in: fixture.workspaceId).map(\.settledWidth), widths)
    }

    func testAMouseResizeIsNeverRefitted() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let firstNode = try XCTUnwrap(engine.columns(in: fixture.workspaceId)[0].windowNodes.first)
        learnMinimumWidth((monitorFrame.width - 2 * sidePadding) * 0.3, for: firstNode.token, fixture: fixture)
        try focusColumn(1, fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.setContainerPrimarySpan(.setProportion(75)))
        let start = try settledFrames(fixture)[0]
        let widths = engine.columns(in: fixture.workspaceId).map(\.settledWidth)
        XCTAssertNotNil(engine.columns(in: fixture.workspaceId)[0].fittedWidth)
        let manager = fixture.controller.workspaceManager

        XCTAssertTrue(manager.withEngineMutationScope(in: fixture.workspaceId) {
            engine.interactiveResizeBegin(
                windowId: firstNode.id, edges: .right, startLocation: CGPoint(x: start.maxX - 2, y: start.midY),
                in: fixture.workspaceId, orientation: .horizontal
            )
        })
        _ = try layoutFrames(fixture)
        XCTAssertTrue(manager.withEngineMutationScope(in: fixture.workspaceId) {
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: start.maxX + 100, y: start.midY),
                monitorFrame: monitorFrame,
                gaps: LayoutGaps(horizontal: innerGap, vertical: innerGap)
            )
        })
        let dragged = engine.columns(in: fixture.workspaceId)[0].settledWidth
        _ = try layoutFrames(fixture)
        manager.withEngineMutationScope(in: fixture.workspaceId) {
            manager.withNiriViewportState(for: fixture.workspaceId) { state in
                engine.interactiveResizeEnd(
                    motion: .enabled,
                    state: &state,
                    workingFrame: CGRect(
                        x: sidePadding,
                        y: 0,
                        width: monitorFrame.width - 2 * sidePadding,
                        height: 1200
                    ),
                    gaps: innerGap
                )
            }
        }
        _ = try settledFrames(fixture)

        let after = engine.columns(in: fixture.workspaceId).map(\.settledWidth)
        XCTAssertGreaterThan(dragged, widths[0])
        XCTAssertEqual(after[0], dragged)
        XCTAssertEqual(after[2], widths[2])
    }

    func testAFullSpanColumnKeepsItsSpanWhenTheGapsChange() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        try focusColumn(2, fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan())
        _ = try settledFrames(fixture)

        fixture.controller.setGapSize(2 * innerGap, publishChange: false)

        let frames = try settledFrames(fixture)
        let pixel = try pixel(fixture)
        let workingWidth = monitorFrame.width - 2 * sidePadding
        XCTAssertTrue(
            frames.contains { abs($0.minX - sidePadding) <= pixel && abs($0.width - workingWidth) <= pixel },
            "\(frames) has no full-span column"
        )
    }

    func testMovingFocusRightAfterAFitNeverResizesColumns() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        fixture.controller.settings.niri.shrinkToFit = true
        fixture.controller.updateNiriConfig(shrinkToFit: true)
        _ = try settledFrames(fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let lastWidth = try XCTUnwrap(engine.columns(in: fixture.workspaceId).last).settledWidth

        let middle = try XCTUnwrap(engine.columns(in: fixture.workspaceId)[1].windowNodes.first).token
        learnMinimumWidth((monitorFrame.width - 2 * sidePadding) * 0.65, for: middle, fixture: fixture)
        _ = try layoutFrames(fixture)
        try revealColumn(2, atLeadingEdge: false, fixture)
        _ = try layoutFrames(fixture)

        XCTAssertEqual(try XCTUnwrap(engine.columns(in: fixture.workspaceId).last).settledWidth, lastWidth)
    }

    func testOffKeepsNoAutomaticFitState() throws {
        let fixture = try makeFixture(windowCount: 3, visibleContainerCount: 2)
        setMinimumWidth(900, for: fixture.tokens[2], fixture: fixture)
        try revealColumn(2, atLeadingEdge: false, fixture)
        try revealColumn(0, atLeadingEdge: true, fixture)
        setVisibleContainerCount(3, fixture)
        _ = try settledFrames(fixture)

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertNil(engine.ensureState(for: fixture.workspaceId).autoFitSignature)
        XCTAssertTrue(engine.columns(in: fixture.workspaceId).allSatisfy { $0.fittedWidth == nil })
    }

    private func revealColumn(_ index: Int, atLeadingEdge: Bool, _ fixture: Fixture) throws {
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let column = engine.columns(in: fixture.workspaceId)[index]
        let node = try XCTUnwrap(column.windowNodes.first)
        let workingWidth = monitorFrame.width - 2 * sidePadding
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = index
            state.viewOffset = atLeadingEdge ? -innerGap : -innerGap - (workingWidth - column.cachedWidth)
            state.clearOffsetTransition()
        }
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: node.token,
            in: fixture.workspaceId,
            onMonitor: try XCTUnwrap(fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)).id
        )
    }

    private func focusColumn(_ index: Int, _ fixture: Fixture) throws {
        let frames = try settledFrames(fixture)
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = index
            state.viewOffset = frames[0].minX - frames[index].minX - innerGap
            state.clearOffsetTransition()
        }
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let node = try XCTUnwrap(engine.columns(in: fixture.workspaceId)[index].windowNodes.first)
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: node.token,
            in: fixture.workspaceId,
            onMonitor: try XCTUnwrap(fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)).id
        )
    }

    private func learnMinimumWidth(_ width: CGFloat, for token: WindowToken, fixture: Fixture) {
        var evidence = ObservedSizeEvidence()
        evidence.minSize = CGSize(width: width, height: 1)
        _ = fixture.controller.workspaceManager.setObservedSizeEvidence(evidence, for: token)
    }

    private func makeEvenFixture(windowCount: Int, visibleContainerCount: Int) throws -> Fixture {
        let fixture = try makeFixture(windowCount: windowCount, visibleContainerCount: visibleContainerCount)
        for handle in fixture.handles {
            XCTAssertTrue(fixture.controller.niriLayoutHandler.setContainerPrimarySpan(
                .setProportion(100 / Double(visibleContainerCount)),
                target: .window(handle)
            ))
        }
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffset = -innerGap
            state.clearOffsetTransition()
        }
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let first = try XCTUnwrap(engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: first.id,
            focusedToken: fixture.tokens[0],
            in: fixture.workspaceId,
            onMonitor: try XCTUnwrap(fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)).id
        )
        _ = try settledFrames(fixture)
        return fixture
    }

    private func setMinimumWidth(_ width: CGFloat, for token: WindowToken, fixture: Fixture) {
        fixture.controller.workspaceManager.setCachedConstraints(
            WindowSizeConstraints(minSize: CGSize(width: width, height: 1), maxSize: .zero, isFixed: false),
            for: token
        )
    }

    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let handles: [WindowHandle]
    }

    private func makeFixture(windowCount: Int, visibleContainerCount: Int) throws -> Fixture {
        let settings = makeSettingsStore()
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = Double(innerGap)
        settings.gaps.outerGapLeft = Double(sidePadding)
        settings.gaps.outerGapRight = Double(sidePadding)
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.niri.edgeGaps = false
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: monitorFrame,
            visibleFrame: monitorFrame,
            hasNotch: false,
            name: "Main"
        )
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(settings: settings)
        controller.setGapSize(innerGap, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        let tokens = (0 ..< windowCount).map { index in
            controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid_t(870 + index)), windowId: 870 + index),
                pid: pid_t(870 + index),
                windowId: 870 + index,
                to: workspaceId
            )
        }
        let fixture = try Fixture(
            controller: controller,
            workspaceId: workspaceId,
            tokens: tokens,
            handles: tokens.map { try XCTUnwrap(controller.workspaceManager.handle(for: $0)) }
        )
        _ = try layoutFrames(fixture)
        controller.settings.niri.visibleContainerCount = visibleContainerCount
        controller.settings.niri.defaultContainerPrimarySpan = nil
        controller.updateNiriConfig(
            visibleContainerCount: visibleContainerCount,
            defaultContainerPrimarySpan: .some(nil)
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: first.id,
            focusedToken: tokens[0],
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffset = -innerGap
            state.clearOffsetTransition()
        }
        _ = try layoutFrames(fixture)
        return fixture
    }

    private func settledFrames(_ fixture: Fixture) throws -> [CGRect] {
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for _ in 0 ..< 2 {
            _ = engine.tickAllColumnAnimations(in: fixture.workspaceId, at: .infinity)
            _ = fixture.controller.workspaceManager.animationDriver.tick(in: fixture.workspaceId, at: .infinity)
            fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
                state.clearOffsetTransition()
            }
            _ = try layoutFrames(fixture)
        }
        return try layoutFrames(fixture).sorted { $0.minX < $1.minX }
    }

    private func pixel(_ fixture: Fixture) throws -> CGFloat {
        1 / (try XCTUnwrap(fixture.controller.niriEngine)).displayScale(in: fixture.workspaceId)
    }

    private func setVisibleContainerCount(_ count: Int, _ fixture: Fixture) {
        fixture.controller.settings.niri.visibleContainerCount = count
        fixture.controller.updateNiriConfig(visibleContainerCount: count)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange()
    }

    private func layoutFrames(_ fixture: Fixture) throws -> [CGRect] {
        let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
        }
        let plan = try XCTUnwrap(plans.first { $0.workspaceId == fixture.workspaceId })
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        return try fixture.tokens.map { token in
            if let frame = plan.diff.frameChanges.first(where: { $0.token == token })?.frame {
                return frame
            }
            return try XCTUnwrap(engine.findNode(for: token, in: fixture.workspaceId)?.renderedFrame)
        }
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriAutoShrinkToFitTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
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
    }
}
