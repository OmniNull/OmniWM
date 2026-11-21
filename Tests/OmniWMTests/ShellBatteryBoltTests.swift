// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellBatteryBoltTests: XCTestCase {
    private enum Layout: CaseIterable {
        case beside
        case off
        case vertical

        var settings: [String: ShellServiceValue] {
            switch self {
            case .beside,
                 .vertical: [:]
            case .off: ["percent": .text("off")]
            }
        }

        var vertical: Bool {
            self == .vertical
        }
    }

    private struct TintCase {
        let level: Double
        let charging: Bool
        let power: ShellPower
        let tint: ShellRole
        let label: String
    }

    private struct PluggedCase {
        let level: Double
        let power: ShellPower
        let label: String
    }

    private static let fullyCharged = ShellPower(source: "ac", charged: true)
    private static let pluggedIn = ShellPower(source: "ac")
    private static let charging = ShellPower(source: "ac", full: 40)
    private static let onBattery = ShellPower(source: "battery", remaining: 254)

    func testBatteryDetailsShowsBoltOnACWhenFullyChargedButNotCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 100, charging: false, power: Self.fullyCharged, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "100% on AC, not charging, \(layout)")
        }
    }

    func testBatteryDetailsShowsBoltOnACDuringOptimizedChargingHold() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 80, charging: false, power: Self.pluggedIn, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "80% hold on AC, not charging, \(layout)")
        }
    }

    func testBatteryDetailsHidesBoltOnBatteryPower() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            for level in [100.0, 76, 15] {
                let tree = render(widget, level: level, charging: false, power: Self.onBattery, layout: layout)
                XCTAssertNil(bolt(in: tree, widget), "\(level)% on battery, \(layout)")
            }
        }
    }

    func testBatteryDetailsKeepsBoltWhileCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for layout in Layout.allCases {
            let tree = render(widget, level: 40, charging: true, power: Self.charging, layout: layout)
            XCTAssertNotNil(bolt(in: tree, widget), "40% charging, \(layout)")
        }
    }

    func testBatteryDetailsTintsFillGreenOnlyWhileActuallyCharging() throws {
        let widget = try ShellRenderedWidget("battery-details")
        let cases = [
            TintCase(level: 80, charging: true, power: Self.charging, tint: .success, label: "80% charging"),
            TintCase(level: 40, charging: true, power: Self.charging, tint: .success, label: "40% charging"),
            TintCase(
                level: 100, charging: false, power: Self.fullyCharged, tint: .foreground, label: "100% on AC, charged"
            ),
            TintCase(level: 80, charging: false, power: Self.pluggedIn, tint: .foreground, label: "80% hold on AC"),
            TintCase(
                level: 15, charging: false, power: Self.pluggedIn, tint: .warning, label: "15% on AC, not charging"
            ),
            TintCase(level: 76, charging: false, power: Self.onBattery, tint: .foreground, label: "76% on battery")
        ]
        for test in cases {
            let tree = render(widget, level: test.level, charging: test.charging, power: test.power, layout: .beside)
            let cellFill = try opaqueLevelFill(in: tree, test.label)
            XCTAssertEqual(role(cellFill.paint.fill), test.tint, test.label)
        }
    }

    func testBatteryDetailsDrawsBoltInBackgroundWhereFillReachesUnderIt() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for level in try [100, Self.boltContrastLevel()] {
            for (charging, power) in [(false, Self.pluggedIn), (true, Self.charging)] {
                let label = "\(level)% charging=\(charging)"
                let tree = render(widget, level: level, charging: charging, power: power, layout: .beside)
                let glyph = try XCTUnwrap(bolt(in: tree, widget), label)
                XCTAssertEqual(role(glyph.content.color), .background, label)
            }
        }
    }

    func testBatteryDetailsDrawsBoltInForegroundBelowTheFillThreshold() throws {
        let widget = try ShellRenderedWidget("battery-details")
        for level in try [Self.boltContrastLevel().nextDown, 0] {
            for (charging, power) in [(false, Self.pluggedIn), (true, Self.charging)] {
                let label = "\(level)% charging=\(charging)"
                let tree = render(widget, level: level, charging: charging, power: power, layout: .beside)
                let glyph = try XCTUnwrap(bolt(in: tree, widget), label)
                XCTAssertEqual(role(glyph.content.color), .foreground, label)
            }
        }
    }

    func testBatterySymbolUsesBoltVariantOnACEvenWhenNotCharging() throws {
        let widget = try ShellRenderedWidget("battery")
        let cases = [
            PluggedCase(level: 100, power: Self.fullyCharged, label: "100% on AC, charged"),
            PluggedCase(level: 80, power: Self.pluggedIn, label: "80% hold on AC")
        ]
        for test in cases {
            let tree = render(widget, level: test.level, charging: false, power: test.power, layout: .beside)
            let name = try XCTUnwrap(batterySymbol(in: tree, widget), test.label)
            XCTAssertTrue(name.contains("bolt"), "\(test.label): \(name)")
        }
    }

    func testBatterySymbolUsesBoltVariantWhileCharging() throws {
        let widget = try ShellRenderedWidget("battery")
        let tree = render(widget, level: 40, charging: true, power: Self.charging, layout: .beside)
        let name = try XCTUnwrap(batterySymbol(in: tree, widget))
        XCTAssertTrue(name.contains("bolt"), name)
    }

    func testBatterySymbolHasNoBoltOnBatteryPower() throws {
        let widget = try ShellRenderedWidget("battery")
        for level in [100.0, 76] {
            let tree = render(widget, level: level, charging: false, power: Self.onBattery, layout: .beside)
            let name = try XCTUnwrap(batterySymbol(in: tree, widget), "\(level)%")
            XCTAssertFalse(name.contains("bolt"), "\(level)%: \(name)")
        }
    }

    private func render(
        _ widget: ShellRenderedWidget,
        level: Double,
        charging: Bool,
        power: ShellPower,
        layout: Layout
    ) -> [TreeNode] {
        widget.set("settings") { ShellServiceValue.object(layout.settings).write(to: &$0) }
        widget.set("battery") { $0.number(level) }
        widget.set("charging") { $0.bool(charging) }
        widget.set("power") { power.write(into: &$0) }
        var bar = ShellBarData(badges: "text")
        bar.style.height = 32
        bar.style.vertical = layout.vertical
        bar.style.position = layout.vertical ? "left" : "top"
        widget.render(bar)
        return widget.tree()
    }

    private static func boltContrastLevel() throws -> Double {
        try ShellRenderedWidget.bundledNumber(
            "module.boltContrastLevel", requiring: "battery", from: "battery-details"
        )
    }

    private func bolt(in tree: [TreeNode], _ widget: ShellRenderedWidget) -> TreeNode? {
        tree.first { $0.kind == .symbol && widget.text.string($0.content.text) == "bolt.fill" }
    }

    private func batterySymbol(in tree: [TreeNode], _ widget: ShellRenderedWidget) -> String? {
        tree.lazy
            .filter { $0.kind == .symbol }
            .map { widget.text.string($0.content.text) }
            .first { $0.hasPrefix("battery.") }
    }

    private func opaqueLevelFill(in tree: [TreeNode], _ label: String) throws -> TreeNode {
        let tints: Set<ShellRole> = [.foreground, .success, .warning, .error]
        let fills = tree.filter { node in
            node.kind != .symbol && node.kind != .label
                && role(node.paint.fill).map(tints.contains) == true
                && node.paint.fill.role >> 8 == 255
        }
        XCTAssertEqual(fills.count, 1, label)
        return try XCTUnwrap(fills.first, label)
    }

    private func role(_ color: Color) -> ShellRole? {
        ShellRole(rawValue: Int(color.role & 0xFF) - 1)
    }
}
