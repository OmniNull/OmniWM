// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellSymbolColourPixelTests: XCTestCase {
    private static let scale = 2
    private static let foreground = "#F3DFCB"
    private static let translucentAlpha = 0.5

    func testNamedForegroundSymbolMatchesTheSameOpaqueColourGivenAsHex() throws {
        let widget = try render(theme: Self.theme(foreground: Self.foreground), source: """
        local function cell(key, color)
            return ui.stack{ key = key, w = 32, h = 32, fill = '#000000FF',
                ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = color } }
        end
        function render(ctx)
            return ui.row{ gap = 0, pad = 0,
                cell('named', 'foreground'), cell('full', 'foreground/1'), cell('hex', '\(Self.foreground)') }
        end
        """)
        let peaks = try Self.peaks(widget, keys: ["named", "full", "hex"])
        let expected = try Self.overBlack(Self.colour(Self.foreground))
        Self.assertRendered(peaks["hex"], expected, "hex symbol")
        Self.assertRendered(peaks["named"], expected, "named foreground symbol")
        Self.assertRendered(peaks["full"], expected, "named foreground/1 symbol")
    }

    func testTranslucentNamedSymbolKeepsTheAlphaAPathAndHexGet() throws {
        let alphaByte = UInt8((Self.translucentAlpha * Double(UInt8.max)).rounded())
        let translucentHex = Self.foreground + String(format: "%02X", alphaByte)
        let named = "foreground/\(Self.translucentAlpha)"
        let widget = try render(theme: Self.theme(foreground: Self.foreground), source: """
        local function cell(key, child)
            return ui.stack{ key = key, w = 32, h = 32, fill = '#000000FF', child }
        end
        function render(ctx)
            return ui.row{ gap = 0, pad = 0,
                cell('named', ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = '\(named)' }),
                cell('hex', ui.symbol{ name = 'bell.fill', size = 24, w = 24, h = 24, color = '\(translucentHex)' }),
                cell('path', ui.path{ d = 'M0 0 L24 0 L24 24 L0 24 Z', viewBox = { 0, 0, 24, 24 }, w = 24, h = 24,
                    fill = '\(named)' }) }
        end
        """)
        let peaks = try Self.peaks(widget, keys: ["named", "hex", "path"])
        let expected = try Self.overBlack(Self.colour(translucentHex))
        Self.assertRendered(peaks["path"], expected, "path in \(named)")
        Self.assertRendered(peaks["named"], expected, "symbol in \(named)")
        Self.assertRendered(peaks["hex"], expected, "symbol in \(translucentHex)")
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
        let native = ShellPalette(theme: .native, appearance: ShellPalette.darkAppearance)
        let expected = try Self.overBlack(native.color(Color(packed: 0), default: .foreground))
        Self.assertRendered(peaks["fill"], expected, "path filled in native foreground")
        Self.assertRendered(peaks["stroke"], expected, "path stroked in native foreground")
        Self.assertRendered(peaks["symbol"], expected, "symbol in native foreground")
    }

    private func render(theme: ShellTheme, source: String) throws -> ShellRenderedWidget {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.palette.refresh(theme: theme, appearance: ShellPalette.darkAppearance)
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

    private static func colour(_ hex: String) throws -> CGColor {
        try XCTUnwrap(NSColor(shellHex: hex)).cgColor
    }

    private static func overBlack(_ color: CGColor) throws -> [Double] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let components = try XCTUnwrap(color.converted(to: space, intent: .defaultIntent, options: nil)?.components)
        let alpha = try XCTUnwrap(components.last)
        return components.dropLast().map { Double($0 * alpha) * Double(UInt8.max) }
    }

    private static func peaks(_ widget: ShellRenderedWidget, keys: [String]) throws -> [String: [Int]] {
        let crop = CGRect(origin: .zero, size: widget.surface.size).integral
        XCTAssertGreaterThan(crop.width, 0)
        let bytes = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
        let width = Int(crop.width) * scale
        var result: [String: [Int]] = [:]
        for key in keys {
            let cell = try VitreusFixture.frame(widget, key: key)
            var brightest: [Int] = []
            for y in Int(cell.minY) * scale ..< Int(cell.maxY) * scale {
                for x in Int(cell.minX) * scale ..< Int(cell.maxX) * scale {
                    let index = (y * width + x) * 4
                    let rgb = [Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index])]
                    if rgb.reduce(0, +) > brightest.reduce(0, +) {
                        brightest = rgb
                    }
                }
            }
            result[key] = brightest
        }
        return result
    }

    private static func assertRendered(
        _ actual: [Int]?, _ exact: [Double], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else { return XCTFail("\(label): no pixels", file: file, line: line) }
        XCTAssertEqual(actual.count, exact.count, label, file: file, line: line)
        for (value, target) in zip(actual, exact) {
            XCTAssertTrue(
                (target.rounded(.down) ... target.rounded(.up)).contains(Double(value)),
                "\(label): \(actual) is not \(exact) rounded to whole 8-bit steps",
                file: file,
                line: line
            )
        }
    }
}
