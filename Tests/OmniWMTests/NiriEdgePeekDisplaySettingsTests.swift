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

    private func peekSettings(percent: Double) -> NiriSettings {
        let settings = NiriSettings()
        settings.edgePeekPercent = percent
        return settings
    }

    private func peekWidths(_ percent: Double, on monitor: Monitor) -> EdgePeekWidths {
        let width = (monitor.frame.width * CGFloat(percent) / 100).rounded()
        return EdgePeekWidths(leading: width, trailing: width)
    }

    func testADisplaysPeekSettingsRoundTripAndThePercentIsClamped() throws {
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(monitorName: "Studio", edgePeekPercent: 6.5),
            MonitorNiriSettings(monitorName: "Laptop", edgePeekPercent: 0)
        ]
        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertEqual(decoded, export)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("edgePeek ="))
        XCTAssertEqual(decoded.monitorNiriSettings[1].edgePeekPercent, 0)
        XCTAssertEqual(MonitorNiriSettings(monitorName: "Wide", edgePeekPercent: 25).edgePeekPercent, 10)
        XCTAssertEqual(MonitorNiriSettings(monitorName: "Wide", edgePeekPercent: -1).edgePeekPercent, 0)
    }

    func testADisplayUsesItsOwnPeekWidthOrFollowsAllDisplays() {
        let monitor = display(7, x: 0, width: 1_500, name: "Peek display")
        let allDisplays: Double = 3
        let own: Double = 6
        let settings = peekSettings(percent: allDisplays)

        XCTAssertEqual(settings.resolved(for: monitor).edgePeekShare, CGFloat(allDisplays) / 100)

        settings.update(MonitorNiriSettings(monitorName: monitor.name, edgePeekPercent: own), for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).edgePeekShare, CGFloat(own) / 100)

        settings.remove(for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).edgePeekShare, CGFloat(allDisplays) / 100)
    }

    func testPeekingCanBeTurnedOnOrOffForOneDisplay() {
        let monitor = display(7, x: 0, width: 1_500, name: "Peek display")
        let own: Double = 5
        let off = peekSettings(percent: 0)
        XCTAssertNil(off.resolved(for: monitor).edgePeekShare)
        off.update(MonitorNiriSettings(monitorName: monitor.name, edgePeekPercent: own), for: monitor)
        XCTAssertEqual(off.resolved(for: monitor).edgePeekShare, CGFloat(own) / 100)

        let on = peekSettings(percent: 3)
        on.update(MonitorNiriSettings(monitorName: monitor.name, edgePeekPercent: 0), for: monitor)
        XCTAssertNil(on.resolved(for: monitor).edgePeekShare)
    }

    func testThePeekCheckIsSkippedOnlyWhileNoDisplayCanPeek() {
        let left = display(9, x: 0, width: 1_500, name: "No peeks")
        let right = display(10, x: 3_000, width: 2_000, name: "Own peeks")
        let own: Double = 5
        let settings = peekSettings(percent: 0)
        let engine = NiriLayoutEngine()
        engine.syncWorkspaceAssignments(
            [
                (workspaceId: WorkspaceDescriptor.ID(), monitor: left),
                (workspaceId: WorkspaceDescriptor.ID(), monitor: right)
            ],
            orientations: [left.id: .horizontal, right.id: .horizontal]
        )
        engine.updateMonitorSettings(settings.resolved(for: left), for: left.id)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)
        XCTAssertFalse(engine.edgePeeksPossible)

        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: own), for: right)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)
        XCTAssertTrue(engine.edgePeeksPossible)
        XCTAssertEqual(engine.edgePeekWidths(viewFrame: right.frame), peekWidths(own, on: right))

        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: 0), for: right)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)
        XCTAssertFalse(engine.edgePeeksPossible)

        engine.edgePeekShare = CGFloat(own) / 100
        XCTAssertTrue(engine.edgePeeksPossible)
    }

    func testEachDisplayGetsPeeksOfItsOwnWidth() {
        let left = display(7, x: 0, width: 1_500, name: "Left peeks")
        let right = display(8, x: 3_000, width: 2_000, name: "Right peeks")
        let allDisplays: Double = 3
        let own: Double = 5
        let settings = peekSettings(percent: allDisplays)
        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: own), for: right)
        let engine = NiriLayoutEngine()
        engine.edgePeekShare = CGFloat(allDisplays) / 100
        engine.syncWorkspaceAssignments(
            [
                (workspaceId: WorkspaceDescriptor.ID(), monitor: left),
                (workspaceId: WorkspaceDescriptor.ID(), monitor: right)
            ],
            orientations: [left.id: .horizontal, right.id: .horizontal]
        )
        engine.updateMonitorSettings(settings.resolved(for: left), for: left.id)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)

        XCTAssertEqual(engine.edgePeekWidths(viewFrame: left.frame), peekWidths(allDisplays, on: left))
        XCTAssertEqual(engine.edgePeekWidths(viewFrame: right.frame), peekWidths(own, on: right))

        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: 0), for: right)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)

        XCTAssertNil(engine.edgePeekWidths(viewFrame: right.frame))
        XCTAssertEqual(engine.edgePeekWidths(viewFrame: left.frame), peekWidths(allDisplays, on: left))
    }
}
