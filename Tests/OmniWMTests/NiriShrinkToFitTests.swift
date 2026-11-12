// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriShrinkToFitTests: XCTestCase {
    private let monitorFrame = CGRect(x: 0, y: 0, width: 2400, height: 1200)
    private let padding: CGFloat = 200
    private let gap: CGFloat = 10

    func testOffLeavesTheNeighbourAlone() throws {
        let fixture = try makeFixture(shrinkToFit: false)
        let neighbour = fixture.columns[1]
        let before = neighbour.cachedWidth

        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()

        XCTAssertEqual(neighbour.cachedWidth, before)
        XCTAssertNil(neighbour.fittedWidth)
        XCTAssertGreaterThan(fixture.columns[0].cachedWidth + before + 3 * gap, fixture.span)
    }

    func testNeighbourFillsTheRestWithoutChangingItsSpec() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        let neighbour = fixture.columns[1]
        let spec = neighbour.width
        let preset = neighbour.presetWidthIdx

        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()

        let resized = fixture.raw(0.7)
        XCTAssertEqual(fixture.columns[0].cachedWidth, resized)
        XCTAssertEqual(
            neighbour.cachedWidth,
            fixture.available(2) - resized,
            accuracy: CGFloat.rounding(operations: 4, at: fixture.span)
        )
        XCTAssertEqual(neighbour.width, spec)
        XCTAssertEqual(neighbour.presetWidthIdx, preset)
        XCTAssertNotNil(neighbour.fittedWidth)

        let frames = try fixture.frames()
        let pixel = 1 / fixture.scale
        XCTAssertEqual(frames[0].minX, padding, accuracy: pixel)
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - padding, accuracy: pixel)
    }

    func testWidthsAndViewportAnimateTogetherFromTheCurrentFrame() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        try fixture.focus(1)
        let columns = fixture.columns
        let before = columns.map(\.cachedWidth)
        var checked = false
        fixture.controller.niriLayoutHandler.withNiriWorkspaceContext {
            engine, workspaceId, _, state, _, workingFrame, gaps, orientation in
            let context = NiriInteractionContext(
                workspaceId: workspaceId,
                motion: .enabled,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            let onScreen = engine.onScreenProjectedColumns(
                in: workspaceId, state: state, geometry: context.sizingGeometry
            )
            engine.setContainerPrimarySpan(columns[1], change: .setProportion(30), context: context, state: &state)
            engine.shrinkVisibleColumnsToFit(around: columns[1], onScreen: onScreen, context: context, state: &state)

            XCTAssertEqual(columns.map(\.cachedWidth), before)
            XCTAssertTrue(columns.allSatisfy(\.hasWidthAnimationRunning))
            guard case .spring = state.offsetTransition.kind else {
                return XCTFail("Expected the viewport to spring, not jump")
            }
            XCTAssertEqual(state.viewOffset, -(columns[0].settledWidth + gaps) - gaps)
            checked = true
        }
        XCTAssertTrue(checked)
    }

    func testResizingTheFocusedRightColumnSettlesInsideTheWorkingArea() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        try fixture.focus(1)

        XCTAssertTrue(fixture.setSpan(.setProportion(30), on: 1))
        fixture.settle()

        let frames = try fixture.frames()
        let pixel = 1 / fixture.scale
        XCTAssertEqual(frames[0].minX, padding, accuracy: pixel)
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - padding, accuracy: pixel)
    }

    func testNeighbourSpecComesBackWhenTheColumnCountChanges() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()
        let neighbour = fixture.columns[1]
        XCTAssertNotNil(neighbour.fittedWidth)

        try fixture.addWindow()
        fixture.settle()

        XCTAssertNil(neighbour.fittedWidth)
        XCTAssertEqual(neighbour.cachedWidth, fixture.raw(0.5))
    }

    func testFullWidthNeighbourComesBack() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan(
            target: .window(fixture.handles[1])
        ))
        fixture.settle()
        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()
        let neighbour = fixture.columns[1]
        XCTAssertTrue(neighbour.isFullWidth)
        XCTAssertLessThan(neighbour.cachedWidth, fixture.raw(1))

        try fixture.addWindow()
        fixture.settle()

        XCTAssertTrue(neighbour.isFullWidth)
        XCTAssertEqual(neighbour.cachedWidth, fixture.raw(1))
    }

    func testNeighbourSpecComesBackWhenTheGapsChange() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()
        let neighbour = fixture.columns[1]
        XCTAssertNotNil(neighbour.fittedWidth)

        fixture.controller.setGapSize(2 * gap, publishChange: false)
        fixture.settle()

        XCTAssertNil(neighbour.fittedWidth)
        XCTAssertEqual(neighbour.cachedWidth, fixture.raw(0.5))
    }

    func testNeighbourMaximumIsRespected() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        let share = fixture.available(2) - fixture.raw(0.3)
        let maximum = share / 2
        fixture.constrain(1, minimum: 1, maximum: maximum)

        XCTAssertTrue(fixture.setSpan(.setProportion(30), on: 0))
        fixture.settle()

        XCTAssertEqual(fixture.columns[1].cachedWidth, maximum)
        XCTAssertEqual(fixture.columns[0].cachedWidth, fixture.raw(0.3))
    }

    func testNeighbourPackingIsRespected() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        let share = fixture.available(2) - fixture.raw(0.7)
        let packed = share + 2 * gap
        fixture.pack(1, requested: share, observed: packed)

        XCTAssertTrue(fixture.setSpan(.setProportion(70), on: 0))
        fixture.settle()

        XCTAssertEqual(fixture.columns[1].cachedWidth, packed)
        XCTAssertEqual(
            fixture.columns[0].cachedWidth,
            fixture.available(2) - packed,
            accuracy: CGFloat.rounding(operations: 4, at: fixture.span)
        )
    }

    func testPresetCyclingMovesPastANeighbourCap() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        let column = fixture.columns[0]
        XCTAssertEqual(column.presetWidthIdx, 1)
        let neighbourMinimum = fixture.available(2) - fixture.raw(0.6)
        fixture.constrain(1, minimum: neighbourMinimum, maximum: 0)

        XCTAssertTrue(fixture.cycle(on: 0))
        fixture.settle()
        XCTAssertEqual(column.presetWidthIdx, 2)
        XCTAssertLessThan(column.cachedWidth, fixture.raw(2.0 / 3))

        XCTAssertTrue(fixture.cycle(on: 0))
        fixture.settle()
        XCTAssertEqual(column.presetWidthIdx, 0)
        XCTAssertEqual(
            column.cachedWidth,
            fixture.raw(1.0 / 3),
            accuracy: CGFloat.rounding(operations: 4, at: fixture.span)
        )
    }

    func testThreeColumnsShareTheChangeAroundTheMiddleOne() throws {
        let fixture = try makeFixture(shrinkToFit: false)
        fixture.controller.settings.niri.visibleContainerCount = 3
        fixture.controller.updateNiriConfig(visibleContainerCount: 3)
        try fixture.addWindow()
        for index in 0 ..< 3 {
            XCTAssertTrue(fixture.setSpan(.setProportion(100.0 / 3), onColumn: index))
        }
        try fixture.focus(column: 0)
        fixture.controller.settings.niri.shrinkToFit = true

        XCTAssertTrue(fixture.setSpan(.setProportion(50), onColumn: 1))
        fixture.settle()

        let columns = fixture.columns
        let share = (fixture.available(3) - fixture.raw(0.5)) / 2
        let tolerance = CGFloat.rounding(operations: 4, at: fixture.span)
        XCTAssertEqual(columns[1].cachedWidth, fixture.raw(0.5))
        XCTAssertEqual(columns[0].cachedWidth, share, accuracy: tolerance)
        XCTAssertEqual(columns[2].cachedWidth, share, accuracy: tolerance)
        let frames = try fixture.frames()
        let pixel = 1 / fixture.scale
        XCTAssertEqual(frames[0].minX, padding, accuracy: pixel)
        XCTAssertEqual(frames[2].maxX, monitorFrame.width - padding, accuracy: pixel)
    }

    func testTabbedNeighbourFillsTheRest() throws {
        let fixture = try makeFixture(shrinkToFit: true)
        try fixture.addWindow()
        try fixture.focus(column: 1)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.consumeWindowIntoColumn(
            containing: try fixture.handle(ofColumn: 1)
        ).didMutate)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleColumnTabbed(
            target: .window(try fixture.handle(ofColumn: 1))
        ))
        try fixture.focus(column: 0)
        XCTAssertEqual(fixture.columns.count, 2)
        XCTAssertTrue(fixture.columns[1].isTabbed)

        XCTAssertTrue(fixture.setSpan(.setProportion(70), onColumn: 0))
        fixture.settle()

        XCTAssertNotNil(fixture.columns[1].fittedWidth)
        let frames = try fixture.frames()
        let pixel = 1 / fixture.scale
        XCTAssertEqual(frames[0].minX, padding, accuracy: pixel)
        XCTAssertEqual(frames[1].maxX, monitorFrame.width - padding, accuracy: pixel)
    }

    func testPortraitNeighbourFillsTheRest() throws {
        let fixture = try makeFixture(shrinkToFit: true, portrait: true)
        let neighbour = fixture.columns[1]
        let spec = neighbour.height

        XCTAssertTrue(fixture.setSpan(.setProportion(70), onColumn: 0))
        fixture.settle()

        XCTAssertEqual(neighbour.height, spec)
        XCTAssertNotNil(neighbour.fittedHeight)
        let frames = try fixture.frames()
        let pixel = 1 / fixture.scale
        let portrait = CGRect(x: 0, y: 0, width: monitorFrame.height, height: monitorFrame.width)
        XCTAssertEqual(frames.map(\.minY).min() ?? 0, padding, accuracy: pixel)
        XCTAssertEqual(frames.map(\.maxY).max() ?? 0, portrait.height - padding, accuracy: pixel)
    }

    func testSettingDefaultsOffAndRoundTrips() throws {
        var legacy = SettingsExport.defaults()
        legacy.niri.shrinkToFit = nil
        let settings = NiriSettings()
        settings.shrinkToFit = true
        settings.apply(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(legacy)).niri, baseline: .defaults())
        XCTAssertFalse(settings.shrinkToFit)

        var export = SettingsExport.defaults()
        export.niri.shrinkToFit = true
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded, export)
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertTrue(settings.shrinkToFit)
        XCTAssertEqual(settings.export(), decoded.niri)
    }

    private func makeFixture(shrinkToFit: Bool, portrait: Bool = false) throws -> Fixture {
        let frame = portrait
            ? CGRect(x: 0, y: 0, width: monitorFrame.height, height: monitorFrame.width)
            : monitorFrame
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriShrinkToFitTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = Double(gap)
        settings.gaps.outerGapLeft = portrait ? 0 : Double(padding)
        settings.gaps.outerGapRight = portrait ? 0 : Double(padding)
        settings.gaps.outerGapTop = portrait ? Double(padding) : 0
        settings.gaps.outerGapBottom = portrait ? Double(padding) : 0
        settings.niri.edgeGaps = false
        settings.niri.shrinkToFit = shrinkToFit
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
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
        controller.motionPolicy.animationsEnabled = false
        controller.setGapSize(gap, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        let fixture = Fixture(controller: controller, monitor: monitor, workspaceId: workspaceId)
        try fixture.addWindow()
        try fixture.addWindow()
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = try XCTUnwrap(engine.findNode(for: fixture.tokens[0], in: workspaceId))
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: first.id,
            focusedToken: fixture.tokens[0],
            in: workspaceId,
            onMonitor: monitor.id
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffset = -gap
            state.clearOffsetTransition()
        }
        fixture.settle()
        return fixture
    }
}

@MainActor
private final class Fixture {
    let controller: WMController
    let monitor: Monitor
    let workspaceId: WorkspaceDescriptor.ID
    private(set) var tokens: [WindowToken] = []

    init(controller: WMController, monitor: Monitor, workspaceId: WorkspaceDescriptor.ID) {
        self.controller = controller
        self.monitor = monitor
        self.workspaceId = workspaceId
    }

    var engine: NiriLayoutEngine {
        controller.niriEngine!
    }

    var columns: [NiriContainer] {
        engine.columns(in: workspaceId)
    }

    var handles: [WindowHandle] {
        tokens.compactMap { controller.workspaceManager.handle(for: $0) }
    }

    var gap: CGFloat {
        controller.niriInteractionGeometry(for: monitor).innerGap
    }

    var span: CGFloat {
        controller.niriInteractionGeometry(for: monitor).workingFrame.width
    }

    var scale: CGFloat {
        engine.displayScale(in: workspaceId)
    }

    func raw(_ proportion: CGFloat) -> CGFloat {
        (span - gap) * proportion - gap
    }

    func available(_ columnCount: Int) -> CGFloat {
        span - CGFloat(columnCount + 1) * gap
    }

    func addWindow() throws {
        let index = tokens.count
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid_t(890 + index)), windowId: 890 + index),
            pid: pid_t(890 + index),
            windowId: 890 + index,
            to: workspaceId
        )
        tokens.append(token)
        _ = try frames()
    }

    func handle(ofColumn index: Int) throws -> WindowHandle {
        let token = try XCTUnwrap(columns[index].windowNodes.first?.token)
        return try XCTUnwrap(controller.workspaceManager.handle(for: token))
    }

    func setSpan(_ change: NiriSizeChange, onColumn index: Int) -> Bool {
        guard let handle = try? handle(ofColumn: index) else { return false }
        return controller.niriLayoutHandler.setContainerPrimarySpan(change, target: .window(handle))
    }

    func focus(column index: Int) throws {
        let token = try XCTUnwrap(columns[index].windowNodes.first?.token)
        try focus(token: token, columnIndex: index)
    }

    func focus(_ index: Int) throws {
        try focus(token: tokens[index], columnIndex: index)
    }

    private func focus(token: WindowToken, columnIndex index: Int) throws {
        let node = try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: token,
            in: workspaceId,
            onMonitor: monitor.id
        )
        let leading = columns.prefix(index).reduce(CGFloat(0)) { $0 + $1.settledWidth + gap }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = index
            state.viewOffset = -leading - gap
            state.clearOffsetTransition()
        }
        settle()
    }

    func setSpan(_ change: NiriSizeChange, on index: Int) -> Bool {
        controller.niriLayoutHandler.setContainerPrimarySpan(change, target: .window(handles[index]))
    }

    func cycle(on index: Int) -> Bool {
        controller.niriLayoutHandler.cycleContainerPrimarySpan(forward: true, target: .window(handles[index]))
    }

    func constrain(_ index: Int, minimum: CGFloat, maximum: CGFloat) {
        controller.workspaceManager.setCachedConstraints(
            WindowSizeConstraints(
                minSize: CGSize(width: minimum, height: 1),
                maxSize: CGSize(width: maximum, height: 0),
                isFixed: false
            ),
            for: tokens[index]
        )
        _ = try? frames()
    }

    func pack(_ index: Int, requested: CGFloat, observed: CGFloat) {
        var evidence = ObservedSizeEvidence()
        evidence.hints = ObservedPackingHints(width: ObservedAxisHint(requested: requested, observed: observed))
        _ = controller.workspaceManager.setObservedSizeEvidence(evidence, for: tokens[index])
        _ = try? frames()
    }

    func settle() {
        _ = engine.tickAllColumnAnimations(in: workspaceId, at: .infinity)
        _ = controller.workspaceManager.animationDriver.tick(in: workspaceId, at: .infinity)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { $0.clearOffsetTransition() }
        _ = try? frames()
        _ = engine.tickAllColumnAnimations(in: workspaceId, at: .infinity)
    }

    func frames() throws -> [CGRect] {
        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first { $0.workspaceId == workspaceId })
        return try columns.compactMap { $0.windowNodes.first?.token }.map { token in
            if let frame = plan.diff.frameChanges.first(where: { $0.token == token })?.frame {
                return frame
            }
            return try XCTUnwrap(engine.findNode(for: token, in: workspaceId)?.renderedFrame)
        }
    }
}
