// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ShellWidgetHost {
    private static let titleDemand = ShellDataKey.title.bit | ShellDataKey.bar.bit

    func publishDemand() {
        var demand: UInt64 = 0
        var readers: [(deps: UInt64, interval: Double?)] = []
        readers.reserveCapacity(widgets.count)
        for state in widgets.values {
            let deps = self.demand(of: state)
            demand |= deps
            readers.append((deps, interval(of: state)))
        }
        feed?.setDemand(demand, cadence: ShellDataFeed.Cadence.of(readers))
        publishTitleDemand(demand & Self.titleDemand != 0)
    }

    func interval(of state: WidgetState) -> Double? {
        config.widgetIntervals[state.name] ?? state.declaration.interval
    }

    func demand(of state: WidgetState) -> UInt64 {
        var deps: UInt64 = state.package == nil ? 0 : state.backgroundDemand
        var active = false
        for (key, instance) in state.instances
            where key.placement != .island || islandData[key]?.surface?.visible == true
        {
            active = true
            deps |= instance.deps | instance.popoutDeps
        }
        return active && state.package != nil && state.failures > 0 ? deps | state.failedDeps : deps
    }

    func publishTitleDemand(_ demands: Bool) {
        guard demands != demandsWindowTitles else { return }
        demandsWindowTitles = demands
        onTitleDemandChange(demands)
    }

    var dataDemand: UInt64 {
        widgets.values.reduce(0) { $0 | demand(of: $1) }
    }
}
