// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsRoutingCodecTests: XCTestCase {
    func testRoutingSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.routing.mode = .custom
        export.mouseWarp.enabled = false
        export.routing.arrangements = [MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Studio Display", monitorDisplayId: 7, gridColumn: 1, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 0)
        ]), MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Work Display", monitorDisplayId: 9, gridColumn: 0, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 1)
        ])]

        let encoded = try SettingsLuauDocument.initialSource(export)
        let fields = try SettingsLuauFixture.fields(in: encoded)
        guard case let .list(arrangements) = fields["routing"]?["arrangements"] else {
            return XCTFail("Missing routing arrangements")
        }
        XCTAssertEqual(arrangements.count, export.routing.arrangements.count)
        XCTAssertNotNil(arrangements.first?["monitors"])
        XCTAssertNil(fields["monitorRoutingOverrides"])

        let decoded = try SettingsLuauFixture.decode(encoded)

        XCTAssertEqual(decoded.routing.mode, .custom)
        XCTAssertFalse(decoded.mouseWarp.enabled)
        XCTAssertEqual(decoded.routing.arrangements, export.routing.arrangements)
    }

    func testRoutingDefaults() throws {
        let decoded = try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(.defaults()))

        XCTAssertEqual(decoded.routing.mode, .macOS)
        XCTAssertTrue(decoded.mouseWarp.enabled)
        XCTAssertTrue(decoded.routing.arrangements.isEmpty)
        XCTAssertTrue(String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
            .contains("arrangements = {}"))
    }
}
