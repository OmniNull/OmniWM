// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MouseWheelSensitivitySettingsTests: XCTestCase {
    func testMouseWheelSensitivityRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.gestures.mouseWheelSensitivity = 8

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = GestureSettings()
        settings.apply(decoded.gestures)

        XCTAssertEqual(decoded.gestures.mouseWheelSensitivity, 8)
        XCTAssertEqual(settings.mouseWheelSensitivity, 8)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, 8)
    }

    func testOlderConfigWithoutMouseWheelSensitivityUsesOriginalBehavior() throws {
        var export = SettingsExport.defaults()
        export.gestures.mouseWheelSensitivity = nil
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = GestureSettings()
        settings.mouseWheelSensitivity = 8

        settings.apply(decoded.gestures)

        XCTAssertNil(decoded.gestures.mouseWheelSensitivity)
        XCTAssertEqual(settings.mouseWheelSensitivity, 1)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, 1)
    }

    func testMouseWheelSensitivityClampsFiniteValuesAndRejectsNonfiniteValues() {
        let settings = GestureSettings()
        let range = GestureSettings.mouseWheelSensitivityRange
        let defaultSensitivity = settings.mouseWheelSensitivity
        var observedValues: [Double] = []
        settings.onChange = { observedValues.append(settings.mouseWheelSensitivity) }
        defer { settings.onChange = nil }

        settings.mouseWheelSensitivity = range.lowerBound - 1
        XCTAssertEqual(settings.mouseWheelSensitivity, range.lowerBound)
        XCTAssertEqual(observedValues, [range.lowerBound])
        settings.mouseWheelSensitivity = range.upperBound + 1
        XCTAssertEqual(settings.mouseWheelSensitivity, range.upperBound)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, range.upperBound)
        XCTAssertEqual(observedValues, [range.lowerBound, range.upperBound])

        for value in [Double.nan, .infinity, -.infinity] {
            observedValues.removeAll()
            settings.mouseWheelSensitivity = value
            XCTAssertEqual(settings.mouseWheelSensitivity, defaultSensitivity)
            XCTAssertTrue(settings.mouseWheelSensitivity.isFinite)
            XCTAssertEqual(observedValues, [defaultSensitivity])
        }
    }

    func testChangingMouseWheelSensitivityDoesNotChangeTrackpadSensitivity() {
        let settings = GestureSettings()
        let trackpadSensitivity = settings.scrollSensitivity
        settings.mouseWheelSensitivity = 8

        XCTAssertEqual(settings.scrollSensitivity, trackpadSensitivity)
        XCTAssertEqual(settings.export().scrollSensitivity, trackpadSensitivity)
    }
}
