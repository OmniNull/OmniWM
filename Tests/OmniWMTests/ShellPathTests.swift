// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPathTests: XCTestCase {
    private func bounds(_ d: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let data = try XCTUnwrap(ShellPath.parse(d), file: file, line: line)
        return data.path(fitting: nil, into: .zero).boundingBoxOfPath
    }

    private func assertRect(_ rect: CGRect, _ expected: CGRect, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.01, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.01, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.01, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.01, line: line)
    }

    func testPathDataParsesEveryCommandAbsoluteAndRelative() throws {
        XCTAssertEqual(ShellPath.parse("M0 0 L10 0 L10 10 Z")?.elements, [
            .move(.zero), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)), .close
        ])
        XCTAssertEqual(ShellPath.parse("m1 1 10 0 0 10z")?.elements, [
            .move(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 11, y: 1)), .line(CGPoint(x: 11, y: 11)), .close
        ])
        XCTAssertEqual(ShellPath.parse("M2,3H8V9h-2v-1")?.elements, [
            .move(CGPoint(x: 2, y: 3)), .line(CGPoint(x: 8, y: 3)), .line(CGPoint(x: 8, y: 9)),
            .line(CGPoint(x: 6, y: 9)), .line(CGPoint(x: 6, y: 8))
        ])
        XCTAssertEqual(ShellPath.parse("M0 0C1 2 3 4 5 6S9 10 11 12")?.elements, [
            .move(.zero),
            .cubic(CGPoint(x: 5, y: 6), control1: CGPoint(x: 1, y: 2), control2: CGPoint(x: 3, y: 4)),
            .cubic(CGPoint(x: 11, y: 12), control1: CGPoint(x: 7, y: 8), control2: CGPoint(x: 9, y: 10))
        ])
        XCTAssertEqual(ShellPath.parse("M0 0Q5 5 10 0T20 0")?.elements, [
            .move(.zero),
            .quad(CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 5)),
            .quad(CGPoint(x: 20, y: 0), control: CGPoint(x: 15, y: -5))
        ])
        XCTAssertEqual(ShellPath.parse("M.5-1.5.5 1e1")?.elements, [
            .move(CGPoint(x: 0.5, y: -1.5)), .line(CGPoint(x: 0.5, y: 10))
        ])
    }

    func testArcsBecomeCurvesThroughTheirEndpoint() throws {
        assertRect(try bounds("M0 10 A10 10 0 0 1 20 10"), CGRect(x: 0, y: 0, width: 20, height: 10))
        assertRect(try bounds("M0 10 A10 10 0 0 0 20 10"), CGRect(x: 0, y: 10, width: 20, height: 10))
        assertRect(try bounds("M0 10 a10 10 0 1 0 20 0 a10 10 0 1 0 -20 0"), CGRect(x: 0, y: 0, width: 20, height: 20))
        assertRect(try bounds("M0 0 A1 1 0 0 1 10 0"), CGRect(x: 0, y: -5, width: 10, height: 5))
        XCTAssertEqual(ShellPath.parse("M0 0 A0 5 0 0 1 10 0")?.elements.last, .line(CGPoint(x: 10, y: 0)))
        guard case let .cubic(end, _, _)? = ShellPath.parse("M0 0a5 5 0 1010 0")?.elements.last else {
            return XCTFail("a packed arc should end in a curve")
        }
        XCTAssertEqual(end, CGPoint(x: 10, y: 0))
    }

    func testMalformedPathDataDrawsNothing() {
        XCTAssertNil(ShellPath.parse(""))
        XCTAssertNil(ShellPath.parse("10 10"))
        XCTAssertNil(ShellPath.parse("M0 0 L10"))
        XCTAssertNil(ShellPath.parse("M0 0 X10 10"))
        XCTAssertNil(ShellPath.parse("M0 0 Z 4 4"))
        XCTAssertNil(ShellPath.parse("M0 0 L1e9 0"))
    }

    func testPathElementsDeclareDataViewBoxAndFillRule() throws {
        let widget = try ShellRenderedWidget(name: "path", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.row{
                ui.path{ d = "M0 0 L24 0 L24 24 Z", viewBox = { 0, 0, 24, 24 }, evenOdd = true,
                    enter = { d = "M12 12 L12 12 L12 12 Z" } },
                ui.path{ d = "M0 0 L4 4" },
            }
        end
        """)
        let tree = widget.renderPopout()
        XCTAssertEqual(tree.map(\.kind), [.group, .path, .path])
        XCTAssertEqual(widget.text.string(tree[1].content.text), "M0 0 L24 0 L24 24 Z")
        XCTAssertEqual(tree[1].content.params, SIMD4(0, 0, 24, 24))
        XCTAssertTrue(tree[1].content.evenOdd)
        XCTAssertEqual(widget.text.string(tree[1].paint.enter.path), "M12 12 L12 12 L12 12 Z")
        XCTAssertFalse(tree[2].content.evenOdd)
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.size, CGSize(width: 24 + 16, height: 24))
    }

    func testPathsDrawAsShapeLayersFittedToTheirViewBox() throws {
        let widget = try ShellRenderedWidget(name: "path", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ w = 48, h = 24,
                ui.path{ d = "M0 0 L24 0 L24 24 Z", viewBox = { 0, 0, 24, 24 }, fill = "accent", border = "foreground", borderWidth = 2 },
            }
        end
        """)
        widget.layoutPopout()
        ShellLayerScene.engineQueue.sync {}
        let shape = try XCTUnwrap(widget.layers().compactMap { $0 as? CAShapeLayer }.first)
        let path = try XCTUnwrap(shape.path)
        assertRect(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 48, height: 24))
        XCTAssertNotNil(shape.fillColor)
        XCTAssertNotNil(shape.strokeColor)
        XCTAssertEqual(shape.lineWidth, 2)
        XCTAssertNil(shape.backgroundColor)
        XCTAssertEqual(shape.fillRule, .nonZero)
    }

    func testAMaskPathClipsItsStackToTheShape() throws {
        let widget = try ShellRenderedWidget(name: "path", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ w = 40, h = 20, fill = "accent",
                ui.path{ d = "M0 0 L10 0 L10 10 Z", viewBox = { 0, 0, 10, 10 }, mask = true },
                ui.box{ w = 40, h = 20, fill = "foreground" },
            }
        end
        """)
        widget.layoutPopout()
        ShellLayerScene.engineQueue.sync {}
        let host = try XCTUnwrap(widget.layers().first { $0.mask != nil })
        let mask = try XCTUnwrap(host.mask as? CAShapeLayer)
        assertRect(try XCTUnwrap(mask.path).boundingBoxOfPath, CGRect(x: 0, y: 0, width: 40, height: 20))
        let shape = try XCTUnwrap(host.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertTrue(shape.isHidden)
    }
}
