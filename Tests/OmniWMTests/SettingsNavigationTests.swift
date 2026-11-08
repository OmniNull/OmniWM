// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testCancelingGuardedNavigationClearsLauncherDraft() {
        let navigation = SettingsNavigationModel()
        navigation.section = .styles
        navigation.leaveGuard = { _ in true }
        navigation.presentLauncherEntry(.init(entry: LauncherEntry()))
        XCTAssertEqual(navigation.section, .styles)
        navigation.cancelNavigation()
        XCTAssertNil(navigation.launcherEditorRequest)
        navigation.leaveGuard = nil
        navigation.section = .launcher
        XCTAssertNil(navigation.launcherEditorRequest)
    }

    func testEveryDestinationAppearsInExactlyOneSidebarGroup() {
        let destinations = SettingsSectionGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(Set(destinations), Set(SettingsSection.allCases))
        XCTAssertEqual(destinations.count, Set(destinations).count)
        XCTAssertEqual(SettingsSectionGroup.desktop.sections, [.styles, .menuBar, .network])
    }

    func testSearchFindsShellTasksAndIndividualControls() throws {
        XCTAssertTrue(SettingsSearchIndex.results(for: "custom bar").contains { $0.route.section == .styles })
        XCTAssertTrue(SettingsSearchIndex.results(for: "dynamic island").contains { $0.route.section == .styles })
        let border = try XCTUnwrap(SettingsSearchIndex.results(for: "Border Width")
            .first { $0.title == String(localized: "Border Width") })
        XCTAssertEqual(border.route, SettingsRoute(section: .appearance, tab: "borders", anchor: "Border Width"))
        let spacing = try XCTUnwrap(SettingsSearchIndex.results(for: "Inner Gaps").first { $0.route.tab == "spacing" })
        XCTAssertEqual(spacing.route.section, .layouts)
        XCTAssertEqual(spacing.route.anchor, "Inner Gaps")
        let edgeNavigation = try XCTUnwrap(SettingsSearchIndex.results(for: "Edge navigation interval")
            .first { $0.title == String(localized: "Edge navigation interval") })
        XCTAssertEqual(
            edgeNavigation.route,
            SettingsRoute(section: .mouseTrackpad, tab: "mouse", anchor: "Edge navigation interval")
        )
        XCTAssertTrue(SettingsSearchIndex.results(for: "zqvnomatch").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.results(for: "  ").isEmpty)
    }

    func testNetworkPermissionsSearchFindsThePageAndItsServices() throws {
        XCTAssertTrue(SettingsSearchIndex.results(for: "permissions").contains {
            $0.route == SettingsRoute(section: .network)
        })
        let lyrics = try XCTUnwrap(SettingsSearchIndex.results(for: "Lyrics")
            .first { $0.title == String(localized: "Lyrics") })
        XCTAssertEqual(lyrics.route, SettingsRoute(section: .network, anchor: NetworkPermissionsPage.servicesAnchor))
    }

    func testIslandSearchTargetsTheEditorSurfaceAndPreservesItsGroups() throws {
        for (title, anchor) in [
            ("Show Dynamic Island", "placement"), ("Island Widgets", nil), ("Component Regions", nil),
            ("Island Appearance", "appearance"), ("Island Interaction", "interaction"),
            ("Island Motion", "interaction")
        ] as [(String, String?)] {
            let result = try XCTUnwrap(SettingsSearchIndex.results(for: title).first { $0.title == title })
            XCTAssertEqual(result.route, SettingsRoute(section: .styles, tab: "island", anchor: anchor))
        }
        XCTAssertEqual(SettingsSearchIndex.tabTitle("island"), String(localized: "Dynamic Island"))
        for tab in ["lanes", "placement", "appearance", "behavior", "apps"] {
            XCTAssertTrue(SettingsSearchIndex.entries.contains { $0.route.section == .styles && $0.route.tab == tab })
        }
    }

    func testWidgetSearchCarriesItsConfiguredItemTarget() throws {
        for (query, item) in [
            ("Clock", "clock"),
            ("World Clock", "world-clock"),
            ("Weather", "weather"),
            ("Volume", "volume")
        ] {
            let result = try XCTUnwrap(SettingsSearchIndex.results(for: query)
                .first { $0.route.section == .styles && $0.route.itemID == item })
            XCTAssertEqual(result.route.itemID, item)
        }
        XCTAssertEqual(Set(SettingsSearchIndex.entries.map(\.id)).count, SettingsSearchIndex.entries.count)
        XCTAssertFalse(SettingsSearchIndex.results(for: "Clock").contains { $0.route.itemID == "weather" })
        XCTAssertEqual(
            SettingsSearchIndex.results(for: "Drawer").first { $0.title == "Drawer" }?.route,
            SettingsRoute(section: .styles, tab: "drawers")
        )
    }

    func testDirtyRuleBlocksNavigationAndCancelKeepsTheDraft() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        navigation.searchText = "widgets"
        let requested = SettingsRoute(section: .styles, itemID: "clock")
        navigation.request(requested)
        XCTAssertEqual(navigation.section, .appRules)
        XCTAssertEqual(navigation.pendingRoute, requested)
        XCTAssertTrue(navigation.ruleEditorState.isDirty)
        navigation.cancelNavigation()
        XCTAssertNil(navigation.pendingRoute)
        XCTAssertTrue(navigation.ruleEditorState.isDirty)
        XCTAssertEqual(navigation.searchText, "widgets")
    }

    func testDiscardNavigatesToTheExactRequestedControl() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        let requested = SettingsRoute(section: .layouts, tab: "niri", anchor: "Resize Increment")
        navigation.request(requested)
        navigation.discardAndNavigate()
        XCTAssertEqual(navigation.route, requested)
        XCTAssertFalse(navigation.ruleEditorState.isDirty)
        XCTAssertNil(navigation.pendingRoute)
    }

    func testRuleCreationWaitsForDiscardApproval() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        let draft = AppRuleDraft()
        navigation.presentRuleDraft(draft)
        XCTAssertNil(navigation.ruleEditorState.requestedDraft)
        navigation.cancelNavigation()
        XCTAssertNil(navigation.ruleEditorState.requestedDraft)
        XCTAssertTrue(navigation.ruleEditorState.isDirty)
        navigation.presentRuleDraft(draft)
        navigation.discardAndNavigate()
        XCTAssertEqual(navigation.ruleEditorState.requestedDraft?.id, draft.id)
        XCTAssertFalse(navigation.ruleEditorState.isDirty)
    }

    func testCanceledMonitorSetupDoesNotAppearOnALaterDisplayVisit() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        navigation.requestMonitorSetupPresentation()
        XCTAssertFalse(navigation.consumeMonitorSetupPresentationRequest())
        navigation.cancelNavigation()
        navigation.ruleEditorState.isDirty = false
        navigation.section = .monitors
        XCTAssertFalse(navigation.consumeMonitorSetupPresentationRequest())
    }

    func testEditorLeaveGuardInterceptsAnotherSectionAndAllowsLocalRoutes() {
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        var intercepted: [SettingsRoute?] = []
        navigation.leaveGuard = { route in
            intercepted.append(route)
            return true
        }
        let local = SettingsRoute(section: .styles, itemID: "clock")
        navigation.request(local)
        XCTAssertEqual(navigation.route, local)
        XCTAssertTrue(intercepted.isEmpty)
        navigation.searchText = "weather"
        let destination = SettingsRoute(section: .menuBar)
        navigation.request(destination)
        XCTAssertEqual(intercepted, [destination])
        XCTAssertEqual(navigation.route, local)
        XCTAssertEqual(navigation.searchText, "weather")
        navigation.proceed(to: destination)
        XCTAssertEqual(navigation.route, destination)
        XCTAssertEqual(intercepted, [destination])
        XCTAssertTrue(navigation.searchText.isEmpty)
    }

    func testProceedWithoutARouteClosesTheEditorWindow() {
        let navigation = SettingsNavigationModel()
        let initial = SettingsRoute(section: .styles, itemID: "clock")
        navigation.proceed(to: initial)
        var closed = 0
        navigation.closeWindow = { closed += 1 }
        navigation.proceed(to: nil)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(navigation.route, initial)
    }

    func testDismissingTheRuleDiscardPromptAfterMonitorNavigationKeepsSetupArmed() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        navigation.requestMonitorSetupPresentation()
        XCTAssertEqual(navigation.pendingRoute, SettingsRoute(section: .monitors))
        navigation.discardAndNavigate()
        XCTAssertEqual(navigation.section, .monitors)
        XCTAssertTrue(navigation.hasPendingMonitorSetupPresentation)
        navigation.cancelNavigation()
        XCTAssertTrue(navigation.hasPendingMonitorSetupPresentation)
        XCTAssertTrue(navigation.consumeMonitorSetupPresentationRequest())
        XCTAssertFalse(navigation.consumeMonitorSetupPresentationRequest())
    }

    func testReflectingTheEditorsSelectionKeepsSearchAndDoesNotInvokeTheLeaveGuard() {
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        navigation.searchText = "Clock"
        var guarded = false
        navigation.leaveGuard = { _ in
            guarded = true
            return true
        }
        let selected = SettingsRoute(section: .styles, itemID: "clock")
        navigation.reflect(selected)
        XCTAssertEqual(navigation.route, selected)
        XCTAssertEqual(navigation.searchText, "Clock")
        XCTAssertFalse(guarded)
    }

    func testReopeningUsesLastDestinationAndTab() {
        let navigation = SettingsNavigationModel()
        navigation.section = .layouts
        navigation.selectTab("dwindle")
        XCTAssertEqual(navigation.route, SettingsRoute(section: .layouts, tab: "dwindle"))
    }
}
