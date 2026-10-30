// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellSpectrumShapeContractTests: XCTestCase {
    private func widget(_ rotation: Double = 0, automatic: Bool = false) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(name: "spectrum-contract", source: """
        local renders=0
        function render(ctx)
            renders+=1
            local body={key='body',w=300,h=300,fill='#45516f',blend=8}
            if (ctx.data.settings or {}).visualiser~=false then
                body[1]=ui.shape{key='column',w=24,h=164.05,dx=128,dy=90,radius=10,hit=false,rotate=\(rotation),
                    spectrum={band=0.5,inset=4.05,threshold=1}}
            end
            return ui.stack{w=300,h=300,ui.glass(body),ui.text{key='count',text=tostring(renders)}}
        end
        """, resources: ShellResources(motion: MotionPolicy()))
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.automatic = automatic
            widget.surface.scene.spectrum.bands = ShellSpectrumBands()
            widget.surface.scene.spectrum.bands.store(.init(repeating: 0.25))
        }
        widget.render(ShellBarData())
        return widget
    }

    private func binding(_ widget: ShellRenderedWidget) throws -> ShellSpectrumShapeBinding {
        let slot = try VitreusFixture.element(widget, key: "column").slot
        return try ShellLayerScene.engineQueue.sync { try XCTUnwrap(widget.surface.scene.spectrum.bindings[slot]) }
    }

    private func tick(_ widget: ShellRenderedWidget, _ value: Float, at time: CFTimeInterval) -> Int {
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            widget.surface.scene.spectrum.bands.store(.init(repeating: value))
            let changed = widget.surface.scene.stepSpectrum(at: time)
            CATransaction.commit()
            return changed
        }
    }

    func testSpectrumWireReusesTextAndAudioWithoutAddingAScriptDataDependency() throws {
        let result = try ShellP3WireFixture.render("""
        ui.glass{ui.shape{key='wave',w=20,h=120,hit=false,rotate=35,
            spectrum={band=0.75,gain=2,taper=0.8,inset=4,threshold=1,response=0.3,bounce=0.4}}}
        """)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        let node = result.nodes[1]
        let recipe = try XCTUnwrap(ShellSpectrumShapeRecipe(result.text.string(node.text)))
        XCTAssertEqual(recipe.band, 0.75)
        XCTAssertEqual(recipe.gain, 2)
        XCTAssertEqual(recipe.taper, 0.8, accuracy: 0.00001)
        XCTAssertEqual(recipe.inset, 4)
        XCTAssertEqual(recipe.threshold, 1)
        XCTAssertEqual(recipe.spring.response, 0.3, accuracy: 0.00001)
        XCTAssertEqual(recipe.spring.bounce, 0.4, accuracy: 0.00001)
        XCTAssertTrue(result.tree[1].content.audio)
        XCTAssertFalse(result.tree[1].content.glassHit)
        let header = result.wire.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self) }
        XCTAssertNotEqual(header.flags & OMNI_WIRE_AUDIO, 0)
        XCTAssertEqual(header.deps & ShellDataKey.spectrum.bit, 0)
    }

    func testSpectrumRejectsInvalidOrCompetingGeometryOwners() throws {
        for fields in [
            "spectrum=true", "spectrum={}", "spectrum={band=-1}", "spectrum={band=2}",
            "spectrum={band=0,gain=math.huge}", "spectrum={band=0,taper=2}",
            "spectrum={band=0,inset=150}", "spectrum={band=0,response=0}",
            "spectrum={band=0,bounce=1}", "spectrum={band=0,unknown=1}",
            "spectrum={band=0},animate='spring'", "spectrum={band=0},reveal={response=0.3}",
            "spectrum={band=0},morph={stops={{at=0},{at=1}}}",
            "spectrum={band=0},follow='target'", "spectrum={band=0},shape='ellipse'",
            "spectrum={band=0},shape='frame'"
        ] {
            try ShellP3WireFixture.reject("ui.glass{ui.shape{w=20,h=120,hit=false,\(fields)}}")
        }
        try ShellP3WireFixture.reject("ui.glass{ui.shape{w=20,h=120,spectrum={band=0}}}")
        try ShellP3WireFixture.reject("ui.glass{ui.shape{h=120,hit=false,spectrum={band=0}}}")
        XCTAssertNil(ShellSpectrumShapeRecipe("spectrum:0:1:1:0:0:0.276:0.43|extra:1"))
    }

    func testEngineUpdatesColumnsWithoutAnyLuaPublicationAndDemandStopsOnRemoval() throws {
        let widget = try widget()
        let original = widget.output()
        let binding = try binding(widget)
        let before = try XCTUnwrap(binding.target)
        XCTAssertEqual(tick(widget, 0.8, at: CACurrentMediaTime()), 1)
        let after = try XCTUnwrap(binding.target)
        XCTAssertGreaterThan(after.rect.height, before.rect.height)
        XCTAssertEqual(widget.output(), original)
        widget.set("spectrum") { ShellSpectrum(access: .granted, bars: [0.1]).write(into: &$0) }
        XCTAssertEqual(widget.output(), original)
        XCTAssertEqual(widget.strings().last, "1")
        VitreusFixture.settings(widget, ["visualiser": .bool(false)])
        widget.render(ShellBarData())
        let header = widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self) }
        XCTAssertEqual(header.flags & OMNI_WIRE_AUDIO, 0)
        XCTAssertEqual(header.deps & ShellDataKey.spectrum.bit, 0)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.spectrum.bindings.isEmpty)
            XCTAssertNil(widget.surface.scene.spectrum.timer)
        }
    }

    func testTimerIsBoundedByMountedBindingsAndVisibilityWithFakeBandsOnly() throws {
        let widget = try widget(automatic: true)
        let scene = widget.surface.scene
        ShellLayerScene.engineQueue.sync { XCTAssertNotNil(scene.spectrum.timer) }
        widget.surface.setVisible(false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(scene.spectrum.timer)
            XCTAssertEqual(scene.stepSpectrum(at: CACurrentMediaTime()), 0)
        }
        widget.surface.setVisible(true)
        ShellLayerScene.engineQueue.sync { XCTAssertNotNil(scene.spectrum.timer) }
        VitreusFixture.settings(widget, ["visualiser": .bool(false)])
        widget.render(ShellBarData())
        ShellLayerScene.engineQueue.sync { XCTAssertNil(scene.spectrum.timer) }
    }

    func testRemovingOnlyTheBindingRestoresTheOrdinaryShapeGeometryOwner() throws {
        let widget = try ShellRenderedWidget(name: "spectrum-unbind", source: """
        function render(ctx)
            return ui.glass{key='body',w=200,h=200,
                ui.shape{key='column',w=24,h=120,dx=40,dy=40,align='topLeading',hit=false,rotate=45,
                    spectrum=if (ctx.data.cpu or 0)<1 then {band=0.5,inset=4} else nil}}
        end
        """, resources: ShellResources(motion: MotionPolicy()))
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.automatic = false
            widget.surface.scene.spectrum.bands = ShellSpectrumBands()
            widget.surface.scene.spectrum.bands.store(.init(repeating: 0.7))
        }
        widget.render(ShellBarData())
        let slot = try VitreusFixture.element(widget, key: "column").slot
        let previous = try binding(widget)
        let body = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(widget.surface.scene.glassBodies[previous.body ?? -1])
        }
        let element = try XCTUnwrap(body.elements[1][.init(slot: slot, part: 0)])
        XCTAssertEqual(element.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        widget.set("cpu") { $0.number(1) }
        widget.render(ShellBarData())
        try ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.spectrum.bindings.isEmpty)
            XCTAssertTrue(body.elements[1][.init(slot: slot, part: 0)] === element)
            let raw = try XCTUnwrap(widget.surface.scene.glassShapes[slot])
            XCTAssertEqual(element.anchorPoint, .zero)
            XCTAssertEqual(element.position, raw.rect.origin)
            XCTAssertEqual(element.bounds.size, raw.rect.size)
            XCTAssertNil(element.animation(forKey: ShellGlassBody.Channel.height.key))
        }
    }

    func testPlainMaterialFallbackMaskFollowsTheSameSpectrumGeometry() async throws {
        let helper = ShellGlassSceneTests()
        let scene = helper.scene(native: false)
        ShellLayerScene.engineQueue.sync {
            scene.spectrum.automatic = false
            scene.spectrum.bands = ShellSpectrumBands()
            scene.spectrum.bands.store(.init(repeating: 0.25))
        }
        let commands: [ShellLayerCommand] = [
            .insert(slot: 0, parent: -1, kind: .glass, after: -1),
            helper.bodyGlass(),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 96, height: 96), animation: nil),
            .insert(slot: 1, parent: 0, kind: .shape, after: -1),
            .glass(slot: 1, ShellGlassContent(
                kind: .shape,
                recipe: "spectrum:0.5:1:1:4:1:0.276:0.43",
                shape: 0,
                paint: helper.paint(radius: 5),
                params: .zero,
                spectrumMotion: .disabled
            ), animation: nil),
            .frame(slot: 1, rect: CGRect(x: 20, y: 10, width: 12, height: 72), animation: nil)
        ]
        await helper.apply(commands, to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            let masks = body.trackLayers(1).values.flatMap { $0 }
            let before = try XCTUnwrap(masks.first).bounds.height
            scene.spectrum.bands.store(.init(repeating: 0.9))
            XCTAssertEqual(scene.stepSpectrum(at: CACurrentMediaTime()), 1)
            let target = try XCTUnwrap(scene.spectrum.bindings[1]?.target)
            for mask in masks {
                XCTAssertGreaterThan(mask.bounds.height, before)
                XCTAssertEqual(mask.position, CGPoint(x: target.rect.midX, y: target.rect.midY))
                XCTAssertNil(mask.animation(forKey: ShellGlassBody.Channel.height.key))
            }
        }
    }

    func testRetargetCarriesHeightVelocityAndUnrelatedUnanimatedCommitKeepsTheSpring() throws {
        let widget = try widget(45)
        let binding = try binding(widget)
        let body = try ShellLayerScene.engineQueue
            .sync { try XCTUnwrap(widget.surface.scene.glassBodies[binding.body ?? -1]) }
        let layer = try XCTUnwrap(binding.targets.values.first?.first)
        let start = CACurrentMediaTime()
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
            root.speed = 0
            root.timeOffset = start
            return try ShellOffscreenRenderer(root: root, width: 300, height: 300)
        }
        _ = tick(widget, 0.9, at: start)
        let first = try XCTUnwrap(layer.animation(forKey: ShellGlassBody.Channel.height.key) as? CASpringAnimation)
        let from = try XCTUnwrap(first.fromValue as? NSNumber).doubleValue
        let to = try XCTUnwrap(first.toValue as? NSNumber).doubleValue
        let spring = ShellSpringDynamics.Parameters(
            mass: first.mass,
            stiffness: first.stiffness,
            damping: first.damping
        )
        let elapsed = 0.04
        let value = to + ShellSpringDynamics.position(
            at: elapsed,
            displacement: from - to,
            initialVelocity: first.initialVelocity * (to - from),
            spring: spring
        )
        let velocity = ShellSpringDynamics.velocity(
            at: elapsed,
            displacement: from - to,
            initialVelocity: first.initialVelocity * (to - from),
            spring: spring
        )
        try ShellLayerScene.engineQueue.sync { _ = try renderer.render(paused: start + elapsed) }
        _ = tick(widget, 0.45, at: start + elapsed)
        let next = try XCTUnwrap(layer.animation(forKey: ShellGlassBody.Channel.height.key) as? CASpringAnimation)
        let nextFrom = try XCTUnwrap(next.fromValue as? NSNumber).doubleValue
        let nextTo = try XCTUnwrap(next.toValue as? NSNumber).doubleValue
        XCTAssertEqual(nextFrom, value, accuracy: 0.0001)
        XCTAssertEqual(next.initialVelocity * (nextTo - nextFrom), velocity, accuracy: 0.001)
        let count = body.elements[1].count
        let slot = try VitreusFixture.element(widget, key: "body").slot
        let style = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(widget.surface.scene.glassStyles[slot]) }
        widget.surface.scene.submit([.paint(slot: slot, style.paint, animation: nil)], animated: false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(body.elements[1].count, count)
            XCTAssertEqual(layer.animation(forKey: ShellGlassBody.Channel.height.key)?.beginTime, next.beginTime)
        }
    }
}
