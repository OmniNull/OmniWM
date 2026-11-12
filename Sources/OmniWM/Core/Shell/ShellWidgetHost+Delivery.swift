// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    func slots(for monitor: Monitor.ID) -> [WorkspaceBarShellWidget] {
        placedSlots[monitor] ?? []
    }

    func surfaceView(widget name: String, key: ShellBarKey, scale: @autoclosure () -> CGFloat) -> NSView? {
        guard let state = widgets[name], let instance = state.instances[key] else { return nil }
        let scale = scale()
        if let surface = instance.surface, surface.scale == scale {
            return surface.view
        }
        if let previous = instance.surface { releaseShellFocus(from: previous, restore: true) }
        let surface = ShellWidgetSurface(scale: scale, resources: resources, directories: folders(of: state))
        surface.assetFolders = state.assetPackages
        surface.palette = palette(for: key)
        connectResourceDrop(surface, key: ShellTreeKey(bar: key, view: .bar), widget: name)
        connectResourceDrag(surface, key: ShellTreeKey(bar: key, view: .bar), widget: name)
        surface.drawsRootMaterial = key.placement == .island
        surface.onAction = { [weak self, weak state, weak surface] click in
            guard let self, let state else { return }
            perform(click, view: .bar, key: key, for: state, from: surface)
        }
        surface.onMove = { [weak self] in
            self?.popout?.refreshAnchor()
        }
        surface.onVisibleBoundsChange = { [weak self] in
            self?.layoutGeneration &+= 1
        }
        surface.onLayoutMenu = { [weak self, weak surface] anchor in
            guard let self, let surface else { return }
            onWidgetMenu?(ShellWidgetMenuRequest(
                widget: name,
                monitor: key.monitor,
                anchor: anchor,
                view: surface.view
            ))
        }
        connectMenu(surface, key: key, state: state)
        if key.placement == .bar {
            connectSurfaceFocus(surface) { [weak state, weak surface] in state?.instances[key]?.surface === surface }
        }
        if !instance.nodes.isEmpty {
            surface.sequence = instance.sequences[ShellWidgetView.bar.rawValue]
            surface.apply(instance.nodes, text: state.text)
        }
        instance.surface = surface
        return surface.view
    }

    func dropTargets(on monitor: Monitor.ID) -> [ShellDropTarget] {
        var targets: [ShellDropTarget] = []
        for state in widgets.values {
            for (key, instance) in state.instances where key.monitor == monitor {
                guard let surface = instance.surface, surface.visible else { continue }
                let visible = surface.visibleScreenFrame
                for frame in surface.targetFrames() {
                    targets.append(ShellDropTarget(
                        target: state.text.string(frame.target),
                        frame: frame.frame,
                        drop: frame.drop,
                        inIsland: key.placement == .island,
                        visible: visible
                    ))
                }
            }
        }
        return targets
    }

    func removeSurfaces(for monitor: Monitor.ID) {
        removeBarShaders(monitor: monitor)
        if popout?.key.placement == .bar { closePopout() }
        for state in widgets.values {
            for (key, instance) in state.instances where key.monitor == monitor && key.placement == .bar {
                if let surface = instance.surface { releaseShellFocus(from: surface, restore: true) }
                instance.surface = nil
            }
        }
    }

    func removeSurfaces(for monitor: Monitor.ID, island: WorkspaceBarIslandSlice) {
        removeBarShaders(monitor: monitor, island: island)
        for state in widgets.values {
            let instance = state.instances[ShellBarKey(monitor: monitor, island: island)]
            if let surface = instance?.surface { releaseShellFocus(from: surface, restore: true) }
            instance?.surface = nil
        }
    }

    func updateWorld() {
        feed?.setWorld(world())
    }

    func updateVars() {
        feed?.setVars(vars())
    }

    func updateBars() {
        guard !widgets.isEmpty else { return }
        let next = barData()
        guard next != bars else { return }
        bars = next
        syncBarPalettes()
        refreshIslandData()
        if let popout, popout.key.placement == .bar, headless == nil, next[popout.key] == nil {
            closePopout()
        }
        if let drawer, drawer.sections.contains(where: { next[$0.key] == nil && drawerKeys[$0.widget] != $0.key }) {
            closeDrawer()
        }
        for state in widgets.values {
            place(state)
        }
        publishDemand()
        refreshSlots()
    }

    func palette(for key: ShellBarKey) -> ShellPalette {
        palette(for: key, dark: darkBarKeys())
    }

    private func palette(for key: ShellBarKey, dark: Set<ShellBarKey>) -> ShellPalette {
        dark.contains(key) ? resources.darkPalette : resources.palette
    }

    private func darkBarKeys() -> Set<ShellBarKey> {
        var keys: Set<ShellBarKey> = []
        for (key, data) in bars where key.placement == .bar && data.style.solidBlack {
            keys.insert(key)
        }
        return keys
    }

    private func syncBarPalettes() {
        let dark = darkBarKeys()
        for state in widgets.values {
            for (key, instance) in state.instances {
                guard let surface = instance.surface else { continue }
                let palette = palette(for: key, dark: dark)
                guard surface.palette !== palette else { continue }
                surface.palette = palette
                instance.redraw(text: state.text)
            }
        }
    }

    @discardableResult
    func place(_ state: WidgetState) -> Bool {
        let placed = bars(for: state)
        let kept = state.instances.filter { placed[$0.key] != nil }
        let changed = kept.count != state.instances.count || kept.count != placed.count
        for (key, instance) in state.instances where kept[key] == nil {
            if let surface = instance.surface { releaseShellFocus(from: surface, restore: true) }
        }
        state.instances = kept
        for key in placed.keys where state.instances[key] == nil {
            state.instances[key] = InstanceState()
        }
        state.mailbox?.yield(.bars(placed))
        return changed
    }

    func bars(for state: WidgetState) -> [ShellBarKey: ShellBarData] {
        let lane = config.barLane(of: state.name) ?? (state.name == config.hiddenBarWidget ? .trailing : nil)
        var placed = lane.map { lane in
            bars.filter { key, _ in
                switch key.island {
                case .all: true
                case .active: state.declaration.spansIslands || lane != .trailing
                case .secondary: state.declaration.spansIslands || lane == .trailing
                }
            }
        } ?? [:]
        if let headless, headless.widget == state.name, placed[headless.key] == nil {
            placed[headless.key] = ShellBarData()
        }
        if let key = drawerKeys[state.name], placed[key] == nil {
            placed[key] = ShellBarData()
        }
        if state.name == config.island?.root {
            placed.merge(islandData) { _, island in island }
        }
        return placed
    }

    func receive(_ batch: [String: ShellWidgetDelivery]) {
        var layoutChanged = false
        var recovered = false
        for (name, delivery) in batch {
            guard let state = widgets[name] else { continue }
            receive(delivery, for: state, layoutChanged: &layoutChanged, recovered: &recovered)
        }
        publishDemand()
        if layoutChanged {
            refreshSlots()
            onLayoutChange()
        }
        if recovered {
            publishToggleNames()
        }
    }

    private func receive(
        _ delivery: ShellWidgetDelivery,
        for state: WidgetState,
        layoutChanged: inout Bool,
        recovered: inout Bool
    ) {
        if let package = [state.package, state.loadingPackage].compactMap({ $0 })
            .first(where: { $0.generation == delivery.generation })
        {
            deliverDesktop(delivery.desktopRequests, package: package)
            recordNetworkApprovals(delivery.networkApprovals)
            recordProviderApprovals(delivery.providerApprovals)
        }
        guard delivery.generation == state.generation else { return }
        let previousDemand = demand(of: state)
        defer {
            if widgets[state.name] === state, state.generation == delivery.generation, state.package != nil,
               delivery.failure == nil, demand(of: state) & ~previousDemand != 0
            {
                state.mailbox?.yield(.dataChanged)
            }
        }
        if let background = delivery.backgroundDemand { state.backgroundDemand = background }
        if tripsAfter(delivery, of: state) { return }
        if let failure = delivery.failure {
            report(state, failure)
        }
        runRequests(of: delivery, for: state)
        enqueueConfigurationRequests(delivery.configurationRequests, to: state)
        if delivery.reload {
            acknowledge(delivery, for: state)
            load(state)
            return
        }
        guard !delivery.trees.isEmpty else {
            acknowledge(delivery, for: state)
            return
        }
        resetIfStale(state, for: delivery)
        if delivery.failure == nil, clearFailure(state) {
            layoutChanged = true
            recovered = true
        }
        state.text.ingest(delivery.strings, count: delivery.stringCount)
        applyTrees(delivery, for: state, layoutChanged: &layoutChanged)
        acknowledge(delivery, for: state, excludingTrees: true)
    }

    private func applyTrees(
        _ delivery: ShellWidgetDelivery,
        for state: WidgetState,
        layoutChanged: inout Bool
    ) {
        for (key, tree) in delivery.trees {
            guard let bar = key.bar else { continue }
            ShellFrameTrace.$context.withValue(tree.trace) {
                ShellFrameTrace.shared.record(.applyStart)
                defer { ShellFrameTrace.shared.record(.applyEnd) }
                switch key.view {
                case .bar:
                    layoutGeneration &+= 1
                    if state.instances[bar]?.apply(
                        tree,
                        text: state.text,
                        gestureAcknowledgement: delivery.acknowledgements[key]?.invocationID ?? 0
                    ) == true, bars[bar] != nil {
                        layoutChanged = true
                    }
                case .window:
                    break
                case .popout:
                    applyPopout(
                        tree,
                        key: bar,
                        for: state,
                        gestureAcknowledgement: delivery.acknowledgements[key]?.invocationID ?? 0
                    )
                }
            }
        }
    }

    func interactionSurface(key: ShellTreeKey, for state: WidgetState) -> ShellWidgetSurface? {
        guard let bar = key.bar else { return nil }
        switch key.view {
        case .bar: return state.instances[bar]?.surface
        case .window: return nil
        case .popout:
            if let popout, popout.widget == state.name, popout.key == bar { return popout.surface }
            return drawer?.section(widget: state.name, key: bar)?.surface
        }
    }

    private func acknowledge(_ delivery: ShellWidgetDelivery, for state: WidgetState, excludingTrees: Bool = false) {
        for (key, acknowledgement) in delivery.acknowledgements where !excludingTrees || delivery.trees[key] == nil {
            interactionSurface(key: key, for: state)?.acknowledgeGesture(through: acknowledgement.invocationID)
        }
    }

    func cancelInput(for state: WidgetState) {
        for instance in state.instances.values { instance.surface?.cancelInput() }
        if popout?.widget == state.name { popout?.surface.cancelInput() }
        for section in drawer?.sections ?? [] where section.widget == state.name { section.surface.cancelInput() }
    }

    private func runRequests(of delivery: ShellWidgetDelivery, for state: WidgetState) {
        for request in delivery.requests {
            guard let action = ShellAction(request.text) else {
                report(state, ShellScriptFailure(
                    kind: .runtime,
                    message: "omniwm.run command is not an omniwmctl, shell or volume command"
                ))
                continue
            }
            run(
                action,
                origin: ShellCommandOrigin(
                    monitor: request.bar?.monitor ?? Monitor
                        .ID(displayId: NSScreen.main?.displayId ?? CGMainDisplayID()),
                    widget: state.name, command: request.text
                ),
                for: state
            )
        }
    }

    private func resetIfStale(_ state: WidgetState, for delivery: ShellWidgetDelivery) {
        guard delivery.generation != state.renderedGeneration || delivery.epoch != state.renderedEpoch else { return }
        state.renderedGeneration = delivery.generation
        state.renderedEpoch = delivery.epoch
        state.text = ShellTextStore()
        for instance in state.instances.values {
            instance.reset(text: state.text)
        }
        if popout?.widget == state.name {
            popout?.surface.reset(text: state.text)
        }
        drawer?.reset(widget: state.name, text: state.text)
    }

    private func applyPopout(
        _ tree: ShellWidgetDelivery.Tree,
        key: ShellBarKey,
        for state: WidgetState,
        gestureAcknowledgement: UInt64
    ) {
        let deps = tree.demand
        let applied: Bool
        if let popout, popout.widget == state.name, popout.key == key {
            state.instances[key]?.popoutDeps = deps
            popout.surface.sequence = tree.sequence
            applied = popout.apply(tree.nodes, text: state.text, gestureAcknowledgement: gestureAcknowledgement)
            if applied, popout.surface.naturalSize == .zero {
                closePopout()
                return
            }
        } else if let drawer, drawer.section(widget: state.name, key: key) != nil {
            state.instances[key]?.popoutDeps = deps
            drawer.section(widget: state.name, key: key)?.surface.sequence = tree.sequence
            applied = drawer.apply(
                widget: state.name,
                key: key,
                tree.nodes,
                text: state.text,
                gestureAcknowledgement: gestureAcknowledgement
            )
        } else {
            return
        }
        if applied {
            state.instances[key]?.sequences[ShellWidgetView.popout.rawValue] = tree.sequence
        }
    }

    func refreshSlots() {
        var placed: [Monitor.ID: [(rank: (lane: Int, rank: Int), widget: WorkspaceBarShellWidget)]] = [:]
        let priorities = config.priorityRanks()
        for state in widgets.values {
            let placement = config.lane(of: state.name)
            for (key, instance) in state.instances where bars[key] != nil {
                let failure = failure(of: state, at: instance)
                guard failure != nil || (instance.size.width > 0 && instance.size.height > 0) else { continue }
                placed[key.monitor, default: []].append((
                    rank: (ShellLane.allCases.firstIndex(of: placement.lane) ?? 0, placement.rank),
                    widget: WorkspaceBarShellWidget(
                        id: state.name,
                        size: instance.size,
                        lane: placement.lane,
                        island: key.island,
                        failure: failure,
                        priority: priorities[state.name] ?? .max
                    )
                ))
            }
        }
        placedSlots = placed.mapValues(Self.slotOrder)
    }

    private nonisolated static func slotOrder(
        _ entries: [(rank: (lane: Int, rank: Int), widget: WorkspaceBarShellWidget)]
    ) -> [WorkspaceBarShellWidget] {
        entries.indices.sorted {
            entries[$0].rank != entries[$1].rank
                ? entries[$0].rank < entries[$1].rank
                : entries[$0].widget.id < entries[$1].widget.id
        }.map { entries[$0].widget }
    }

    private func failure(of state: WidgetState, at instance: InstanceState) -> ShellWidgetFailure? {
        if let failure = state.lastFailure {
            return ShellWidgetFailure(message: failure.message, source: state.sourceURL)
        }
        if let fallback = state.fallback, let trip = trips[state.name] {
            return ShellWidgetFailure(
                message: "Using the built-in \(state.name): \(fallback.message)",
                source: trip.source
            )
        }
        guard let program = instance.surface?.failedShader, let message = program.failure else {
            return nil
        }
        return ShellWidgetFailure(message: message, source: program.url ?? state.sourceURL)
    }

    func report(_ state: WidgetState, _ failure: ShellScriptFailure) {
        guard state.lastFailure != failure else { return }
        state.lastFailure = failure
        Log.shell.error("Widget \(state.name): \(failure.message)")
        refreshSlots()
        onLayoutChange()
        publishToggleNames()
    }

    func clearFailure(_ state: WidgetState) -> Bool {
        guard state.lastFailure != nil else { return false }
        state.lastFailure = nil
        return true
    }

    private func tripsAfter(_ delivery: ShellWidgetDelivery, of state: WidgetState) -> Bool {
        if let failure = delivery.failure, delivery.trees.isEmpty {
            state.failedDeps = state.failures == 0 ? delivery.failedDeps : state.failedDeps | delivery.failedDeps
            state.failures += 1
            guard state.failures >= Self.failureLimit else { return false }
            trip(
                state,
                ShellScriptFailure(kind: failure.kind, message: "Stopped after repeated errors: \(failure.message)")
            )
            return true
        }
        if delivery.failure == nil, !delivery.trees.isEmpty {
            state.failures = 0
        }
        return false
    }

    func hasFallback(_ state: WidgetState) -> Bool {
        state.fallback == nil && config.builtInWidget(state.name, replacing: state.sourceURL) != nil
    }

    func trip(_ state: WidgetState, _ failure: ShellScriptFailure) {
        cancelInput(for: state)
        trips[state.name] = Trip(source: state.sourceURL, fingerprint: state.fingerprint, failure: failure)
        if popout?.widget == state.name {
            closePopout()
        }
        Self.retireTraceCapture(state.package)
        state.mailbox?.finish()
        state.mailbox = nil
        state.package = nil
        for instance in state.instances.values {
            instance.deps = 0
            instance.popoutDeps = 0
        }
        if hasFallback(state) {
            rescan()
            onLayoutChange()
        } else {
            report(state, failure)
        }
        publishDemand()
    }
}
