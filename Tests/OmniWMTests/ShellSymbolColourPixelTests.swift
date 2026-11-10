// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellSymbolColourPixelTests: XCTestCase {
    private static let scale = 2

    func testNamedForegroundSymbolMatchesTheSameOpaqueColourGivenAsHex() throws {
        let widget = try render(theme: Self.theme(foreground: "#F3DFCB"), source: """
        local function cell(key, color)
            return ui.stack{ key = key, w = 32, h = 32, fill = '#000000FF',
                ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = color } }
        end
        function render(ctx)
            return ui.row{ gap = 0, pad = 0,
                cell('named', 'foreground'), cell('full', 'foreground/1'), cell('hex', '#F3DFCB') }
        end
        """)
        let peaks = try Self.peaks(widget, keys: ["named", "full", "hex"])
        let expected = [0xF3, 0xDF, 0xCB]
        Self.assertColour(peaks["hex"], expected, "hex symbol")
        Self.assertColour(peaks["named"], expected, "named foreground symbol")
        Self.assertColour(peaks["full"], expected, "named foreground/1 symbol")
        let hex = try XCTUnwrap(peaks["hex"])
        Self.assertColour(peaks["named"], hex, "named vs hex symbol")
    }

    func testTranslucentNamedSymbolKeepsTheAlphaAPathAndHexGet() throws {
        let widget = try render(theme: Self.theme(foreground: "#F3DFCB"), source: """
        local function cell(key, child)
            return ui.stack{ key = key, w = 32, h = 32, fill = '#000000FF', child }
        end
        function render(ctx)
            return ui.row{ gap = 0, pad = 0,
                cell('named', ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = 'foreground/0.5' }),
                cell('hex', ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = '#F3DFCB80' }),
                cell('path', ui.path{ d = 'M0 0 L24 0 L24 24 L0 24 Z', viewBox = { 0, 0, 24, 24 }, w = 24, h = 24,
                    fill = 'foreground/0.5' }) }
        end
        """)
        let peaks = try Self.peaks(widget, keys: ["named", "hex", "path"])
        let expected = [122, 112, 102]
        Self.assertColour(peaks["path"], expected, "path in foreground/0.5")
        Self.assertColour(peaks["named"], expected, "symbol in foreground/0.5")
        Self.assertColour(peaks["hex"], expected, "symbol in #F3DFCB80")
    }

    func testNativeForegroundSymbolIsAsBrightAsAPathInNativeForeground() throws {
        let widget = try render(theme: .native, source: """
        local function cell(key, child)
            return ui.stack{ key = key, w = 32, h = 32, fill = '#000000FF', child }
        end
        function render(ctx)
            return ui.row{ gap = 0, pad = 0,
                cell('symbol', ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = 'foreground' }),
                cell('fill', ui.path{ d = 'M0 0 L24 0 L24 24 L0 24 Z', viewBox = { 0, 0, 24, 24 }, w = 24, h = 24,
                    fill = 'foreground' }),
                cell('stroke', ui.path{ d = 'M2 12 H22', w = 24, h = 24, border = 'foreground', borderWidth = 8 }) }
        end
        """)
        let peaks = try Self.peaks(widget, keys: ["symbol", "fill", "stroke"])
        let fill = try XCTUnwrap(peaks["fill"])
        XCTAssertGreaterThan(fill.min() ?? 0, 100, "the native dark foreground path should render light: \(fill)")
        Self.assertColour(peaks["stroke"], fill, "stroked path vs filled path in foreground")
        Self.assertColour(peaks["symbol"], fill, "symbol vs path in native foreground")
    }

    private func render(theme: ShellTheme, source: String) throws -> ShellRenderedWidget {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        try resources.palette.refresh(theme: theme, appearance: XCTUnwrap(NSAppearance(named: .darkAqua)))
        let widget = try ShellRenderedWidget(
            name: "symbol-colour", source: source, scale: CGFloat(Self.scale), resources: resources
        )
        widget.render(ShellBarData())
        return widget
    }

    private static func theme(foreground hex: String) throws -> ShellTheme {
        let color = try XCTUnwrap(NSColor(shellHex: hex))
        var theme = ShellTheme.native
        theme.light[ShellRole.foreground.rawValue] = color
        theme.dark[ShellRole.foreground.rawValue] = color
        return theme
    }

    private static func peaks(_ widget: ShellRenderedWidget, keys: [String]) throws -> [String: [Int]] {
        let crop = CGRect(origin: .zero, size: widget.surface.size).integral
        XCTAssertGreaterThan(crop.width, 0)
        let bytes = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
        let width = Int(crop.width) * scale
        var result: [String: [Int]] = [:]
        for key in keys {
            let cell = try VitreusFixture.frame(widget, key: key).insetBy(dx: 1, dy: 1)
            var best = [0, 0, 0]
            var brightest = -1.0
            for y in Int(cell.minY) * scale ..< Int(cell.maxY) * scale {
                for x in Int(cell.minX) * scale ..< Int(cell.maxX) * scale {
                    let index = (y * width + x) * 4
                    let rgb = [Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index])]
                    let luma = 0.2126 * Double(rgb[0]) + 0.7152 * Double(rgb[1]) + 0.0722 * Double(rgb[2])
                    if luma > brightest {
                        brightest = luma
                        best = rgb
                    }
                }
            }
            result[key] = best
        }
        return result
    }

    private static func assertColour(
        _ actual: [Int]?, _ expected: [Int], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else { return XCTFail("\(label): no pixels", file: file, line: line) }
        XCTAssertEqual(actual.count, expected.count, label, file: file, line: line)
        for (value, target) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(
                abs(value - target), 2, "\(label): \(actual) vs \(expected)", file: file, line: line
            )
        }
    }
}
