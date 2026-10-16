// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellIslandDragTests: XCTestCase {
    @MainActor
    private final class Driver {
        var count = 10
        var offered: ShellDropTypes = .file
        var typeReads = 0
        var installs = 0
        var removed = 0
        var monitorCount = 2
        var receive: (@Sendable (ShellIslandDragInbox.Event) -> Void)?
        var changes: [ShellIslandDragState] = []

        func monitor() -> ShellIslandDragMonitor {
            ShellIslandDragMonitor(environment: .init(
                changeCount: { self.count },
                types: { self.typeReads += 1
                    return self.offered
                },
                install: { self.installs += 1
                    self.receive = $0
                    return Array(0 ..< self.monitorCount)
                },
                remove: { self.removed += $0.count }
            ), onChange: { self.changes.append($0) })
        }

        func send(_ input: ShellIslandDragInbox.Event, to monitor: ShellIslandDragMonitor) throws {
            receive?(input)
            monitor.drain(try XCTUnwrap(monitor.inbox))
        }
    }

    func testStalePasteboardAndWindowMovesDoNotActivateAndTypesAreCachedPerChange() {
        var reducer = ShellIslandDragReducer(changeCount: 12)
        var reads = 0
        for _ in 0 ..< 1000 {
            reducer.drag(changeCount: 12) { reads += 1
                return .file
            }
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(reducer.state, .init())
        reducer.drag(changeCount: 13) { reads += 1
            return [.file, .image]
        }
        XCTAssertEqual(reducer.state, .init(active: true, types: [.file, .image]))
        for _ in 0 ..< 1000 {
            reducer.drag(changeCount: 13) { reads += 1
                return .text
            }
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(reducer.state.types, [.file, .image])
        reducer.drag(changeCount: 14) { reads += 1
            return .text
        }
        XCTAssertEqual(reducer.state.types, .text)
        reducer.reset(changeCount: 14)
        reducer.drag(changeCount: 14) { reads += 1
            return .text
        }
        XCTAssertEqual(reducer.state, .init())
        XCTAssertEqual(reads, 2)
        reducer.drag(changeCount: 15) { reads += 1
            return []
        }
        XCTAssertEqual(reducer.state, .init())
        XCTAssertEqual(reads, 3)
    }

    func testMoveBurstUsesOneWakeAndResetKeepsOnlyTheCurrentGesture() throws {
        let wakes = Mutex(0)
        let inbox = ShellIslandDragInbox { _ in wakes.withLock { $0 += 1 } }
        for _ in 0 ..< 50000 { inbox.post(.dragged) }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(inbox.take(), .init(began: false, ended: false, dragged: true))
        inbox.post(.ended)
        inbox.post(.dragged)
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        inbox.finish()
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertEqual(inbox.take(), .init(began: false, ended: true, dragged: true))
        inbox.finish()
        inbox.post(.dragged)
        inbox.post(.ended)
        XCTAssertEqual(wakes.withLock { $0 }, 3)
        XCTAssertEqual(inbox.take(), .init(began: false, ended: true, dragged: false))
        inbox.finish()
        inbox.close()
        inbox.post(.dragged)
        XCTAssertNil(inbox.take())
        XCTAssertEqual(wakes.withLock { $0 }, 3)
    }

    func testDemandOwnsMonitorPairAndOldCallbacksCannotReactivateReplacement() throws {
        let driver = Driver()
        let monitor = driver.monitor()
        monitor.setDemand(false)
        XCTAssertEqual(driver.installs, 0)
        monitor.setDemand(true)
        monitor.setDemand(true)
        XCTAssertEqual(driver.installs, 1)
        let old = try XCTUnwrap(monitor.inbox)
        let oldReceive = driver.receive
        driver.count += 1
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(driver.changes, [.init(active: true, types: .file)])
        for _ in 0 ..< 1000 { try driver.send(.dragged, to: monitor) }
        XCTAssertEqual(driver.changes.count, 1)
        XCTAssertEqual(driver.typeReads, 1)
        monitor.setDemand(false)
        monitor.setDemand(false)
        XCTAssertEqual(driver.removed, 2)
        XCTAssertEqual(driver.changes.last, .init())
        XCTAssertFalse(monitor.monitoring)
        oldReceive?(.dragged)
        monitor.drain(old)
        XCTAssertEqual(driver.changes.count, 2)
        monitor.setDemand(true)
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(driver.typeReads, 1)
        XCTAssertEqual(driver.changes.count, 2)
        driver.count += 1
        driver.offered = .url
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(driver.changes.last, .init(active: true, types: .url))
        monitor.setDemand(false)
        XCTAssertEqual(driver.installs, 2)
        XCTAssertEqual(driver.removed, 4)
    }

    func testActualDropEndClearsPendingMovesAndChangedTypesPublishOnlyOnce() throws {
        let driver = Driver()
        let monitor = driver.monitor()
        monitor.setDemand(true)
        defer { monitor.setDemand(false) }
        driver.count += 1
        driver.receive?(.began)
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(driver.changes.last, .init(active: true, types: .file))
        driver.count += 1
        driver.offered = [.image, .file]
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(driver.changes.count, 2)
        XCTAssertEqual(driver.changes.last?.types, [.image, .file])
        driver.receive?(.dragged)
        monitor.end()
        monitor.drain(try XCTUnwrap(monitor.inbox))
        XCTAssertEqual(driver.changes.count, 3)
        XCTAssertEqual(driver.changes.last, .init())
        try driver.send(.ended, to: monitor)
        XCTAssertEqual(driver.changes.count, 3)
    }

    func testUnobservedExternalDragEndCannotActivateFollowingWindowMove() throws {
        let driver = Driver()
        let monitor = driver.monitor()
        monitor.setDemand(true)
        defer { monitor.setDemand(false) }
        driver.count += 1
        driver.receive?(.dragged)
        driver.receive?(.ended)
        driver.receive?(.began)
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(monitor.state, .init())
        XCTAssertEqual(driver.typeReads, 0)
        XCTAssertTrue(driver.changes.isEmpty)
        try driver.send(.dragged, to: monitor)
        XCTAssertTrue(driver.changes.isEmpty)
        driver.receive?(.ended)
        try driver.send(.began, to: monitor)
        driver.count += 1
        try driver.send(.dragged, to: monitor)
        XCTAssertEqual(monitor.state, .init(active: true, types: .file))
        XCTAssertEqual(driver.typeReads, 1)
    }

    func testPartialMonitorInstallationIsRemovedWithoutLeavingAnActiveInbox() {
        let driver = Driver()
        driver.monitorCount = 1
        let monitor = driver.monitor()
        monitor.setDemand(true)
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(driver.removed, 1)
        XCTAssertFalse(monitor.monitoring)
        driver.receive?(.dragged)
        XCTAssertTrue(driver.changes.isEmpty)
    }

    func testIslandWireAndPlacementRebuildKeepDragState() throws {
        let driver = Driver()
        let monitor = driver.monitor()
        monitor.setDemand(true)
        defer { monitor.setDemand(false) }
        driver.count += 1
        driver.offered = [.text, .url]
        try driver.send(.dragged, to: monitor)
        let host = host()
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        host.islandDragMonitor = monitor
        let display = display()
        let key = ShellBarKey(monitor: display.id, placement: .island)
        let data = try XCTUnwrap(host.islandPlacements([.init(monitor: display, fullscreen: false)])[key]?.surface)
        XCTAssertEqual(data.drag, .init(active: true, types: [.text, .url]))
        var writer = ShellValueWriter()
        data.write(to: &writer)
        let drag = try XCTUnwrap(ShellServiceValue.decode(writer.bytes).fields?["drag"]?.fields)
        XCTAssertEqual(drag["active"], .bool(true))
        XCTAssertEqual(drag["types"], .array([.text("url"), .text("text")]))
        host.islandData[key] = ShellBarData(surface: data)
        host.publishIslandDrag(.init())
        XCTAssertEqual(host.islandData[key]?.surface?.drag, .init())
    }

    func testVisibleDropDeclarationChangesAndCloseOwnExactMonitorLifetime() throws {
        _ = NSApplication.shared
        let widget = try ShellRenderedWidget(name: "drag-demand", source: """
        function render(ctx)
            if ctx.data.seconds == 1 then return ui.box{w=30,h=20,accepts={'file'},onDrop=function() end} end
            return ui.box{w=30,h=20}
        end
        """)
        widget.set("seconds") { $0.number(0) }
        widget.render(ShellBarData())
        let display = display()
        let island = ShellIsland(
            surface: widget.surface,
            monitor: display,
            size: CGSize(width: 300, height: 150),
            registry: OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        )
        let host = host()
        let driver = Driver()
        let monitor = driver.monitor()
        host.islandDragMonitor = monitor
        host.islandWindows[display.id] = island
        host.connectIslandInput(island, on: display.id)
        defer { host.closeIslands() }
        island.update(monitor: display, size: CGSize(width: 300, height: 150), visible: true, level: .normal)
        XCTAssertEqual(driver.installs, 0)
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        XCTAssertEqual(driver.installs, 1)
        XCTAssertTrue(monitor.monitoring)
        island.update(monitor: display, size: CGSize(width: 300, height: 150), visible: false, level: .normal)
        XCTAssertEqual(driver.removed, 2)
        island.update(monitor: display, size: CGSize(width: 300, height: 150), visible: true, level: .normal)
        XCTAssertEqual(driver.installs, 2)
        widget.set("seconds") { $0.number(0) }
        widget.render(ShellBarData())
        XCTAssertEqual(driver.removed, 4)
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        XCTAssertEqual(driver.installs, 3)
        host.closeIslands()
        XCTAssertEqual(driver.removed, 6)
        XCTAssertFalse(monitor.monitoring)
    }

    private func display() -> Monitor {
        Monitor(
            id: .init(displayId: 95800),
            displayId: 95800,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
            hasNotch: false,
            name: "Island drag"
        )
    }

    private func host() -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { _, _ in },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
    }
}
