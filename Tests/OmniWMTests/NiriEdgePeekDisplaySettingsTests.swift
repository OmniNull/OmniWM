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

    private func peekWidths(_ percent: Double, on monitor: Monitor) -> EdgePeekSpans {
        let width = (monitor.frame.width * CGFloat(percent) / 100).rounded()
        return EdgePeekSpans(leading: width, trailing: width)
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
        XCTAssertEqual(
            engine.edgePeekSpans(viewFrame: right.frame, orientation: .horizontal),
            peekWidths(own, on: right)
        )

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

        XCTAssertEqual(
            engine.edgePeekSpans(viewFrame: left.frame, orientation: .horizontal),
            peekWidths(allDisplays, on: left)
        )
        XCTAssertEqual(
            engine.edgePeekSpans(viewFrame: right.frame, orientation: .horizontal),
            peekWidths(own, on: right)
        )

        settings.update(MonitorNiriSettings(monitorName: right.name, edgePeekPercent: 0), for: right)
        engine.updateMonitorSettings(settings.resolved(for: right), for: right.id)

        XCTAssertNil(engine.edgePeekSpans(viewFrame: right.frame, orientation: .horizontal))
        XCTAssertEqual(
            engine.edgePeekSpans(viewFrame: left.frame, orientation: .horizontal),
            peekWidths(allDisplays, on: left)
        )
    }

    func testVerticalPeeksUseEachDisplaysHeightAndOverride() {
        let first = display(7, x: 0, width: 1_500, name: "Global portrait peeks")
        let frame = CGRect(x: first.frame.maxX + 100, y: -213, width: 800, height: 1_600)
        let second = Monitor(
            id: .init(displayId: 8), displayId: 8, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Own portrait peeks"
        )
        let global: Double = 3
        let own: Double = 6
        let settings = peekSettings(percent: global)
        settings.update(MonitorNiriSettings(monitorName: second.name, edgePeekPercent: own), for: second)
        let engine = NiriLayoutEngine()
        engine.edgePeekShare = CGFloat(global) / 100
        let firstWorkspace = WorkspaceDescriptor.ID()
        let secondWorkspace = WorkspaceDescriptor.ID()
        engine.syncWorkspaceAssignments(
            [(workspaceId: firstWorkspace, monitor: first), (workspaceId: secondWorkspace, monitor: second)],
            orientations: [first.id: .vertical, second.id: .vertical]
        )
        for monitor in [first, second] {
            engine.updateMonitorSettings(settings.resolved(for: monitor), for: monitor.id)
        }
        let globalSpan = (first.frame.height * CGFloat(global) / 100).rounded()
        let ownSpan = (second.frame.height * CGFloat(own) / 100).rounded()
        XCTAssertEqual(
            engine.edgePeekSpans(in: firstWorkspace),
            EdgePeekSpans(leading: globalSpan, trailing: globalSpan)
        )
        XCTAssertEqual(engine.edgePeekSpans(in: secondWorkspace), EdgePeekSpans(leading: ownSpan, trailing: ownSpan))
        settings.update(MonitorNiriSettings(monitorName: second.name, edgePeekPercent: 0), for: second)
        engine.updateMonitorSettings(settings.resolved(for: second), for: second.id)
        XCTAssertNil(engine.edgePeekSpans(in: secondWorkspace))
        XCTAssertEqual(
            engine.edgePeekSpans(in: firstWorkspace),
            EdgePeekSpans(leading: globalSpan, trailing: globalSpan)
        )
    }

    func testSharedPrimaryEdgesSuppressPeeksButDiagonalCornersDoNot() {
        let frame = CGRect(x: 137, y: -219, width: 1500, height: 1700)
        let share: CGFloat = 0.05
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let horizontal = orientation == .horizontal
            let span = horizontal ? frame.width : frame.height
            let crossSpan = horizontal ? frame.height : frame.width
            let peek = (span * share).rounded()
            for leading in [false, true] {
                for cornerOnly in [false, true] {
                    let primaryDelta = leading ? -span : span
                    let crossDelta = cornerOnly ? crossSpan : 0
                    let neighborFrame = frame.offsetBy(
                        dx: horizontal ? primaryDelta : crossDelta, dy: horizontal ? crossDelta : primaryDelta
                    )
                    let main = Monitor(
                        id: .init(displayId: 7), displayId: 7, frame: frame, visibleFrame: frame,
                        hasNotch: false, name: "Shared peek edge"
                    )
                    let neighbor = Monitor(
                        id: .init(displayId: 8), displayId: 8, frame: neighborFrame, visibleFrame: neighborFrame,
                        hasNotch: false, name: "Peek neighbor"
                    )
                    let engine = NiriLayoutEngine()
                    engine.edgePeekShare = share
                    let workspace = WorkspaceDescriptor.ID()
                    engine.syncWorkspaceAssignments(
                        [
                            (workspaceId: workspace, monitor: main),
                            (workspaceId: WorkspaceDescriptor.ID(), monitor: neighbor)
                        ],
                        orientations: [main.id: orientation, neighbor.id: orientation]
                    )
                    XCTAssertEqual(engine.edgePeekSpans(in: workspace), EdgePeekSpans(
                        leading: leading && !cornerOnly ? 0 : peek,
                        trailing: !leading && !cornerOnly ? 0 : peek
                    ))
                }
            }
        }
    }
}
