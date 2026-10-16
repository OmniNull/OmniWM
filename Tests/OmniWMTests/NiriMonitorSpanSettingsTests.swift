// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import TOML
import XCTest

@MainActor
final class NiriMonitorSpanSettingsTests: XCTestCase {
    func testMonitorSpanChoicesResolveIndependentlyOfGlobalMode() {
        let settings = NiriSettings()
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 873),
            displayId: 873,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Span display"
        )
        var override = MonitorNiriSettings(monitorName: monitor.name, visibleContainerCount: 4)
        settings.update(override, for: monitor)
        settings.defaultContainerPrimarySpan = 0.95
        XCTAssertEqual(settings.resolved(for: monitor).defaultContainerPrimarySpan, 0.95)

        override.defaultContainerPrimarySpan = .auto
        settings.update(override, for: monitor)
        XCTAssertNil(settings.resolved(for: monitor).defaultContainerPrimarySpan)
        XCTAssertEqual(settings.resolved(for: monitor).visibleContainerCount, 4)

        override.defaultContainerPrimarySpan = .custom(0.6)
        settings.update(override, for: monitor)
        settings.defaultContainerPrimarySpan = nil
        XCTAssertEqual(settings.resolved(for: monitor).defaultContainerPrimarySpan, 0.6)

        override.defaultContainerPrimarySpan = nil
        settings.update(override, for: monitor)
        XCTAssertNil(settings.resolved(for: monitor).defaultContainerPrimarySpan)
        settings.defaultContainerPrimarySpan = 0.75
        XCTAssertEqual(settings.resolved(for: monitor).defaultContainerPrimarySpan, 0.75)
    }

    func testMonitorSpanChoicesRoundTripWithoutStoringAnInheritedValue() throws {
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(monitorName: "Global"),
            MonitorNiriSettings(monitorName: "Auto", defaultContainerPrimarySpan: .auto),
            MonitorNiriSettings(monitorName: "Custom", defaultContainerPrimarySpan: .custom(0.6))
        ]
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).isEmpty)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard case let .array(overrides) = tree["monitorNiriOverrides"] else {
            return XCTFail("Missing monitor overrides")
        }
        let spans = overrides.compactMap { node -> (String, TOMLNode?)? in
            guard case let .table(table) = node, case let .string(name) = table["monitorName"] else { return nil }
            return (name, table["defaultContainerPrimarySpan"])
        }
        XCTAssertEqual(spans.count, 3)
        for (name, span) in spans {
            switch name {
            case "Global": XCTAssertNil(span)
            case "Auto": XCTAssertEqual(span, .string("auto"))
            case "Custom": XCTAssertEqual(span, .float(0.6))
            default: XCTFail("Unexpected monitor")
            }
        }
    }

    func testInvalidMonitorSpanOverridesRejectDecode() throws {
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [MonitorNiriSettings(monitorName: "Auto", defaultContainerPrimarySpan: .auto)]
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        for invalid in ["\"unknown\"", "0.0", "1.5", "nan", "true"] {
            let input = toml.replacingOccurrences(
                of: "defaultContainerPrimarySpan = \"auto\"",
                with: "defaultContainerPrimarySpan = \(invalid)"
            )
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(input.utf8)), invalid)
        }
    }
}
