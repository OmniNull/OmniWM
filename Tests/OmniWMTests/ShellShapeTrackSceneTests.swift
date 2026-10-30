// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellShapeTrackSceneTests: XCTestCase {
    final class Clock {
        var time = CACurrentMediaTime()
    }

    struct Fixture {
        let widget: ShellRenderedWidget
        let renderer: ShellOffscreenRenderer
        let clock: Clock
        let scene: ShellLayerScene
    }

    private func fixture(_ shapes: String? = nil, parentReveal: Bool = false) throws -> Fixture {
        let source = shapes ?? """
        local props = {key='a',w=if step>=4 and step~=6 then 100 else 80,h=60,dx=-40,radius=8,
            reveal={response=.482,bounce=.31,delay=.03,hold=.05},
            morph={anchor={x=1,y=.5},stops={{at=0,scale=0,round=0},{at=1,scale=1,round=1}}}}
        if step==3 then props.reveal.exit=false end
        if step==4 then props.reveal=nil props.morph=nil end
        if step==6 then props.reveal=nil end
        if step~=1 then body[#body+1]=ui.shape(props) end
        if step==1 then body[#body+1]=ui.shape{key='b',w=12,h=12,dx=70} end
        """
        let widget = try ShellRenderedWidget(name: "shape-track", source: """
        function render(ctx)
            local step = ctx.data.seconds or 0
            local body = {key='body',w=256,h=256,blend=0,fill='#FFFFFFFF',blurRadius=0,
                shadow='#00000000',shadowRadius=0,saturation=1}
            \(source)
            return ui.stack{key='root',w=256,h=256,reveal=if \(parentReveal) then {response=.05,bounce=0} else nil,ui.glass(body),ui.stack{key='content',reveal={response=.482,bounce=.31},
                ui.stack{morph={stops={{at=0,scale=.05,opacity=0},{at=1,scale=1,opacity=1}}},w=1,h=1}}}
        end
        """)
        let clock = Clock()
        widget.resources.motion.userAnimationsEnabled = true
        widget.surface.clock = { clock.time }
        widget.surface.animates = true
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
            root.speed = 0
            root.timeOffset = clock.time
            return try ShellOffscreenRenderer(root: root, width: 256, height: 256)
        }
        widget.render(ShellBarData(monitor: "test"))
        return Fixture(widget: widget, renderer: renderer, clock: clock, scene: widget.surface.scene)
    }

    private func step(_ value: Double, _ fixture: Fixture, after elapsed: Double = 0) {
        fixture.clock.time += elapsed
        ShellLayerScene.engineQueue.sync { fixture.scene.container.timeOffset = fixture.clock.time }
        fixture.widget.set("seconds") { $0.number(value) }
        fixture.widget.render(ShellBarData(monitor: "test"))
    }

    private func handle(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        let key = name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
            & ~(UInt64(3) << 62)
        return try XCTUnwrap(fixture.widget.surface.layout.core.elements { _ in true }.first {
            fixture.widget.surface.layout.core.key(of: $0) == key
        })
    }

    private func entry(_ fixture: Fixture, _ name: String) throws -> ShellShapeTrackEntry {
        let slot = try handle(fixture, name).slot
        return try ShellLayerScene.engineQueue.sync { try XCTUnwrap(fixture.scene.shapeTracks.entries[slot]) }
    }

    func testOwnShapeDelayAndSiblingContentUseOneCommitClockAndRenderAt84Milliseconds() throws {
        let fixture = try fixture()
        let shape = try entry(fixture, "a")
        let content = try handle(fixture, "content")
        let root = try XCTUnwrap(fixture.widget.surface.reveals[content]?.plan)
        XCTAssertEqual(shape.begin, root.begin)
        XCTAssertEqual(shape.plan?.begin ?? 0, shape.begin + 0.03, accuracy: 1e-9)
        XCTAssertEqual(shape.shape(at: shape.begin + 0.02).rect.size, .zero)
        let clock = shape.begin + 0.084
        let pixels = try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(fixture.scene.glassBodies[shape.body])
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
            for index in [0, 2, 3] { body.sdfLayers[index].isHidden = true }
            return try fixture.renderer.render(paused: clock)
        }
        assertEqual(try bounds(pixels), shape.shape(at: clock).rect, accuracy: 1)
    }

    func testRemovalKeepsAnOrderedDistinctRenderSlotWhileACoreSlotIsReused() throws {
        let fixture = try fixture()
        let original = try handle(fixture, "a").slot
        step(1, fixture, after: 0.1)
        let replacement = try handle(fixture, "b").slot
        let retained = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries.first { $0.value.carrier != nil })
        }
        XCTAssertNotEqual(retained.key, original)
        XCTAssertNotEqual(retained.key, replacement)
        XCTAssertEqual(retained.value.plan?.begin ?? 0, fixture.clock.time + 0.05, accuracy: 1e-9)
        ShellLayerScene.engineQueue.sync {
            let scene = fixture.scene
            XCTAssertNotNil(scene.glassShapes[replacement])
            XCTAssertNotNil(scene.glassShapes[retained.key])
            scene.completeShapeTrack(retained.key, generation: retained.value.generation &- 1)
            XCTAssertNotNil(scene.glassShapes[retained.key])
            scene.completeShapeTrack(retained.key, generation: retained.value.generation)
            scene.completeShapeTrack(retained.key, generation: retained.value.generation)
            XCTAssertNil(scene.glassShapes[retained.key])
            XCTAssertNotNil(scene.glassShapes[replacement])
            XCTAssertNil(retained.value.carrier?.superlayer)
        }
    }

    func testReinsertionDuringHoldSeedsProgressVelocityAndReusesNativeLayers() throws {
        let fixture = try fixture()
        step(1, fixture, after: 0.1)
        let old = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries.first { $0.value.carrier != nil })
        }
        let native = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.glassBodies[old.value.body]?.lockstepLayers(old.key).first)
        }
        fixture.clock.time += 0.02
        let seed = try XCTUnwrap(old.value.plan?.state(at: fixture.clock.time))
        step(2, fixture)
        let reopened = try entry(fixture, "a")
        XCTAssertEqual(reopened.plan?.progress ?? -1, seed.progress, accuracy: 1e-9)
        XCTAssertEqual(reopened.plan?.velocity ?? -1, seed.velocity, accuracy: 1e-9)
        XCTAssertEqual(reopened.plan?.begin, fixture.clock.time)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(fixture.scene.shapeTracks.retired.isEmpty)
            XCTAssertTrue(fixture.scene.glassBodies[reopened.body]?.lockstepLayers(reopened.base.target.slot)
                .first === native)
            fixture.scene.completeShapeTrack(old.key, generation: old.value.generation)
            XCTAssertNotNil(fixture.scene.glassShapes[reopened.base.target.slot])
        }
    }

    func testLiveExitPolicyAndRemovingTrackPropertiesDoNotKeepOldPlans() throws {
        let fixture = try fixture()
        step(3, fixture, after: 0.08)
        let shape = try handle(fixture, "a")
        XCTAssertFalse(try XCTUnwrap(fixture.widget.surface.reveals[shape]?.recipe.exits))
        step(1, fixture, after: 0.01)
        ShellLayerScene.engineQueue.sync {
            XCTAssertFalse(fixture.scene.shapeTracks.entries.values.contains { $0.carrier != nil })
        }
        XCTAssertTrue(fixture.widget.surface.retiringReveals.isEmpty)
        step(2, fixture)
        step(4, fixture, after: 0.08)
        let slot = try handle(fixture, "a").slot
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(fixture.scene.shapeTracks.entries[slot])
            let body = fixture.scene.parents[slot].flatMap { fixture.scene.glassBodies[$0] }
            for layer in body?.lockstepLayers(slot) ?? [] {
                XCTAssertNil(layer.animation(forKey: "omni.glass.position"))
            }
        }
    }

    func testHideFinalizesAnalyticStateAndBodyRemovalDropsRetainedCarriers() throws {
        let fixture = try fixture()
        fixture.widget.surface.setVisible(false)
        ShellLayerScene.engineQueue.sync {}
        let finished = try entry(fixture, "a")
        XCTAssertNil(finished.plan)
        XCTAssertTrue(finished.impulses.isEmpty)
        XCTAssertNil(finished.edges)
        fixture.widget.surface.setVisible(true)
        step(5, fixture, after: 0.08)
        let resized = try entry(fixture, "a")
        XCTAssertEqual(resized.shape(at: fixture.clock.time).rect.width, 100, accuracy: 1e-9)
        step(1, fixture)
        let body = try handle(fixture, "body").slot
        fixture.scene.submit([.remove(slot: body)], animated: false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(fixture.scene.shapeTracks.entries.isEmpty)
            XCTAssertTrue(fixture.scene.shapeTracks.retired.isEmpty)
        }
    }

    func testTriggersWaitForACrossingAndChainedPulsesUseTheShiftedSourceClock() throws {
        let waiting = try fixture("""
        body[1]=ui.shape{key='source',w=10,h=10}
        body[2]=ui.shape{key='pulse',w=80,h=60,reveal={response=.3,bounce=.2},
            morph={trigger={shape='source',at=.97},stops={{at=0,scale=0},{at=1,scale=1}}}}
        """)
        let idle = try entry(waiting, "pulse")
        XCTAssertNil(idle.plan)
        XCTAssertEqual(idle.shape(at: waiting.clock.time + 1).rect.size, .zero)
        let chained = try fixture("""
        body[1]=ui.shape{key='source',w=10,h=10,reveal={response=.482,bounce=.31},
            morph={stops={{at=0,scale=0},{at=1,scale=1}}}}
        body[2]=ui.shape{key='pulse',w=80,h=60,reveal={response=.3,bounce=.2},
            morph={trigger={shape='source',at=.97},stops={{at=0,scale=0},{at=1,scale=1}}}}
        body[3]=ui.shape{key='chained',w=20,h=20,reveal={response=.4,bounce=.1},
            morph={trigger={shape='pulse',at=.5},stops={{at=0,scale=0},{at=1,scale=1}}}}
        """)
        let source = try entry(chained, "source")
        let pulse = try entry(chained, "pulse")
        let tail = try entry(chained, "chained")
        let first = try XCTUnwrap(source.plan?.crossings(at: 0.97, rising: true).first)
        XCTAssertEqual(pulse.plan?.begin ?? 0, first, accuracy: 0.001)
        let second = try XCTUnwrap(pulse.plan?.crossings(at: 0.5, rising: true).first)
        XCTAssertEqual(tail.plan?.begin ?? 0, second, accuracy: 0.001)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(pulse.shape(at: first - 0.001).rect.size, .zero)
    }

    func testReplacingAFrameKeepsTheSingleFrameBodyValid() throws {
        let fixture = try fixture("""
        body.blend=8
        body[1]=ui.shape{key=if step==0 then 'frame-a' else 'frame-b',shape='frame',
            w=336,h=336,radius=80,thickness=40,reveal={response=.482,bounce=.31,hold=.05},
            morph={stops={{at=0,scale=1,dx=0},{at=1,scale=1,dx=0}}}}
        """)
        step(1, fixture, after: 0.1)
        let frame = try entry(fixture, "frame-b")
        ShellLayerScene.engineQueue.sync {
            XCTAssertFalse(fixture.scene.shapeTracks.entries.values.contains { $0.carrier != nil })
            XCTAssertEqual(fixture.scene.glassShapes.values.filter { $0.kind == 2 }.count, 1)
            XCTAssertTrue(fixture.scene.glassBodies[frame.body]?.nativeAvailable == true)
        }
    }

    func testGeometryRetargetKeepsTheCompositeAndCarriesBaseVelocity() throws {
        let fixture = try fixture("""
        body[1]=ui.shape{key='a',w=if step==0 then 80 elseif step==1 then 100 else 90,h=60,radius=8,
            animate={response=.363,bounce=.42},reveal={response=.482,bounce=.31},
            morph={stops={{at=0,scale=0},{at=1,scale=1}}}}
        """)
        fixture.clock.time += 0.08
        let old = try entry(fixture, "a")
        let before = old.shape(at: fixture.clock.time)
        step(1, fixture)
        let first = try entry(fixture, "a")
        assertEqual(first.shape(at: fixture.clock.time).rect, before.rect, accuracy: 1e-9)
        fixture.clock.time += 0.04
        let moving = first.base.state(at: fixture.clock.time)
        XCTAssertGreaterThan(abs(moving.velocity[2]), 1)
        let presented = first.shape(at: fixture.clock.time)
        step(2, fixture)
        let second = try entry(fixture, "a")
        assertEqual(second.shape(at: fixture.clock.time).rect, presented.rect, accuracy: 1e-9)
        XCTAssertEqual(second.base.velocity[2], moving.velocity[2], accuracy: 1e-9)
    }

    func testReduceMotionFinishesTracksWithoutReplayingThemOnTheNextCommit() throws {
        let fixture = try fixture()
        fixture.widget.resources.motion.userAnimationsEnabled = false
        step(0, fixture, after: 0.08)
        let final = try entry(fixture, "a")
        XCTAssertNil(final.plan)
        XCTAssertEqual(final.terminal.rect.width, 80, accuracy: 1e-9)
        fixture.widget.resources.motion.userAnimationsEnabled = true
        step(5, fixture, after: 0.01)
        let resized = try entry(fixture, "a")
        XCTAssertNil(resized.plan)
        XCTAssertEqual(resized.shape(at: fixture.clock.time).rect.width, 100, accuracy: 1e-9)
    }

    func testRemovingOwnRevealAdoptsTheSettledAncestorInsteadOfTheObsoletePlan() throws {
        let fixture = try fixture(parentReveal: true)
        let root = try handle(fixture, "root")
        let token = try XCTUnwrap(fixture.widget.surface.reveals[root]?.token)
        fixture.widget.surface.revealSettled(root.slot, token: token)
        let old = try entry(fixture, "a")
        XCTAssertNotNil(old.plan)
        ShellLayerScene.engineQueue.sync { XCTAssertNil(fixture.scene.presence.revealPlans[root.slot]) }
        step(6, fixture, after: 0.08)
        let changed = try entry(fixture, "a")
        XCTAssertEqual(changed.root, root.slot)
        XCTAssertNil(changed.plan)
        XCTAssertEqual(changed.terminal.rect.width, 80, accuracy: 1e-9)
    }

    private func bounds(_ pixels: [UInt8]) throws -> CGRect {
        var left = 256, right = -1, top = 256, bottom = -1
        for y in 0 ..< 256 {
            for x in 0 ..< 256 where pixels[(y * 256 + x) * 4 + 3] >= 128 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left else { throw ShellScriptFailure(kind: .runtime, message: "The shape track rendered empty") }
        return CGRect(x: left, y: top, width: right + 1 - left, height: bottom + 1 - top)
    }

    private func assertEqual(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, line: line)
    }
}

@MainActor
extension ShellShapeTrackSceneTests {
    func testAnUnanimatedLayoutJumpEndsOnlyTheRevealAndTrackItMoves() throws {
        let fixture = try fixture()
        let surface = fixture.widget.surface
        let shape = try handle(fixture, "a")
        let content = try handle(fixture, "content")
        let group = try XCTUnwrap(surface.layout.core.elements { _ in true }.first {
            surface.layout.core.paint(of: $0).morph != 0 && surface.layout.core.kind(of: $0) != .shape
        })
        fixture.clock.time += 0.05
        let plan = try XCTUnwrap(surface.reveals[shape]?.plan)
        let moved = CGRect(x: 20, y: 30, width: 80, height: 60)
        fixture.scene.submit([
            .frame(slot: shape.slot, rect: moved, animation: nil),
            .reveal(slot: shape.slot, token: 999, plan.retargeted(at: fixture.clock.time, to: 1))
        ], animated: false)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.scene
            XCTAssertNil(scene.presence.revealPlans[shape.slot])
            let entry = try XCTUnwrap(scene.shapeTracks.entries[shape.slot])
            XCTAssertNil(entry.plan)
            XCTAssertTrue(entry.animations.isEmpty)
            XCTAssertEqual(entry.terminal.rect, moved)
            for layer in try XCTUnwrap(scene.glassBodies[entry.body]).lockstepLayers(shape.slot) {
                XCTAssertNil(layer.animation(forKey: "omni.glass.position"))
                XCTAssertEqual(layer.position, moved.origin)
            }
            XCTAssertNotNil(scene.presence.revealPlans[content.slot])
            XCTAssertNotNil(scene.layers[group.slot]?.animation(forKey: ShellLayerScene.revealTransformKey))
        }
    }
}
