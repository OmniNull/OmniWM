// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testEveryDestinationAppearsInExactlyOneSidebarGroup() {
        let destinations = SettingsSectionGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(Set(destinations), Set(SettingsSection.allCases))
        XCTAssertEqual(destinations.count, Set(destinations).count)
        XCTAssertEqual(SettingsSectionGroup.desktop.sections, [.styles, .bar, .island, .widgets, .menuBar])
    }

    func testSearchFindsShellTasksAndIndividualControls() throws {
        XCTAssertTrue(SettingsSearchIndex.results(for: "custom bar").contains { $0.route.section == .bar })
        XCTAssertTrue(SettingsSearchIndex.results(for: "dynamic island").contains { $0.route.section == .island })
        let border = try XCTUnwrap(SettingsSearchIndex.results(for: "Border Width")
            .first { $0.title == String(localized: "Border Width") })
        XCTAssertEqual(border.route, SettingsRoute(section: .appearance, tab: "borders", anchor: "Border Width"))
        let spacing = try XCTUnwrap(SettingsSearchIndex.results(for: "Inner Gaps").first { $0.route.tab == "spacing" })
        XCTAssertEqual(spacing.route.section, .layouts)
        XCTAssertEqual(spacing.route.anchor, "Inner Gaps")
        XCTAssertTrue(SettingsSearchIndex.results(for: "zqvnomatch").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.results(for: "  ").isEmpty)
    }

    func testWidgetSearchCarriesItsConfiguredItemTarget() throws {
        for (query, item) in [
            ("Clock", "clock"),
            ("World Clock", "world-clock"),
            ("Weather", "weather"),
            ("Volume", "volume")
        ] {
            let result = try XCTUnwrap(SettingsSearchIndex.results(for: query)
                .first { $0.route.section == .widgets && $0.route.itemID == item })
            XCTAssertEqual(result.route.itemID, item)
        }
        XCTAssertEqual(Set(SettingsSearchIndex.entries.map(\.id)).count, SettingsSearchIndex.entries.count)
        XCTAssertFalse(SettingsSearchIndex.results(for: "Clock").contains { $0.route.itemID == "weather" })
        XCTAssertEqual(
            SettingsSearchIndex.results(for: "Drawer").first { $0.title == "Drawer" }?.route.anchor,
            "Drawers"
        )
    }

    func testDirtyRuleBlocksNavigationAndCancelKeepsTheDraft() {
        let navigation = SettingsNavigationModel()
        navigation.section = .appRules
        navigation.ruleEditorState.isDirty = true
        navigation.searchText = "widgets"
        let requested = SettingsRoute(section: .widgets, itemID: "clock")
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

    func testReopeningUsesLastDestinationAndTab() {
        let navigation = SettingsNavigationModel()
        navigation.section = .layouts
        navigation.selectTab("dwindle")
        XCTAssertEqual(navigation.route, SettingsRoute(section: .layouts, tab: "dwindle"))
    }
}
