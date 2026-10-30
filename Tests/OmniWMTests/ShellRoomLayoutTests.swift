// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellRoomLayoutTests: XCTestCase {
    func testTotalsPutNiriAndDwindleTilesOnTheRoomEdgesOnBothAxesAndWithEdgeGapsOnOrOff() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for edgeGaps in [true, false] {
                for outer in [CGFloat(8), 30] {
                    let controller = fixture(outer: outer, edgeGaps: edgeGaps)
                    let monitor = monitor()
                    let room = totalRoom()
                    setRoom(room, on: controller)
                    let expected = try envelope(of: room, on: monitor)
                    XCTAssertEqual(try niriEnvelope(controller, monitor, orientation: orientation), expected)
                    XCTAssertEqual(
                        try dwindleEnvelope(controller.layoutFrames(for: monitor, scale: monitor.backingScale)),
                        expected
                    )
                }
            }
        }
    }

    func testTogglingNiriEdgeGapsKeepsBothLayoutsOnTheRoomEdges() throws {
        let controller = fixture(edgeGaps: true)
        let monitor = monitor()
        let room = totalRoom()
        setRoom(room, on: controller)
        let expected = try envelope(of: room, on: monitor)
        XCTAssertEqual(try niriEnvelope(controller, monitor, orientation: .horizontal), expected)
        for edgeGaps in [false, true] {
            controller.settings.niri.edgeGaps = edgeGaps
            controller.updateMonitorGapSettings()
            XCTAssertEqual(try niriEnvelope(controller, monitor, orientation: .horizontal), expected)
            XCTAssertEqual(try dwindleEnvelope(controller.layoutFrames(for: monitor, scale: 2)), expected)
        }
    }

    func testTopAddNormalizesTheCombinedGapAndRoomOnce() {
        for menu in [CGFloat(0), 24] {
            for outer in [CGFloat(8), 32] {
                let controller = fixture(outer: outer)
                let monitor = monitor(menu: menu)
                setRoom(WorkspaceBarRoom(edges: [.top: .init(value: 62, mode: .add)], displays: .all), on: controller)
                let frame = controller.layoutFrames(for: monitor, scale: 2).workingFrame
                XCTAssertEqual(monitor.frame.maxY - frame.maxY, outer + 62)
                XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor).top, 62 - menu)
            }
        }
    }

    func testNotchAndMenuClearancesUseDistancesFromTheFrameTop() {
        let controller = fixture()
        let menu = CGFloat(24), notch = CGFloat(32), top = CGFloat(59)
        let monitor = monitor(menu: menu, notch: notch)
        for (clear, extra) in [(WorkspaceBarRoom.Clearance.notch, notch), (.menuBar, menu), (.none, 0)] {
            var room = totalRoom()
            room.edges[.top] = .init(value: top, mode: .total, clear: clear)
            setRoom(room, on: controller)
            let frame = controller.layoutFrames(for: monitor, scale: monitor.backingScale).workingFrame
            XCTAssertEqual(monitor.frame.maxY - frame.maxY, top + extra)
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor).top + menu, top + extra)
        }
    }

    func testUngappedFullscreenIslandAndIPCSeeTheRoomWithoutUserGaps() {
        let controller = fixture(outer: 30)
        let monitor = monitor(menu: 24)
        var room = totalRoom()
        room.edges[.top] = .init(value: 76, mode: .total)
        room.edges[.left] = .init(value: 24, mode: .total)
        setRoom(room, on: controller)
        controller.settings.gaps.fullscreenUsesOuterGaps = false
        let reserved = controller.workspaceBarReservedInsets(for: monitor)
        XCTAssertEqual(reserved, Struts(left: 24, right: 24, top: 52, bottom: 24))
        XCTAssertEqual(reserved.ipcInsets.top, 52)
        XCTAssertEqual(
            controller.layoutFrames(for: monitor, scale: 2).fullscreenLayoutFrame,
            CGRect(x: 24, y: 24, width: 1680, height: 1017)
        )
        let island = ShellIslandData(
            monitor: monitor, geometry: ShellIslandGeometry(monitor: monitor, size: monitor.frame.size),
            visible: true, fullscreen: false, reservedInsets: reserved
        )
        XCTAssertEqual(island.usableRect, CGRect(x: 24, y: 76, width: 1680, height: 1017))
    }

    func testRoomIsGatedByIslandSelectorAndThePerMonitorBar() {
        let controller = fixture()
        let monitor = monitor()
        let baseline = frames(controller.layoutFrames(for: monitor, scale: 2))
        var room = totalRoom()
        room = WorkspaceBarRoom(edges: room.edges, displays: .notch)
        setRoom(room, on: controller)
        XCTAssertEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), baseline)
        setRoom(totalRoom(), on: controller)
        XCTAssertNotEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), baseline)
        controller.settings.island.enabled = false
        controller.updateWorkspaceBarSettings()
        XCTAssertEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), baseline)
        controller.settings.island.enabled = true
        controller.settings.workspaceBar.enabled = false
        XCTAssertEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), baseline)
    }

    func testResolvedRoomAndDisplayChangesInvalidateTheCachedFrames() {
        let controller = fixture()
        let monitor = monitor()
        setRoom(totalRoom(), on: controller)
        let original = frames(controller.layoutFrames(for: monitor, scale: 2))
        let revision = controller.settings.layoutConfigurationRevision
        var room = totalRoom()
        let left = WorkspaceBarRoom.Reservation(value: 100, mode: .total)
        room.edges[.left] = left
        setRoom(room, on: controller)
        XCTAssertGreaterThan(controller.settings.layoutConfigurationRevision, revision)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame.minX, left.value)
        setRoom(WorkspaceBarRoom(edges: room.edges, displays: .notch), on: controller)
        XCTAssertNotEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), original)
        XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), .zero)
    }

    func testDockRaisesItsEdgeAndKeepsLargerExistingGaps() throws {
        for outer in [CGFloat(8), 100] {
            let controller = fixture(outer: outer)
            let monitor = monitor()
            var room = totalRoom()
            let dock = WorkspaceBarRoom.Dock(edge: .bottom, value: 70)
            room.dock = dock
            setRoom(room, on: controller)
            let bottom = try XCTUnwrap(room.edges[.bottom]).value
            XCTAssertEqual(
                controller.layoutFrames(for: monitor, scale: 2).workingFrame.minY, max(outer, bottom, dock.value)
            )
            XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor).bottom, dock.value)
        }
    }

    func testDockNearTheOuterGapKeepsTheNiriGapWhileDwindleStaysOnTheDock() throws {
        let monitor = monitor()
        for borders in [false, true] {
            let probe = fixture(borders: borders)
            let gap = probe.innerGap(for: monitor)
            let clearance = BorderConfig.layoutClearance(
                enabled: borders, width: CGFloat(probe.settings.borders.width), scale: monitor.backingScale
            )
            for dockValue in [CGFloat(70), gap] {
                let dock = WorkspaceBarRoom.Dock(edge: .bottom, value: dockValue)
                for outer in [0, dock.value - gap / 2, dock.value - gap * 2] where outer >= 0 {
                    let controller = fixture(outer: outer, borders: borders)
                    setRoom(WorkspaceBarRoom(dock: dock, displays: .all), on: controller)
                    let floor = max(outer, clearance)
                    let niri = try niriEnvelope(controller, monitor, orientation: .horizontal)
                    let layout = controller.layoutFrames(for: monitor, scale: monitor.backingScale)
                    XCTAssertEqual(niri.minY - monitor.frame.minY, max(floor + gap, dock.value))
                    XCTAssertEqual(try dwindleEnvelope(layout).minY - monitor.frame.minY, max(floor, dock.value))
                }
            }
        }
    }

    func testRemovingRoomRestoresAllPreviousGeometry() {
        let controller = fixture(outer: 30)
        let monitor = monitor(menu: 24)
        controller.settings.workspaceBar.reserveLayoutSpace = true
        controller.settings.workspaceBar.height = 40
        controller.settings.workspaceBar.fullWidth = true
        let before = frames(controller.layoutFrames(for: monitor, scale: 2))
        let reservation = controller.workspaceBarReservedInsets(for: monitor)
        setRoom(totalRoom(), on: controller)
        XCTAssertNotEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), before)
        controller.settings.workspaceBar.profileOverride = nil
        XCTAssertEqual(frames(controller.layoutFrames(for: monitor, scale: 2)), before)
        XCTAssertEqual(controller.workspaceBarReservedInsets(for: monitor), reservation)
    }
}

extension ShellRoomLayoutTests {
    private func frames(_ frames: MonitorLayoutFrames) -> [CGRect] {
        [frames.workingFrame, frames.borderSafeFillFrame, frames.fullscreenLayoutFrame]
    }

    private func fixture(outer: CGFloat = 8, edgeGaps: Bool = true, borders: Bool = false) -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-room-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.borders.enabled = borders
        settings.island.enabled = true
        settings.workspaceBar.enabled = true
        settings.workspaceBar.reserveLayoutSpace = false
        settings.workspaceBar.revealModifier = .off
        settings.workspaceBar.autoHide = false
        settings.workspaceBar.position = .overlappingMenuBar
        settings.gaps.outerGapTop = Double(outer)
        settings.gaps.outerGapBottom = Double(outer)
        settings.gaps.outerGapLeft = Double(outer)
        settings.gaps.outerGapRight = Double(outer)
        settings.niri.edgeGaps = edgeGaps
        let controller = WMController(settings: settings)
        controller.setGapSize(10, publishChange: false)
        return controller
    }

    private func monitor(menu: CGFloat = 0, notch: CGFloat = 0) -> Monitor {
        Monitor(
            id: .init(displayId: 84200), displayId: 84200,
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117 - menu),
            hasNotch: notch > 0, notchRange: notch > 0 ? 800 ... 928 : nil,
            notchHeight: notch, backingScale: 2, name: "Room fixture", isMain: true
        )
    }

    private func totalRoom() -> WorkspaceBarRoom {
        WorkspaceBarRoom(edges: [
            .left: .init(value: 76, mode: .total), .right: .init(value: 24, mode: .total),
            .top: .init(value: 24, mode: .total), .bottom: .init(value: 24, mode: .total)
        ], displays: .all)
    }

    private func setRoom(_ room: WorkspaceBarRoom, on controller: WMController) {
        controller.settings.workspaceBar.profileOverride = WorkspaceBarProfileOverride(
            profile: "room", settings: MonitorBarSettings(monitorName: ""), room: room
        )
    }

    private func envelope(of room: WorkspaceBarRoom, on monitor: Monitor) throws -> CGRect {
        let left = try XCTUnwrap(room.edges[.left]).value, right = try XCTUnwrap(room.edges[.right]).value
        let top = try XCTUnwrap(room.edges[.top]).value, bottom = try XCTUnwrap(room.edges[.bottom]).value
        return CGRect(
            x: monitor.frame.minX + left, y: monitor.frame.minY + bottom,
            width: monitor.frame.width - left - right, height: monitor.frame.height - top - bottom
        )
    }

    private func niriEnvelope(
        _ controller: WMController, _ monitor: Monitor, orientation: Monitor.Orientation
    ) throws -> CGRect {
        let geometry = controller.niriInteractionGeometry(for: monitor, scale: monitor.backingScale)
        let engine = NiriLayoutEngine(visibleContainerCount: 2)
        engine.defaultContainerPrimarySpan = nil
        let workspace = WorkspaceDescriptor.ID()
        for id in 1 ... 2 {
            _ = engine.addWindow(token: WindowToken(pid: 841, windowId: id), to: workspace, afterSelection: nil)
        }
        var state = ViewportState()
        state.jumpOffset(to: -geometry.innerGap)
        let frames = engine.calculateLayout(
            state: state, workspaceId: workspace, monitorFrame: geometry.workingFrame,
            gaps: (geometry.innerGap, geometry.innerGap), orientation: orientation
        )
        XCTAssertEqual(frames.count, 2)
        return try XCTUnwrap(frames.values.reduce(nil as CGRect?) { $0?.union($1) ?? $1 })
    }

    private func dwindleEnvelope(_ layout: MonitorLayoutFrames) throws -> CGRect {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        for id in 1 ... 2 {
            _ = engine.addWindow(token: WindowToken(pid: 842, windowId: id), to: workspace, activeWindowFrame: nil)
        }
        let frames = engine.calculateLayout(for: workspace, screen: layout.workingFrame)
        XCTAssertEqual(frames.count, 2)
        return try XCTUnwrap(frames.values.reduce(nil as CGRect?) { $0?.union($1) ?? $1 })
    }
}
