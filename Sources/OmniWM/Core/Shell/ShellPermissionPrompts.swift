// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Observation

@MainActor
@Observable
final class ShellPermissionPrompts {
    enum Request: Equatable, Sendable {
        case network(ShellNetworkApproval)
        case program(ShellProviderApproval)

        var key: Key {
            switch self {
            case let .network(approval): .network(approval.key)
            case let .program(approval): .program(approval.key)
            }
        }

        var principal: ShellWidgetPrincipal {
            switch self {
            case let .network(approval): approval.key.principal
            case let .program(approval): approval.principal
            }
        }

        fileprivate var order: [String] {
            switch self {
            case let .network(approval):
                [principal.name, principal.role.rawValue, principal.source, "network"] + approval.key.hosts.sorted()
            case let .program(approval):
                [principal.name, principal.role.rawValue, principal.source, "program"] + approval.command
            }
        }
    }

    enum Key: Hashable, Sendable {
        case network(ShellNetworkApproval.Key)
        case program(ShellProviderApproval.Key)
    }

    typealias Present = @MainActor (Request, @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void

    private(set) var active: Request?
    private(set) var queue: [Request] = []
    @ObservationIgnored private let settings: ShellPermissionSettings
    @ObservationIgnored private let present: Present
    @ObservationIgnored private var dismissActive: (@MainActor () -> Void)?
    @ObservationIgnored private var presentation = 0
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private weak var host: ShellWidgetHost?
    @ObservationIgnored private var appNetwork: [ShellNetworkApproval] = []
    @ObservationIgnored private var appPrograms: [ShellProviderApproval] = []

    init(settings: ShellPermissionSettings, present: @escaping Present) {
        self.settings = settings
        self.present = present
    }

    var pending: [Request] {
        (active.map { [$0] } ?? []) + queue
    }

    func observe(_ host: ShellWidgetHost) {
        self.host = host
        host.onApprovalsChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func setAppApprovals(network: [ShellNetworkApproval], programs: [ShellProviderApproval]) {
        appNetwork = network
        appPrograms = programs
        refresh()
    }

    private func refresh() {
        update(
            network: (host.map { Array($0.networkApprovals.values) } ?? []) + appNetwork,
            programs: (host.map { Array($0.providerApprovals.values) } ?? []) + appPrograms
        )
    }

    func update(network: some Sequence<ShellNetworkApproval>, programs: some Sequence<ShellProviderApproval>) {
        let requests = network.map(Request.network) + programs.map(Request.program)
        let current = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        queue = queue.compactMap { current[$0.key] }
        if let active, current[active.key] != active {
            cancelActive()
            if let latest = current[active.key] { queue.insert(latest, at: 0) }
        }
        let known = Set(pending.map(\.key))
        queue += current.values.filter { !known.contains($0.key) }
            .sorted { $0.order.lexicographicallyPrecedes($1.order) }
        presentNext()
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended, let active {
            cancelActive()
            queue.insert(active, at: 0)
        }
        presentNext()
    }

    private func presentNext() {
        guard active == nil, !suspended, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        presentation &+= 1
        let token = presentation
        active = request
        let dismiss = present(request) { [weak self] allowed in self?.answer(token, allowed: allowed) }
        if presentation == token, active != nil { dismissActive = dismiss }
    }

    private func answer(_ token: Int, allowed: Bool) {
        guard token == presentation, let request = active else { return }
        active = nil
        dismissActive = nil
        let decision: ShellPermissionDecisions.HostDecision = allowed ? .allowed : .denied
        switch request {
        case let .network(approval):
            settings.setNetwork(decision, hosts: approval.key.hosts, for: approval.key.principal)
        case let .program(approval):
            settings.setProgram(decision, for: approval)
        }
        presentNext()
    }

    private func cancelActive() {
        presentation &+= 1
        active = nil
        let dismiss = dismissActive
        dismissActive = nil
        dismiss?()
    }
}
