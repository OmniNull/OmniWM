// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePeekDisplaySettingsTests: XCTestCase {
    private func display(_ displayId: UInt32, x: CGFloat, width: CGFloat, name: String) -> Monitor {
        let frame = CGRect(x: x, y: 0, width: width, height: 900)
        return Monitor(
            id: Monitor.ID(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: name
        )
    }

    private func fusionSettings(peek: Bool = true, percent: Double = 3) -> NiriSettings {
        let settings = NiriSettings()
        settings.macOSFusion = true
        settings.edgePeek = peek
        settings.edgePeekPercent = percent
        return settings
    }

    func testADisplaysPeekSettingsRoundTripAndThePercentIsClamped() throws {
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(monitorName: "Studio", edgePeek: true, edgePeekPercent: 6.5),
            MonitorNiriSettings(monitorName: "Laptop", edgePeek: false)
        ]
        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertEqual(decoded, export)
        XCTAssertFalse(SettingsTOMLCodec.unknownKeyPaths(in: data).contains { $0.contains("edgePeek") })
        XCTAssertNil(decoded.monitorNiriSettings[1].edgePeekPercent)
        XCTAssertEqual(MonitorNiriSettings(monitorName: "Wide", edgePeekPercent: 25).edgePeekPercent, 10)
        XCTAssertEqual(MonitorNiriSettings(monitorName: "Wide", edgePeekPercent: 0).edgePeekPercent, 1)
    }

    func testADisplayUsesItsOwnPeekWidthOrFollowsAllDisplays() throws {
        let monitor = display(7, x: 0, width: 1_500, name: "Peek display")
        let settings = fusionSettings(percent: 3)

        XCTAssertEqual(try XCTUnwrap(settings.resolved(for: monitor).edgePeekShare), 0.03, accuracy: 0.0001)

        settings.update(MonitorNiriSettings(monitorName: monitor.name, edgePeekPercent: 6), for: monitor)
        XCTAssertEqual(try XCTUnwrap(settings.resolved(for: monitor).edgePeekShare), 0.06, accuracy: 0.0001)

        settings.remove(for: monitor)
        XCTAssertEqual(try XCTUnwrap(settings.resolved(for: monitor).edgePeekShare), 0.03, accuracy: 0.0001)
    }

    func testPeekingCanBeTurnedOnOrOffForOneDisplay() throws {
        let monitor = display(7, x: 0, width: 1_500, name: "Peek display")
        let off = fusionSettings(peek: false)
        off.update(MonitorNiriSettings(monitorName: monitor.name, edgePeek: true, edgePeekPercent: 5), for: monitor)
        XCTAssertEqual(try XCTUnwrap(off.resolved(for: monitor).edgePeekShare), 0.05, accuracy: 0.0001)

        let on = fusionSettings(peek: true)
        on.update(MonitorNiriSettings(monitorName: monitor.name, edgePeek: false), for: monitor)
        XCTAssertNil(on.resolved(for: monitor).edgePeekShare)
    }

    func testWithMacOSFusionOffNoDisplayPeeks() {
        let monitor = display(7, x: 0, width: 1_500, name: "Peek display")
        let settings = fusionSettings()
        settings.update(
            MonitorNiriSettings(monitorName: monitor.name, edgePeek: true, edgePeekPercent: 5),
            for: monitor
        )
        settings.macOSFusion = false

        XCTAssertNil(settings.resolved(for: monitor).edgePeekShare)
    }

    func testEachDisplayGetsPeeksOfItsOwnWidth() {
        let left = display(7, x: 0, width: 1_500, name: "Left peeks")
        let right = display(8, x: 3_000, width: 2_000, name: "Right peeks")
        let settings = fusionSettings(percent: 3)
        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: 5), for: right)
        let engine = NiriLayoutEngine()
        engine.edgePeekShare = 0.03
        engine.syncWorkspaceAssignments(
            [
                (workspaceId: WorkspaceDescriptor.ID(), monitor: left),
                (workspaceId: WorkspaceDescriptor.ID(), monitor: right)
            ],
            orientations: [left.id: .horizontal, right.id: .horizontal]
        )
        engine.updateMonitorSettings(settings.resolved(for: left), for: left.id)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)

        XCTAssertEqual(engine.edgePeekWidths(viewFrame: left.frame), EdgePeekWidths(leading: 45, trailing: 45))
        XCTAssertEqual(engine.edgePeekWidths(viewFrame: right.frame), EdgePeekWidths(leading: 100, trailing: 100))

        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeek: false), for: right)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)

        XCTAssertNil(engine.edgePeekWidths(viewFrame: right.frame))
        XCTAssertEqual(engine.edgePeekWidths(viewFrame: left.frame), EdgePeekWidths(leading: 45, trailing: 45))
    }
}
