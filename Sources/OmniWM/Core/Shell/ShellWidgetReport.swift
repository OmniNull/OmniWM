// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ShellWidgetReport: Equatable {
    enum State: String {
        case loading, loaded, failed, fallback
    }

    struct Widget: Equatable {
        let name: String
        let source: String
        let state: State
        let error: String?
        let placements: [String]
    }

    static let empty = Self(profile: ShellDefaults.profile, widgets: [], problems: [])

    let profile: String
    let widgets: [Widget]
    let problems: [String]
}

extension ShellWidgetHost.WidgetState {
    var runtimeStatus: (state: ShellWidgetReport.State, error: String?) {
        let state: ShellWidgetReport.State = if lastFailure != nil {
            .failed
        } else if package == nil {
            .loading
        } else {
            fallback == nil ? .loaded : .fallback
        }
        return (state, (lastFailure ?? fallback)?.message)
    }
}

extension ShellWidgetHost {
    var widgetReport: ShellWidgetReport {
        publishedReport ?? .empty
    }

    private func makeWidgetReport() -> ShellWidgetReport {
        ShellWidgetReport(
            profile: config.profile,
            widgets: widgets.values.sorted { $0.name < $1.name }.map { state in
                let status = state.runtimeStatus
                return ShellWidgetReport.Widget(
                    name: state.name,
                    source: state.sourceURL.path,
                    state: status.state,
                    error: status.error,
                    placements: placements(of: state)
                )
            },
            problems: configProblems
        )
    }

    private func placements(of state: WidgetState) -> [String] {
        [
            config.barLane(of: state.name)?.rawValue,
            config.hiddenBarWidget == state.name ? "hidden bar" : nil,
            config.systemStatsWidget == state.name ? "system stats" : nil,
            config.island?.root == state.name ? "island" : nil
        ].compactMap(\.self) + config.drawers.filter { $0.widgets.contains(state.name) }.map { "drawer \($0.id)" }
    }

    func publishToggleNames(forceWidgetReport: Bool = false) {
        let names = toggleNames
        let namesChanged = names != publishedToggleNames
        let report = makeWidgetReport()
        let reportChanged = report != publishedReport
        if reportChanged { publishedReport = report }
        if namesChanged {
            publishedToggleNames = names
            onToggleNamesChange?()
        }
        if reportChanged || forceWidgetReport { onWidgetsChange?() }
    }
}
