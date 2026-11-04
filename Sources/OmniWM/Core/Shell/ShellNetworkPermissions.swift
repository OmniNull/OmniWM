// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
import Synchronization

struct ShellWidgetPrincipal: Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case root
        case bar
        case component
    }

    let role: Role
    let name: String
    let source: String
}

extension ShellWidgetPrincipal {
    init(role: Role, name: String, folder: URL) {
        self.init(role: role, name: name, source: Self.source(of: folder))
    }

    static func source(of folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum ShellNetworkDecision: Equatable, Sendable {
    case allowed
    case denied
    case blocked
    case notApproved

    var failure: ShellHTTPFailure? {
        switch self {
        case .allowed: nil
        case .denied: ShellHTTPFailure("network_denied")
        case .blocked: ShellHTTPFailure("network_blocked")
        case .notApproved: ShellHTTPFailure("network_not_approved")
        }
    }
}

struct ShellNetworkApproval: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let principal: ShellWidgetPrincipal
        let hosts: Set<String>
    }

    let key: Key
    let purpose: String?
}

struct ShellProviderApproval: Hashable, Sendable {
    struct Key: Hashable, Sendable {
        let principal: ShellWidgetPrincipal
        let command: [String]
    }

    let principal: ShellWidgetPrincipal
    let command: [String]
    let sha256: String

    var key: Key {
        Key(principal: principal, command: command)
    }
}

enum ShellServiceAccess: String, Sendable {
    case ok
    case off
    case blocked
}

extension ShellBuiltInService {
    private static let weatherHosts: Set<String> = ["api.open-meteo.com", "geocoding-api.open-meteo.com"]
    private static let lyricsHosts: Set<String> = ["lrclib.net"]

    var hosts: Set<String> {
        switch self {
        case .weather: Self.weatherHosts
        case .lyrics: Self.lyricsHosts
        }
    }
}

final class ShellHTTPDeclarations: Sendable {
    private let policies = Mutex<[String?: ShellHTTPPolicy]>([:])

    subscript(owner: String?) -> ShellHTTPPolicy {
        policies.withLock { $0[owner] } ?? .denied
    }

    func update(
        _ source: ShellWidgetSource,
        components: [ShellComponentInstance],
        permissions: ShellNetworkPermissions
    ) {
        var next: [String?: ShellHTTPPolicy] = [nil: .root(source, permissions: permissions)]
        for instance in components {
            next[instance.id] = .resolve(
                component: instance.id,
                instances: [instance],
                descriptors: source.componentDescriptors,
                permissions: permissions
            )
        }
        policies.withLock { $0 = next }
    }

    func declares(_ key: ShellNetworkApproval.Key) -> Bool {
        policies.withLock { policies in
            policies.values.contains { policy in
                guard case let .widget(principal, hosts, _) = policy else { return false }
                return principal == key.principal && hosts.isSuperset(of: key.hosts)
            }
        }
    }
}

final class ShellNetworkPermissions: Observable, Sendable {
    struct Hosts: Equatable, Sendable {
        var allowed: Set<String> = []
        var denied: Set<String> = []
    }

    struct Snapshot: Equatable, Sendable {
        var revision: UInt64 = 0
        var widgets: [ShellWidgetPrincipal: Hosts] = [:]
        var programs: [ShellProviderApproval.Key: ShellPermissionDecisions.Program] = [:]
        var services = ShellPermissionDecisions.Services()
        var managed = ShellManagedPolicy()

        func decide(_ host: String, for principal: ShellWidgetPrincipal) -> ShellNetworkDecision {
            if managed.blocks(host) { return .blocked }
            let user = widgets[principal]
            if user?.denied.contains(host) == true { return .denied }
            return managed.allowedHosts.contains(host) || user?.allowed.contains(host) == true ? .allowed : .notApproved
        }

        func decide(_ approval: ShellProviderApproval) -> ShellNetworkDecision {
            guard managed.providersAllowed else { return .blocked }
            guard let program = programs[approval.key] else { return .notApproved }
            if program.denied { return .denied }
            return program.sha256 == approval.sha256 ? .allowed : .notApproved
        }

        func access(_ service: ShellBuiltInService) -> ShellServiceAccess {
            guard !managed.blockedServices.contains(service), !service.hosts.contains(where: managed.blocks)
            else { return .blocked }
            let enabled = service == .weather ? services.weather : services.lyrics
            return enabled ? .ok : .off
        }
    }

    private let state: Mutex<Snapshot>
    private let registrar = ObservationRegistrar()

    init(
        decisions: ShellPermissionDecisions = ShellPermissionDecisions(),
        managed: ShellManagedPolicy = ShellManagedPolicy()
    ) {
        state = Mutex(Snapshot(
            widgets: Self.widgets(decisions), programs: Self.programs(decisions),
            services: decisions.services, managed: managed
        ))
    }

    var snapshot: Snapshot {
        registrar.access(self, keyPath: \.snapshot)
        return state.withLock { $0 }
    }

    func decide(_ host: String, for principal: ShellWidgetPrincipal) -> ShellNetworkDecision {
        state.withLock { $0.decide(host, for: principal) }
    }

    func decide(_ approval: ShellProviderApproval) -> ShellNetworkDecision {
        state.withLock { $0.decide(approval) }
    }

    func approvedDigest(for principal: ShellWidgetPrincipal, command: [String]) -> String? {
        state.withLock { state in
            guard state.managed.providersAllowed,
                  let program = state.programs[ShellProviderApproval.Key(principal: principal, command: command)],
                  !program.denied else { return nil }
            return program.sha256
        }
    }

    func access(_ service: ShellBuiltInService) -> ShellServiceAccess {
        state.withLock { $0.access(service) }
    }

    func permits(_ url: URL, service: ShellBuiltInService) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host, service.hosts.contains(ShellHTTPPolicy.canonicalHost(host)) else { return false }
        return access(service) == .ok
    }

    func undecided(
        _ hosts: Set<String>,
        for principal: ShellWidgetPrincipal
    ) -> (revision: UInt64, hosts: Set<String>) {
        state.withLock { state in (state.revision, hosts.filter { state.decide($0, for: principal) == .notApproved }) }
    }

    func isPending(_ key: ShellNetworkApproval.Key) -> Bool {
        undecided(key.hosts, for: key.principal).hosts == key.hosts
    }

    @discardableResult
    func update(decisions: ShellPermissionDecisions? = nil, managed: ShellManagedPolicy? = nil) -> Bool {
        let widgets = decisions.map(Self.widgets)
        let programs = decisions.map(Self.programs)
        let changed = state.withLock { state in
            var next = state
            if let widgets { next.widgets = widgets }
            if let programs { next.programs = programs }
            if let decisions { next.services = decisions.services }
            if let managed { next.managed = managed }
            guard next != state else { return false }
            next.revision &+= 1
            state = next
            return true
        }
        if changed { registrar.withMutation(of: self, keyPath: \.snapshot) {} }
        return changed
    }

    private static func widgets(_ decisions: ShellPermissionDecisions) -> [ShellWidgetPrincipal: Hosts] {
        decisions.widgets.reduce(into: [:]) { result, widget in
            result[widget.principal, default: Hosts()].allowed
                .formUnion(widget.allowed.map(ShellHTTPPolicy.canonicalHost))
            result[widget.principal, default: Hosts()].denied
                .formUnion(widget.denied.map(ShellHTTPPolicy.canonicalHost))
        }
    }

    private static func programs(
        _ decisions: ShellPermissionDecisions
    ) -> [ShellProviderApproval.Key: ShellPermissionDecisions.Program] {
        decisions.programs.reduce(into: [:]) { result, program in
            let principal = ShellWidgetPrincipal(role: .component, name: program.name, source: program.source)
            let key = ShellProviderApproval.Key(principal: principal, command: program.command)
            if result[key]?.denied != true { result[key] = program }
        }
    }
}
