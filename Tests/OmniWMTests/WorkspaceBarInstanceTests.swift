// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarInstanceTests: XCTestCase {
    private final class MeasurementView: NSHostingView<WorkspaceBarMeasurementView> {
        var measurementCount = 0

        override var fittingSize: NSSize {
            measurementCount += 1
            return NSSize(width: 120, height: 24)
        }
    }

    private struct Fixture {
        let instance: WorkspaceBarInstance
        let measurementView: MeasurementView
    }

    func testRepeatedSnapshotReusesMeasurementAndChangedSnapshotInvalidatesIt() {
        let fixture = makeFixture()
        let instance = fixture.instance
        let snapshot = instance.model.snapshot
        defer { instance.primary.panel.close() }

        XCTAssertEqual(instance.measuredWidth(for: snapshot, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 1)
        instance.updateSnapshot(snapshot)
        XCTAssertEqual(instance.measuredWidth(for: snapshot, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 1)

        let changed = snapshot.replacingScratchpads([
            WorkspaceBarScratchpadItem(index: 1, label: "Terminal", windows: [], isVisible: false)
        ])
        instance.updateSnapshot(changed)
        XCTAssertEqual(instance.measuredWidth(for: changed, slice: .all, showsSystemStatsButton: false), 120)
        XCTAssertEqual(fixture.measurementView.measurementCount, 2)
        XCTAssertEqual(instance.model.snapshot, changed)
    }

    func testMissingScreenRejectsUpdateWithoutChangingExistingMonitorOrPanels() {
        let fixture = makeFixture(screenDisplayId: 1)
        let instance = fixture.instance
        let originalMonitor = instance.monitor
        let panel = instance.primary.panel
        defer { panel.close() }

        XCTAssertFalse(instance.updateMonitor(makeMonitor(width: 800), screen: nil))
        XCTAssertEqual(instance.monitor.frame, originalMonitor.frame)
        XCTAssertEqual(instance.screenDisplayId, 1)
        XCTAssertTrue(instance.primary.panel === panel)
    }

    func testHeadlessMonitorUpdateRetainsPanelAndModelIdentity() {
        let fixture = makeFixture()
        let instance = fixture.instance
        let panel = instance.primary.panel
        let model = instance.model
        let updated = makeMonitor(width: 800)
        defer { panel.close() }

        XCTAssertTrue(instance.updateMonitor(updated, screen: nil))
        XCTAssertEqual(instance.monitor.frame, updated.frame)
        XCTAssertNil(instance.screenDisplayId)
        XCTAssertTrue(instance.primary.panel === panel)
        XCTAssertTrue(instance.model === model)
    }

    func testRepeatedFrameDoesNotApplyAgainAndRetargetingUsesSamePanel() {
        let fixture = makeFixture()
        let island = fixture.instance.primary
        let panel = island.panel
        let initial = NSRect(x: 100, y: 740, width: 120, height: 24)
        let retargeted = initial.offsetBy(dx: 80, dy: 0)
        var appliedFrames: [NSRect] = []
        let apply: (WorkspaceBarPanel, NSRect) -> Void = { target, frame in
            XCTAssertTrue(target === panel)
            appliedFrames.append(frame)
        }
        defer { panel.close() }

        island.applyFrame(initial, using: apply)
        island.applyFrame(initial, using: apply)
        island.applyFrame(retargeted, using: apply)
        XCTAssertEqual(appliedFrames, [initial, retargeted])
        XCTAssertEqual(island.lastAppliedFrame, retargeted)
    }

    func testFrameApplicationAllowsSynchronousIslandRead() {
        let fixture = makeFixture()
        let instance = fixture.instance
        let panel = instance.primary.panel
        let frame = NSRect(x: 100, y: 740, width: 120, height: 24)
        var applied = false
        defer { panel.close() }

        instance.primary.applyFrame(frame) { target, _ in
            applied = true
            XCTAssertTrue(instance.primary.panel === target)
            XCTAssertEqual(instance.primary.slice, .all)
        }

        XCTAssertTrue(applied)
        XCTAssertEqual(instance.primary.lastAppliedFrame, frame)
    }

    func testFillModeCompactsAgainstPanelWidthAndRecalculatesAfterModeAndMonitorChanges() {
        let fixture = makeFixture(barHeight: 28)
        let instance = fixture.instance
        defer { instance.primary.panel.close() }
        let monitor = makeMonitor(width: 1512, notchRange: 656 ... 856)
        let resolved = makeResolved(notchMode: .fillLeftOfNotch)
        let snapshot = instance.model.snapshot.replacingScratchpads((1 ... 5).map {
            WorkspaceBarScratchpadItem(index: $0, label: "Scratchpad number \($0)", windows: [], isVisible: false)
        })
        let frame = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            .frame(fittingWidth: 0, monitor: monitor, resolved: resolved)
        let expandedWidth = 120 + WorkspaceBarScratchpadLayout.estimatedWidth(
            of: snapshot.scratchpads,
            barHeight: snapshot.barHeight
        )
        XCTAssertGreaterThan(expandedWidth, frame.width)
        XCTAssertLessThan(expandedWidth, monitor.frame.width)

        let compacted = instance.scratchpadCompactedSnapshot(snapshot, monitor: monitor, resolved: resolved)
        XCTAssertTrue(compacted.scratchpads.allSatisfy { $0.presentation == .compact })
        let view = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: compacted))
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.width, frame.width)

        let ordinary = instance.scratchpadCompactedSnapshot(snapshot, monitor: monitor, resolved: makeResolved())
        XCTAssertTrue(ordinary.scratchpads.allSatisfy { $0.presentation == .expanded })
        XCTAssertEqual(instance.scratchpadCompactedSnapshot(snapshot, monitor: monitor, resolved: resolved), compacted)

        let widerMonitor = makeMonitor(width: 3000, origin: CGPoint(x: 500, y: 100))
        let widened = instance.scratchpadCompactedSnapshot(snapshot, monitor: widerMonitor, resolved: resolved)
        XCTAssertTrue(widened.scratchpads.allSatisfy { $0.presentation == .expanded })
    }

    func testPanelSettingsApplyToBothExistingIslands() {
        let primary = makeFixture()
        let secondary = makeFixture()
        let instance = primary.instance
        instance.secondary = secondary.instance.primary
        defer {
            instance.primary.panel.close()
            instance.secondary?.panel.close()
        }

        instance.applyPanelSettings(resolved: makeResolved(notchMode: .fillLeftOfNotch))
        for panel in [instance.primary.panel, secondary.instance.primary.panel] {
            XCTAssertEqual(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
            XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }

        instance.applyPanelSettings(resolved: makeResolved())
        for panel in [instance.primary.panel, secondary.instance.primary.panel] {
            XCTAssertEqual(panel.level, .popUpMenu)
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
    }

    func testAppearanceRefreshPreservesConfiguredAppearanceControls() {
        let fixture = makeFixture()
        let instance = fixture.instance
        defer { instance.primary.panel.close() }
        let snapshot = WorkspaceBarSnapshot(
            projection: instance.model.snapshot.projection,
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.1,
            inactiveIconOpacity: 0.7,
            transparentBackground: true,
            solidBlackBackground: true,
            showItemBackgrounds: false,
            showAccentHighlights: false,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        instance.updateSnapshot(snapshot)
        let accentColor = SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)

        instance.refreshAppearance(resolved: makeResolved(accentColor: accentColor))

        XCTAssertEqual(instance.model.snapshot.accentColor, accentColor)
        XCTAssertEqual(instance.model.snapshot.inactiveIconOpacity, 0.7)
        XCTAssertTrue(instance.model.snapshot.transparentBackground)
        XCTAssertTrue(instance.model.snapshot.solidBlackBackground)
        XCTAssertFalse(instance.model.snapshot.showItemBackgrounds)
        XCTAssertFalse(instance.model.snapshot.showAccentHighlights)
    }

    private func makeFixture(screenDisplayId: CGDirectDisplayID? = nil, barHeight: CGFloat = 24) -> Fixture {
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.1,
            barHeight: barHeight,
            accentColor: nil,
            textColor: nil
        )
        let model = WorkspaceBarModel(snapshot: snapshot)
        let measurementView = MeasurementView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let primary = WorkspaceBarIslandPanel(
            panel: WorkspaceBarPanel.defaultPanel(),
            rootView: WorkspaceBarView(
                model: model,
                motionPolicy: MotionPolicy(animationsEnabled: false),
                onFocusWorkspace: { _ in },
                onFocusWindow: { _ in },
                onActivateScratchpad: { _ in }
            ),
            resolved: makeResolved()
        )
        return Fixture(
            instance: WorkspaceBarInstance(
                monitor: makeMonitor(),
                primary: primary,
                measurementView: measurementView,
                model: model,
                screenDisplayId: screenDisplayId
            ),
            measurementView: measurementView
        )
    }

    private func makeMonitor(
        width: CGFloat = 1200,
        origin: CGPoint = .zero,
        notchRange: ClosedRange<CGFloat>? = nil
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: CGRect(origin: origin, size: CGSize(width: width, height: 800)),
            visibleFrame: CGRect(origin: origin, size: CGSize(width: width, height: 772)),
            hasNotch: notchRange != nil,
            notchRange: notchRange,
            name: "Test"
        )
    }

    private func makeResolved(
        notchMode: WorkspaceBarNotchMode = .off,
        accentColor: SettingsColor? = nil
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: notchMode,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: .popup,
            height: 24,
            backgroundOpacity: 0.1,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: 0,
            yOffset: 0,
            accentColor: accentColor,
            textColor: nil
        )
    }
}
