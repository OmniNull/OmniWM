// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellRevealRecipeTests: XCTestCase {
    func testRevealPreservesSpringAndAdmitsItsBoundaryValues() throws {
        let reveal = try XCTUnwrap(ShellRevealRecipe("reveal:0.482:0.31"))
        XCTAssertEqual(reveal.response, 0.482)
        XCTAssertEqual(reveal.bounce, 0.31)
        XCTAssertNotNil(ShellRevealRecipe("reveal:0.05:0"))
        XCTAssertNotNil(ShellRevealRecipe("reveal:2.5:0.95"))
    }

    func testRevealRejectsInvalidSpringAndRecordBoundaries() {
        for source in [
            "spring:0.482:0.31", "reveal:0.482", "reveal:0.482:0.31:0",
            "reveal::0.31", "reveal:0.049:0.31", "reveal:2.501:0.31",
            "reveal:0.482:-0.01", "reveal:0.482:0.951"
        ] {
            XCTAssertNil(ShellRevealRecipe(source), source)
        }
        for value in ["nan", "inf", "-inf", "1e999"] {
            XCTAssertNil(ShellRevealRecipe("reveal:\(value):0.31"))
            XCTAssertNil(ShellRevealRecipe("reveal:0.482:\(value)"))
        }
    }
}

final class ShellMorphRecipeTests: XCTestCase {
    private let fields = ["morph", "1", "0.5", "0.07", "0.5", "1", "-0.5", "0,0.05,0,0,0,0;1,1,1,1,1,1"]

    private func recipe(_ replacements: [Int: String] = [:]) -> ShellMorphRecipe? {
        var next = fields
        for (index, value) in replacements { next[index] = value }
        return ShellMorphRecipe(next.joined(separator: ":"))
    }

    private func firstStop(_ index: Int, _ value: String) -> ShellMorphRecipe? {
        var first = ["0", "0.05", "0", "0", "0", "0"]
        first[index] = value
        return recipe([7: first.joined(separator: ",") + ";1,1,1,1,1,1"])
    }

    func testMorphPreservesAnchorAdditiveStretchAndStops() throws {
        let value = try XCTUnwrap(recipe())
        XCTAssertEqual(value.anchor, CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(value.stretch.gain, 0.07)
        XCTAssertEqual(value.stretch.max, 0.5)
        XCTAssertEqual(value.stretch.width, 1)
        XCTAssertEqual(value.stretch.height, -0.5)
        XCTAssertEqual(value.stops.count, 2)
        XCTAssertEqual(value.stops[0], .init(at: 0, scale: 0.05, opacity: 0, width: 0, height: 0, round: 0))
        XCTAssertEqual(value.stops[1], .init(at: 1, scale: 1, opacity: 1, width: 1, height: 1, round: 1))
        XCTAssertEqual(value, recipe())
    }

    func testMorphAdmitsScalarAndStopCountBoundaries() {
        XCTAssertNotNil(recipe([1: "0", 2: "1", 3: "0", 4: "1000000", 5: "-1000000", 6: "1000000"]))
        XCTAssertNotNil(recipe([7: "-0.5,0,0,0,0,0;1.5,1000000,1,1000000,1000000,1"]))
        let stops = (0 ..< 16).map { "\(Double($0) / 15),1,1,1,1,1" }.joined(separator: ";")
        XCTAssertNotNil(recipe([7: stops]))
    }

    func testMorphRejectsNonfiniteAndOutOfRangeHeaderValues() {
        for index in 1 ... 6 {
            for value in ["", "nan", "inf", "-inf", "1e999", "1000001"] {
                XCTAssertNil(recipe([index: value]), "\(index):\(value)")
            }
        }
        for index in [1, 2] {
            XCTAssertNil(recipe([index: "-0.001"]))
            XCTAssertNil(recipe([index: "1.001"]))
        }
        for index in [3, 4] { XCTAssertNil(recipe([index: "-0.001"])) }
        for index in [5, 6] { XCTAssertNil(recipe([index: "-1000001"])) }
    }

    func testMorphRejectsNonfiniteAndOutOfRangeStopValues() {
        for index in 0 ... 5 {
            for value in ["", "nan", "inf", "-inf", "1e999", "1000001"] {
                XCTAssertNil(firstStop(index, value), "\(index):\(value)")
            }
        }
        XCTAssertNil(firstStop(0, "-0.501"))
        for index in 1 ... 5 { XCTAssertNil(firstStop(index, "-0.001")) }
        for index in [2, 5] { XCTAssertNil(firstStop(index, "1.001")) }
        XCTAssertNil(recipe([7: "0,1,1,1,1,1;1.501,1,1,1,1,1"]))
    }

    func testMorphRejectsMalformedAndUnorderedStopRecords() {
        for stops in [
            "", "0,1,1,1,1,1", "0,1,1,1,1,1;0,1,1,1,1,1", "1,1,1,1,1,1;0,1,1,1,1,1",
            "0,1,1,1,1;1,1,1,1,1,1", "0,1,1,1,1,1,1;1,1,1,1,1,1", "0,1,1,1,1,1;1,1,1,1,1,1;"
        ] {
            XCTAssertNil(recipe([7: stops]), stops)
        }
        let stops = (0 ..< 17).map { "\(Double($0) / 16),1,1,1,1,1" }.joined(separator: ";")
        XCTAssertNil(recipe([7: stops]))
        XCTAssertNil(recipe([0: "shape"]))
        XCTAssertNil(ShellMorphRecipe(fields.dropLast().joined(separator: ":")))
        XCTAssertNil(ShellMorphRecipe((fields + ["extra"]).joined(separator: ":")))
        XCTAssertNil(recipe([1: "0." + String(repeating: "0", count: 1536)]))
    }
}

final class ShellPresenceRecipeTests: XCTestCase {
    func testPresencePreservesAnchorDelayAndColonDelimitedSpringPayload() throws {
        let recipe = try XCTUnwrap(ShellPresenceRecipe("life:0:0.88:0:-8:1:0.5:0.2:1:255:spring:0.31:0.22"))
        XCTAssertEqual(recipe.opacity, 0)
        XCTAssertEqual(recipe.scale, 0.88)
        XCTAssertEqual(recipe.offset, CGPoint(x: 0, y: -8))
        XCTAssertEqual(recipe.anchor, CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(recipe.delay, 0.2)
        XCTAssertFalse(recipe.inherited)
        XCTAssertEqual(recipe.motion, .spring(response: 0.31, bounce: 0.22))
        XCTAssertNil(recipe.curve)
    }

    func testPresenceAdmitsInheritedAndDisabledMotionWithNewRecordLayout() throws {
        let inherited = try XCTUnwrap(ShellPresenceRecipe("life:1:1:0:0:0.5:0.5:0:inherit"))
        XCTAssertTrue(inherited.inherited)
        XCTAssertEqual(inherited.anchor, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(inherited.delay, 0)
        XCTAssertNil(inherited.motion)
        let disabled = try XCTUnwrap(ShellPresenceRecipe("life:0:1:0:0:0:1:2:0:0:"))
        XCTAssertFalse(disabled.inherited)
        XCTAssertEqual(disabled.anchor, CGPoint(x: 0, y: 1))
        XCTAssertEqual(disabled.delay, 2)
        XCTAssertNil(disabled.motion)
    }

    func testPresenceRejectsLegacyMalformedAndOutOfRangeRecords() {
        for source in [
            "life:1:1:0:0:inherit", "life:0:1:0:0:0:0:", "life:1:1:0:0:0.5:0.5:0",
            "life:1:1:0:0:0.5:0.5:0:inherit:extra", "life:1:1:0:0:0.5:0.5:0:1:0",
            "life:1:1:0:0:1.2:0.5:0:inherit", "life:1:1:0:0:0.5:-0.1:0:inherit",
            "life:1:1:0:0:0.5:0.5:3:inherit", "life:1:1:0:0:0.5:0.5:-0.1:inherit"
        ] {
            XCTAssertNil(ShellPresenceRecipe(source), source)
        }
        for index in 5 ... 7 {
            for value in ["", "nan", "inf", "-inf", "1e999"] {
                var fields = ["life", "1", "1", "0", "0", "0.5", "0.5", "0", "inherit"]
                fields[index] = value
                XCTAssertNil(ShellPresenceRecipe(fields.joined(separator: ":")), "\(index):\(value)")
            }
        }
    }
}
