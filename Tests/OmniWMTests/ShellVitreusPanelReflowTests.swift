// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusPanelReflowTests: XCTestCase {
    let windows = ShellVitreusWindowShelfTests()

    private func renderer(_ fixture: ShellVitreusDrawerTests.Fixture) throws -> ShellOffscreenRenderer {
        try ShellLayerScene.engineQueue.sync {
            let root = fixture.scene.container
            root.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
            let renderer = try ShellOffscreenRenderer(root: root, width: 1920, height: 1080)
            root.speed = 0
            root.timeOffset = 30
            _ = try renderer.render(paused: 33)
            return renderer
        }
    }

    private func assertHeightSpring(_ fixture: ShellVitreusDrawerTests.Fixture) throws {
        let widget = fixture.widget
        let target = try VitreusFixture.element(widget, key: "drawer-content-controls")
        let glass = try VitreusFixture.element(widget, key: "drawer")
        let expected = ShellSpringDynamics.Parameters(ShellAnimation(
            motion: .spring(response: 0.513, bounce: 0.06),
            speed: 1
        ))
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(fixture.scene.layers[target.slot])
            let keys = layer.animationKeys() ?? []
            XCTAssertTrue(keys.contains { $0.hasPrefix("bounds") }, "\(keys)")
            XCTAssertEqual(fixture.scene.shapeTracks.entries[glass.slot]?.base.spring, expected)
        }
    }

    func testHoldingKeepsTheSlotAndReleaseRetractsTheDockedPanelWithTheGlassSpring() throws {
        let fixture = try windows.drawers.fixture(animations: true)
        windows.seed(fixture.widget)
        windows.trigger(fixture, "drawer-controls")
        let before = try windows.frame(fixture, "drawer-content-controls")
        let renderer = try renderer(fixture)
        let point = try windows.grab(fixture, id: "controls-toggles", to: CGPoint(x: 100, y: 650))
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-controls").height, before.height)
        windows.drop(fixture, at: point)
        XCTAssertLessThan(try windows.frame(fixture, "drawer-content-controls").height, before.height)
        XCTAssertFalse(windows.has(fixture, "card-slot-controls-toggles"))
        try assertHeightSpring(fixture)
        windows.trigger(fixture, "drawer-controls")
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-controls").height, before.height)
        try assertHeightSpring(fixture)
        let sliders = try VitreusFixture.element(fixture.widget, key: "drawer-content-controls-sliders")
        XCTAssertNil(fixture.widget.surface.followMotion(of: sliders))
        XCTAssertEqual(fixture.widget.surface.animation(for: sliders)?.motion, .spring(response: 0.513, bounce: 0.06))
        withExtendedLifetime(renderer) {}
    }

    func testLoosePanelsRetractTogetherWithoutDeclaringAnUnsupportedBoundSpring() throws {
        let fixture = try windows.drawers.fixture(animations: true)
        windows.seed(fixture.widget)
        windows.trigger(fixture, "drawer-controls")
        try windows.move(fixture, id: "controls", to: CGPoint(x: 700, y: 400))
        let before = try windows.frame(fixture, "drawer-content-controls")
        let point = try windows.grab(fixture, id: "controls-toggles", to: CGPoint(x: 100, y: 650))
        windows.drop(fixture, at: point)
        XCTAssertLessThan(try windows.frame(fixture, "drawer-content-controls").height, before.height)
        let target = try VitreusFixture.element(fixture.widget, key: "drawer-content-controls")
        XCTAssertNil(fixture.widget.surface.animation(for: target))
        let sliders = try VitreusFixture.element(fixture.widget, key: "drawer-content-controls-sliders")
        XCTAssertNil(fixture.widget.surface.animation(for: sliders))
    }

    func testEmptyControlsAndPlayerKeepASmallReachableHeaderAndReturnToFullSize() throws {
        let sections = ShellVitreusSectionCardTests()
        for (owner, ids) in [
            ("controls", ["controls-toggles", "controls-sliders"]),
            ("player", ["player-album", "player-windows"])
        ] {
            let fixture = try windows.fixture()
            windows.trigger(fixture, "drawer-" + owner)
            let before = try windows.frame(fixture, "drawer-content-" + owner)
            for (index, id) in ids.enumerated() {
                try sections.moveCard(fixture, id: id, to: CGPoint(x: 50 + 600 * index, y: 650))
            }
            XCTAssertEqual(try windows.frame(fixture, "drawer-content-" + owner).height, 36 * 1.5525, accuracy: 0.01)
            windows.trigger(fixture, "drawer-" + owner)
            XCTAssertEqual(try windows.frame(fixture, "drawer-content-" + owner).height, before.height)
        }
    }
}

@MainActor
extension ShellVitreusPanelReflowTests {
    func testTheDockedClipMaskPathAnimatesDuringRetraction() throws {
        let fixture = try windows.drawers.fixture(animations: true)
        windows.seed(fixture.widget)
        windows.trigger(fixture, "drawer-controls")
        let renderer = try renderer(fixture)
        windows.drop(fixture, at: try windows.grab(fixture, id: "controls-toggles", to: CGPoint(x: 100, y: 650)))
        let mask = try VitreusFixture.element(fixture.widget, key: "drawer-mask-controls")
        try ShellLayerScene.engineQueue.sync {
            let native = try XCTUnwrap(fixture.scene.masks[mask.slot]?.layer)
            XCTAssertNotNil(native.animation(forKey: "path"))
        }
        withExtendedLifetime(renderer) {}
    }

    func testClickRedockingALooseRetractedPanelSeedsGlassFromItsDrawnRect() throws {
        let fixture = try windows.drawers.fixture(animations: true)
        windows.seed(fixture.widget)
        windows.trigger(fixture, "drawer-controls")
        let renderer = try renderer(fixture)
        try windows.move(fixture, id: "controls", to: CGPoint(x: 700, y: 400))
        windows.drop(fixture, at: try windows.grab(fixture, id: "controls-toggles", to: CGPoint(x: 100, y: 650)))
        let before = try windows.frame(fixture, "drawer-content-controls")
        windows.trigger(fixture, "drawer-controls")
        let glass = try VitreusFixture.element(fixture.widget, key: "drawer")
        try ShellLayerScene.engineQueue.sync {
            let base = try XCTUnwrap(fixture.scene.shapeTracks.entries[glass.slot]?.base)
            let start = CGRect(x: base.from[0], y: base.from[1], width: base.from[2], height: base.from[3])
            ShellVitreusMediaCardTests.assertRect(start, before)
            XCTAssertGreaterThan(base.duration, 0)
        }
        withExtendedLifetime(renderer) {}
    }
}
