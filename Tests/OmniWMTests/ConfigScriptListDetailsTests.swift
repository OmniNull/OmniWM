// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptListDetailsTests: XCTestCase {
    private let sessionToken = "list-details"

    func testWorkspaceDetailsMatchTheWorkspaceQuery() async throws {
        let first = NiriGatherFixture.monitor(displayId: 1)
        let displays = [first, NiriGatherFixture.monitor(displayId: first.displayId + 1, x: first.frame.maxX)]
        let base = try NiriGatherFixture(prefix: "list-details", monitors: displays, workspaces: [
            .init(name: "1", layoutType: .niri, monitor: displays[0]),
            .init(name: "2", layoutType: .dwindle, monitor: displays[1]),
            .init(name: "3", layoutType: .defaultLayout, monitor: displays[0])
        ])
        let fixture = ConfigScriptWindowFixture(base: base)
        let controller = base.controller
        let manager = base.manager
        let workspaces = controller.settings.workspaces
        workspaces.defaultLayoutType = .defaultLayout
        let label = try XCTUnwrap(workspaces.configurations.firstIndex { $0.name == "1" })
        workspaces.configurations[label].displayName = "Main"
        let one = base.workspace("1")
        XCTAssertTrue(manager.setActiveWorkspace(one, on: displays[0].id))
        XCTAssertTrue(manager.setActiveWorkspace(base.workspace("2"), on: displays[1].id))
        base.add(Array(1 ... 6), to: one)
        base.stack(4, onto: 3, in: one)
        base.add([8], to: base.workspace("2"))
        base.add([9], to: base.workspace("3"))
        let floating = base.token(7)
        _ = WindowAdmissionTestSupport.track(floating, in: one, controller: controller)
        XCTAssertTrue(manager.setWindowMode(.floating, for: floating))
        let slot = try XCTUnwrap(ScratchpadIndex(ScratchpadIndex.range.lowerBound))
        XCTAssertTrue(manager.setScratchpadMembership(floating, to: slot))
        let tabbed = try XCTUnwrap(base.node(3, in: one).flatMap(base.engine.column(of:)))
        let display = displays[0]
        let area = controller.niriInteractionGeometry(for: display, scale: display.backingScale).workingFrame
        manager.withEngineMutationScope(in: one) {
            XCTAssertTrue(base.engine.setColumnDisplay(
                .tabbed, for: tabbed, in: one, motion: .disabled, orientation: .horizontal
            ))
            for column in base.engine.columns(in: one) {
                column.targetWidth = area.width / 2
            }
        }
        try await fixture.focus(3, on: "1")
        let activeColumn = try XCTUnwrap(base.engine.columns(in: one).firstIndex { $0 === tabbed })
        manager.withNiriViewportState(for: one) {
            $0.activeColumnIndex = activeColumn
            $0.viewOffset = -area.width / 4
        }
        collectBackingScales(of: displays, in: controller)

        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: sessionToken)
        let query = router.workspacesResult(IPCQueryRequest(name: .workspaces)).workspaces
        let snapshot = capture([.workspaces, .workspaceDetails], from: controller)
        XCTAssertEqual(query.first { $0.rawName == "3" }?.layout, .defaultLayout)
        let columns = try XCTUnwrap(query.first { $0.rawName == "1" }?.columns)
        XCTAssertEqual(Set(columns.map(\.viewport)), Set(IPCColumnViewport.allCases))
        XCTAssertTrue(columns.contains { $0.mode == .tabbed })
        let focused = try XCTUnwrap(manager.nativeManagedFocusToken)
        let focusedID = ConfigScriptWindowID.string(focused, session: controller.scriptSession.identity)
        let expected = try query.map { workspace in
            let id = try XCTUnwrap(workspace.id)
            let workspaceId = try XCTUnwrap(UUID(uuidString: id))
            let layout = manager.activeLayoutKind(for: workspaceId)
            let counts = try XCTUnwrap(workspace.counts)
            let fields = [
                "displayName = \(lua(workspace.displayName))",
                "number = \(lua(workspace.number))",
                "layout = '\(layout.rawValue)'",
                "focused = \(lua(workspace.isFocused))",
                "visible = \(lua(workspace.isVisible))",
                "current = \(lua(workspace.isCurrent))",
                "counts = { \(counts.total), \(counts.tiled), \(counts.floating), \(counts.scratchpad) }",
                "focusedWindow = \(lua(workspace.focusedWindowId.map { _ in focusedID }))",
                "scrollOffset = \(lua(layout == .niri ? manager.niriViewportState(for: workspaceId).viewOffset : nil))",
                "columns = \(workspace.columns.map(luaColumns) ?? "nil")"
            ]
            return "['\(id)'] = { \(fields.joined(separator: ", ")) }"
        }
        try await invoke("""
        local expected = { \(expected.joined(separator: ",\n")) }
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.workspaces == \(query.count))
            for _, row in ctx.workspaces do
                local want = assert(expected[row.id], row.id)
                assert(row.displayName == want.displayName and row.number == want.number, row.name)
                assert(row.layout == want.layout and row.focusedWindow == want.focusedWindow, row.name)
                assert(row.focused == want.focused and row.visible == want.visible and row.current == want.current)
                local counts = row.windowCounts
                assert(table.isfrozen(counts) and counts.total == want.counts[1] and counts.tiled == want.counts[2])
                assert(counts.floating == want.counts[3] and counts.scratchpad == want.counts[4], row.name)
                assert(row.scrollOffset == want.scrollOffset, row.name)
                if want.columns then
                    assert(table.isfrozen(row.columns) and #row.columns == #want.columns, row.name)
                    for index, column in row.columns do
                        assert(table.isfrozen(column) and column.mode == want.columns[index][1], row.name)
                        assert(column.viewport == want.columns[index][2], row.name)
                    end
                else
                    assert(row.columns == nil, row.name)
                end
            end
            assert(ctx.truncated.details.workspaces == false and ctx.truncated.details.monitors == nil)
        end, { reads = { 'workspaces', 'details' } })
        omniwm.on('workspace.active', function(ctx)
            for _, row in ctx.workspaces do
                assert(row.displayName == nil and row.layout == nil and row.windowCounts == nil, row.name)
                assert(row.focused == nil and row.scrollOffset == nil and row.columns == nil, row.name)
            end
            assert(ctx.truncated.details == nil)
        end, { reads = { 'workspaces' } })
        """, expecting: [.workspaces, .workspaceDetails], on: snapshot)
    }

    func testDisplayDetailsMatchTheDisplayQueryAsTheBarShowsHidesAndCloses() async throws {
        let notched = Monitor(
            id: .init(displayId: 1), displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
            hasNotch: true, notchRange: 663.5 ... 848.5, notchHeight: 33, backingScale: 2,
            name: "Notched", displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230", isMain: true
        )
        let portraitFrame = CGRect(x: notched.frame.maxX, y: 0, width: 1080, height: 1920)
        let portrait = Monitor(
            id: .init(displayId: notched.displayId + 1), displayId: notched.displayId + 1,
            frame: portraitFrame, visibleFrame: portraitFrame, hasNotch: false, name: "Portrait", isMain: false
        )
        let displays = [notched, portrait]
        let base = try NiriGatherFixture(prefix: "display-details", monitors: displays, workspaces: [
            .init(name: "1", monitor: notched), .init(name: "2", monitor: portrait)
        ])
        let fixture = ConfigScriptWindowFixture(base: base)
        let controller = base.controller
        XCTAssertTrue(base.manager.setActiveWorkspace(base.workspace("1"), on: notched.id))
        XCTAssertTrue(base.manager.setActiveWorkspace(base.workspace("2"), on: portrait.id))
        base.add([1], to: base.workspace("1"))
        try await fixture.focus(1, on: "1")
        let gaps = controller.settings.gaps
        gaps.size = 7
        gaps.outerGapLeft = 3
        gaps.outerGapRight = 5
        gaps.outerGapTop = 11
        gaps.outerGapBottom = 13
        gaps.fullscreenUsesOuterGaps.toggle()
        collectBackingScales(of: displays, in: controller)
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: sessionToken)
        let barSettings = controller.settings.workspaceBar
        barSettings.position = .left
        barSettings.reserveLayoutSpace = true
        for enabled in [true, false] {
            barSettings.enabled = enabled
            let query = router.displaysResult(IPCQueryRequest(name: .displays)).displays
            let snapshot = capture([.monitors, .monitorDetails], from: controller)
            let reserves = query.contains { $0.reservedInsets != IPCInsets(top: 0, left: 0, bottom: 0, right: 0) }
            XCTAssertEqual(reserves, enabled)
            try await assertDisplayDetails(match: query, displays: displays, on: snapshot)
        }

        let bars = controller.workspaceBarManager
        bars.setup(controller: controller, settings: controller.settings)
        bars.screenProvider = { _ in nil }
        bars.panelFactory = { WorkspaceBarPanel.defaultPanel() }
        bars.frameApplier = { panel, frame in panel.setFrame(frame, display: false) }
        defer { bars.cleanup() }
        let barSnapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: barSettings.backgroundOpacity,
            barHeight: CGFloat(barSettings.height),
            orientation: barSettings.resolved(for: notched).position.orientation
        )
        let shown = DesiredBarSurface(monitor: notched, visible: true, snapshot: barSnapshot)
        var hidden = shown
        hidden.visible = false
        hidden.retainWhileHidden = true
        for (surfaces, shownBars) in [([shown], 1), ([hidden], 0), ([shown], 1), ([], 0)] {
            bars.apply(surfaces)
            let query = router.displaysResult(IPCQueryRequest(name: .displays)).displays
            let snapshot = capture([.monitors, .monitorDetails], from: controller)
            XCTAssertEqual(query.compactMap(\.barFrames).joined().count, shownBars)
            try await assertDisplayDetails(match: query, displays: displays, on: snapshot)
        }
    }

    func testEachDetailedListHasItsOwnAllowance() async throws {
        let display = NiriGatherFixture.monitor(displayId: 1)
        let extraWorkspaces = 8
        let base = try NiriGatherFixture(
            prefix: "list-detail-allowance", monitors: [display],
            workspaces: (1 ... extraWorkspaces).map { .init(name: String($0), monitor: display) }
        )
        let controller = base.controller
        let workspaces = controller.settings.workspaces
        let count = base.manager.sortedWorkspaces().count
        XCTAssertEqual(count, workspaces.configurations.count)
        let label = String(repeating: "x", count: ConfigScriptSnapshot.detailByteLimit / (count - 1))
        for index in workspaces.configurations.indices {
            workspaces.configurations[index].displayName = label
        }
        let reads: ConfigScriptReads = [.workspaces, .monitors, .workspaceDetails, .monitorDetails]
        let snapshot = capture(reads, from: controller)
        try await invoke("""
        local function detailed(rows)
            local cut = 0
            for index, row in rows do
                if row.displayName then
                    assert(#row.displayName == \(label.utf8.count) and cut == 0, 'rows after the cut keep no details')
                elseif cut == 0 then
                    cut = index
                end
                assert(row.id and row.name, 'every row keeps its base fields')
            end
            return cut
        end
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.workspaces == \(count) and ctx.truncated.workspaces == false)
            assert(ctx.truncated.details.workspaces == true and ctx.truncated.details.monitors == false)
            local cut = detailed(ctx.workspaces)
            assert(cut > 1 and cut <= \(count), 'details stop at a row boundary')
            assert(ctx.monitors[1].main ~= nil and ctx.monitors[1].orientation)
        end, { reads = { 'workspaces', 'monitors', 'details' } })
        omniwm.on('workspace.active', function(ctx)
            assert(ctx.truncated.details.monitors == false and ctx.truncated.details.workspaces == nil)
            assert(ctx.monitors[1].orientation and ctx.workspaces == nil)
        end, { reads = { 'monitors', 'details' } })
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.workspaces == \(count) and ctx.truncated.details == nil and detailed(ctx.workspaces) == 1)
        end, { reads = { 'workspaces' } })
        """, expecting: reads, on: snapshot)
    }

    func testWorkspaceNumbersStayExactInLuau() async throws {
        let display = NiriGatherFixture.monitor(displayId: 1)
        let largest = OMNI_CONFIG_MAX_SAFE_INTEGER
        let names = [String(largest), String(largest + 1)]
        let base = try NiriGatherFixture(
            prefix: "list-detail-numbers", monitors: [display],
            workspaces: names.map { .init(name: $0, monitor: display) }
        )
        let snapshot = capture([.workspaces, .workspaceDetails], from: base.controller)
        try await invoke("""
        omniwm.on('workspace.active', function(ctx)
            local rows = {}
            for _, row in ctx.workspaces do rows[row.name] = row end
            assert(rows['\(names[0])'].number == \(largest), 'the largest exact number')
            assert(rows['\(names[1])'] and rows['\(names[1])'].number == nil, 'no rounded number')
        end, { reads = { 'workspaces', 'details' } })
        """, expecting: [.workspaces, .workspaceDetails], on: snapshot)
    }

    private func assertDisplayDetails(
        match query: [IPCDisplayQuerySnapshot], displays: [Monitor], on snapshot: ConfigScriptSnapshot
    ) async throws {
        let expected = try query.map { display in
            let monitor = try XCTUnwrap(displays.first { $0.name == display.name })
            let gaps = [display.outerGapLeft, display.outerGapRight, display.outerGapTop, display.outerGapBottom]
            let insets = try XCTUnwrap(display.reservedInsets)
            let fields = [
                "main = \(lua(display.isMain))",
                "current = \(lua(display.isCurrent))",
                "uuid = \(lua(display.uuid))",
                "hasNotch = \(lua(display.hasNotch))",
                "notch = \(display.notch.map { "{ \($0.start), \($0.end) }" } ?? "nil")",
                "orientation = \(lua(display.orientation?.rawValue))",
                "innerGap = \(lua(display.innerGap))",
                "outerGaps = { \(gaps.map(lua).joined(separator: ", ")) }",
                "fullscreenUsesOuterGaps = \(lua(display.fullscreenUsesOuterGaps))",
                "menuBarHeight = \(lua(display.menuBarHeight))",
                "insets = { \(insets.left), \(insets.right), \(insets.top), \(insets.bottom) }",
                "bars = { \(try XCTUnwrap(display.barFrames).map(luaRect).joined(separator: ", ")) }"
            ]
            return "['\(monitor.id.scriptIdentifier)'] = { \(fields.joined(separator: ", ")) }"
        }
        try await invoke("""
        local expected = { \(expected.joined(separator: ",\n")) }
        local function same(values, wanted, keys, name)
            assert(table.isfrozen(values), name)
            for index, key in keys do
                assert(values[key] == wanted[index], name .. '.' .. key)
            end
        end
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.monitors == \(query.count))
            for _, row in ctx.monitors do
                local want = assert(expected[row.id], row.id)
                assert(row.main == want.main and row.current == want.current and row.uuid == want.uuid, row.name)
                assert(row.hasNotch == want.hasNotch and row.orientation == want.orientation, row.name)
                if want.notch then
                    same(row.notch, want.notch, { 'left', 'right' }, 'notch')
                else
                    assert(row.notch == nil, row.name)
                end
                assert(row.innerGap == want.innerGap and row.menuBarHeight == want.menuBarHeight, row.name)
                assert(row.fullscreenUsesOuterGaps == want.fullscreenUsesOuterGaps, row.name)
                local edges = { 'left', 'right', 'top', 'bottom' }
                same(row.outerGaps, want.outerGaps, edges, 'outerGaps')
                same(row.reservedInsets, want.insets, edges, 'reservedInsets')
                assert(table.isfrozen(row.barFrames) and #row.barFrames == #want.bars, row.name)
                for index, frame in row.barFrames do
                    same(frame, want.bars[index], { 'x', 'y', 'width', 'height' }, 'barFrames')
                end
            end
            assert(ctx.truncated.details.monitors == false)
        end, { reads = { 'monitors', 'details' } })
        """, expecting: [.monitors, .monitorDetails], on: snapshot)
    }

    private func capture(_ reads: ConfigScriptReads, from controller: WMController) -> ConfigScriptSnapshot {
        var pool = ConfigScriptSnapshotPool()
        return controller.configScriptSnapshot(reads: reads, target: controller.configScriptTarget(), pool: &pool)
    }

    private func invoke(
        _ source: String, expecting reads: ConfigScriptReads, on snapshot: ConfigScriptSnapshot
    ) async throws {
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        XCTAssertEqual(result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }, reads)
        for listener in result.events {
            _ = try await generation.invoke(
                function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
            )
        }
    }

    private func collectBackingScales(of displays: [Monitor], in controller: WMController) {
        controller.layoutRefreshController.layoutState.backingScaleByDisplay = Dictionary(
            uniqueKeysWithValues: displays.map { ($0.displayId, $0.backingScale) }
        )
    }

    private func luaColumns(_ columns: [IPCWorkspaceColumn]) -> String {
        "{ " + columns.map { "{ '\($0.mode.rawValue)', '\($0.viewport.rawValue)' }" }
            .joined(separator: ", ") + " }"
    }

    private func luaRect(_ rect: IPCRect) -> String {
        "{ \(rect.x), \(rect.y), \(rect.width), \(rect.height) }"
    }

    private func lua(_ value: String?) -> String {
        value.map { "'\($0)'" } ?? "nil"
    }

    private func lua(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "nil"
    }

    private func lua(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    private func lua(_ value: Double?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    private func lua(_ value: CGFloat?) -> String {
        lua(value.map(Double.init))
    }
}
