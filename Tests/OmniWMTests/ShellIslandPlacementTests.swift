// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        host.config.island = ShellIslandConfig()
        host.config.leading = ["lake", "clock"]
        host.bars = [bar: ShellBarData()]
        host.islandData = host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: false)])
        host.widgets = [root.name: root, other.name: other]

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
        host.config.island = ShellIslandConfig()
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
        host.config.island = ShellIslandConfig()
        host.bars = [bar: ShellBarData()]
        host.islandData = host.islandPlacements([DesiredIslandSurface(monitor: monitor, fullscreen: false)])
        host.publishDemand()
        XCTAssertEqual(titleDemands, [true])

        host.updateBars()

        XCTAssertEqual(host.dataDemand, ShellDataKey.media.bit)
        XCTAssertEqual(titleDemands, [true, false])
        XCTAssertTrue(root.instances[island] === islandInstance)
        XCTAssertTrue(other.instances.isEmpty)
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

    private func makeHost(onTitleDemandChange: @escaping @MainActor (Bool) -> Void = { _ in }) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: onTitleDemandChange
        )
    }
}
