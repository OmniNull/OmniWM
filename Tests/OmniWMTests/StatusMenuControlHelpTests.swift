// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StatusMenuControlHelpTests: XCTestCase {
    func testControlCatalogHasExactlyTheUniqueSettingIdentifiers() {
        let identifiers = StatusMenuControl.allCases.map(\.id)
        let expectedIdentifiers: Set<String> = [
            "bordersEnabled",
            "workspaceBarEnabled",
            "preventSleepEnabled",
            "focusFollowsMouse",
            "focusCrossesMonitorAtEdge",
            "moveMouseToFocusedWindow",
            "focusFollowsWindowToMonitor",
            "moveCrossesMonitorAtEdge",
            "mouseWarpEnabled",
            "hiddenBarEnabled"
        ]

        XCTAssertEqual(Set(identifiers), expectedIdentifiers)
        XCTAssertEqual(identifiers.count, expectedIdentifiers.count)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testEveryControlHasCompleteDistinctHelpMetadata() {
        for control in StatusMenuControl.allCases {
            XCTAssertFalse(control.icon.isEmpty, "\(control.id) has no icon")
            XCTAssertFalse(control.label.isEmpty, "\(control.id) has no label")
            XCTAssertFalse(control.accessibilityName.isEmpty, "\(control.id) has no accessibility name")
            XCTAssertFalse(control.explanation.isEmpty, "\(control.id) has no explanation")
            XCTAssertNotEqual(control.explanation, control.label, "\(control.id) repeats its label as help")
        }
    }

    func testEveryControlHasTheExpectedPreview() {
        let expectedPreviews: [StatusMenuControl: StatusMenuControlPreview] = [
            .bordersEnabled: .focusedWindow,
            .workspaceBarEnabled: .workspaceBar,
            .preventSleepEnabled: .keepAwake,
            .focusFollowsMouse: .focusMouse,
            .focusCrossesMonitorAtEdge: .focusEdge,
            .moveMouseToFocusedWindow: .mouseToFocused,
            .focusFollowsWindowToMonitor: .followMonitor,
            .moveCrossesMonitorAtEdge: .moveEdge,
            .mouseWarpEnabled: .mouseWarp,
            .hiddenBarEnabled: .hiddenMenuIcons
        ]

        XCTAssertEqual(expectedPreviews.count, StatusMenuControl.allCases.count)
        for control in StatusMenuControl.allCases {
            XCTAssertEqual(control.preview, expectedPreviews[control], "\(control.id) has the wrong preview")
        }
    }

    func testRoutedPreviewPhaseCyclesDirectionsAtSuccessiveBoundaries() {
        let phases = (0 ... 4).map { cycle in
            StatusMenuControlPreviewPhase(
                timeInterval: Double(cycle) * StatusMenuControlPreviewPhase.cycleDuration
            )
        }

        XCTAssertEqual(phases.map(\.direction), [.right, .down, .left, .up, .right])
        XCTAssertTrue(phases.allSatisfy { $0.progress == 0 })
    }

    func testRoutedPreviewPhaseClampsProgressAndDefinesStaticEnd() {
        XCTAssertEqual(
            StatusMenuControlPreviewPhase(direction: .left, progress: -0.5),
            StatusMenuControlPreviewPhase(direction: .left, progress: 0)
        )
        XCTAssertEqual(
            StatusMenuControlPreviewPhase(direction: .up, progress: 1.5),
            StatusMenuControlPreviewPhase(direction: .up, progress: 1)
        )
        XCTAssertEqual(
            StatusMenuControlPreviewPhase.staticEnd,
            StatusMenuControlPreviewPhase(direction: .right, progress: 1)
        )
    }

    func testRoutedGeometryOwnsFourContainedWindowsPerDisplay() {
        for direction in StatusMenuControlPreviewDirection.allCases {
            let geometry = StatusMenuControlRoutedGeometry(direction: direction)

            XCTAssertEqual(geometry.sourceWindows.count, 4, "\(direction) source window count")
            XCTAssertEqual(geometry.destinationWindows.count, 4, "\(direction) destination window count")
            for window in geometry.sourceWindows {
                XCTAssertTrue(geometry.sourceDisplay.contains(window), "\(direction) source window escapes its display")
            }
            for window in geometry.destinationWindows {
                XCTAssertTrue(
                    geometry.destinationDisplay.contains(window),
                    "\(direction) destination window escapes its display"
                )
            }
        }
    }

    func testRoutedGeometryOrientsDisplaysAndArrowForEveryDirection() {
        for direction in StatusMenuControlPreviewDirection.allCases {
            let geometry = StatusMenuControlRoutedGeometry(direction: direction)

            switch direction {
            case .right:
                XCTAssertLessThan(geometry.sourceDisplay.maxX, geometry.destinationDisplay.minX)
                XCTAssertLessThan(geometry.arrowStart.x, geometry.arrowEnd.x)
                XCTAssertEqual(geometry.arrowStart.y, geometry.arrowEnd.y)
            case .down:
                XCTAssertLessThan(geometry.sourceDisplay.maxY, geometry.destinationDisplay.minY)
                XCTAssertLessThan(geometry.arrowStart.y, geometry.arrowEnd.y)
                XCTAssertEqual(geometry.arrowStart.x, geometry.arrowEnd.x)
            case .left:
                XCTAssertGreaterThan(geometry.sourceDisplay.minX, geometry.destinationDisplay.maxX)
                XCTAssertGreaterThan(geometry.arrowStart.x, geometry.arrowEnd.x)
                XCTAssertEqual(geometry.arrowStart.y, geometry.arrowEnd.y)
            case .up:
                XCTAssertGreaterThan(geometry.sourceDisplay.minY, geometry.destinationDisplay.maxY)
                XCTAssertGreaterThan(geometry.arrowStart.y, geometry.arrowEnd.y)
                XCTAssertEqual(geometry.arrowStart.x, geometry.arrowEnd.x)
            }
        }
    }

    func testDirectionalEdgeExplanationsExplicitlyCoverEveryDirection() {
        for control in [StatusMenuControl.focusCrossesMonitorAtEdge, .moveCrossesMonitorAtEdge] {
            let words = Set(
                control.explanation
                    .lowercased()
                    .components(separatedBy: CharacterSet.letters.inverted)
                    .filter { !$0.isEmpty }
            )

            for direction in ["left", "right", "up", "down"] {
                XCTAssertTrue(words.contains(direction), "\(control.id) omits \(direction)")
            }
        }
    }

    func testFocusFollowsMouseHelpPointsToRaiseBehaviorInSettings() {
        let explanation = StatusMenuControl.focusFollowsMouse.explanation

        XCTAssertTrue(explanation.contains("raises"))
        XCTAssertTrue(explanation.contains("Settings"))
    }

    func testHoveredControlIsPresentedOnlyAfterDwellCompletes() {
        var selection = StatusMenuHelpSelection()

        selection.hoverEntered(.focusFollowsMouse)

        XCTAssertEqual(selection.hoveredControl, .focusFollowsMouse)
        XCTAssertNil(selection.presentedControl)
        XCTAssertTrue(selection.presentHovered(.focusFollowsMouse))
        XCTAssertEqual(selection.presentedControl, .focusFollowsMouse)
    }

    func testStaleHoverExitCannotClearANewerHover() {
        var selection = StatusMenuHelpSelection()
        selection.hoverEntered(.focusFollowsMouse)
        selection.hoverEntered(.mouseWarpEnabled)
        XCTAssertTrue(selection.presentHovered(.mouseWarpEnabled))

        XCTAssertFalse(selection.hoverExited(.focusFollowsMouse))
        XCTAssertEqual(selection.hoveredControl, .mouseWarpEnabled)
        XCTAssertEqual(selection.presentedControl, .mouseWarpEnabled)
    }

    func testHoverTakesPrecedenceAndFocusBecomesFallbackAfterSettle() {
        var selection = StatusMenuHelpSelection()
        selection.focusChanged(.bordersEnabled, isFocused: true)
        selection.hoverEntered(.workspaceBarEnabled)
        XCTAssertTrue(selection.presentHovered(.workspaceBarEnabled))

        selection.focusChanged(.preventSleepEnabled, isFocused: true)

        XCTAssertEqual(selection.focusedControl, .preventSleepEnabled)
        XCTAssertEqual(selection.presentedControl, .workspaceBarEnabled)
        XCTAssertTrue(selection.hoverExited(.workspaceBarEnabled))
        XCTAssertEqual(selection.presentedControl, .workspaceBarEnabled)

        selection.settleAfterHoverExit()

        XCTAssertEqual(selection.presentedControl, .preventSleepEnabled)
    }

    func testFocusAlonePresentsImmediately() {
        var selection = StatusMenuHelpSelection()

        selection.focusChanged(.moveCrossesMonitorAtEdge, isFocused: true)

        XCTAssertEqual(selection.focusedControl, .moveCrossesMonitorAtEdge)
        XCTAssertEqual(selection.presentedControl, .moveCrossesMonitorAtEdge)
    }

    func testResetClearsHoverFocusAndPresentation() {
        var selection = StatusMenuHelpSelection()
        selection.focusChanged(.bordersEnabled, isFocused: true)
        selection.hoverEntered(.mouseWarpEnabled)
        XCTAssertTrue(selection.presentHovered(.mouseWarpEnabled))

        selection.reset()

        XCTAssertNil(selection.hoveredControl)
        XCTAssertNil(selection.focusedControl)
        XCTAssertNil(selection.presentedControl)
    }

    func testPresentationSchedulesExactHoverDwellBeforePresenting() async throws {
        let sleeper = ManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }

        presentation.hoverChanged(.focusFollowsMouse, isHovered: true)
        let dwell = try XCTUnwrap(presentation.transitionTask)

        XCTAssertEqual(presentation.selection.hoveredControl, .focusFollowsMouse)
        XCTAssertNil(presentation.selection.presentedControl)

        await sleeper.waitForPendingSleeps(1)

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertNil(presentation.selection.presentedControl)

        sleeper.resumeNext()
        await dwell.value

        XCTAssertEqual(presentation.selection.presentedControl, .focusFollowsMouse)
    }

    func testPresentationCancelsFirstDwellDuringRapidHover() async throws {
        let sleeper = ManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }

        presentation.hoverChanged(.focusFollowsMouse, isHovered: true)
        let firstDwell = try XCTUnwrap(presentation.transitionTask)
        await sleeper.waitForPendingSleeps(1)
        presentation.hoverChanged(.mouseWarpEnabled, isHovered: true)
        let secondDwell = try XCTUnwrap(presentation.transitionTask)
        await firstDwell.value
        await sleeper.waitForPendingSleeps(1)

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300), .milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(presentation.selection.hoveredControl, .mouseWarpEnabled)
        XCTAssertNil(presentation.selection.presentedControl)

        sleeper.resumeNext()
        await secondDwell.value

        XCTAssertEqual(presentation.selection.presentedControl, .mouseWarpEnabled)
    }

    func testPresentationKeepsHoveredHelpThroughExactExitGrace() async throws {
        let sleeper = ManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }
        presentation.focusChanged(.bordersEnabled, isFocused: true)
        presentation.hoverChanged(.workspaceBarEnabled, isHovered: true)
        let dwell = try XCTUnwrap(presentation.transitionTask)
        await sleeper.waitForPendingSleeps(1)
        sleeper.resumeNext()
        await dwell.value

        presentation.hoverChanged(.workspaceBarEnabled, isHovered: false)
        let exitGrace = try XCTUnwrap(presentation.transitionTask)

        XCTAssertNil(presentation.selection.hoveredControl)
        XCTAssertEqual(presentation.selection.presentedControl, .workspaceBarEnabled)

        await sleeper.waitForPendingSleeps(1)

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300), .milliseconds(150)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(presentation.selection.presentedControl, .workspaceBarEnabled)

        sleeper.resumeNext()
        await exitGrace.value

        XCTAssertEqual(presentation.selection.presentedControl, .bordersEnabled)
    }

    func testPresentationResetCancelsPendingTransition() async throws {
        let sleeper = ManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }
        presentation.hoverChanged(.moveCrossesMonitorAtEdge, isHovered: true)
        let dwell = try XCTUnwrap(presentation.transitionTask)
        await sleeper.waitForPendingSleeps(1)

        presentation.reset()
        await dwell.value

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertNil(presentation.selection.hoveredControl)
        XCTAssertNil(presentation.selection.focusedControl)
        XCTAssertNil(presentation.selection.presentedControl)
    }

    func testMenuPresentationGenerationAdvancesOnOpenAndClose() {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 0)

        fixture.model.menuWillOpen()

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)

        fixture.model.menuDidClose()

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 2)
    }

    func testHiddenBarTileInclusionMatchesControllerAvailability() {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let hiddenBarTiles = fixture.model.toggleTiles.filter { $0.control == .hiddenBarEnabled }

        XCTAssertEqual(hiddenBarTiles.count, fixture.controller.isHiddenBarHidingAvailable ? 1 : 0)
    }

    func testHiddenBarTileReadsAndWritesTheActiveProfileEnabledValue() async throws {
        let fixture = makeStatusMenuModelFixture(hiddenBarAvailable: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.model.settings
        let directory = ShellWidgetHost.shellDirectory(in: settings.settingsFileURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("look"),
            withIntermediateDirectories: true
        )
        try Data("profile = 'look'\n[profiles.look.hiddenBar]\nenabled = false\n".utf8)
            .write(to: directory.appendingPathComponent("shell.toml"))
        settings.hiddenBar.enabled = true
        settings.hiddenBar.profileOverride = ShellConfig.resolve(shellDirectory: directory).hiddenBarOverride
        fixture.model.infoAlertPresenter = { _, message in XCTFail(message) }
        let tile = try XCTUnwrap(fixture.model.toggleTiles.first { $0.control == .hiddenBarEnabled })
        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
        let applySavedConfiguration = configuration.onSave
        defer { configuration.onSave = applySavedConfiguration }
        let enabledSaved = expectation(description: "HiddenBar enabled value persisted")
        configuration.onSave = { config in
            applySavedConfiguration?(config)
            enabledSaved.fulfill()
        }

        XCTAssertFalse(tile.isOn.wrappedValue)
        tile.isOn.wrappedValue = true
        await fulfillment(of: [enabledSaved], timeout: 1)
        await configuration.flush()

        XCTAssertTrue(tile.isOn.wrappedValue)
        XCTAssertEqual(ShellConfig.load(shellDirectory: directory)?.hiddenBarOverride?.enabled, true)

        let disabledSaved = expectation(description: "HiddenBar disabled value persisted")
        configuration.onSave = { config in
            applySavedConfiguration?(config)
            disabledSaved.fulfill()
        }
        tile.isOn.wrappedValue = false
        await fulfillment(of: [disabledSaved], timeout: 1)
        await configuration.flush()

        XCTAssertFalse(tile.isOn.wrappedValue)
        XCTAssertTrue(settings.hiddenBar.enabled)
        XCTAssertEqual(ShellConfig.load(shellDirectory: directory)?.hiddenBarOverride?.enabled, false)
    }

    func testHiddenBarTileSurfacesUnreadableProfileWithoutChangingEnabledValue() async throws {
        let fixture = makeStatusMenuModelFixture(hiddenBarAvailable: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.model.settings
        let directory = ShellWidgetHost.shellDirectory(in: settings.settingsFileURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = Data("trailing = [".utf8)
        let url = directory.appendingPathComponent("shell.toml")
        try invalid.write(to: url)
        settings.hiddenBar.enabled = false
        var messages: [(String, String)] = []
        let errorPresented = expectation(description: "Unreadable HiddenBar profile error presented")
        fixture.model.infoAlertPresenter = { title, message in
            messages.append((title, message))
            errorPresented.fulfill()
        }
        let tile = try XCTUnwrap(fixture.model.toggleTiles.first { $0.control == .hiddenBarEnabled })

        tile.isOn.wrappedValue = true
        await fulfillment(of: [errorPresented], timeout: 1)
        await fixture.controller.workspaceBarManager.shellConfiguration.flush()

        XCTAssertFalse(tile.isOn.wrappedValue)
        XCTAssertFalse(settings.hiddenBar.enabled)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.0, String(localized: "Unable to Save Shell Settings"))
        XCTAssertFalse(try XCTUnwrap(messages.first?.1).isEmpty)
    }

    func testFocusFollowsMouseTileDoesNotChangeRaisePreference() throws {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.settings.focus.raiseOnMouseFocus = true
        let tile = try XCTUnwrap(fixture.model.toggleTiles.first { $0.control == .focusFollowsMouse })

        tile.isOn.wrappedValue = true
        tile.isOn.wrappedValue = false

        XCTAssertTrue(fixture.model.settings.focus.raiseOnMouseFocus)
    }

    private struct StatusMenuModelFixture {
        let root: URL
        let controller: WMController
        let model: StatusMenuModel
    }

    private func makeStatusMenuModelFixture(hiddenBarAvailable: Bool = false) -> StatusMenuModelFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMStatusMenuHelpTests-\(UUID().uuidString)", isDirectory: true)
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
        let controller = WMController(
            settings: settings,
            hiddenBarController: HiddenBarController(settings: settings, hider: NativeMenuBarHider(
                preferences: hiddenBarAvailable ? NativeMenuBarPreferences(read: {
                    try PropertyListSerialization.data(fromPropertyList: [[String: Any]](), format: .binary, options: 0)
                }, write: { _ in XCTFail("The status-menu settings must not change native preferences") }) : nil
            )),
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard", isDirectory: true),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        controller.workspaceBarManager.setup(controller: controller, settings: settings)
        return StatusMenuModelFixture(
            root: root,
            controller: controller,
            model: StatusMenuModel(settings: settings, controller: controller)
        )
    }
}
