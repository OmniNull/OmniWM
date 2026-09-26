// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleStackIncomingWindowsSettingsTests: XCTestCase {
    private let displayUUID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

    func testMissingKeyDecodesAsDisabled() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let withoutKey = source
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("stackIncomingWindows = ") }
            .joined(separator: "\n")
        XCTAssertNotEqual(withoutKey, source)

        let decoded = try SettingsTOMLCodec.decode(Data(withoutKey.utf8))

        XCTAssertFalse(decoded.dwindle.stackIncomingWindows)
    }

    func testEnabledValueAndMonitorOverrideSurviveTOMLRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.dwindle.stackIncomingWindows = true
        export.monitorDwindleSettings = [
            MonitorDwindleSettings(monitorName: "Display", monitorDisplayUUID: displayUUID, stackIncomingWindows: false)
        ]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertTrue(decoded.dwindle.stackIncomingWindows)
        XCTAssertEqual(decoded.monitorDwindleSettings.first?.stackIncomingWindows, false)
    }

    @MainActor
    func testMonitorOverrideWinsOverGlobalValue() {
        let overridden = makeMonitor(displayId: 2, displayUUID: displayUUID)
        let inheriting = makeMonitor(displayId: 3, displayUUID: nil)
        let settings = makeSettingsStore()
        settings.dwindle.stackIncomingWindows = true
        settings.dwindle.update(
            MonitorDwindleSettings(
                monitorName: overridden.name,
                monitorDisplayUUID: displayUUID,
                stackIncomingWindows: false
            ),
            for: overridden
        )

        XCTAssertFalse(settings.dwindle.resolved(for: overridden).stackIncomingWindows)
        XCTAssertTrue(settings.dwindle.resolved(for: inheriting).stackIncomingWindows)
    }

    @MainActor
    func testApplyingExportUpdatesRuntimeSetting() {
        var export = SettingsExport.defaults()
        export.dwindle.stackIncomingWindows = true
        let settings = makeSettingsStore()

        settings.applyExport(export)

        XCTAssertTrue(settings.dwindle.stackIncomingWindows)
        XCTAssertTrue(settings.dwindle.export().stackIncomingWindows)
    }

    private func makeMonitor(displayId: CGDirectDisplayID, displayUUID: String?) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: "Display \(displayId)",
            displayUUID: displayUUID
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDwindleStackIncomingTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
