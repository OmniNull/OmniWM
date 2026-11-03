// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MouseWheelSensitivitySettingsTests: XCTestCase {
    func testMouseWheelSensitivityRoundTripsThroughTOML() throws {
        let sensitivity = 8.0
        var export = SettingsExport.defaults()
        export.gestures.mouseWheelSensitivity = sensitivity

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = GestureSettings()
        settings.apply(decoded.gestures)

        XCTAssertEqual(decoded.gestures.mouseWheelSensitivity, sensitivity)
        XCTAssertEqual(settings.mouseWheelSensitivity, sensitivity)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, sensitivity)
    }

    func testOlderConfigWithoutMouseWheelSensitivityUsesOriginalBehavior() throws {
        let defaultSensitivity = try XCTUnwrap(SettingsExport.Gestures.defaults().mouseWheelSensitivity)
        var export = SettingsExport.defaults()
        export.gestures.mouseWheelSensitivity = nil
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = GestureSettings()
        settings.mouseWheelSensitivity = 8

        settings.apply(decoded.gestures)

        XCTAssertNil(decoded.gestures.mouseWheelSensitivity)
        XCTAssertEqual(settings.mouseWheelSensitivity, defaultSensitivity)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, defaultSensitivity)
    }

    func testMouseWheelSensitivityClampsFiniteValuesAndRejectsNonfiniteValues() throws {
        let settings = GestureSettings()
        let range = GestureSettings.mouseWheelSensitivityRange
        let defaultSensitivity = try XCTUnwrap(SettingsExport.Gestures.defaults().mouseWheelSensitivity)
        var observedValues: [Double] = []
        settings.onChange = { observedValues.append(settings.mouseWheelSensitivity) }
        defer { settings.onChange = nil }

        settings.mouseWheelSensitivity = range.lowerBound.nextDown
        XCTAssertEqual(settings.mouseWheelSensitivity, range.lowerBound)
        XCTAssertEqual(observedValues, [range.lowerBound])
        settings.mouseWheelSensitivity = range.upperBound.nextUp
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
        let trackpadSensitivity = SettingsExport.Gestures.defaults().scrollSensitivity
        settings.mouseWheelSensitivity = 8

        XCTAssertEqual(settings.scrollSensitivity, trackpadSensitivity)
        XCTAssertEqual(settings.export().scrollSensitivity, trackpadSensitivity)
    }
}
