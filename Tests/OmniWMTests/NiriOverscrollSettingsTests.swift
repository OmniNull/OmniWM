// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriOverscrollSettingsTests: XCTestCase {
    func testDefaultsRemainOptInAndLegacySettingsLoadWithoutNewKeys() throws {
        var export = SettingsExport.defaults()
        export.niri.allowOverscroll = nil
        export.niri.overscrollVisibleStripPercent = nil
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = NiriSettings()
        settings.allowOverscroll = true
        settings.overscrollVisibleStripPercent = 25
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertFalse(settings.allowOverscroll)
        XCTAssertEqual(settings.overscrollVisibleStripPercent, 5)
        XCTAssertEqual(settings.edgeOverscroll, .disabled)
    }

    func testGlobalAndMonitorSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.niri.allowOverscroll = true
        export.niri.overscrollVisibleStripPercent = 15
        export.monitorNiriSettings = [
            MonitorNiriSettings(monitorName: "Portrait", allowOverscroll: false, overscrollVisibleStripPercent: 30)
        ]
        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded, export)
        XCTAssertFalse(SettingsTOMLCodec.unknownKeyPaths(in: data).contains { $0.contains("verscroll") })
        let settings = NiriSettings()
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(settings.edgeOverscroll, .enabled(visibleFraction: 0.15))
        XCTAssertEqual(settings.export(), decoded.niri)
    }

    func testVisibleStripClampsBeforeSaving() {
        let settings = NiriSettings()
        var saved: [Int] = []
        settings.onChange = { saved.append(settings.overscrollVisibleStripPercent) }
        for (value, expected) in [(-1, 1), (0, 1), (101, 100), (5, 5)] {
            settings.overscrollVisibleStripPercent = value
            XCTAssertEqual(settings.overscrollVisibleStripPercent, expected)
            XCTAssertEqual(saved.last, expected)
        }
        XCTAssertEqual(saved.count, 4)
        settings.onChange = nil
    }

    func testMonitorOverridesInheritIndependently() {
        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7), displayId: 7, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Overscroll display"
        )
        let settings = NiriSettings()
        settings.allowOverscroll = true
        settings.overscrollVisibleStripPercent = 20
        XCTAssertEqual(settings.resolved(for: monitor).edgeOverscroll, .enabled(visibleFraction: 0.2))
        settings.update(MonitorNiriSettings(monitorName: monitor.name, overscrollVisibleStripPercent: 35), for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).edgeOverscroll, .enabled(visibleFraction: 0.35))
        settings.update(MonitorNiriSettings(monitorName: monitor.name, allowOverscroll: false), for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).edgeOverscroll, .disabled)
        settings.remove(for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).edgeOverscroll, .enabled(visibleFraction: 0.2))
    }
}
