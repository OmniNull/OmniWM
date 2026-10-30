// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreText
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellTextMeasureTests: XCTestCase {
    private typealias Script = ShellScriptHostTests.Script

    private struct Measurement {
        let size: Size2
        let node: TreeNode
        let store: ShellTextStore
    }

    private func measured(
        _ text: String, options: String = "{}", props: String = "", fonts: ShellFontSet = .init()
    ) throws -> Measurement {
        let encoded = String(data: try JSONEncoder().encode(text), encoding: .utf8)!
        let script = try Script("""
        function render(ctx)
            local w, h = ctx.format.measure(\(encoded), \(options))
            return ui.text{ text = \(encoded), help = tostring(w) .. "," .. tostring(h), \(props) }
        end
        """, fonts: fonts)
        XCTAssertEqual(script.render(budget: 100_000_000).status, OMNI_OK, script.message)
        let host = ShellScriptHostTests()
        let node = try XCTUnwrap(host.decode(script.output).first)
        let store = host.strings(script.output)
        let values = store.string(node.content.help).split(separator: ",").compactMap { Float($0) }
        XCTAssertEqual(values.count, 2)
        let width = try XCTUnwrap(values.first)
        let height = try XCTUnwrap(values.dropFirst().first)
        return Measurement(size: Size2(width: width, height: height), node: node, store: store)
    }

    func testSystemAndStyleFontsMatchCoreTextAndLayoutMetrics() throws {
        let fonts = try ShellFontFixture.fonts()
        for (text, family, size) in [("Finder", "system", 13), ("12", ShellFontFixture.family, 40)] {
            let options = "{font='\(family)', size=\(size), weight='bold'}"
            let props = "font='\(family)', size=\(size), weight='bold'"
            let measurement = try measured(text, options: options, props: props, fonts: fonts)
            let result = measurement.size
            let node = measurement.node
            let store = measurement.store
            XCTAssertEqual(result, store.measureMiss(node.content.text, style: node.content.style))
            let font = store.font(node.content.style)
            if family != "system" { XCTAssertEqual(CTFontCopyFamilyName(font) as String, family) }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            ))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            XCTAssertEqual(result.width, Float(ceil(width)))
            XCTAssertEqual(result.height, Float(ceil(ascent + descent)))
        }
    }

    func testWrappingUsesTheSameLineLimitAndTrailingWhitespaceRules() throws {
        let width = Float(236 * 1.35)
        let text = String(repeating: "A notification with several words and trailing spaces   ", count: 6)
        let measurement = try measured(
            text, options: "{maxWidth=\(width), lines=3}", props: "maxWidth=\(width), lines=3"
        )
        let result = measurement.size
        let node = measurement.node
        let store = measurement.store
        XCTAssertEqual(
            result,
            store.measureWrapped(node.content.text, style: node.content.style, width: width, lines: 3)
        )
        let font = store.font(node.content.style)
        let attributed = NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let lines = ShellTextStyle.wrappedLines(attributed, width: CGFloat(width), limit: 3)
        XCTAssertEqual(lines.count, 3)
        let typographicWidth = lines.reduce(0.0) { widest, line in
            max(widest, CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        }
        XCTAssertEqual(result.width, Float(ceil(typographicWidth)))
        let expected = ShellTextStyle.wrappedSize(of: lines, font: font)
        XCTAssertEqual(result.height, Float(expected.height))
    }

    func testSingleLineIgnoresMaxWidthAndQuarterTurnSwapsAxes() throws {
        let text = "A long unwrapped title"
        let plain = try measured(text).size
        let single = try measured(text, options: "{maxWidth=5, lines=1}").size
        XCTAssertEqual(single, plain)
        let measurement = try measured(text, options: "{quarter=true}", props: "rotate=90")
        let turned = measurement.size
        let node = measurement.node
        let store = measurement.store
        XCTAssertEqual(turned, Size2(width: plain.height, height: plain.width))
        XCTAssertEqual(turned, store.measureMiss(node.content.text, style: node.content.style))
    }

    func testSizeQuantizationAndUnknownFamilyMatchTextRendering() throws {
        let options = "{font='OmniWM Missing Measure Font', size=13.127, weight='medium'}"
        let props = "font='OmniWM Missing Measure Font', size=13.127, weight='medium'"
        let measurement = try measured("Fallback", options: options, props: props)
        let result = measurement.size
        let node = measurement.node
        let store = measurement.store
        XCTAssertEqual(node.content.style & OMNI_STYLE_FONT_MASK, 0)
        XCTAssertEqual(result, store.measureMiss(node.content.text, style: node.content.style))
        XCTAssertEqual(CTFontGetSize(store.font(node.content.style)), 13.13, accuracy: 0.0001)
    }

    func testEmptyTextMatchesLayout() throws {
        let measurement = try measured("")
        let result = measurement.size
        let node = measurement.node
        let store = measurement.store
        XCTAssertEqual(result, store.measureMiss(node.content.text, style: node.content.style))
        XCTAssertEqual(result.width, 0)
    }

    func testMeasureRejectsNonStringTextAndFormatRemainsReadOnly() throws {
        for value in ["12", "false", "{}", "nil"] {
            let script = try Script("function render(ctx) ctx.format.measure(\(value)) return ui.box{} end")
            XCTAssertNotEqual(script.render().status, OMNI_OK)
            XCTAssertTrue(script.message.contains("string"), script.message)
        }
        let script = try Script("function render(ctx) ctx.format.measure=nil return ui.box{} end")
        XCTAssertNotEqual(script.render().status, OMNI_OK)
    }

    func testMeasurementConsumesTheRenderBudget() throws {
        let script = try Script("""
        function render(ctx)
            for i=1,70000 do ctx.format.measure("") end
            return ui.box{}
        end
        """)
        XCTAssertNotEqual(script.render(budget: 1_000_000_000).status, OMNI_OK)
        XCTAssertTrue(script.message.contains("65536") || script.message.contains("budget"), script.message)
    }

    func testMeasurementAndEncodingShareOnlyTheCurrentCallBudget() throws {
        let script = try Script("""
        function render(ctx)
            local phase = ctx.data.cpu or 0
            if phase > 0 then
                for i=1,30000 do ctx.format.measure("") end
                if phase == 1 then return ui.box{} end
            end
            local children = { w=200, h=200 }
            for i=1,3000 do
                table.insert(children, ui.box{w=1,h=1,dx=1,dy=1,opacity=1,radius=1,
                    fill='#ffffff',border='#ffffff',borderWidth=1,padding=0,grow=0})
            end
            return ui.stack(children)
        end
        """)
        XCTAssertEqual(script.render(budget: 1_000_000_000).status, OMNI_OK, script.message)
        XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", 1), OMNI_OK)
        XCTAssertEqual(script.render(budget: 1_000_000_000).status, OMNI_OK, script.message)
        XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", 2), OMNI_OK)
        XCTAssertNotEqual(script.render(budget: 1_000_000_000).status, OMNI_OK)
        XCTAssertTrue(script.message.contains("65536"), script.message)
    }

    func testConcurrentVMMeasurementsMatchTheLayoutFontMetrics() async throws {
        let id = try ShellFontFixture.id()
        let style = UInt32(id) << OMNI_STYLE_FONT_SHIFT | UInt32(4000) << OMNI_STYLE_SIZE_SHIFT
        let expected = ShellTextStyle.measure("12:34", font: ShellTextStyle.font(for: style), style: style)
        let results = await withTaskGroup(of: Size2.self, returning: [Size2].self) { group in
            for _ in 0 ..< 16 {
                group.addTask { ShellTextMeasurer.measure("12:34", style: style) }
            }
            var results: [Size2] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }
}
