// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellIslandSettingsReadinessTests: XCTestCase {
    func testTriggerDeclarationChangesPublishReadinessWhenTheLoadedReportStaysEqual() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        let state = ShellWidgetHost.WidgetState(name: "example", sourceURL: root.appendingPathComponent("init.luau"))
        host.widgets[state.name] = state
        var readiness: [Bool] = []
        host.onWidgetsChange = { readiness.append(state.package != nil && state.declaration.hasTrigger) }
        let outbox = ShellWidgetOutbox { _ in }
        var packages: [ShellWidgetPackage] = []
        var initialReport = host.widgetReport
        for (index, hasTrigger) in [false, true, false].enumerated() {
            let generation = index + 1
            let source = ShellWidgetSource(
                chunk: "=example/init.luau",
                main: "function render(ctx) return ui.box{w=1,h=1} end"
                    + (hasTrigger ? "\nfunction trigger(ctx,event) end" : ""),
                modules: []
            )
            let package = ShellWidgetPackage(name: state.name, generation: generation, outbox: outbox)
            packages.append(package)
            state.loadingGeneration = generation
            let failure = await package.load(source)
            XCTAssertNil(failure)
            let declaration = await package.declaration
            host.finishLoad(state: state, package: package, source: source, failure: failure, declaration: declaration)
            XCTAssertEqual(state.declaration.hasTrigger, hasTrigger)
            XCTAssertEqual(readiness.count, index + 1)
            if index == 0 { initialReport = host.widgetReport }
            else { XCTAssertEqual(host.widgetReport, initialReport) }
        }
        XCTAssertEqual(readiness, [false, true, false])
        host.stop()
        for package in packages { await package.close() }
    }

    func testSameTriggerReloadPublishesLoadingThenLoadedReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let file = shell.appendingPathComponent("widgets/example/init.luau")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{w=1,h=1} end\nfunction trigger(ctx,event) end".utf8)
            .write(to: file)
        let host = ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        defer {
            host.onWidgetsChange = nil
            host.stop()
        }
        host.config.directories = [shell]
        host.outbox = ShellWidgetOutbox { _ in }
        let state = ShellWidgetHost.WidgetState(name: "example", sourceURL: file)
        host.widgets[state.name] = state
        let initial = expectation(description: "initial package loaded")
        let replacement = expectation(description: "same-trigger replacement loaded")
        var readiness: [Bool] = []
        var reportedStates: [String] = []
        func recordReadiness() -> Bool {
            let available = state.package != nil && state.declaration.hasTrigger
            readiness.append(available)
            reportedStates.append(host.widgetReport.widgets.first?.state ?? "missing")
            return available
        }
        host.onWidgetsChange = {
            if recordReadiness() { initial.fulfill() }
        }
        host.load(state)
        await fulfillment(of: [initial], timeout: 10)
        let previous = try XCTUnwrap(state.package)
        XCTAssertTrue(state.declaration.hasTrigger)
        host.onWidgetsChange = {
            if recordReadiness() { replacement.fulfill() }
        }
        host.load(state)
        await fulfillment(of: [replacement], timeout: 10)
        XCTAssertEqual(readiness, [true, false, true])
        XCTAssertEqual(reportedStates, ["loaded", "loading", "loaded"])
        XCTAssertTrue(state.declaration.hasTrigger)
        let current = try XCTUnwrap(state.package)
        XCTAssertFalse(current === previous)
        host.onWidgetsChange = nil
        host.stop()
        await previous.close()
        await current.close()
    }
}
