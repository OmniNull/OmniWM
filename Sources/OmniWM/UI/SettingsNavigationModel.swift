// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

struct SettingsRoute: Equatable, Hashable {
    var section: SettingsSection
    var tab: String?
    var anchor: String?
    var itemID: String?
}

@MainActor
@Observable
final class SettingsNavigationModel {
    private(set) var route = SettingsRoute(section: .general)
    private(set) var pendingRoute: SettingsRoute?
    private var pendingRuleDraft: AppRuleDraft?
    private(set) var hasPendingMonitorSetupPresentation = false
    let ruleEditorState = AppRulesEditorState()
    var searchText = ""

    var section: SettingsSection {
        get { route.section }
        set { request(SettingsRoute(section: newValue)) }
    }

    func request(_ destination: SettingsRoute) {
        guard route != destination else { return }
        if route.section == .appRules, ruleEditorState.isDirty {
            pendingRoute = destination
        } else {
            route = destination
            searchText = ""
        }
    }

    func discardAndNavigate() {
        guard let pendingRoute else { return }
        ruleEditorState.isDirty = false
        route = pendingRoute
        if let pendingRuleDraft {
            ruleEditorState.requestedDraft = pendingRuleDraft
        }
        pendingRuleDraft = nil
        self.pendingRoute = nil
        searchText = ""
    }

    func cancelNavigation() {
        if pendingRoute?.section == .monitors { hasPendingMonitorSetupPresentation = false }
        pendingRoute = nil
        pendingRuleDraft = nil
    }

    func selectTab(_ tab: String) {
        request(SettingsRoute(section: route.section, tab: tab))
    }

    func presentRuleDraft(_ draft: AppRuleDraft) {
        let destination = SettingsRoute(section: .appRules)
        if ruleEditorState.isDirty {
            pendingRoute = destination
            pendingRuleDraft = draft
        } else {
            request(destination)
            ruleEditorState.requestedDraft = draft
        }
    }

    func requestMonitorSetupPresentation() {
        request(SettingsRoute(section: .monitors))
        hasPendingMonitorSetupPresentation = true
    }

    func consumeMonitorSetupPresentationRequest() -> Bool {
        guard section == .monitors, hasPendingMonitorSetupPresentation else { return false }
        hasPendingMonitorSetupPresentation = false
        return true
    }
}
