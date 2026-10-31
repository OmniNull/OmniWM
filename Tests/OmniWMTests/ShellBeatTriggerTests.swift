// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
final class ShellBeatTriggerTests: XCTestCase {
    private let response = 0.5
    private var crest: String {
        "ui.shape{key='crest',w=18,h=18,hit=false,reveal={response=\(response),bounce=0,exit=false},"
    }

    private func widget() throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(name: "beat-trigger", source: """
        function render(ctx)
            local body={key='body',w=200,h=200,
                ui.shape{key='column',w=24,h=120,align='topLeading',hit=false,spectrum={band=0}}}
            if ctx.data.cpu then
                body[2]=\(crest)align='topLeading',dx=120,morph={stops={{at=0,h=0},{at=1}},trigger={beat=true}}}
            end
            return ui.glass(body)
        end
        """, resources: ShellResources(motion: MotionPolicy()))
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.automatic = false
            widget.surface.scene.spectrum.bands = ShellSpectrumBands()
        }
        widget.resources.motion.userAnimationsEnabled = true
        widget.render(ShellBarData())
        widget.set("cpu") { $0.number(1) }
        widget.render(ShellBarData())
        return widget
    }

    func testBeatTriggerWireRaisesAudioAndWaitsWithoutASourceShape() throws {
        let result = try ShellP3WireFixture.render("""
        ui.glass{\(crest)morph={stops={{at=0,h=0},{at=1}},trigger={beat=true}}}}
        """)
        let recipe = try XCTUnwrap(ShellMorphRecipe(result.text.string(result.nodes[1].morph)))
        XCTAssertTrue(recipe.beat)
        XCTAssertTrue(recipe.waits)
        XCTAssertNil(recipe.trigger)
        XCTAssertTrue(result.tree[1].content.audio)
        let header = result.wire.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self) }
        XCTAssertNotEqual(header.flags & OMNI_WIRE_AUDIO, 0)
        XCTAssertEqual(header.deps & ShellDataKey.spectrum.bit, 0)
        for fields in ["shape='other'", "at=0.5", "rising=false", "contact=true"] {
            try ShellP3WireFixture.reject("""
            ui.glass{ui.shape{key='other',w=8,h=8},\(crest)morph={stops={{at=0},{at=1}},trigger={beat=true,\(fields)}}}}
            """)
        }
        try ShellP3WireFixture.reject("""
        ui.glass{\(crest)morph={stops={{at=0},{at=1}},source={target='t',edge='left',span=1},trigger={beat=true}}}}
        """)
        for morph in [
            "morph={edges={lead={response=0.3},trail={response=0.4},unit=40},trigger={beat=true}}",
            "morph={stops={{at=0},{at=1}},trigger={beat=true}}"
        ] {
            let shape = "ui.shape{w=18,h=18,hit=false,\(morph)}"
            let revealed = "ui.shape{w=18,h=18,hit=false,reveal={response=\(response)},\(morph)}"
            _ = try ShellP3WireFixture.render("ui.stack{reveal={response=\(response)},ui.glass{\(revealed)}}")
            try ShellP3WireFixture.reject("ui.stack{reveal={response=\(response)},ui.glass{\(shape)}}")
            try ShellP3WireFixture.reject("ui.glass{\(shape)}")
        }
        let triggered = try ShellP3WireFixture.render("""
        ui.glass{ui.shape{key='other',w=8,h=8},\(crest)morph={stops={{at=0},{at=1}},trigger={shape='other',at=0.5}}}}
        """)
        let text = triggered.text.string(triggered.nodes[2].morph)
        XCTAssertNotNil(ShellMorphRecipe(text))
        XCTAssertNil(ShellMorphRecipe(text + "|beat:1"))
        let beat = result.text.string(result.nodes[1].morph)
        XCTAssertNil(ShellMorphRecipe(beat.replacingOccurrences(of: "|beat:1", with: "|beat:0")))
    }

    func testOneBeatStartsPerRisingBassCrossingAndNoneWithoutAnimations() throws {
        let widget = try widget()
        let slot = try VitreusFixture.element(widget, key: "crest").slot
        let quiet = Float(ShellSpectrumShapeStore.beatThreshold) / 2
        func beat(_ level: Float, at time: CFTimeInterval) -> Bool {
            ShellLayerScene.engineQueue.sync {
                widget.surface.scene.spectrum.bands.store(.init(repeating: level))
                return widget.surface.scene.startBeats(at: time)
            }
        }
        func plan() -> ShellReveal? {
            ShellLayerScene.engineQueue.sync { widget.surface.scene.shapeTracks.entries[slot]?.plan }
        }
        let start = widget.surface.clock()
        XCTAssertNil(plan())
        XCTAssertEqual(ShellLayerScene.engineQueue.sync {
            widget.surface.scene.shapeTracks.entries[slot]?.progress(at: start).progress
        }, 0)
        XCTAssertFalse(beat(0, at: start))
        XCTAssertNil(plan())
        XCTAssertTrue(beat(1, at: start))
        let first = try XCTUnwrap(plan())
        XCTAssertEqual(first.begin, start)
        XCTAssertEqual(first.state(at: start).progress, 0)
        XCTAssertEqual(first.spring, ShellMorphRecipe.Spring(response: response, bounce: 0).parameters)
        let later = start + first.duration
        XCTAssertFalse(beat(1, at: later))
        XCTAssertEqual(plan(), first)
        XCTAssertFalse(beat(quiet, at: later))
        XCTAssertTrue(beat(1, at: later))
        XCTAssertEqual(plan()?.begin, later)
        widget.resources.motion.userAnimationsEnabled = false
        widget.surface.refreshShaders()
        let still = later + first.duration
        XCTAssertFalse(beat(quiet, at: still))
        XCTAssertFalse(beat(1, at: still))
        XCTAssertNotEqual(plan()?.begin, still)
    }
}
