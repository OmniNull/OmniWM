// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import XCTest

final class ShellP3RecipeTests: XCTestCase {
    private let morph = "morph:0.5:0.5:0:0:1:0:0,1,1,1,1,1;1,1,1,1,1,1"
    private let manipulation = "manip:move:42:10:20:600:400:60:40:600:400:0:0:0"

    func testCompactRecipesKeepTheirActivelyEmittedDefaults() throws {
        let reveal = try XCTUnwrap(ShellRevealRecipe("reveal:0.4:0.3"))
        XCTAssertEqual(reveal.delay, 0)
        XCTAssertEqual(reveal.hold, 0)
        XCTAssertTrue(reveal.exits)
        let glass = try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1"))
        XCTAssertEqual(glass.rim, 0.1)
        XCTAssertFalse(glass.flat)
        XCTAssertEqual(glass.gradientAngle, 90)
        XCTAssertNil(try XCTUnwrap(ShellManipulationRecipe(manipulation)).outline)
        let value = try XCTUnwrap(ShellMorphRecipe(morph))
        XCTAssertTrue(value.impulses.isEmpty)
        XCTAssertNil(value.edges)
        XCTAssertNil(value.source)
        XCTAssertNil(value.trigger)
        XCTAssertEqual(value.stops[0].dx, 0)
        XCTAssertEqual(value.stops[0].dy, 0)
        XCTAssertEqual(value.stops[0].thickness, 1)
    }

    func testShapeRevealPreservesDelayHoldAndExitFlag() throws {
        let value = try XCTUnwrap(ShellRevealRecipe("reveal:0.05:0.95|shape:2:1.2:0"))
        XCTAssertEqual(value.response, 0.05)
        XCTAssertEqual(value.bounce, 0.95)
        XCTAssertEqual(value.delay, 2)
        XCTAssertEqual(value.hold, 1.2)
        XCTAssertFalse(value.exits)
        for fields in ["-0.1:0:1", "0:2.1:1", "0:0:true", "0:0:2", "nan:0:1", "0:0"] {
            XCTAssertNil(ShellRevealRecipe("reveal:0.4:0.3|shape:\(fields)"), fields)
        }
    }

    func testGlassOpticsPreserveRimFlatAndGradientAngle() throws {
        let value = try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1|optics:0.37:1:-45"))
        XCTAssertEqual(value.rim, 0.37)
        XCTAssertTrue(value.flat)
        XCTAssertEqual(value.gradientAngle, -45)
        for fields in ["-0.1:0:90", "1.1:0:90", "0.1:2:90", "0.1:0:nan", "0.1:0:1000001", "0.1:0"] {
            XCTAssertNil(ShellGlassRecipe("glass:26:-1:0:0:1|optics:\(fields)"), fields)
        }
    }

    func testManipulationOutlinePreservesExplicitColorAndDisabledState() throws {
        let value = try XCTUnwrap(ShellManipulationRecipe(manipulation + "|outline:1:16909060:14"))
        XCTAssertEqual(value.outline?.enabled, true)
        XCTAssertEqual(value.outline?.color, Color(packed: 16_909_060, role: 14))
        let disabled = try XCTUnwrap(ShellManipulationRecipe(manipulation + "|outline:0:0:0"))
        XCTAssertEqual(disabled.outline?.enabled, false)
        XCTAssertEqual(disabled.outline?.color, .clear)
        for fields in ["0:1:0", "0:0:1", "2:0:0", "1:4294967296:0", "1:0:65536", "1:0"] {
            XCTAssertNil(ShellManipulationRecipe(manipulation + "|outline:\(fields)"), fields)
        }
    }

    func testMorphOffsetsPreserveEveryStopAndMultiplier() throws {
        let value = try XCTUnwrap(ShellMorphRecipe(morph + "|offsets:-12,20,0;30,-40,2"))
        XCTAssertEqual(value.stops[0].dx, -12)
        XCTAssertEqual(value.stops[0].dy, 20)
        XCTAssertEqual(value.stops[0].thickness, 0)
        XCTAssertEqual(value.stops[1].dx, 30)
        XCTAssertEqual(value.stops[1].dy, -40)
        XCTAssertEqual(value.stops[1].thickness, 2)
        for fields in ["0,0,1", "0,0,1;0,0", "0,0,-1;0,0,1", "nan,0,1;0,0,1", "1000001,0,1;0,0,1"] {
            XCTAssertNil(ShellMorphRecipe(morph + "|offsets:\(fields)"), fields)
        }
    }

    func testMorphImpulsesPreserveThresholdTimeDirectionSpringAndPivot() throws {
        let value =
            try XCTUnwrap(ShellMorphRecipe(morph + "|impulses:0,0.7,1,0.4,0.3,80,-1,2,0;1,30,0,2.5,0.95,-100,3,-4,1"))
        XCTAssertEqual(value.impulses.count, 2)
        let crossing = value.impulses[0]
        XCTAssertEqual(crossing.kind, .at)
        XCTAssertEqual(crossing.time, 0.7)
        XCTAssertTrue(crossing.rising)
        XCTAssertEqual(crossing.spring.response, 0.4)
        XCTAssertEqual(crossing.spring.bounce, 0.3)
        XCTAssertEqual(crossing.velocity, 80)
        XCTAssertEqual(crossing.width, -1)
        XCTAssertEqual(crossing.height, 2)
        XCTAssertEqual(crossing.pivot, .anchor)
        XCTAssertEqual(value.impulses[1].kind, .after)
        XCTAssertEqual(value.impulses[1].time, 30)
        XCTAssertFalse(value.impulses[1].rising)
        XCTAssertEqual(value.impulses[1].pivot, .centre)
    }

    func testMorphImpulseBoundsAndRecordCountAreStrict() {
        let valid = "0,0.7,1,0.4,0.3,80,-1,2,0"
        XCTAssertNotNil(ShellMorphRecipe(morph + "|impulses:" + Array(repeating: valid, count: 8)
                .joined(separator: ";")))
        XCTAssertNil(ShellMorphRecipe(morph + "|impulses:" + Array(repeating: valid, count: 9).joined(separator: ";")))
        for fields in [
            "", "2,0,1,0.4,0.3,0,0,0,0", "0,1.51,1,0.4,0.3,0,0,0,0", "1,30.1,1,0.4,0.3,0,0,0,0",
            "0,0,2,0.4,0.3,0,0,0,0", "0,0,1,0.04,0.3,0,0,0,0", "0,0,1,0.4,0.96,0,0,0,0",
            "0,0,1,0.4,0.3,inf,0,0,0", "0,0,1,0.4,0.3,0,0,0,2", "0,0,1,0.4,0.3,0,0,0"
        ] {
            XCTAssertNil(ShellMorphRecipe(morph + "|impulses:\(fields)"), fields)
        }
    }
}

extension ShellP3RecipeTests {
    func testMorphEdgesRequireTheCanonicalIdentityStops() throws {
        let section = "|edges:0.4:0.3:0.5:0.2:0.1:1.35"
        let value = try XCTUnwrap(ShellMorphRecipe(morph + section))
        XCTAssertEqual(value.edges?.lead.response, 0.4)
        XCTAssertEqual(value.edges?.trail.bounce, 0.2)
        XCTAssertEqual(value.edges?.thin, 0.1)
        XCTAssertEqual(value.edges?.unit, 1.35)
        XCTAssertEqual(value.stops.count, 2)
        XCTAssertEqual(value.stops[0].at, 0)
        XCTAssertEqual(value.stops[1].at, 1)
        XCTAssertNil(ShellMorphRecipe(morph.replacingOccurrences(of: "0,1,1,1,1,1", with: "0,0,1,1,1,1") + section))
        for fields in ["0.4:0.3:0.5:0.2:0.1:0", "0.4:0.3:0.5:0.2:1.1:1", "0.4:0.3:0.5:0.2:0.1:inf"] {
            XCTAssertNil(ShellMorphRecipe(morph + "|edges:\(fields)"), fields)
        }
    }

    func testMorphSourcePreservesTargetEdgeSpanAndOptionalPads() throws {
        let value = try XCTUnwrap(ShellMorphRecipe(morph + "|source:18446744073709551615:3:-10:160:1:1:2:3:4"))
        XCTAssertEqual(value.source?.target, UInt64.max)
        XCTAssertEqual(value.source?.edge, .bottom)
        XCTAssertEqual(value.source?.from, -10)
        XCTAssertEqual(value.source?.span, 160)
        XCTAssertEqual(value.source?.pads, .init(left: 1, right: 2, top: 3, bottom: 4))
        XCTAssertNil(try XCTUnwrap(ShellMorphRecipe(morph + "|source:2:0:0:1:0:0:0:0:0")).source?.pads)
        for fields in [
            "0:0:0:1:0:0:0:0:0", "1:4:0:1:0:0:0:0:0", "1:0:0:0:0:0:0:0:0", "1:0:0:1:2:0:0:0:0",
            "1:0:0:1:1:0:0:nan:0", "1:0:0:1:0:0:0:0"
        ] {
            XCTAssertNil(ShellMorphRecipe(morph + "|source:\(fields)"), fields)
        }
    }

    func testMorphTriggerPreservesReferenceThresholdAndDirection() throws {
        let value = try XCTUnwrap(ShellMorphRecipe(morph + "|trigger:99:-0.5:0"))
        XCTAssertEqual(value.trigger?.shape, 99)
        XCTAssertEqual(value.trigger?.at, -0.5)
        XCTAssertEqual(value.trigger?.rising, false)
        for fields in ["0:0:1", "99:1.51:1", "99:nan:1", "99:0:2", "99:0"] {
            XCTAssertNil(ShellMorphRecipe(morph + "|trigger:\(fields)"), fields)
        }
    }

    func testCompatibleMorphSectionsCoexistAndCompetingOwnersOrDuplicateTagsFail() {
        let sections = [
            "offsets:0,1,1;2,3,1", "impulses:0,0.5,1,0.4,0.3,0,1,0,0", "edges:0.4:0.3:0.5:0.2:0.1:1"
        ]
        let source = "source:42:0:0:160:0:0:0:0:0"
        let adhere = "adhere:0:0:1:14:0:0:0:0"
        let trigger = "trigger:99:0.7:1"
        let common = morph + "|" + sections.joined(separator: "|")
        XCTAssertNotNil(ShellMorphRecipe(common + "|" + source + "|" + adhere))
        XCTAssertNotNil(ShellMorphRecipe(common + "|" + trigger))
        XCTAssertNil(ShellMorphRecipe(common + "|" + source + "|" + trigger))
        for section in sections + [source, trigger, adhere] {
            XCTAssertNil(ShellMorphRecipe(morph + "|" + section + "|" + section), section)
        }
        XCTAssertNil(ShellMorphRecipe(morph + "|unknown:0"))
        XCTAssertNil(ShellMorphRecipe(morph + "|"))
        XCTAssertNil(ShellMorphRecipe(morph + "|trigger"))
    }

    func testPulsePreservesSparseChannelsAndEnforcesDenseSampleCounts() throws {
        let value = try XCTUnwrap(ShellPulseRecipe("pulse:9:0.6::0,0.2,0::"))
        XCTAssertEqual(value.key, 9)
        XCTAssertEqual(value.duration, 0.6)
        XCTAssertEqual(value.scale, [0, 0.2, 0])
        XCTAssertTrue(value.rotate.isEmpty)
        XCTAssertTrue(value.dx.isEmpty)
        XCTAssertTrue(value.dy.isEmpty)
        let samples = Array(repeating: "0", count: 256).joined(separator: ",")
        XCTAssertEqual(ShellPulseRecipe("pulse:9:30:\(samples):::")?.rotate.count, 256)
        XCTAssertNil(ShellPulseRecipe("pulse:9:30:\(samples),0:::"))
        for source in [
            "pulse:0:1:0,1:::", "pulse:9:0:0,1:::", "pulse:9:30.1:0,1:::", "pulse:9:1::::",
            "pulse:9:1:0:::", "pulse:9:1:0,,1:::", "pulse:9:1:0,nan:::", "pulse:9:1:0,1000001:::",
            "pulse:9:1:0,1:::|extra:0"
        ] {
            XCTAssertNil(ShellPulseRecipe(source), source)
        }
    }

    func testEveryTaggedRecipeRejectsDuplicateUnknownAndOversizedRecords() {
        let reveal = "reveal:0.4:0.3"
        let glass = "glass:26:-1:0:0:1"
        XCTAssertNil(ShellRevealRecipe(reveal + "|shape:0:0:1|shape:0:0:1"))
        XCTAssertNil(ShellRevealRecipe(reveal + "|extra:0"))
        XCTAssertNil(ShellGlassRecipe(glass + "|optics:0.1:0:90|optics:0.1:0:90"))
        XCTAssertNil(ShellGlassRecipe(glass + "|extra:0"))
        XCTAssertNil(ShellManipulationRecipe(manipulation + "|outline:0:0:0|outline:0:0:0"))
        XCTAssertNil(ShellManipulationRecipe(manipulation + "|extra:0"))
        XCTAssertNil(ShellRevealRecipe(reveal + "|shape:" + String(repeating: "0", count: 256) + ":0:1"))
        XCTAssertNil(ShellGlassRecipe(glass + "|optics:" + String(repeating: "0", count: 256) + ":0:90"))
        XCTAssertNil(ShellManipulationRecipe(manipulation + "|outline:1:" + String(repeating: "0", count: 512) + ":0"))
        XCTAssertNil(ShellMorphRecipe(morph + "|trigger:99:" + String(repeating: "0", count: 1536) + ":1"))
        XCTAssertNil(ShellPulseRecipe("pulse:9:1:" + String(repeating: "0", count: 16_384) + ",1:::"))
    }
}
