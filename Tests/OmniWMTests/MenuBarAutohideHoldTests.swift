// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class FakeMenuBarAutohide {
    var preference: Bool? = false
    var succeeds = true
    var writesWhenFailing = false
    var calls: [Bool?] = []
    var nativeAutohide = false

    var system: MenuBarAutohideHold.System {
        MenuBarAutohideHold.System(
            preference: { self.preference },
            apply: { value in
                self.calls.append(value)
                if self.succeeds || self.writesWhenFailing {
                    self.preference = value
                }
                if self.succeeds {
                    self.nativeAutohide = value == true
                }
                return self.succeeds
            }
        )
    }
}

@MainActor
final class MenuBarAutohideHoldTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> RuntimeStateStore {
        RuntimeStateStore(directory: directory, deferSaves: false)
    }

    func testStartupLeavesOrdinaryPersistentHoldForCurrentBarPolicy() {
        for preference in [nil, false, true] {
            let menuBar = FakeMenuBarAutohide()
            menuBar.preference = preference
            menuBar.nativeAutohide = preference != true
            let state = store()
            state.menuBarHideHold = MenuBarHideHold(previous: nil)

            _ = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

            XCTAssertEqual(menuBar.nativeAutohide, preference != true)
            XCTAssertEqual(menuBar.preference, preference)
            XCTAssertTrue(menuBar.calls.isEmpty)
            XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: nil))
        }
    }

    func testMenuAccessJournalsFullVisibilityChangeAndRestoresAllOriginalPreferences() {
        for preference in [nil, false, true] {
            let menuBar = FakeMenuBarAutohide()
            menuBar.preference = preference
            let state = store()
            state.menuBarHideHold = nil
            let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

            XCTAssertTrue(hold.setMenuAccess(true))
            XCTAssertTrue(hold.setMenuAccess(true))
            XCTAssertFalse(menuBar.nativeAutohide)
            XCTAssertEqual(menuBar.preference, false)
            XCTAssertEqual(store().menuBarHideHold, MenuBarHideHold(previous: preference, temporarilyVisible: true))
            XCTAssertTrue(hold.setMenuAccess(false))
            XCTAssertTrue(hold.setMenuAccess(false))

            XCTAssertEqual(menuBar.nativeAutohide, preference == true)
            XCTAssertEqual(menuBar.preference, preference)
            XCTAssertEqual(menuBar.calls, [false, preference])
            XCTAssertNil(store().menuBarHideHold)
        }
    }

    func testMenuAccessPreservesOriginalPreferenceAcrossPersistentHideAndTemporaryVisibility() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        XCTAssertTrue(hold.setMenuAccess(true))
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false, temporarilyVisible: true))
        XCTAssertEqual(menuBar.preference, false)
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false, temporarilyVisible: true))
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false, temporarilyVisible: true))
        XCTAssertTrue(hold.setMenuAccess(false))

        XCTAssertTrue(menuBar.nativeAutohide)
        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(menuBar.calls, [true, false, true])
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false))
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false, true, false])
        XCTAssertNil(state.menuBarHideHold)
    }

    func testExternalPreferenceChangeDuringMenuAccessSupersedesUnchangedBarPolicy() {
        for external in [nil, true] {
            let menuBar = FakeMenuBarAutohide()
            let state = store()
            state.menuBarHideHold = nil
            let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
            hold.update(hiding: true)
            XCTAssertTrue(hold.setMenuAccess(true))
            menuBar.preference = external
            hold.update(hiding: true)
            XCTAssertTrue(hold.setMenuAccess(false))

            XCTAssertEqual(menuBar.nativeAutohide, external == true)
            XCTAssertEqual(menuBar.preference, external)
            XCTAssertEqual(menuBar.calls, [true, false, external])
            XCTAssertNil(state.menuBarHideHold)
        }
    }

    func testNewBarHideRequestAfterExternalChangeDuringMenuAccessStillApplies() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: false)
        XCTAssertTrue(hold.setMenuAccess(true))
        menuBar.preference = nil
        hold.update(hiding: true)
        XCTAssertTrue(hold.setMenuAccess(false))

        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(menuBar.calls, [false, true])
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: nil))
    }

    func testPolicyChangesWaitForMenuAccessAndApplyLatestValueWithoutDuplicateNativeWrite() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        XCTAssertTrue(hold.setMenuAccess(true))
        hold.update(hiding: false)
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false, temporarilyVisible: true))
        XCTAssertTrue(hold.setMenuAccess(false))
        XCTAssertEqual(menuBar.calls, [true, false, false])
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertNil(state.menuBarHideHold)
    }

    func testEnablingFullWidthDuringMenuAccessWaitsUntilRelease() {
        let menuBar = FakeMenuBarAutohide()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: store())
        hold.update(hiding: false)
        XCTAssertTrue(hold.setMenuAccess(true))
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [false])
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertTrue(hold.setMenuAccess(false))

        XCTAssertEqual(menuBar.calls, [false, true])
        XCTAssertTrue(menuBar.nativeAutohide)
    }

    func testFailedMenuAccessDoesNotOwnAccessOrDeferSubsequentPolicy() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = true
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        menuBar.succeeds = false

        XCTAssertFalse(hold.setMenuAccess(true))
        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(menuBar.calls, [false])
        XCTAssertNil(state.menuBarHideHold)
        XCTAssertTrue(hold.setMenuAccess(false))
        menuBar.succeeds = true
        menuBar.preference = false
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [false, true])
    }

    func testStartupRestoresInterruptedMenuAccessBeforeApplyingCurrentBarPolicy() {
        for previous in [nil, false, true] {
            let menuBar = FakeMenuBarAutohide()
            menuBar.preference = false
            let state = store()
            state.menuBarHideHold = MenuBarHideHold(previous: previous, temporarilyVisible: true)

            let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

            XCTAssertEqual(menuBar.preference, previous)
            XCTAssertEqual(menuBar.calls, [previous])
            XCTAssertNil(store().menuBarHideHold)
            hold.update(hiding: true)
            XCTAssertEqual(menuBar.preference, true)
            XCTAssertEqual(menuBar.calls, previous == true ? [true] : [previous, true])
        }
    }

    func testStartupKeepsExternalChangeAfterInterruptedMenuAccess() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = true
        let state = store()
        state.menuBarHideHold = MenuBarHideHold(previous: false, temporarilyVisible: true)

        _ = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(menuBar.calls, [true])
        XCTAssertNil(store().menuBarHideHold)
    }

    func testFailedVisibilityChangeThatWritesPreferenceRestoresThePreviousPolicy() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        menuBar.succeeds = false
        menuBar.writesWhenFailing = true

        XCTAssertFalse(hold.setMenuAccess(true))
        XCTAssertEqual(menuBar.calls, [true, false, true])
        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(store().menuBarHideHold, MenuBarHideHold(previous: false))
        menuBar.succeeds = true
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.preference, false)
        XCTAssertNil(store().menuBarHideHold)
    }

    func testHidesTheMenuBarOnlyWhileNeededAndRestoresTheUsersValue() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [])
        hold.update(hiding: true)
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true])
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false))
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertNil(state.menuBarHideHold)
    }

    func testAnAbsentSettingIsRemovedAgainOnRestore() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = nil
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: store())
        hold.update(hiding: true)
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, nil])
        XCTAssertNil(menuBar.preference)
    }

    func testLeavesAMenuBarTheUserAlreadyHidesAlone() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = true
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [])
        XCTAssertNil(state.menuBarHideHold)
    }

    func testAChangeTheUserMakesDuringTheHoldIsKept() {
        let menuBar = FakeMenuBarAutohide()
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        menuBar.preference = nil
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true])
        XCTAssertNil(menuBar.preference)
        XCTAssertNil(state.menuBarHideHold)
    }

    func testRestoresAfterACrashThroughTheRuntimeState() {
        let menuBar = FakeMenuBarAutohide()
        MenuBarAutohideHold(system: menuBar.system, runtimeState: store()).update(hiding: true)
        XCTAssertEqual(store().menuBarHideHold, MenuBarHideHold(previous: false))

        let relaunched = MenuBarAutohideHold(system: menuBar.system, runtimeState: store())
        relaunched.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true])
        relaunched.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertNil(store().menuBarHideHold)

        MenuBarAutohideHold(system: menuBar.system, runtimeState: store()).update(hiding: true)
        MenuBarAutohideHold(system: menuBar.system, runtimeState: store()).update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false, true, false])
    }

    func testAHoldTheUserUndidWhileOmniWMWasNotRunningIsReplaced() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = nil
        MenuBarAutohideHold(system: menuBar.system, runtimeState: store()).update(hiding: true)
        menuBar.preference = false

        let relaunched = MenuBarAutohideHold(system: menuBar.system, runtimeState: store())
        relaunched.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true, true])
        XCTAssertEqual(store().menuBarHideHold, MenuBarHideHold(previous: false))
        relaunched.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, true, false])
        XCTAssertNil(store().menuBarHideHold)
    }

    func testAHideThatFailsAfterWritingThePreferenceIsStillRestored() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.succeeds = false
        menuBar.writesWhenFailing = true
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.preference, true)
        XCTAssertEqual(state.menuBarHideHold, MenuBarHideHold(previous: false))
        menuBar.succeeds = true
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertEqual(menuBar.preference, false)
        XCTAssertNil(state.menuBarHideHold)
    }

    func testAFailedChangeLeavesNoHoldAndWaitsForTheNextRequest() {
        let menuBar = FakeMenuBarAutohide()
        menuBar.succeeds = false
        let state = store()
        let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)
        hold.update(hiding: true)
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true])
        XCTAssertNil(state.menuBarHideHold)
        hold.update(hiding: false)
        XCTAssertEqual(menuBar.calls, [true])
        hold.update(hiding: true)
        XCTAssertEqual(menuBar.calls, [true, true])
    }

    func testAFullWidthBarOverTheMenuBarSitsAtTheScreenTopWhetherOrNotTheMenuBarIsHidden() {
        let settings = WorkspaceBarSettings()
        settings.reserveLayoutSpace = true
        func geometry(visibleTop: CGFloat, height: Double, fullWidth: Bool = true) -> (CGRect, CGFloat) {
            let monitor = Monitor(
                id: .init(displayId: 8),
                displayId: 8,
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: visibleTop),
                hasNotch: true,
                notchRange: 656 ... 856,
                name: "Notched"
            )
            settings.height = height
            settings.fullWidth = fullWidth
            let resolved = settings.resolved(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            return (
                geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved),
                geometry.reservedInsets.top
            )
        }
        for height in [24.0, 40.0] {
            let shown = geometry(visibleTop: 945, height: height)
            XCTAssertEqual(shown.0.minY, 982 - height)
            XCTAssertEqual(shown.0, geometry(visibleTop: 982, height: height).0)
            XCTAssertEqual(shown.1, max(0, 945 - (982 - height)))
        }
        XCTAssertNotEqual(
            geometry(visibleTop: 945, height: 24, fullWidth: false).0,
            geometry(visibleTop: 982, height: 24, fullWidth: false).0
        )
    }

    func testFullWidthBelowMenuBarPreservesTheUsersAutohidePreference() {
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: false,
            name: "Plain"
        )
        let settings = WorkspaceBarSettings()
        settings.fullWidth = true
        settings.position = .belowMenuBar

        for preference in [nil, false, true] {
            let menuBar = FakeMenuBarAutohide()
            menuBar.preference = preference
            menuBar.nativeAutohide = preference == true
            let state = store()
            state.menuBarHideHold = nil
            let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

            hold.update(hiding: WorkspaceBarManager.hidesMenuBar(settings.resolved(for: monitor)))

            XCTAssertEqual(menuBar.preference, preference)
            XCTAssertEqual(menuBar.nativeAutohide, preference == true)
            XCTAssertTrue(menuBar.calls.isEmpty)
            XCTAssertNil(state.menuBarHideHold)
        }
    }

    func testMovingFullWidthBarBelowMenuBarRestoresTheUsersAutohidePreference() {
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: false,
            name: "Plain"
        )
        let settings = WorkspaceBarSettings()
        settings.fullWidth = true

        for preference in [nil, false, true] {
            let menuBar = FakeMenuBarAutohide()
            menuBar.preference = preference
            menuBar.nativeAutohide = preference == true
            let state = store()
            state.menuBarHideHold = nil
            let hold = MenuBarAutohideHold(system: menuBar.system, runtimeState: state)

            settings.position = .overlappingMenuBar
            hold.update(hiding: WorkspaceBarManager.hidesMenuBar(settings.resolved(for: monitor)))
            XCTAssertTrue(menuBar.nativeAutohide)

            settings.position = .belowMenuBar
            hold.update(hiding: WorkspaceBarManager.hidesMenuBar(settings.resolved(for: monitor)))

            XCTAssertEqual(menuBar.preference, preference)
            XCTAssertEqual(menuBar.nativeAutohide, preference == true)
            XCTAssertEqual(menuBar.calls, preference == true ? [] : [true, preference])
            XCTAssertNil(state.menuBarHideHold)
        }
    }

    func testFullWidthBarsHideTheMenuBarExceptBelowMenuBar() {
        let plain = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: false,
            name: "Plain"
        )
        let notched = Monitor(
            id: .init(displayId: 8),
            displayId: 8,
            frame: plain.frame,
            visibleFrame: plain.visibleFrame,
            hasNotch: true,
            notchRange: 656 ... 856,
            name: "Notched"
        )
        let settings = WorkspaceBarSettings()
        func hides(on monitor: Monitor) -> Bool {
            WorkspaceBarManager.hidesMenuBar(settings.resolved(for: monitor))
        }
        XCTAssertFalse(hides(on: plain))
        settings.fullWidth = true
        XCTAssertTrue(hides(on: plain))
        XCTAssertTrue(hides(on: notched))
        settings.fullWidthNotchMode = .moveBelowMenuBar
        XCTAssertTrue(hides(on: notched))
        XCTAssertTrue(hides(on: plain))
        for position in [WorkspaceBarPosition.belowMenuBar, .bottom, .left, .right] {
            settings.position = position
            XCTAssertEqual(hides(on: plain), position != .belowMenuBar, "\(position)")
            XCTAssertEqual(hides(on: notched), position != .belowMenuBar, "\(position)")
            settings.fullWidth = false
            XCTAssertFalse(hides(on: plain), "\(position)")
            XCTAssertFalse(hides(on: notched), "\(position)")
            settings.fullWidth = true
        }
    }

    func testABarFillingLeftOfTheNotchCoversTheAppMenusButKeepsTheMenuBar() {
        let notched = Monitor(
            id: .init(displayId: 9),
            displayId: 9,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            notchRange: 656 ... 856,
            name: "Notched"
        )
        let settings = WorkspaceBarSettings()
        settings.notchMode = .fillLeftOfNotch
        XCTAssertFalse(WorkspaceBarManager.hidesMenuBar(settings.resolved(for: notched)))
        XCTAssertTrue(WorkspaceBarManager.coversAppMenus(settings.resolved(for: notched)))
        settings.notchMode = .rightOfNotch
        XCTAssertFalse(WorkspaceBarManager.coversAppMenus(settings.resolved(for: notched)))
        settings.fullWidth = true
        XCTAssertTrue(WorkspaceBarManager.coversAppMenus(settings.resolved(for: notched)))
    }

    func testAFullWidthBarOverTheMenuBarStaysAboveNativeMenus() {
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasNotch: false,
            name: "Hidden menu bar"
        )
        let settings = WorkspaceBarSettings()
        settings.fullWidth = true
        let island = WorkspaceBarIslandPanel(
            panel: WorkspaceBarPanel.defaultPanel(),
            rootView: WorkspaceBarView(
                model: WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
                    projection: WorkspaceBarProjection(items: [], scratchpads: []),
                    backgroundOpacity: 0.1,
                    barHeight: 24
                )),
                motionPolicy: MotionPolicy(animationsEnabled: false)
            ),
            resolved: settings.resolved(for: monitor),
            monitor: monitor
        )
        defer { island.panel.close() }
        XCTAssertGreaterThan(island.panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
        settings.windowLevel = .floating
        island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
        XCTAssertEqual(island.panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        settings.windowLevel = .popup
        island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
        XCTAssertEqual(island.panel.level, .popUpMenu)
        settings.position = .bottom
        island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
        XCTAssertEqual(island.panel.level, .popUpMenu)

        settings.position = .overlappingMenuBar
        let resolved = settings.resolved(for: monitor)
        let frame = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            .frame(fittingLength: 0, monitor: monitor, resolved: resolved)
        XCTAssertEqual(frame, CGRect(x: 0, y: 958, width: 1512, height: 24))

        settings.windowLevel = .floating
        settings.fullWidth = false
        island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
        XCTAssertEqual(island.panel.level, .floating)

        settings.fullWidth = true
        for position in [WorkspaceBarPosition.belowMenuBar, .bottom, .left, .right] {
            settings.position = position
            island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
            XCTAssertEqual(island.panel.level, .floating, "\(position)")
        }

        settings.position = .overlappingMenuBar
        settings.fullWidthNotchMode = .moveBelowMenuBar
        let notched = Monitor(
            id: .init(displayId: 8),
            displayId: 8,
            frame: monitor.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            notchRange: 656 ... 856,
            name: "Notched"
        )
        island.applySettings(resolved: settings.resolved(for: notched), monitor: notched)
        XCTAssertEqual(island.panel.level, .floating)
        island.applySettings(resolved: settings.resolved(for: monitor), monitor: monitor)
        XCTAssertEqual(island.panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
    }
}
