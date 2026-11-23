// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class QuakeSectionSettingsExportTests: XCTestCase {
    func testOptionalQuakeFieldsStayAbsentWithoutCodecDefaults() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.opacity = nil
        export.quakeTerminal.backgroundBlurRadius = nil
        export.quakeTerminal.monitorMode = nil
        let data = try SettingsLuauDocument.initialSource(export)
        let tree = try SettingsLuauFixture.fields(in: data)
        let node = try XCTUnwrap(tree["quakeTerminal"])
        guard case let .record(quake) = node else { return XCTFail("Expected quakeTerminal table") }

        XCTAssertNil(quake["opacity"])
        XCTAssertNil(quake["backgroundBlurRadius"])
        XCTAssertNil(quake["monitorMode"])
        XCTAssertEqual(try SettingsLuauFixture.decode(data).quakeTerminal, SettingsExport.defaults().quakeTerminal)
    }

    func testNonoptionalQuakeFieldsRemainRequired() throws {
        let keys = [
            "enabled", "position", "widthPercent", "heightPercent", "animationDuration", "autoHide", "backgroundEffect"
        ]
        try SettingsLuauFixture.assertRequiredFields(keys, in: "quakeTerminal")
    }
}
