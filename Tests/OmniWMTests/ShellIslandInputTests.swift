// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellIslandInputTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        let island: ShellIsland
        let monitor: Monitor
        var events: [ShellClick] = []

        init(_ body: String, display: UInt32 = 95101) throws {
            _ = NSApplication.shared
            monitor = Monitor(
                id: .init(displayId: display), displayId: display,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
                hasNotch: false, name: "Island input \(display)"
            )
            widget = try ShellRenderedWidget(name: "island-input", source: "function render(ctx) " + body + " end")
            widget.surface.sequence = 1
            widget.render(ShellBarData())
            island = ShellIsland(
                surface: widget.surface, monitor: monitor, size: CGSize(width: 300, height: 150),
                registry: OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
            )
            widget.surface.onAction = { [weak self] in self?.events.append($0) }
        }

        func show(_ visible: Bool = true) {
            island.update(monitor: monitor, size: CGSize(width: 300, height: 150), visible: visible, level: .normal)
        }

        func screenPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: island.geometry.frame.minX + point.x, y: island.geometry.frame.maxY - point.y)
        }

        func render(seconds: Double, sequence: Int) {
            widget.set("seconds") { $0.number(seconds) }
            widget.surface.sequence = sequence
            widget.render(ShellBarData())
        }
    }

    func testFocusTransfersAcrossDisplaysAndStaleCallbacksCannotReleaseNewLease() throws {
        let policy = FocusPolicyEngine()
        let host = host(policy)
        let first = try Fixture("return ui.box{w=80,h=30,focusable=true,keys={'escape'},onKey=function() end}")
        let second = try Fixture(
            "return ui.box{w=80,h=30,focusable=true,keys={'escape'},onKey=function() end}",
            display: 95102
        )
        attach(first, to: host)
        attach(second, to: host)
        defer { host.closeIslands() }
        first.show()
        second.show()
        first.widget.surface.focusDeclared(first.widget.surface.layout.core.rootHandle)
        XCTAssertEqual(host.focusedIsland, first.monitor.id)
        XCTAssertEqual(policy.activeLease?.owner, .shellIsland)
        XCTAssertTrue(first.island.panel.canBecomeKey)
        XCTAssertEqual(host.islandData[key(first)]?.surface?.focused, true)
        XCTAssertEqual(host.islandData[key(second)]?.surface?.focused, false)

        second.widget.surface.focusDeclared(second.widget.surface.layout.core.rootHandle)
        XCTAssertEqual(host.focusedIsland, second.monitor.id)
        XCTAssertEqual(policy.activeLease?.owner, .shellIsland)
        XCTAssertFalse(first.widget.surface.declaredFocus)
        XCTAssertFalse(first.island.panel.canBecomeKey)
        XCTAssertTrue(second.island.panel.canBecomeKey)
        XCTAssertEqual(host.islandData[key(first)]?.surface?.focused, false)
        XCTAssertEqual(host.islandData[key(second)]?.surface?.focused, true)
        first.island.onFocusChange?(false)
        first.island.onBlur?()
        XCTAssertEqual(host.focusedIsland, second.monitor.id)
        XCTAssertEqual(policy.activeLease?.owner, .shellIsland)

        second.widget.surface.blurDeclaredFocus()
        XCTAssertNil(host.focusedIsland)
        XCTAssertNil(policy.activeLease)
        XCTAssertFalse(second.island.panel.canBecomeKey)
        XCTAssertEqual(host.islandData[key(second)]?.surface?.focused, false)
        XCTAssertNil(host.islandInputMonitors)
    }

    func testOutsideOnlyTargetKeepsEnvelopeTransparentAndUsesCurrentLocalCoordinatesAndSequence() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=120,h=70,center=false,pad=10+(ctx.data.seconds or 0),ui.box{w=40,h=20,onOutsidePress=function() end}}"
            )
        defer { fixture.island.close() }
        fixture.show()
        XCTAssertTrue(fixture.island.hasOutsidePress)
        XCTAssertTrue(fixture.island.regions.isEmpty)
        XCTAssertFalse(fixture.widget.surface.hasAction(at: CGPoint(x: 20, y: 15)))
        var event = ShellEvent(button: .right)
        event.kind = .outsidePress
        fixture.island.outsidePress(at: fixture.screenPoint(CGPoint(x: 20, y: 15)), event: event)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.island.outsidePress(at: fixture.screenPoint(CGPoint(x: 80, y: 15)), event: event)
        XCTAssertEqual(fixture.events.count, 1)
        XCTAssertEqual(fixture.events[0].event.x, 70)
        XCTAssertEqual(fixture.events[0].event.y, 5)
        XCTAssertEqual(fixture.events[0].event.button, .right)
        XCTAssertEqual(fixture.events[0].sequence, 1)

        fixture.render(seconds: 5, sequence: 9)
        fixture.island.outsidePress(at: fixture.screenPoint(CGPoint(x: 80, y: 25)), event: event)
        XCTAssertEqual(fixture.events.count, 2)
        XCTAssertEqual(fixture.events[1].event.x, 65)
        XCTAssertEqual(fixture.events[1].event.y, 10)
        XCTAssertEqual(fixture.events[1].sequence, 9)
    }

    func testOutsideTargetsUseAncestorScrollClipAndIgnoreFullyClippedAndInvisibleDeclarations() throws {
        let fixture =
            try Fixture(
                "return ui.column{w=40,h=20,scroll=true,ui.box{w=40,h=40,onOutsidePress=function() end},ui.box{w=40,h=20,onOutsidePress=function() end},ui.box{w=40,h=20,opacity=0,onOutsidePress=function() end}}"
            )
        defer { fixture.island.close() }
        fixture.show()
        XCTAssertEqual(fixture.widget.surface.outsidePressTargets.count, 3)
        var event = ShellEvent()
        event.kind = .outsidePress
        fixture.island.outsidePress(at: fixture.screenPoint(CGPoint(x: 5, y: 10)), event: event)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.island.outsidePress(at: fixture.screenPoint(CGPoint(x: 5, y: 30)), event: event)
        XCTAssertEqual(fixture.events.count, 1)
        XCTAssertEqual(fixture.events.first?.event.y, 30)
    }

    func testMonitorDemandStopsAndRestartsAndIgnoresOldGenerationWithoutConsumingLocalClick() throws {
        let host = host(FocusPolicyEngine())
        let fixture = try Fixture("return ui.box{w=40,h=20,onOutsidePress=function() end}")
        attach(fixture, to: host)
        defer { host.closeIslands() }
        host.updateIslandInputMonitoring()
        XCTAssertNil(host.islandInputMonitors)
        fixture.show()
        XCTAssertNotNil(host.islandInputMonitors)
        let firstGeneration = host.islandInputGeneration
        host.updateIslandInputMonitoring()
        XCTAssertEqual(host.islandInputGeneration, firstGeneration)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: fixture.screenPoint(CGPoint(x: 80, y: 30)), modifierFlags: [.shift],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        XCTAssertTrue(host.handleIslandLocalPress(event, generation: firstGeneration) === event)
        XCTAssertEqual(fixture.events.count, 1)
        XCTAssertEqual(fixture.events.first?.event.shift, true)

        fixture.show(false)
        XCTAssertNil(host.islandInputMonitors)
        XCTAssertTrue(host.handleIslandLocalPress(event, generation: firstGeneration) === event)
        XCTAssertEqual(fixture.events.count, 1)
        fixture.show()
        XCTAssertNotNil(host.islandInputMonitors)
        XCTAssertNotEqual(host.islandInputGeneration, firstGeneration)
        _ = host.handleIslandLocalPress(event, generation: firstGeneration)
        XCTAssertEqual(fixture.events.count, 1)
        _ = host.handleIslandLocalPress(event, generation: host.islandInputGeneration)
        XCTAssertEqual(fixture.events.count, 2)
        fixture.widget.surface.reset(text: fixture.widget.text)
        XCTAssertFalse(fixture.island.hasOutsidePress)
        XCTAssertNil(host.islandInputMonitors)
    }

    private func attach(_ fixture: Fixture, to host: ShellWidgetHost) {
        host.config.island = ShellIslandConfig()
        host.islandWindows[fixture.monitor.id] = fixture.island
        host.islandData[key(fixture)] = ShellBarData(surface: ShellIslandData(
            monitor: fixture.monitor, geometry: fixture.island.geometry, visible: true, fullscreen: false
        ))
        host.connectIslandInput(fixture.island, on: fixture.monitor.id)
    }

    private func key(_ fixture: Fixture) -> ShellBarKey {
        ShellBarKey(monitor: fixture.monitor.id, placement: .island)
    }

    private func host(_ policy: FocusPolicyEngine) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)), focusPolicyEngine: policy,
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
    }
}
