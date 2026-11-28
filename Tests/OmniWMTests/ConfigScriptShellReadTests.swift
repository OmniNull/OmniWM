// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptShellReadTests: XCTestCase {
    func testDiskReloadPublishesProblemOnlyChangesBeforeReturning() throws {
        let fixture = try scene()
        let host = makeHost(in: fixture.controller.settings.settingsFileURL.deletingLastPathComponent())
        let config = host.shellDirectory.appendingPathComponent("shell.luau")
        try FileManager.default.createDirectory(at: host.shellDirectory, withIntermediateDirectories: true)
        let valid = "return {}"
        try Data(valid.utf8).write(to: config)
        host.reloadConfig()
        let initial = host.config
        var reports: [[String]] = []
        host.onWidgetsChange = { [weak host] in
            if let host { reports.append(host.widgetReport.problems) }
        }

        let unknown = "unknownField"
        try Data("return { \(unknown) = true }".utf8).write(to: config)
        host.reloadConfig()
        XCTAssertEqual(host.config, initial)
        XCTAssertEqual(reports, [["shell.luau has unknown key \(unknown)"]])

        try Data("return {".utf8).write(to: config)
        host.reloadConfig()
        XCTAssertEqual(host.config, initial)
        let rejected = try XCTUnwrap(reports.last)
        XCTAssertTrue(try XCTUnwrap(rejected.first).hasPrefix("shell/\(config.lastPathComponent): "))
        XCTAssertEqual(reports.count, 2)
        host.reloadConfig()
        XCTAssertEqual(reports.count, 2)

        try Data(valid.utf8).write(to: config)
        host.reloadConfig()
        XCTAssertEqual(reports, [["shell.luau has unknown key \(unknown)"], rejected, []])
    }

    func testFlexAndCLIReadTheSamePublishedReport() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        let host = makeHost(in: fixture.controller.settings.settingsFileURL.deletingLastPathComponent())
        controller.workspaceBarManager.shellHost = host
        let profile = "fixture-shell-profile"
        let problem = "Configuration warning"
        let widgetRows = seedWidgets(on: host)
        host.config.profile = profile
        host.applyConfig(host.config, problems: [problem])

        let reads: ConfigScriptReads = [.shell, .workspaces]
        let cli = IPCQueryRouter(controller: controller, sessionToken: "").shellWidgetsResult()
        XCTAssertEqual(cli, IPCShellWidgetsQueryResult(profile: profile, widgets: widgetRows, problems: [problem]))
        host.config.profile = "unpublished-profile"
        host.configProblems = []
        host.widgets.removeAll()
        let snapshot = capture(reads, from: controller)
        XCTAssertEqual(IPCQueryRouter(controller: controller, sessionToken: "").shellWidgetsResult(), cli)
        try await assertScript(
            """
            local expected = { \(cli.widgets.map(luaWidget).joined(separator: ",\n")) }
            omniwm.on('config.reloaded', function(ctx)
                local report = assert(ctx.shell)
                assert(report.profile == \(String(reflecting: cli.profile)))
                assert(table.isfrozen(report) and table.isfrozen(report.widgets) and table.isfrozen(report.problems))
                assert(#report.problems == 1 and report.problems[1] == \(String(reflecting: problem)))
                assert(#report.widgets == #expected)
                for i, widget in report.widgets do
                    local row = expected[i]
                    assert(table.isfrozen(widget) and table.isfrozen(widget.placements))
                    assert(widget.name == row.name and widget.source == row.source)
                    assert(widget.state == row.state and widget.error == row.error)
                    assert(#widget.placements == #row.placements)
                    for j, placement in widget.placements do assert(placement == row.placements[j]) end
                end
                assert(ctx.truncated.shell == false and ctx.truncated.workspaces == nil)
                assert(ctx.workspaces == nil)
            end, { reads = { 'shell' } })
            omniwm.on('config.reloaded', function(ctx)
                assert(ctx.shell == nil and ctx.truncated.shell == nil)
                assert(ctx.workspaces and ctx.truncated.workspaces == false)
            end, { reads = { 'workspaces' } })
            """, expecting: reads, snapshot: snapshot
        )
    }

    func testShellReportDefaultAndTruncation() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        let missing = capture(.shell, from: controller)
        let host = makeHost(in: fixture.controller.settings.settingsFileURL.deletingLastPathComponent())
        controller.workspaceBarManager.shellHost = host
        let retained = "Retained configuration problem"
        let oversized = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit)
        host.applyConfig(host.config, problems: [retained, oversized])
        let byteClipped = capture([.shell, .workspaces], from: controller)
        let problems = (0 ..< ConfigScriptSnapshot.rowLimit).map { "Problem \($0)" }
        host.applyConfig(host.config, problems: problems)
        let rowClipped = capture([.shell, .workspaces], from: controller)
        try await assertScript(
            """
            omniwm.on('config.reloaded', function(ctx)
                local report = assert(ctx.shell)
                assert(report.profile == \(String(reflecting: ShellDefaults.profile)))
                assert(#report.widgets == 0 and #report.problems == 0 and ctx.truncated.shell == false)
            end, { reads = { 'shell' } })
            """, expecting: .shell, snapshot: missing
        )
        try await assertClippedShell(byteClipped, problems: [retained])
        try await assertClippedShell(rowClipped, problems: Array(problems.dropLast()))
    }

    private func seedWidgets(on host: ShellWidgetHost) -> [IPCShellWidget] {
        let fixtures: [(String, ShellWidgetReport.State, ShellLane?)] = [
            ("pending", .loading, nil), ("broken", .failed, .leading),
            ("rescued", .fallback, .center), ("ready", .loaded, .trailing)
        ]
        let outbox = ShellWidgetOutbox { _ in }
        let failure = ShellScriptFailure(kind: .compile, message: "Cannot compile widget\nSee source")
        return fixtures.enumerated().map { index, fixture in
            let (name, state, lane) = fixture
            let url = host.widgetsDirectory.appendingPathComponent("\(name)/init.luau")
            let widget = ShellWidgetHost.WidgetState(name: name, sourceURL: url)
            if state == .loaded || state == .fallback {
                widget.package = ShellWidgetPackage(name: name, generation: index, outbox: outbox)
            }
            if state == .failed { widget.lastFailure = failure }
            if state == .fallback { widget.fallback = failure }
            if lane == .leading { host.config.leading.append(name) }
            if lane == .center { host.config.center.append(name) }
            if lane == .trailing { host.config.trailing.append(name) }
            host.widgets[name] = widget
            return IPCShellWidget(
                name: name, source: url.path, state: state.rawValue,
                error: state == .failed || state == .fallback ? failure.message : nil,
                placements: lane.map { [$0.rawValue] } ?? []
            )
        }.sorted { $0.name < $1.name }
    }

    private func scene() throws -> NiriGatherFixture {
        let monitor = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
        return try NiriGatherFixture(
            prefix: "config-shell-read", monitors: [monitor], workspaces: [.init(name: "1", monitor: monitor)]
        )
    }

    private func makeHost(in directory: URL) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: directory, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("shell-resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {}, onCommand: { _, _ in },
            onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
    }

    private func capture(_ reads: ConfigScriptReads, from controller: WMController) -> ConfigScriptSnapshot {
        var pool = ConfigScriptSnapshotPool()
        return controller.configScriptSnapshot(reads: reads, target: controller.configScriptTarget(), pool: &pool)
    }

    private func luaWidget(_ widget: IPCShellWidget) -> String {
        """
        { name = \(String(reflecting: widget.name)), source = \(String(reflecting: widget.source)),
          state = \(String(reflecting: widget.state)), error = \(widget.error.map { String(reflecting: $0) } ?? "nil"),
          placements = { \(widget.placements.map { String(reflecting: $0) }.joined(separator: ", ")) } }
        """
    }

    private func assertClippedShell(_ snapshot: ConfigScriptSnapshot, problems: [String]) async throws {
        try await assertScript(
            """
            local expected = { \(problems.map { String(reflecting: $0) }.joined(separator: ", ")) }
            omniwm.on('config.reloaded', function(ctx)
                local report = assert(ctx.shell)
                assert(#report.problems == #expected)
                for i, problem in report.problems do assert(problem == expected[i]) end
                assert(ctx.truncated.shell == true)
                assert(ctx.workspaces and ctx.truncated.workspaces == false)
            end, { reads = { 'shell', 'workspaces' } })
            """, expecting: [.shell, .workspaces], snapshot: snapshot
        )
    }

    private func assertScript(
        _ source: String, expecting reads: ConfigScriptReads, snapshot: ConfigScriptSnapshot
    ) async throws {
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        XCTAssertEqual(result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }, reads)
        for listener in result.events {
            _ = try await generation.invoke(
                function: listener.function, event: ConfigScriptEventPayload(name: "config.reloaded"),
                snapshot: snapshot
            )
        }
    }
}
