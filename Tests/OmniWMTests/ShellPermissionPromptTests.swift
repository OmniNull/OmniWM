// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellPermissionPromptTests: XCTestCase {
    @MainActor
    private final class Presenter {
        var shown: [ShellPermissionPrompts.Request] = []
        var answers: [@MainActor (Bool) -> Void] = []
        var dismissed: [ShellPermissionPrompts.Request] = []

        func present(
            _ request: ShellPermissionPrompts.Request,
            answer: @escaping @MainActor (Bool) -> Void
        ) -> @MainActor () -> Void {
            shown.append(request)
            answers.append(answer)
            return { [weak self] in self?.dismissed.append(request) }
        }
    }

    private let ci = ShellWidgetPrincipal(role: .component, name: "ci-status", source: "/shell/widgets/ci-status")
    private let clock = ShellWidgetPrincipal(role: .bar, name: "clock", source: "/shell/widgets/clock")

    private func network(
        _ principal: ShellWidgetPrincipal,
        _ hosts: Set<String>,
        purpose: String? = nil
    ) -> ShellNetworkApproval {
        ShellNetworkApproval(key: ShellNetworkApproval.Key(principal: principal, hosts: hosts), purpose: purpose)
    }

    private func program(_ digest: String) -> ShellProviderApproval {
        ShellProviderApproval(principal: ci, command: ["provider.pl", "--serve"], sha256: digest)
    }

    private func prompts(_ settings: ShellPermissionSettings, _ presenter: Presenter) -> ShellPermissionPrompts {
        ShellPermissionPrompts(settings: settings, present: presenter.present)
    }

    func testOnePromptIsActiveAtATimeAndTheRestQueueInOrder() {
        let presenter = Presenter()
        let prompts = prompts(ShellPermissionSettings(), presenter)
        let first = network(ci, ["api.github.com"])
        let second = network(clock, ["time.example"])
        prompts.update(network: [second, first], programs: [program("aa")])

        XCTAssertEqual(presenter.shown, [.network(first)])
        XCTAssertEqual(prompts.active, .network(first))
        XCTAssertEqual(prompts.queue, [.program(program("aa")), .network(second)])

        presenter.answers[0](false)
        XCTAssertEqual(presenter.shown, [.network(first), .program(program("aa"))])
        presenter.answers[1](false)
        XCTAssertEqual(presenter.shown.last, .network(second))
        XCTAssertEqual(prompts.queue, [])
        XCTAssertTrue(presenter.dismissed.isEmpty)
    }

    func testTheRegistryKeyCoalescesRequestsAndQueuedPromptsShowTheLatestPayload() {
        let presenter = Presenter()
        let prompts = prompts(ShellPermissionSettings(), presenter)
        prompts.update(network: [network(clock, ["time.example"])], programs: [])
        prompts.update(network: [
            network(clock, ["time.example"]),
            network(ci, ["api.github.com"], purpose: "Earlier")
        ], programs: [])
        prompts.update(network: [
            network(clock, ["time.example"]),
            network(ci, ["api.github.com"], purpose: "Later")
        ], programs: [])

        XCTAssertEqual(presenter.shown, [.network(network(clock, ["time.example"]))])
        XCTAssertEqual(prompts.queue, [.network(network(ci, ["api.github.com"], purpose: "Later"))])
        presenter.answers[0](true)
        XCTAssertEqual(presenter.shown.last, .network(network(ci, ["api.github.com"], purpose: "Later")))
        XCTAssertEqual(presenter.shown.count, 2)
    }

    func testARemovedEntryCancelsItsOpenOrQueuedPromptAndALateAnswerIsIgnored() {
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = prompts(settings, presenter)
        let first = network(ci, ["api.github.com"])
        let queued = network(clock, ["time.example"])
        let last = network(clock, ["other.example"])
        prompts.update(network: [first, queued, last], programs: [])
        XCTAssertEqual(prompts.active, .network(first))

        prompts.update(network: [last], programs: [])
        XCTAssertEqual(presenter.dismissed, [.network(first)])
        XCTAssertEqual(presenter.shown, [.network(first), .network(last)])
        XCTAssertEqual(prompts.queue, [])

        presenter.answers[0](true)
        XCTAssertEqual(settings.decisions, ShellPermissionDecisions())
        XCTAssertEqual(prompts.active, .network(last))

        prompts.update(network: [], programs: [])
        XCTAssertEqual(presenter.dismissed, [.network(first), .network(last)])
        XCTAssertNil(prompts.active)
        XCTAssertTrue(prompts.pending.isEmpty)
    }

    func testAllowAndDenyRememberEveryHostOfTheNetworkPrompt() {
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = prompts(settings, presenter)
        prompts.update(network: [
            network(ci, ["api.github.com", "uploads.github.com"]),
            network(clock, ["time.example"])
        ], programs: [])

        presenter.answers[0](true)
        presenter.answers[1](false)

        XCTAssertEqual(settings.decisions.widgets, [
            ShellPermissionDecisions.Widget(
                role: .component, name: "ci-status", source: ci.source,
                allowed: ["api.github.com", "uploads.github.com"]
            ),
            ShellPermissionDecisions.Widget(
                role: .bar, name: "clock", source: clock.source, denied: ["time.example"]
            )
        ])
    }

    func testProgramAllowStoresTheDigestAndDenyStoresADenial() {
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = prompts(settings, presenter)
        prompts.update(network: [], programs: [program("aa")])
        presenter.answers[0](true)
        XCTAssertEqual(settings.decisions.programs, [ShellPermissionDecisions.Program(
            name: "ci-status", source: ci.source, command: ["provider.pl", "--serve"], sha256: "aa"
        )])

        prompts.update(network: [], programs: [program("bb")])
        presenter.answers[1](false)
        XCTAssertEqual(settings.decisions.programs, [ShellPermissionDecisions.Program(
            name: "ci-status", source: ci.source, command: ["provider.pl", "--serve"], sha256: "bb", denied: true
        )])
    }

    func testAChangedPayloadReplacesTheOpenPromptAndAllowStoresTheLatestDigest() {
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = prompts(settings, presenter)
        prompts.update(network: [], programs: [program("aa")])
        prompts.update(network: [], programs: [program("aa")])
        XCTAssertTrue(presenter.dismissed.isEmpty)

        prompts.update(network: [], programs: [program("bb")])
        XCTAssertEqual(presenter.dismissed, [.program(program("aa"))])
        XCTAssertEqual(presenter.shown, [.program(program("aa")), .program(program("bb"))])
        XCTAssertEqual(prompts.active, .program(program("bb")))

        presenter.answers[0](true)
        XCTAssertEqual(settings.decisions, ShellPermissionDecisions())
        presenter.answers[1](true)
        XCTAssertEqual(settings.decisions.programs, [ShellPermissionDecisions.Program(
            name: "ci-status", source: ci.source, command: ["provider.pl", "--serve"], sha256: "bb"
        )])
    }

    func testLockHidesTheOpenPromptAndShowsItAgainWhenUnlocked() {
        let presenter = Presenter()
        let prompts = prompts(ShellPermissionSettings(), presenter)
        let first = network(ci, ["api.github.com"])
        prompts.update(network: [first], programs: [])
        prompts.setSuspended(true)
        prompts.update(network: [first, network(clock, ["time.example"])], programs: [])

        XCTAssertEqual(presenter.dismissed, [.network(first)])
        XCTAssertNil(prompts.active)
        XCTAssertEqual(prompts.queue, [.network(first), .network(network(clock, ["time.example"]))])
        presenter.answers[0](true)
        XCTAssertNil(prompts.active)

        prompts.setSuspended(false)
        XCTAssertEqual(presenter.shown, [.network(first), .network(first)])
        XCTAssertEqual(prompts.active, .network(first))
    }

    func testHostRegistryDrivesPromptsAndALaterHostStillPrompts() {
        let settings = ShellPermissionSettings()
        let permissions = ShellNetworkPermissions()
        let host = makeHost(permissions: permissions)
        let island = ShellWidgetHost.WidgetState(
            name: "lake", sourceURL: URL(fileURLWithPath: "/shell/widgets/lake/init.luau")
        )
        var source = ShellWidgetSource(chunk: "", main: "", modules: [])
        source.componentDescriptors = [ShellComponentDescriptor(
            widget: ci.name, title: "CI Status", icon: "circle", views: [], uses: [], options: [:],
            capabilities: ShellComponentCapabilities(network: ["api.github.com", "uploads.github.com"]),
            providerCommand: nil, folder: URL(fileURLWithPath: ci.source)
        )]
        host.config.island = ShellIslandConfig(components: [ShellComponentInstance(id: "ci", widget: ci.name)])
        host.widgets["lake"] = island
        host.setDeclarations(source, of: island)
        settings.onDecisionsChange = { [weak host, weak settings] in
            guard let host, let settings, permissions.update(decisions: settings.decisions) else { return }
            host.permissionsChanged()
        }
        let presenter = Presenter()
        let prompts = prompts(settings, presenter)
        prompts.observe(host)

        host.recordNetworkApprovals([network(ci, ["api.github.com"], purpose: "Shows CI")])
        XCTAssertEqual(presenter.shown, [.network(network(ci, ["api.github.com"], purpose: "Shows CI"))])
        presenter.answers[0](true)
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertNil(prompts.active)
        XCTAssertEqual(permissions.decide("api.github.com", for: ci), .allowed)

        host.recordNetworkApprovals([network(ci, ["api.github.com"])])
        XCTAssertEqual(presenter.shown.count, 1)
        host.recordNetworkApprovals([network(ci, ["uploads.github.com"])])
        XCTAssertEqual(presenter.shown.last, .network(network(ci, ["uploads.github.com"])))

        settings.setNetwork(.denied, hosts: ["uploads.github.com"], for: ci)
        XCTAssertEqual(presenter.dismissed, [.network(network(ci, ["uploads.github.com"]))])
        XCTAssertNil(prompts.active)
    }

    private func makeHost(permissions: ShellNetworkPermissions) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            permissions: permissions,
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { _, _ in },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
    }
}
