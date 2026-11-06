// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

private func printed(_ value: Double) -> Double {
    Double(String(format: "%.9g", value)) ?? .nan
}

extension ShellVitreusVisualiserTests {
    func testAllEdgePlacementsUseThePhysicalInnerEdgeAt1512Points() throws {
        let thin = 10.8
        for layout in ["island", "left", "right", "ftop", "fbottom"] {
            var fixture = try fixture(settings: ["visualiser": .bool(true), "layout": .string(layout)], metadata: true)
            let canonicalLeft = layout == "left" || layout == "right" ? 62.1 : thin
            let canonicalTop = layout == "ftop" || layout == "fbottom" ? 62.1 : thin
            let length = 1512 - canonicalLeft - thin
            let physicalLeft = layout == "right" ? thin : canonicalLeft
            let physicalRight = layout == "right" ? 1512 - canonicalLeft : 1512 - thin
            let top = layout == "island" ? 0 : layout == "fbottom" ? thin : canonicalTop
            let bottom = layout == "island" ? 982 : layout == "fbottom" ? 982 - canonicalTop : 982 - thin
            for placement in ["bottom", "top", "left", "right"] {
                fixture.settings["lay"] = .string(placement)
                show(fixture)
                let columns = try columns(fixture)
                XCTAssertEqual(columns.count, 24)
                for column in columns {
                    let fraction = (Double(column.index) + 0.5) / 24
                    let side = placement == "left" || placement == "right"
                    let wide = (side ? bottom - top : length) / 24 * 1.9
                    XCTAssertEqual(column.width, printed(wide))
                    XCTAssertEqual(column.radius, printed(wide * 0.45))
                    XCTAssertEqual(column.band, printed(abs(2 * fraction - 1) * 23))
                    if side {
                        XCTAssertEqual(
                            column.base.x,
                            placement == "left" ? (layout == "island" ? 0 : physicalLeft)
                                : (layout == "island" ? 1512 : physicalRight)
                        )
                        XCTAssertEqual(
                            column.base.y,
                            printed(layout == "fbottom" ? bottom - fraction * (bottom - top) : top + fraction *
                                (bottom - top))
                        )
                        XCTAssertEqual(column.direction, CGVector(dx: placement == "left" ? 1 : -1, dy: 0))
                    } else {
                        let x = canonicalLeft + fraction * length
                        XCTAssertEqual(column.base.x, printed(layout == "right" ? 1512 - x : x))
                        XCTAssertEqual(column.base.y, placement == "top" ? top : bottom)
                        XCTAssertEqual(column.direction, CGVector(dx: 0, dy: placement == "top" ? 1 : -1))
                    }
                }
            }
        }
    }

    func testCornerFansHaveTheSourceQuartetCountsAnglesAndSpectralOrder() throws {
        var fixture = try fixture(settings: ["visualiser": .bool(true), "lay": .string("corners")], metadata: true)
        for (configured, expected) in [(6, 8), (7, 8), (11, 8), (24, 24), (47, 44)] {
            fixture.settings["cols"] = .number(Double(configured))
            show(fixture)
            let columns = try columns(fixture)
            XCTAssertEqual(columns.count, expected)
            for column in columns {
                let quartet = Double(column.index / 4), corner = column.index % 4
                let fraction = (quartet + 0.5) / Double(expected / 4)
                let angle = fraction * .pi / 2
                XCTAssertEqual(column.width, printed(17 * 1.35 * 1.9))
                XCTAssertEqual(column.base.x, corner % 2 == 0 ? 10.8 : 1501.2)
                XCTAssertEqual(column.base.y, corner < 2 ? 982 : 0)
                let dx = (corner % 2 == 0 ? 1 : -1) * cos(angle), dy = (corner < 2 ? -1 : 1) * sin(angle)
                XCTAssertEqual(column.direction.dx, printed(dx))
                XCTAssertEqual(column.direction.dy, printed(dy))
                XCTAssertEqual(column.band, printed(fraction * 23))
                XCTAssertEqual(column.taper, 1)
                XCTAssertEqual(column.rotation, printed(atan2(dx, -dy) * 180 / .pi))
            }
        }
    }

    func testResampledHeightsPreserveTheEmbeddedBaseAndNeverBecomeInputRegions() throws {
        let fixture = try fixture()
        let source = (0 ..< 60).map { Float($0) / 59 }
        setBands(fixture.widget, source)
        show(fixture)
        let elements = fixture.widget.surface.layout.core.elements { _ in true }
        let crests = VitreusFixture.crests("beat", phase: "close")
        XCTAssertEqual(
            elements.filter { fixture.widget.surface.layout.core.kind(of: $0) == .shape }.count, 24 + crests.count
        )
        for name in crests {
            let element = try VitreusFixture.element(fixture.widget, key: name)
            let content = fixture.widget.surface.layout.core.content(of: element)
            XCTAssertFalse(content.glassHit, name)
            XCTAssertFalse(content.acceptsPointer, name)
        }
        let columns = try (0 ..< 24).map { try VitreusFixture.element(fixture.widget, key: "visualiser-column-\($0)") }
        for (index, element) in columns.enumerated() {
            let content = fixture.widget.surface.layout.core.content(of: element)
            XCTAssertFalse(content.glassHit)
            XCTAssertFalse(content.acceptsPointer)
            let shape = try XCTUnwrap(ShellLayerScene.engineQueue.sync {
                fixture.widget.surface.scene.spectrum.bindings[element.slot]?.target
            })
            let fraction = (Double(index) + 0.5) / 24
            let band = abs(2 * fraction - 1) * 23
            func average(_ band: Int) -> Double {
                let left = Double(band) * 2.5, right = left + 2.5
                return (Int(floor(left)) ..< Int(ceil(right))).reduce(0) { total, sample in
                    total + Double(source[sample]) * max(
                        0,
                        min(right, Double(sample + 1)) - max(left, Double(sample))
                    ) /
                        2.5
                }
            }
            let position = recipeStored(band / 23) * 23
            let low = min(22, Int(position))
            let first = Float(average(low)), rise = Float(average(low + 1)) - first
            let level = Double(first) + Double(rise) * (position - Double(low))
            let taper = recipeStored(min(1, min(Double(index) + 0.5, 23.5 - Double(index)) / 1.2))
            let stored = floatStored(206.55), top = floatStored(982 - (202.5 - 4.05) / 2 - 206.55 / 2)
            let height = pow(level, 1.4) * taper * (stored - 4.05)
            XCTAssertEqual(shape.rect.height, height + 4.05)
            XCTAssertEqual(
                shape.rect.midY + (height - 4.05) / 2,
                top + stored - 4.05,
                accuracy: .rounding(operations: 8, at: top + stored)
            )
            XCTAssertEqual(shape.rect.maxY, top + stored, accuracy: .rounding(operations: 4, at: top + stored))
            let stripe = 1490.4 / 24 * 1.9
            XCTAssertEqual(
                shape.rect.midX,
                floatStored(10.8 + fraction * 1490.4 - stripe / 2) + floatStored(stripe) / 2
            )
        }
        XCTAssertTrue(fixture.widget.surface.islandRegions().isEmpty)
        setBands(fixture.widget, [], access: .denied)
        show(fixture)
        XCTAssertTrue(shapes(fixture.widget).allSatisfy { $0.rect.minX > 29000 })
        XCTAssertTrue(fixture.widget.surface.islandRegions().isEmpty)
    }
}
