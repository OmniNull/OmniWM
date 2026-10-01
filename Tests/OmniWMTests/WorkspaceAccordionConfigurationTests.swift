// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceAccordionConfigurationTests: XCTestCase {
    func testAccordionDefaultsToFalse() {
        XCTAssertFalse(WorkspaceConfiguration(name: "1").accordion)
    }

    func testWithAccordionKeepsOtherFields() {
        let config = WorkspaceConfiguration(name: "1", layoutType: .niri)
        let copy = config.with(accordion: true)

        XCTAssertTrue(copy.accordion)
        XCTAssertEqual(copy.id, config.id)
        XCTAssertEqual(copy.name, "1")
        XCTAssertEqual(copy.layoutType, .niri)
    }

    func testAccordionRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations[0] = export.workspaceConfigurations[0].with(accordion: true)

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("accordion = true"))
        XCTAssertTrue(decoded.workspaceConfigurations[0].accordion)
        XCTAssertFalse(decoded.workspaceConfigurations[1].accordion)
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).isEmpty)
    }

    func testWorkspaceWithoutAccordionKeyDecodesAsFalse() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations[0] = export.workspaceConfigurations[0].with(accordion: true)
        let source = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("accordion = ") }
            .joined(separator: "\n")

        let decoded = try SettingsTOMLCodec.decode(Data(stripped.utf8))

        XCTAssertFalse(decoded.workspaceConfigurations.isEmpty)
        XCTAssertTrue(decoded.workspaceConfigurations.allSatisfy { !$0.accordion })
    }
}
