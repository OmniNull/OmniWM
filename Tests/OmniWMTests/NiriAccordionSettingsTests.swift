// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class NiriAccordionSettingsTests: XCTestCase {
    func testDefaultsAreThirtyAndHorizontal() {
        let defaults = SettingsExport.Niri.defaults()
        XCTAssertEqual(defaults.accordionPadding, 30)
        XCTAssertEqual(defaults.accordionAxis, .horizontal)
    }

    @MainActor
    func testApplyUsesBaselineWhenKeysAreMissing() {
        let settings = NiriSettings()
        var incoming = SettingsExport.Niri.defaults()
        incoming.accordionPadding = nil
        incoming.accordionAxis = nil
        var baseline = SettingsExport.Niri.defaults()
        baseline.accordionPadding = 12
        baseline.accordionAxis = .vertical

        settings.apply(incoming, baseline: baseline)

        XCTAssertEqual(settings.accordionPadding, 12)
        XCTAssertEqual(settings.accordionAxis, .vertical)
    }

    @MainActor
    func testExportRoundTripsValues() {
        let settings = NiriSettings()
        settings.accordionPadding = 44
        settings.accordionAxis = .vertical

        let exported = settings.export()

        XCTAssertEqual(exported.accordionPadding, 44)
        XCTAssertEqual(exported.accordionAxis, .vertical)
    }

    func testTOMLWithoutAccordionKeysDecodesWithDefaults() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("accordionPadding") && !$0.hasPrefix("accordionAxis") }
            .joined(separator: "\n")

        let decoded = try SettingsTOMLCodec.decode(Data(stripped.utf8))

        XCTAssertEqual(decoded.niri.accordionPadding, 30)
        XCTAssertEqual(decoded.niri.accordionAxis, .horizontal)
    }

    func testTOMLAccordionKeysRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.niri.accordionPadding = 44
        export.niri.accordionAxis = .vertical

        let data = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(text.contains("accordionPadding = 44"))
        XCTAssertTrue(text.contains("accordionAxis = \"vertical\""))
        XCTAssertEqual(decoded.niri.accordionPadding, 44)
        XCTAssertEqual(decoded.niri.accordionAxis, .vertical)
    }

    @MainActor
    func testApplyNormalizesOutOfRangeAndNonFinitePadding() {
        let settings = NiriSettings()
        var incoming = SettingsExport.Niri.defaults()
        let cases: [(Double, Double)] = [(1e30, 200), (-5, 0), (.infinity, 30), (.nan, 30), (44, 44)]

        for (input, expected) in cases {
            incoming.accordionPadding = input
            settings.apply(incoming, baseline: SettingsExport.Niri.defaults())
            XCTAssertEqual(settings.accordionPadding, expected, "input \(input)")
        }
    }

    func testPaddingIsClampedToTwoHundred() {
        let engine = NiriLayoutEngine()
        engine.updateAccordionStyle(padding: 900, axis: .vertical)
        XCTAssertEqual(engine.renderStyle.accordionPadding, 200)
        engine.updateAccordionStyle(padding: -4, axis: .vertical)
        XCTAssertEqual(engine.renderStyle.accordionPadding, 0)
        XCTAssertEqual(engine.renderStyle.accordionAxis, .vertical)
    }
}
