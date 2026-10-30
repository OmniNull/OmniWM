// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellBoundTrackTests {
    func testAncestorRevealExitKeepsTheSourcesNativeGeometryOwner() throws {
        let body = Self.pulseBody.replacingOccurrences(of: "key='root',w=730,h=400,", with: """
        key='root',w=730,h=400,reveal={response=0.2},
        ui.box{key='closing-content',w=20,h=20,fill='#FFFFFFFF',
            morph={stops={{at=0,scale=0},{at=1}}}},
        """)
        let begin = CACurrentMediaTime() + 1
        let fixture = try Fixture(body, animations: true, clock: { begin })
        let stage = try ShellBoundSurfaceFixture.stage(fixture, at: begin)
        defer { withExtendedLifetime(stage) {} }
        let source = try helper.shape(fixture, "bound").slot
        let root = try helper.shape(fixture, "root").slot
        send(try input(at: begin, spring: .init(mass: 1, stiffness: 100, damping: 2)), to: source, on: fixture)
        let before = try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let entry = try XCTUnwrap(scene.shapeTracks.entries[source])
            let animation = try XCTUnwrap(entry.animations.first)
            let native = try XCTUnwrap(animation.layer.animation(forKey: animation.key) as? CAKeyframeAnimation)
            return (entry, animation.layer, animation.key, native)
        }
        let bound = try XCTUnwrap(before.0.bound)
        let time = try XCTUnwrap(bound.crossings(at: 0.7, rising: true).first) + 0.03
        let closing = ShellReveal(
            begin: time, progress: 1, target: 0,
            spring: ShellMorphRecipe.Spring(response: 0.2, bounce: 0).parameters
        )
        fixture.surface.scene.submit([.reveal(slot: root, token: 0, closing), .remove(slot: root)], animated: true)
        ShellLayerScene.engineQueue.sync {}
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertFalse(scene.presence.retained.isEmpty)
            XCTAssertNil(scene.shapeTracks.entries[source])
            let native = try XCTUnwrap(before.1.animation(forKey: before.2) as? CAKeyframeAnimation)
            XCTAssertEqual(native.beginTime, before.3.beginTime)
            XCTAssertEqual(native.duration, before.3.duration)
            XCTAssertEqual(native.keyTimes, before.3.keyTimes)
            XCTAssertEqual(native.values as NSArray?, before.3.values as NSArray?)
        }
    }
}
