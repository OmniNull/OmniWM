// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class HostedAppPermissionTests: XCTestCase {
    private let promptFailureDeadline: TimeInterval = 10

    @MainActor
    private final class Presenter {
        var shown: [ShellPermissionPrompts.Request] = []
        var answers: [@MainActor (Bool) -> Void] = []
        var dismissed: [ShellPermissionPrompts.Request] = []
        var onPresent: (() -> Void)?

        func present(
            _ request: ShellPermissionPrompts.Request,
            answer: @escaping @MainActor (Bool) -> Void
        ) -> @MainActor () -> Void {
            shown.append(request)
            answers.append(answer)
            onPresent?()
            return { [weak self] in self?.dismissed.append(request) }
        }
    }

    @MainActor
    private final class Harness {
        let fixture: HostedManagementFixture
        let presenter = Presenter()
        let prompts: ShellPermissionPrompts
        var bar: WorkspaceBarManager {
            fixture.controller.workspaceBarManager
        }

        init() throws {
            fixture = try HostedManagementFixture(layout: .niri)
            let controller = fixture.controller
            controller.settings.workspaceBar.enabled = false
            controller.workspaceBarManager.setup(controller: controller, settings: controller.settings)
            prompts = ShellPermissionPrompts(
                settings: controller.settings.shellPermissions, present: presenter.present
            )
            controller.workspaceBarManager.shellPermissionPrompts = prompts
        }

        func open(_ definition: ShellAppDefinition) throws -> HostedManagementInstance {
            XCTAssertTrue(fixture.manager.open(definition, in: fixture.source, newInstance: true))
            let window = try XCTUnwrap(fixture.windows.last)
            let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
            return try HostedManagementInstance(
                token: token, window: window, session: XCTUnwrap(fixture.manager.runtime(for: token))
            )
        }
    }

    private func openAwaitingPrompt(
        _ definition: ShellAppDefinition,
        in harness: Harness
    ) async throws -> HostedManagementInstance {
        let prompted = expectation(description: "The app asks before using its permission")
        harness.presenter.onPresent = { prompted.fulfill() }
        let instance = try harness.open(definition)
        await fulfillment(of: [prompted], timeout: promptFailureDeadline)
        harness.presenter.onPresent = nil
        return instance
    }

    private func providerReview() async throws -> ShellAppDefinition {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: apps) }
        _ = try ShellProviderReviewExampleFixture.copy(to: apps)
        let snapshot = try await ShellAppCatalogLoader().load(directories: [apps], bundled: nil)
        return try XCTUnwrap(snapshot.definitions["provider-review"])
    }

    private func networkApp() throws -> ShellAppDefinition {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("network-app", isDirectory: true)
        let helper = folder.appendingPathComponent("widgets/helper", isDirectory: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data("""
        title = "Network App"
        icon = "app"
        views = ["window"]
        uses = ["helper"]
        capabilities = { network = ["api.example"], purpose = "Shows a report" }

        [window]
        width = 320
        height = 200
        minWidth = 200
        minHeight = 120
        """.utf8).write(to: folder.appendingPathComponent("component.toml"))
        try Data("""
        return {
            init = function() assert(omniwm.http({url='https://api.example/data'}, function(result) end)) end,
            views = { window = function(ctx) return ui.box{ w = ctx.view.w, h = ctx.view.h } end },
        }
        """.utf8).write(to: folder.appendingPathComponent("init.luau"))
        try Data("""
        views = ["compact"]
        capabilities = { network = ["helper.example"] }
        """.utf8).write(to: helper.appendingPathComponent("component.toml"))
        try Data("""
        return { views = { compact = function() return ui.box{ w = 1, h = 1 } end } }
        """.utf8).write(to: helper.appendingPathComponent("component.luau"))
        return try ShellAppDefinition.load(id: "network-app", folder: folder)
    }

    func testProviderReviewAsksFirstAndItsDocumentedFlowRunsOnceApproved() async throws {
        let harness = try Harness()
        defer { harness.fixture.close() }
        let definition = try await providerReview()
        let instance = try await openAwaitingPrompt(definition, in: harness)
        let surface = instance.session.surface
        guard case let .program(approval) = harness.prompts.active else {
            return XCTFail("The app must ask for its program first")
        }
        XCTAssertEqual(approval.principal, definition.component?.principal)
        XCTAssertEqual(approval.command, definition.component?.providerCommand)
        XCTAssertEqual(harness.bar.shellPermissionTitle(of: approval.principal), definition.title)
        XCTAssertFalse(hostedSheetLabels(surface).contains("Ready"))

        await hostedSheetEvent(instance.session, description: "The approved program publishes its state", completed: {
            self.hostedSheetLabels(surface).contains("Ready")
        }, action: { harness.presenter.answers[0](true) })
        XCTAssertEqual(harness.prompts.pending, [])
        XCTAssertEqual(instance.session.providerApprovals, [:])
        XCTAssertEqual(harness.bar.shellPermissions.decide(approval), .allowed)

        await hostedSheetEvent(instance.session, description: "The program answers with a reviewable item", completed: {
            self.hostedSheetLabels(surface).contains("Review selected-item")
        }, action: try hostedSheetAction("Check for work", surface: surface))
        let sheet = try await openHostedSheet(instance, fixture: harness.fixture, button: "Review selected-item")
        try await closeHostedSheet(
            sheet, button: "Delete", parent: instance, fixture: harness.fixture,
            expectedResult: "Deleted selected-item."
        )

        let second = try harness.open(definition)
        await hostedSheetEvent(second.session, description: "A new window reuses the approval", completed: {
            self.hostedSheetLabels(second.session.surface).contains("Ready")
        }, action: {})
        XCTAssertEqual(harness.presenter.shown, [.program(approval)])
    }

    func testOneNetworkPromptFollowsTheAppsOpenWindowsAndLeavesWithThem() async throws {
        let harness = try Harness()
        defer { harness.fixture.close() }
        let definition = try networkApp()
        let first = try await openAwaitingPrompt(definition, in: harness)
        guard case let .network(approval) = harness.prompts.active else {
            return XCTFail("The app must ask for its server")
        }
        XCTAssertEqual(approval.key.principal, definition.component?.principal)
        XCTAssertEqual(approval.key.hosts, ["api.example"])
        XCTAssertEqual(approval.purpose, definition.component?.capabilities.purpose)

        let second = try harness.open(definition)
        await hostedSheetEvent(second.session, description: "The second window makes the same request", completed: {
            !second.session.networkApprovals.isEmpty
        }, action: {})
        XCTAssertEqual(harness.presenter.shown, [.network(approval)])

        first.window.close()
        XCTAssertEqual(harness.prompts.pending, [.network(approval)])
        XCTAssertEqual(harness.presenter.dismissed, [])

        second.window.close()
        XCTAssertEqual(harness.prompts.pending, [])
        XCTAssertEqual(harness.presenter.dismissed, [.network(approval)])
    }

    func testAnsweringTheNetworkPromptUsesTheSharedDecisionsAndClearsEveryWindow() async throws {
        let harness = try Harness()
        defer { harness.fixture.close() }
        let definition = try networkApp()
        let first = try await openAwaitingPrompt(definition, in: harness)
        let second = try harness.open(definition)
        await hostedSheetEvent(second.session, description: "The second window makes the same request", completed: {
            !second.session.networkApprovals.isEmpty
        }, action: {})
        guard case let .network(approval) = harness.prompts.active else {
            return XCTFail("The app must ask for its server")
        }

        XCTAssertTrue(first.session.package.permissions === harness.bar.shellPermissions)
        harness.presenter.answers[0](true)

        XCTAssertEqual(
            harness.bar.shellPermissions.decide("api.example", for: approval.key.principal), .allowed
        )
        XCTAssertEqual(harness.fixture.controller.settings.shellPermissions.decisions.widgets.map(\.allowed), [
            ["api.example"]
        ])
        XCTAssertEqual(first.session.networkApprovals, [:])
        XCTAssertEqual(second.session.networkApprovals, [:])
        XCTAssertEqual(harness.prompts.pending, [])
    }

    func testAnEditedManifestKeepsAnOpenAppsEarlierPermissionsInSettingsUntilItCloses() async throws {
        let harness = try Harness()
        defer { harness.fixture.close() }
        let catalog = harness.fixture.controller.shellAppCatalog
        let folder = catalog.directory.appendingPathComponent("edited-app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for script in ["old.sh", "new.sh"] {
            let file = folder.appendingPathComponent(script)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try Data("""
        return { views = { window = function(ctx) return ui.box{ w = ctx.view.w, h = ctx.view.h } end } }
        """.utf8).write(to: folder.appendingPathComponent("init.luau"))
        func publish(host: String, command: String) async throws {
            try Data("""
            title = "Edited App"
            icon = "app"
            views = ["window"]
            capabilities = { network = ["\(host)"], provider = true }

            [provider]
            command = ["\(command)"]

            [window]
            width = 320
            height = 200
            minWidth = 200
            minHeight = 120
            """.utf8).write(to: folder.appendingPathComponent("component.toml"))
            await catalog.refresh()
            XCTAssertEqual(catalog.problems, [])
            XCTAssertEqual(catalog.definitions["edited-app"]?.component?.capabilities.network, [host])
        }
        func page() -> NetworkPermissionsPage {
            NetworkPermissionsPage(
                config: ShellConfig(), schemas: [:], catalog: nil,
                apps: harness.fixture.manager.permissionDescriptors,
                permissions: harness.bar.shellPermissions.snapshot, pending: []
            )
        }

        try await publish(host: "old.example", command: "old.sh")
        let instance = try harness.open(XCTUnwrap(catalog.definitions["edited-app"]))
        try await publish(host: "new.example", command: "new.sh")

        XCTAssertEqual(page().widgets.map { $0.hosts.map(\.name) }, [["new.example", "old.example"]])
        XCTAssertEqual(Set(page().programs.map(\.key.command)), [["old.sh"], ["new.sh"]])
        XCTAssertEqual(Set(page().programs.map(\.id)).count, page().programs.count)

        instance.window.close()
        XCTAssertEqual(page().widgets.map { $0.hosts.map(\.name) }, [["new.example"]])
        XCTAssertEqual(page().programs.map(\.key.command), [["new.sh"]])
    }

    func testSettingsListsWhatAnOpenAppLoadedOnlyWhileItIsOpen() async throws {
        let harness = try Harness()
        defer { harness.fixture.close() }
        let definition = try networkApp()
        let app = try XCTUnwrap(definition.component)
        let helper = try ShellComponentCatalog.load("helper", directories: [definition.folder])
        let listed = { Set(harness.fixture.manager.permissionDescriptors.map(\.principal)) }
        XCTAssertFalse(listed().contains(app.principal))

        let instance = try harness.open(definition)
        XCTAssertTrue(listed().isSuperset(of: [app.principal, helper.principal]))

        instance.window.close()
        XCTAssertFalse(listed().contains(app.principal))
        XCTAssertFalse(listed().contains(helper.principal))
    }
}
