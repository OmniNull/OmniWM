// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellManipulationRecipeTests: XCTestCase {
    private let fields = [
        "manip", "move", "42", "10", "20", "600", "400", "60", "40", "600", "400", "0", "0", "0"
    ]

    private func recipe(_ replacements: [Int: String] = [:]) -> ShellManipulationRecipe? {
        var next = fields
        for (index, value) in replacements { next[index] = value }
        return ShellManipulationRecipe(next.joined(separator: ":"))
    }

    func testMoveRecipePreservesExactTargetAndCheckedGeometry() throws {
        let value = try XCTUnwrap(recipe([2: String(UInt64.max)]))
        XCTAssertEqual(value.mode, .move)
        XCTAssertEqual(value.target, UInt64.max)
        XCTAssertEqual(value.bounds, CGRect(x: 10, y: 20, width: 600, height: 400))
        XCTAssertEqual(value.minimum, CGSize(width: 60, height: 40))
        XCTAssertEqual(value.maximum, CGSize(width: 600, height: 400))
        XCTAssertEqual(value.resizeMask, 0)
        XCTAssertEqual(value.inset, .zero)
    }

    func testMoveAndScalePreserveFractionalContentInsets() throws {
        let move = try XCTUnwrap(recipe([12: "0.125", 13: "0.25"]))
        XCTAssertEqual(move.inset, CGSize(width: 0.125, height: 0.25))
        for mask in [5, 6, 9, 10] {
            let scale = try XCTUnwrap(recipe([1: "scale", 11: String(mask), 12: "0.125", 13: "0.25"]))
            XCTAssertEqual(scale.mode, .scale)
            XCTAssertEqual(scale.resizeMask, UInt8(mask))
            XCTAssertEqual(scale.inset, move.inset)
        }
    }

    func testRejectsInvalidInsetsAndInsetsOnResize() {
        for index in [12, 13] {
            for value in ["", "nan", "inf", "-inf", "-0.001", "0.5", "1"] {
                XCTAssertNil(recipe([index: value]), "\(index):\(value)")
            }
            XCTAssertNil(recipe([1: "resize", 11: "5", index: "0.1"]))
        }
    }

    func testAllEightResizeHandlesAreAdmitted() throws {
        for mask in [1, 2, 4, 8, 5, 6, 9, 10] {
            let value = try XCTUnwrap(recipe([1: "resize", 11: String(mask)]))
            XCTAssertEqual(value.resizeMask, UInt8(mask))
        }
    }

    func testRejectsContradictoryAndMissingResizeHandles() {
        for mask in [0, 3, 7, 11, 12, 13, 14, 15, 16] {
            XCTAssertNil(recipe([1: "resize", 11: String(mask)]), String(mask))
        }
        XCTAssertNil(recipe([11: "1"]))
    }

    func testRejectsNonfiniteAndExcessiveValues() {
        for index in [3, 4, 5, 6, 7, 8, 9, 10] {
            for value in ["nan", "inf", "-inf", "1e999", "1000001"] {
                XCTAssertNil(recipe([index: value]), "\(index):\(value)")
            }
        }
        XCTAssertNotNil(recipe([3: "-1000000", 4: "-1000000"]))
        XCTAssertNil(recipe([3: "-1000001"]))
    }

    func testRejectsEmptyInvertedOrOutOfCanvasSizes() {
        for index in [5, 6, 7, 8, 9, 10] {
            XCTAssertNil(recipe([index: "0"]))
            XCTAssertNil(recipe([index: "-1"]))
        }
        XCTAssertNil(recipe([7: "601"]))
        XCTAssertNil(recipe([8: "401"]))
        XCTAssertNil(recipe([9: "601"]))
        XCTAssertNil(recipe([10: "401"]))
        XCTAssertNil(recipe([7: "100", 9: "99"]))
        XCTAssertNil(recipe([8: "100", 10: "99"]))
    }

    func testRejectsMalformedIdentityAndRecordBoundaries() {
        XCTAssertNil(recipe([0: "track"]))
        XCTAssertNil(recipe([1: "rotate"]))
        XCTAssertNil(recipe([2: "0"]))
        XCTAssertNil(recipe([2: "-1"]))
        XCTAssertNil(recipe([2: "18446744073709551616"]))
        XCTAssertNil(recipe([2: "42.0"]))
        XCTAssertNil(ShellManipulationRecipe(fields.dropLast().joined(separator: ":")))
        XCTAssertNil(ShellManipulationRecipe(fields.dropLast(2).joined(separator: ":")))
        XCTAssertNil(ShellManipulationRecipe((fields + ["extra"]).joined(separator: ":")))
        XCTAssertNil(recipe([3: ""]))
        XCTAssertNil(recipe([2: String(repeating: "0", count: 512) + "42"]))
    }
}
