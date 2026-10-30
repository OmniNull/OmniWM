// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellIslandPlacementTests: XCTestCase {
    func testDisplaySelectionAndFullscreenPolicyRemainSeparateFromBarPlacement() {
        let host = makeHost()
        let main = monitor(CGMainDisplayID(), notch: true)
        let secondary = monitor(main.displayId == 92101 ? 92102 : 92101, notch: false)
        let targets = [
            DesiredIslandSurface(monitor: main, fullscreen: true),
            DesiredIslandSurface(monitor: secondary, fullscreen: false)
        ]
        host.config.island = ShellIslandConfig()
        let notch = host.islandPlacements(targets)
        XCTAssertEqual(Set(notch.keys), [ShellBarKey(monitor: main.id, placement: .island)])
        XCTAssertEqual(notch.values.first?.surface?.visible, false)
        XCTAssertEqual(notch.values.first?.surface?.fullscreen, true)

        host.config.island?.displays = .all
        host.config.island?.fullscreen = .show
        let all = host.islandPlacements(targets)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.values.allSatisfy { $0.surface?.visible == true })
        XCTAssertTrue(all.keys.allSatisfy { $0.placement == .island })

        host.config.island?.displays = .main
        XCTAssertEqual(Set(host.islandPlacements(targets).keys), [ShellBarKey(monitor: main.id, placement: .island)])
    }

    func testRootCanOccupyBothPlacementsWithoutLeakingIslandIntoBarSlots() throws {
        let host = makeHost()
        let monitor = monitor(92103, notch: true)
        let bar = ShellBarKey(monitor: monitor.id)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        let root = state("lake")
        let other = state("clock")
        host.config.island = ShellIslandConfig(root: root.name)
        host.config.leading = ["lake", "clock"]
        host.bars = [bar: ShellBarData()]
        host.islandData = host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: false)])
        host.widgets = [root.name: root, other.name: other]
        XCTAssertEqual(host.islandData[island]?.monitorId, "display:92103")
        XCTAssertEqual(host.islandData[island]?.monitor, monitor.name)

        XCTAssertTrue(host.place(root))
        XCTAssertEqual(Set(root.instances.keys), [bar, island])
        XCTAssertTrue(host.place(other))
        XCTAssertEqual(Set(other.instances.keys), [bar])
        let barInstance = try XCTUnwrap(root.instances[bar])
        let islandInstance = try XCTUnwrap(root.instances[island])
        XCTAssertFalse(barInstance === islandInstance)
        barInstance.size = CGSize(width: 20, height: 10)
        islandInstance.size = CGSize(width: 300, height: 60)
        host.refreshSlots()
        XCTAssertEqual(host.slots(for: monitor.id).map(\.size), [barInstance.size])

        host.bars = [:]
        XCTAssertTrue(host.place(root))
        XCTAssertTrue(root.instances[island] === islandInstance)
        XCTAssertNil(root.instances[bar])
    }

    func testIslandPlacementCarriesResolvedBarReservationIntoCanvasData() throws {
        let host = makeHost()
        let monitor = monitor(92106, notch: false)
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        host.config.island?.sizing = .display
        let data = try XCTUnwrap(host.islandPlacements([
            DesiredIslandSurface(
                monitor: monitor,
                fullscreen: false,
                reservedInsets: Struts(left: 17, right: 23, top: 41, bottom: 29)
            )
        ]).values.first?.surface)
        XCTAssertEqual(data.usableRect.minX, 17)
        XCTAssertEqual(data.usableRect.minY, data.menuBar + 41)
        XCTAssertEqual(data.usableRect.width, monitor.visibleFrame.width - 40)
        XCTAssertEqual(data.usableRect.height, monitor.visibleFrame.height - 70)
    }

    func testHiddenIslandDemandAndBarRemovalPreserveIndependentSurface() throws {
        let host = makeHost()
        let monitor = monitor(92104, notch: true)
        let bar = ShellBarKey(monitor: monitor.id)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        let root = state("lake")
        let barInstance = ShellWidgetHost.InstanceState()
        let islandInstance = ShellWidgetHost.InstanceState()
        barInstance.deps = ShellDataKey.clock.bit
        islandInstance.deps = ShellDataKey.media.bit
        islandInstance.popoutDeps = ShellDataKey.spectrum.bit
        root.instances = [bar: barInstance, island: islandInstance]
        host.widgets = [root.name: root]
        host.config.island = ShellIslandConfig(root: root.name)
        host.islandData = host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: false)])
        XCTAssertEqual(host.dataDemand, ShellDataKey.clock.bit | ShellDataKey.media.bit | ShellDataKey.spectrum.bit)

        host.islandData = host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: true)])
        XCTAssertEqual(host.dataDemand, ShellDataKey.clock.bit)
        XCTAssertNotNil(host.surfaceView(widget: root.name, key: bar, scale: 1))
        XCTAssertNotNil(host.surfaceView(widget: root.name, key: island, scale: 1))
        let surface = try XCTUnwrap(islandInstance.surface)
        host.removeSurfaces(for: monitor.id)
        XCTAssertNil(barInstance.surface)
        XCTAssertTrue(islandInstance.surface === surface)
        XCTAssertTrue(root.instances[island] === islandInstance)
        host.removeSurfaces(for: monitor.id, island: .all)
        XCTAssertTrue(islandInstance.surface === surface)
    }

    func testRemovingBarPlacementPublishesReducedDemandWithoutAnotherTree() {
        var titleDemands: [Bool] = []
        let host = makeHost(onTitleDemandChange: { titleDemands.append($0) })
        let monitor = monitor(92105, notch: true)
        let bar = ShellBarKey(monitor: monitor.id)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        let root = state("lake")
        let other = state("clock")
        let barInstance = ShellWidgetHost.InstanceState()
        barInstance.deps = ShellDataKey.title.bit | ShellDataKey.cpu.bit
        let islandInstance = ShellWidgetHost.InstanceState()
        islandInstance.deps = ShellDataKey.media.bit
        root.instances = [island: islandInstance]
        other.instances = [bar: barInstance]
        host.widgets = [root.name: root, other.name: other]
        host.config.leading = [other.name]
        host.config.island = ShellIslandConfig(root: root.name)
        host.bars = [bar: ShellBarData()]
        host.desiredIslands = [DesiredIslandSurface(monitor: monitor, fullscreen: false)]
        host.islandData = host.islandPlacements(host.desiredIslands)
        host.publishDemand()
        XCTAssertEqual(titleDemands, [true])

        host.updateBars()

        XCTAssertEqual(host.dataDemand, ShellDataKey.media.bit)
        XCTAssertEqual(titleDemands, [true, false])
        XCTAssertTrue(root.instances[island] === islandInstance)
        XCTAssertTrue(other.instances.isEmpty)
    }

    func testIslandPlacementsCarryEachDisplaysBarWorkspacesScratchpadsAndStyle() throws {
        let host = makeHost()
        let first = monitor(92107, notch: false)
        let second = monitor(92108, notch: false)
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        let bars = [first.id: bar(7, height: 32), second.id: bar(8, height: 40)]
        host.bars = Dictionary(uniqueKeysWithValues: bars.map { (ShellBarKey(monitor: $0.key), $0.value) })
        let placements = host
            .islandPlacements([first, second].map { DesiredIslandSurface(monitor: $0, fullscreen: false) })
        for (monitor, source) in bars {
            let data = try XCTUnwrap(placements[ShellBarKey(monitor: monitor, placement: .island)])
            XCTAssertEqual(data.workspaces, source.workspaces)
            XCTAssertEqual(data.scratchpads, source.scratchpads)
            XCTAssertEqual(data.style, source.style)
            XCTAssertTrue(data.barEnabled)
            XCTAssertNotNil(data.surface)
        }
    }

    func testSplitBarIslandUsesActiveSliceWithUncompactedScratchpads() throws {
        let host = makeHost()
        let monitor = monitor(92109, notch: false)
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        let active = bar(9, height: 36)
        host.bars = [
            ShellBarKey(monitor: monitor.id, island: .active): active,
            ShellBarKey(monitor: monitor.id, island: .secondary): bar(9, height: 36, compact: true)
        ]
        let data = try XCTUnwrap(host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: false)])
            .values.first)
        XCTAssertEqual(data.workspaces, active.workspaces)
        XCTAssertEqual(data.scratchpads, active.scratchpads)
        XCTAssertFalse(data.scratchpads.contains(where: \.compact))
        XCTAssertEqual(data.style, active.style)
    }

    func testDisplayWithoutEnabledBarDeliversEmptyListsAndNilStyle() throws {
        let host = makeHost()
        let barred = monitor(92110, notch: false)
        let bare = monitor(92111, notch: false)
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        host.bars = [ShellBarKey(monitor: barred.id): bar(10, height: 32)]
        let placements = host.islandPlacements([barred, bare].map {
            DesiredIslandSurface(monitor: $0, fullscreen: false)
        })
        let data = try XCTUnwrap(placements[ShellBarKey(monitor: bare.id, placement: .island)])
        XCTAssertFalse(data.barEnabled)
        XCTAssertTrue(data.workspaces.isEmpty)
        XCTAssertTrue(data.scratchpads.isEmpty)
        let widget = try ShellRenderedWidget(name: "island-bar", source: """
        function render(ctx)
            local bar = ctx.data.bar
            return ui.text{text = tostring(bar.style and bar.style.height) .. ':' .. #bar.workspaces .. ':'
                .. #bar.scratchpads}
        end
        """)
        widget.render(data)
        XCTAssertEqual(widget.strings(), ["nil:0:0"])
        widget.render(try XCTUnwrap(placements[ShellBarKey(monitor: barred.id, placement: .island)]))
        XCTAssertEqual(widget.strings(), ["32:1:1"])
    }

    func testBarChangeRepublishesIslandDataOnceAndUnchangedBarsDeliverNothing() async throws {
        let source = BarSource()
        let host = makeHost(bars: { source.bars })
        let monitor = monitor(92112, notch: false)
        let key = ShellBarKey(monitor: monitor.id)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        let root = state("lake")
        let (stream, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        root.mailbox = mailbox
        host.widgets = [root.name: root]
        host.config.island = ShellIslandConfig(root: root.name)
        host.config.island?.displays = .all
        host.desiredIslands = [DesiredIslandSurface(monitor: monitor, fullscreen: false)]
        source.bars = [key: bar(12, height: 32)]
        host.updateBars()
        host.updateBars()
        source.bars = [key: bar(13, height: 32)]
        host.updateBars()
        host.updateBars()
        mailbox.finish()
        var delivered: [[String]] = []
        for await message in stream {
            guard case let .bars(placed) = message else { continue }
            XCTAssertEqual(Set(placed.keys), [island])
            delivered.append(placed[island]?.workspaces.map(\.id) ?? [])
        }
        XCTAssertEqual(delivered, [["12"], ["13"]])
        XCTAssertEqual(host.islandData[island]?.workspaces, source.bars[key]?.workspaces)
    }

    private func bar(_ id: Int, height: Double, compact: Bool = false) -> ShellBarData {
        var style = ShellBarStyle()
        style.height = height
        let window = ShellBarWindow(id: "window-\(id)", title: "Title \(id)", focused: true, hidden: false)
        let item = ShellBarItem(
            id: "item-\(id)", bundle: "com.apple.Safari", name: "Safari", focused: true, count: 1, hidden: 0,
            windows: [window]
        )
        return ShellBarData(
            monitor: "Display \(id)",
            style: style,
            workspaces: [ShellBarWorkspace(id: "\(id)", name: "\(id)", focused: true, windows: [item])],
            scratchpads: [ShellBarScratchpad(
                id: id, name: "Pad \(id)", focused: false, revealed: false, visible: false, windows: [item],
                compact: compact
            )]
        )
    }

    private func monitor(_ displayId: UInt32, notch: Bool) -> Monitor {
        Monitor(
            id: .init(displayId: displayId), displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
            hasNotch: notch, notchRange: notch ? 630 ... 810 : nil,
            notchHeight: notch ? 32 : 0, name: "Display \(displayId)"
        )
    }

    private func state(_ name: String) -> ShellWidgetHost.WidgetState {
        ShellWidgetHost.WidgetState(name: name, sourceURL: URL(fileURLWithPath: "/tmp/\(name)/init.luau"))
    }

    func testIslandDrawersOpenIntoTheIslandDataOfTheirDisplayInsteadOfAPanel() {
        let host = makeHost()
        let monitor = monitor(92104, notch: false)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        var shelf = ShellDrawerConfig(id: "shelf", edge: .top, widgets: [], hover: true)
        shelf.island = true
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        host.config.drawers = [shelf]
        host.desiredIslands = [DesiredIslandSurface(monitor: monitor, fullscreen: false)]
        host.refreshIslandData()
        XCTAssertNil(host.islandData[island]?.surface?.drawer)
        XCTAssertFalse(host.toggleDrawer("shelf", on: Monitor.ID(displayId: 92105)))

        XCTAssertTrue(host.toggle("shelf", on: monitor.id))
        XCTAssertNil(host.drawer)
        XCTAssertEqual(host.islandData[island]?.surface?.drawer, "shelf")
        XCTAssertEqual(host.openDrawer?.drawer.id, "shelf")
        XCTAssertEqual(host.openDrawer?.islandRegions, [])

        XCTAssertTrue(host.toggle("shelf", on: monitor.id))
        XCTAssertNil(host.islandDrawer?.id)
        XCTAssertNil(host.islandData[island]?.surface?.drawer)
        XCTAssertNil(host.openDrawer)

        XCTAssertTrue(host.toggleDrawer("shelf", on: monitor.id))
        host.closeDrawer()
        XCTAssertNil(host.islandData[island]?.surface?.drawer)
    }

    private func makeHost(
        bars: @escaping @MainActor () -> [ShellBarKey: ShellBarData] = { [:] },
        onTitleDemandChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: bars, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: onTitleDemandChange
        )
    }
}

@MainActor
private final class BarSource {
    var bars: [ShellBarKey: ShellBarData] = [:]
}
