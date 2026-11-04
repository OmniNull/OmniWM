// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class HostedWindowBarLifetimeTests: XCTestCase {
    @MainActor
    private struct HostedOwners {
        let instance: HostedManagementInstance
        let package: ShellWidgetPackage
        let surface: ShellWidgetSurface
        let input: ShellTextInput

        init(_ instance: HostedManagementInstance) throws {
            self.instance = instance
            package = instance.session.package
            surface = instance.session.surface
            input = try XCTUnwrap(surface.textInputs.values.first)
        }
    }

    @MainActor
    private final class BarFixture {
        let directory: URL
        let host: ShellWidgetHost
        let feed: ShellDataFeed
        let name = "lifetime-probe"
        let key: ShellBarKey
        let initial: ShellConfig
        let replacement: ShellConfig
        var onDelivery: (@MainActor @Sendable () -> Void)?

        init(monitor: Monitor.ID) throws {
            let key = ShellBarKey(monitor: monitor)
            self.key = key
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let shell = directory.appendingPathComponent("shell")
            let profiles = ["before-reload", "after-reload"]
            var configurations: [ShellConfig] = []
            for profile in profiles {
                let folder = shell.appendingPathComponent(profile)
                let widget = folder.appendingPathComponent("widgets/\(name)")
                try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
                let source = "function render(ctx) return ui.text{text='\(profile)'} end"
                try Data(source.utf8).write(to: widget.appendingPathComponent("init.luau"))
                var config = ShellConfig()
                config.profile = profile
                config.directories = [folder]
                config.leading = [name]
                configurations.append(config)
            }
            initial = configurations[0]
            replacement = configurations[1]
            let host = ShellWidgetHost(
                configDirectory: directory,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
                world: { ShellWorldData() }, vars: { [:] },
                bars: { [key: ShellBarData()] },
                onLayoutChange: {}, onCommand: { _, _ in }, onMenu: { _ in },
                onPreview: { _ in }, onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
            )
            self.host = host
            feed = ShellDataFeed(deliver: { [weak host] data in host?.broadcast(data) })
            host.feed = feed
            host.config = initial
            host.outbox = ShellWidgetOutbox { [weak self] batch in
                guard let self else { return }
                self.host.receive(batch)
                onDelivery?()
            }
            host.started = true
        }

        func dispose() {
            host.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testBarConfigurationReloadAndStopPreserveHostedOwnersAndInput() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let instances = [try fixture.open(), try fixture.open()]
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let initialText = ["First app before bar reload", "Second app before bar reload"]
        for (instance, value) in zip(instances, initialText) {
            try await applyHosted(value, to: instance.session)
        }
        let owners = try instances.map(HostedOwners.init)
        let bar = try BarFixture(monitor: fixture.sourceMonitor.id)
        defer { bar.dispose() }
        let manager = fixture.controller.workspaceBarManager
        manager.shellHost = bar.host
        defer { manager.shellHost = nil }
        let oldPackage = try await loadedPackage(
            in: bar, configuration: bar.initial,
            after: { bar.host.rescan(reloadConfiguration: false) }
        )
        XCTAssertNil(bar.host.observation)
        XCTAssertFalse(bar.feed.started)
        var configurations: [ShellConfig] = []
        bar.host.onConfigChange = { configurations.append($0) }
        var retiredReload: Task<Void, Never>?
        let reloaded = try await loadedPackage(in: bar, configuration: bar.replacement, after: {
            manager.shellConfigurationSaved(bar.replacement)
            retiredReload = ShellWidgetHost.retiringTasks[ObjectIdentifier(oldPackage)]
        })
        XCTAssertTrue(manager.shellHost === bar.host)
        XCTAssertEqual(configurations, [bar.replacement])
        XCTAssertEqual(bar.host.config, bar.replacement)
        XCTAssertFalse(reloaded === oldPackage)
        await (try XCTUnwrap(retiredReload)).value
        XCTAssertNil(ShellWidgetHost.retiringTasks[ObjectIdentifier(oldPackage)])
        XCTAssertNil(bar.host.observation)
        XCTAssertFalse(bar.feed.started)
        assertRetained(owners, values: initialText, in: fixture)
        let afterReload = ["First app after bar reload", "Second app after bar reload"]
        for (instance, value) in zip(instances, afterReload) {
            try await applyHosted(value, to: instance.session)
        }
        assertRetained(owners, values: afterReload, in: fixture)

        manager.stopShellHost()

        XCTAssertNil(manager.shellHost)
        XCTAssertFalse(bar.host.started)
        XCTAssertTrue(bar.host.widgets.isEmpty)
        let retiredStop = try XCTUnwrap(ShellWidgetHost.retiringTasks[ObjectIdentifier(reloaded)])
        await retiredStop.value
        XCTAssertNil(ShellWidgetHost.retiringTasks[ObjectIdentifier(reloaded)])
        XCTAssertNil(bar.host.observation)
        XCTAssertFalse(bar.feed.started)
        assertRetained(owners, values: afterReload, in: fixture)
        let afterStop = ["First app after bar stop", "Second app after bar stop"]
        for (instance, value) in zip(instances, afterStop) {
            try await applyHosted(value, to: instance.session)
        }
        assertRetained(owners, values: afterStop, in: fixture)
        fixture.close()
        for owner in owners {
            if let retirement = ShellWidgetHost.retiringTasks[ObjectIdentifier(owner.package)] {
                await retirement.value
            }
        }
    }

    private func loadedPackage(
        in bar: BarFixture, configuration: ShellConfig, after action: () -> Void
    ) async throws -> ShellWidgetPackage {
        let source = try XCTUnwrap(configuration.widget(bar.name))
        let loaded = expectation(description: "Declared bar tree is applied or reports failure")
        let loadFailureDeadline: TimeInterval = 10
        let completeIfReady: @MainActor @Sendable () -> Void = { [weak bar] in
            guard let bar, let state = bar.host.widgets[bar.name], state.sourceURL == source,
                  state.lastFailure != nil
                  || (state.renderedGeneration == state.package?.generation
                      && state.instances[bar.key]?.nodes.isEmpty == false) else { return }
            bar.host.onWidgetsChange = nil
            bar.onDelivery = nil
            XCTAssertNil(state.lastFailure)
            loaded.fulfill()
        }
        bar.host.onWidgetsChange = completeIfReady
        bar.onDelivery = completeIfReady
        action()
        await fulfillment(of: [loaded], timeout: loadFailureDeadline)
        bar.host.onWidgetsChange = nil
        bar.onDelivery = nil
        let state = try XCTUnwrap(bar.host.widgets[bar.name])
        XCTAssertEqual(state.sourceURL, source)
        XCTAssertNil(state.lastFailure)
        let package = try XCTUnwrap(state.package)
        XCTAssertEqual(state.renderedGeneration, package.generation)
        let instance = try XCTUnwrap(state.instances[bar.key])
        XCTAssertFalse(instance.nodes.isEmpty)
        let layout = try XCTUnwrap(instance.unmountedLayout)
        let captions = layout.core.elements { $0.text != 0 }.map { handle in
            state.text.string(layout.core.content(of: handle).text)
        }
        XCTAssertEqual(captions, [configuration.profile])
        return package
    }

    private func assertRetained(
        _ owners: [HostedOwners], values: [String], in fixture: HostedManagementFixture
    ) {
        XCTAssertEqual(owners.count, values.count)
        for (owner, value) in zip(owners, values) {
            let instance = owner.instance
            XCTAssertTrue(fixture.manager.windows[instance.token] === instance.window)
            XCTAssertTrue(fixture.manager.runtime(for: instance.token) === instance.session)
            XCTAssertTrue(instance.session.package === owner.package)
            XCTAssertTrue(instance.session.surface === owner.surface)
            XCTAssertTrue(owner.surface.textInputs[owner.input.handle] === owner.input)
            XCTAssertFalse(instance.session.closed)
            XCTAssertNotNil(fixture.world.entry(for: instance.token))
            assertHostedContent(value, in: instance.session)
        }
    }
}
