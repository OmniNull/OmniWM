// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    func testReturningASectionToABottomStuckParentStartsAtItsReleaseRect() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        let full = try windows.frame(fixture, "drawer-content-calendar")
        try windows.move(fixture, id: "calendar", to: CGPoint(x: 500, y: 1080 - full.height))
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 500))
        let retracted = try windows.frame(fixture, "drawer-content-calendar")
        let release = CGPoint(x: retracted.minX + 20, y: retracted.minY + 20)
        let point = try windows.grab(fixture, id: "calendar-month", to: release)
        windows.drop(fixture, at: point)
        let parent = try windows.frame(fixture, "drawer-content-calendar")
        XCTAssertLessThan(parent.minY, retracted.minY)
        let card = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: card), try VitreusFixture.element(
            fixture.widget, key: "drawer-content-calendar"
        ))
        let rect = try windows.frame(fixture, "drawer-content-calendar-month")
        let paint = fixture.widget.surface.layout.core.paint(of: card)
        let appear = try XCTUnwrap(fixture.widget.surface.presence(paint.appear, for: card))
        XCTAssertEqual(appear.offset.x, release.x - rect.minX, accuracy: 0.01)
        XCTAssertEqual(appear.offset.y, release.y - rect.minY, accuracy: 0.01)
    }

    func testMixerChoosesItsSideWhenDemandedAudioAppsArrive() throws {
        for freeBelow in [0.0, 50.0] {
            let fixture = try windows.fixture()
            windows.trigger(fixture, "drawer-controls")
            let card = try windows.frame(fixture, "drawer-content-controls-sliders")
            try dragCard(fixture, "controls-sliders", to: CGPoint(
                x: 1000, y: 1080 - card.height - freeBelow * 1.5525
            ))
            _ = try windows.invoke(fixture, "controls-mixer-toggle")
            XCTAssertEqual(
                try windows.frame(fixture, "drawer-content-controls-mixer").height,
                28 * 1.5525, accuracy: 0.01
            )
            fixture.widget.set("audioApps") {
                ShellAudioApps(access: .granted, apps: (0 ..< 3).map {
                    .init(id: "test.app.\($0)", name: "App \($0)", playing: true, volume: 50, muted: false)
                }).write(into: &$0)
            }
            windows.show(fixture)
            let sliders = try windows.frame(fixture, "drawer-content-controls-sliders")
            let mixer = try windows.frame(fixture, "drawer-content-controls-mixer")
            XCTAssertEqual(mixer.height, 92 * 1.5525, accuracy: 0.01)
            XCTAssertEqual(mixer.maxY, sliders.minY - 12 * 1.35, accuracy: 0.01)
            XCTAssertFalse(mixer.intersects(sliders))
        }
    }
}
