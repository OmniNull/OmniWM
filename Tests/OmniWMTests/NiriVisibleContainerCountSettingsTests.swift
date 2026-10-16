// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriVisibleContainerCountSettingsTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let leftMonitor: Monitor
        let rightMonitor: Monitor
        let leftWorkspaceId: WorkspaceDescriptor.ID
        let rightWorkspaceId: WorkspaceDescriptor.ID
    }

    func testCustomDefaultSpanSurvivesVisibleContainerCountChanges() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.niri.defaultContainerPrimarySpan = 0.95
        fixture.controller.updateNiriConfig(defaultContainerPrimarySpan: 0.95)
        let before = widths(fixture)

        fixture.controller.settings.niri.visibleContainerCount = 3
        fixture.controller.updateNiriConfig(visibleContainerCount: 3)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange()
        overrideVisibleContainerCount(4, on: fixture.leftMonitor, fixture: fixture)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange(on: fixture.leftMonitor.id)

        XCTAssertEqual(fixture.controller.settings.niri.defaultContainerPrimarySpan, 0.95)
        XCTAssertEqual(fixture.engine.defaultContainerPrimarySpan, 0.95)
        let after = widths(fixture)
        XCTAssertEqual(after.left, before.left)
        XCTAssertEqual(after.right, before.right)
    }

    func testAutoSpanPerMonitorChangeOnlyRebalancesThatMonitor() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.niri.defaultContainerPrimarySpan = nil
        fixture.controller.updateNiriConfig(defaultContainerPrimarySpan: .some(nil))
        let before = widths(fixture)

        XCTAssertEqual(fixture.controller.settings.niri.visibleContainerCount, 2)
        overrideVisibleContainerCount(4, on: fixture.leftMonitor, fixture: fixture)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange(on: fixture.leftMonitor.id)

        let after = widths(fixture)
        XCTAssertEqual(after.left, [0.25, 0.25])
        XCTAssertEqual(after.right, before.right)
    }

    func testMonitorAutoSpanRebalancesWhileGlobalSpanIsCustom() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.niri.defaultContainerPrimarySpan = 0.95
        fixture.controller.updateNiriConfig(defaultContainerPrimarySpan: 0.95)
        overrideSpan(.auto, on: fixture.leftMonitor, fixture: fixture)
        let before = widths(fixture)

        overrideVisibleContainerCount(4, on: fixture.leftMonitor, fixture: fixture)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange(on: fixture.leftMonitor.id)

        XCTAssertEqual(widths(fixture).left, [0.25, 0.25])
        XCTAssertEqual(widths(fixture).right, before.right)
        XCTAssertEqual(fixture.controller.settings.niri.defaultContainerPrimarySpan, 0.95)
    }

    func testGlobalAutoCountChangePreservesMonitorCustomSpans() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.niri.defaultContainerPrimarySpan = nil
        fixture.controller.updateNiriConfig(defaultContainerPrimarySpan: .some(nil))
        overrideSpan(.custom(0.6), on: fixture.leftMonitor, fixture: fixture)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.leftWorkspaceId) {
            fixture.engine.columns(in: fixture.leftWorkspaceId)[0].width = .proportion(0.4)
        }
        let before = widths(fixture)

        fixture.controller.settings.niri.visibleContainerCount = 4
        fixture.controller.updateNiriConfig(visibleContainerCount: 4)
        fixture.controller.rebalanceNiriSizesForVisibleContainerCountChange()

        XCTAssertEqual(widths(fixture).left, before.left)
        XCTAssertEqual(widths(fixture).right, [0.25, 0.25])
    }

    func testGlobalSpanChangeAndUseGlobalOnlyRebalanceAffectedMonitors() throws {
        let fixture = try makeFixture()
        overrideSpan(.custom(0.6), on: fixture.leftMonitor, fixture: fixture)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.leftWorkspaceId) {
            fixture.engine.columns(in: fixture.leftWorkspaceId)[0].width = .proportion(0.4)
        }

        fixture.controller.settings.niri.defaultContainerPrimarySpan = 0.95
        fixture.controller.updateNiriConfig(defaultContainerPrimarySpan: 0.95)

        XCTAssertEqual(widths(fixture).left, [0.4, 0.6])
        XCTAssertEqual(widths(fixture).right, [0.95, 0.95])
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.rightWorkspaceId) {
            fixture.engine.columns(in: fixture.rightWorkspaceId)[0].width = .proportion(0.3)
        }
        overrideSpan(nil, on: fixture.leftMonitor, fixture: fixture)

        XCTAssertEqual(widths(fixture).left, [0.95, 0.95])
        XCTAssertEqual(widths(fixture).right, [0.3, 0.95])
    }

    func testResettingDisplayOverridesRestoresInheritedSpan() throws {
        let fixture = try makeFixture()
        overrideSpan(.custom(0.6), on: fixture.leftMonitor, fixture: fixture)
        let before = widths(fixture)

        fixture.controller.settings.niri.remove(for: fixture.leftMonitor)
        fixture.controller.updateMonitorNiriSettings()

        XCTAssertEqual(widths(fixture).left, [0.5, 0.5])
        XCTAssertEqual(widths(fixture).right, before.right)
    }

    func testNewAndClaimedColumnsUseMonitorSpanAndKeepExplicitSizing() throws {
        let fixture = try makeFixture()
        overrideSpan(.custom(0.6), on: fixture.leftMonitor, fixture: fixture)
        overrideSpan(.custom(0.9), on: fixture.rightMonitor, fixture: fixture)

        fixture.controller.workspaceManager.withEngineMutationScope {
            for (index, workspaceId) in [fixture.leftWorkspaceId, fixture.rightWorkspaceId].enumerated() {
                let window = fixture.engine.addWindow(
                    token: WindowToken(pid: 873, windowId: index + 1), to: workspaceId, afterSelection: nil
                )
                let expected: CGFloat = workspaceId == fixture.leftWorkspaceId ? 0.6 : 0.9
                XCTAssertEqual(fixture.engine.column(of: window)?.width, .proportion(expected))
                XCTAssertEqual(fixture.engine.column(of: window)?.height, .proportion(expected))
            }
            let explicit = fixture.engine.addWindow(
                token: WindowToken(pid: 873, windowId: 3),
                to: fixture.leftWorkspaceId,
                afterSelection: nil,
                containerSizingState: fixture.engine.initialContainerSizingState(for: 0.25)
            )
            XCTAssertEqual(fixture.engine.column(of: explicit)?.width, .proportion(0.25))
            let tokens = fixture.engine.columns(in: fixture.rightWorkspaceId).flatMap(\.windowNodes).map(\.token)
            for token in tokens {
                fixture.engine.removeWindow(token: token, in: fixture.rightWorkspaceId)
            }
            let empty = NiriContainer()
            empty.width = .proportion(0.25)
            fixture.engine.ensureRoot(for: fixture.rightWorkspaceId).appendChild(empty)
            let claimed = fixture.engine.addWindow(
                token: WindowToken(pid: 873, windowId: 4), to: fixture.rightWorkspaceId, afterSelection: nil
            )
            XCTAssertTrue(fixture.engine.column(of: claimed) === empty)
            XCTAssertEqual(fixture.engine.column(of: claimed)?.width, .proportion(0.9))
        }
    }

    private func overrideSpan(
        _ span: NiriContainerPrimarySpanOverride?,
        on monitor: Monitor,
        fixture: Fixture
    ) {
        var monitorSettings = fixture.controller.settings.niri.settings(for: monitor)
            ?? MonitorNiriSettings(monitorName: monitor.name)
        monitorSettings.defaultContainerPrimarySpan = span
        fixture.controller.settings.niri.update(monitorSettings, for: monitor)
        fixture.controller.updateMonitorNiriSettings()
    }

    private func overrideVisibleContainerCount(_ count: Int, on monitor: Monitor, fixture: Fixture) {
        var monitorSettings = fixture.controller.settings.niri.settings(for: monitor)
            ?? MonitorNiriSettings(monitorName: monitor.name)
        monitorSettings.visibleContainerCount = count
        fixture.controller.settings.niri.update(monitorSettings, for: monitor)
        fixture.controller.updateMonitorNiriSettings()
    }

    private func widths(_ fixture: Fixture) -> (left: [CGFloat], right: [CGFloat]) {
        func proportions(_ workspaceId: WorkspaceDescriptor.ID) -> [CGFloat] {
            fixture.engine.columns(in: workspaceId).map { column in
                if case let .proportion(value) = column.width { return value }
                return -1
            }
        }
        return (proportions(fixture.leftWorkspaceId), proportions(fixture.rightWorkspaceId))
    }

    private func makeFixture() throws -> Fixture {
        let leftMonitor = makeMonitor(displayId: 868_001, x: 0)
        let rightMonitor = makeMonitor(displayId: 868_002, x: 1600)
        let settings = makeSettings(left: leftMonitor, right: rightMonitor)
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        controller.workspaceManager.applySettings()
        let engine = NiriLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.niriEngine = engine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()

        let leftWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let rightWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        let workspaceIds = [leftWorkspaceId, leftWorkspaceId, rightWorkspaceId, rightWorkspaceId]
        for (index, workspaceId) in workspaceIds.enumerated() {
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(
                    token: WindowToken(pid: 868, windowId: index + 1),
                    to: workspaceId,
                    afterSelection: nil
                )
            }
        }
        return Fixture(
            controller: controller,
            engine: engine,
            leftMonitor: leftMonitor,
            rightMonitor: rightMonitor,
            leftWorkspaceId: leftWorkspaceId,
            rightWorkspaceId: rightWorkspaceId
        )
    }

    private func makeSettings(left: Monitor, right: Monitor) -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NiriVisibleContainerCountSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
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
        settings.animationsEnabled = false
        settings.workspaces.defaultLayoutType = .niri
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: left)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: right)),
                layoutType: .niri
            )
        ]
        return settings
    }

    private func makeMonitor(displayId: CGDirectDisplayID, x: CGFloat) -> Monitor {
        let frame = CGRect(x: x, y: 0, width: 1600, height: 900)
        return Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Visible Containers \(displayId)"
        )
    }
}
