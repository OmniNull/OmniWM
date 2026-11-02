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
        settings.mouseWheelSensitivity = 0
        XCTAssertEqual(settings.mouseWheelSensitivity, 0.1)
        settings.mouseWheelSensitivity = 100
        XCTAssertEqual(settings.mouseWheelSensitivity, 10)
        XCTAssertEqual(settings.export().mouseWheelSensitivity, 10)

        for value in [Double.nan, .infinity, -.infinity] {
            settings.mouseWheelSensitivity = value
            XCTAssertEqual(settings.mouseWheelSensitivity, 1)
            XCTAssertTrue(settings.mouseWheelSensitivity.isFinite)
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
