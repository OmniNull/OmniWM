// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ShellWidgetHost {
    private struct ApprovalDeclarations {
        var hosts: [ShellWidgetPrincipal: Set<String>] = [:]
        var programs: Set<ShellProviderApproval.Key> = []

        func declares(_ key: ShellNetworkApproval.Key) -> Bool {
            hosts[key.principal]?.isSuperset(of: key.hosts) == true
        }
    }

    func permissionsChanged() {
        networkApprovals = networkApprovals.filter { isPending($0.key) }
        providerApprovals = providerApprovals.filter { permissions.decide($0.value) == .notApproved }
        feed?.permissionsChanged()
        for state in widgets.values {
            state.mailbox?.yield(.permissions)
            state.loadingPackage?.permissionsChanged()
        }
        hiddenBarMenu?.permissionsChanged()
    }

    func recordNetworkApprovals(_ approvals: [ShellNetworkApproval]) {
        guard !approvals.isEmpty else { return }
        let declarations = approvalDeclarations()
        for approval in approvals where declarations.declares(approval.key) && isPending(approval.key) {
            networkApprovals[approval.key] = approval
        }
    }

    func recordProviderApprovals(_ approvals: [ShellProviderApproval]) {
        guard !approvals.isEmpty else { return }
        let programs = approvalDeclarations().programs
        for approval in approvals
            where programs.contains(approval.key) && permissions.decide(approval) == .notApproved
        {
            providerApprovals[approval.key] = approval
        }
    }

    func pruneApprovals() {
        guard !networkApprovals.isEmpty || !providerApprovals.isEmpty else { return }
        let declarations = approvalDeclarations()
        networkApprovals = networkApprovals.filter { declarations.declares($0.key) }
        providerApprovals = providerApprovals.filter { declarations.programs.contains($0.key) }
    }

    func setDeclarations(_ source: ShellWidgetSource, of state: WidgetState) {
        state.declaredHosts = source.declaredHosts
        state.componentDescriptors = source.componentDescriptors
        pruneApprovals()
    }

    func title(of principal: ShellWidgetPrincipal) -> String {
        guard principal.role == .component else { return ShellBarLayout.title(of: principal.name) }
        return widgets.values.lazy.flatMap(\.componentDescriptors).first { $0.principal == principal }?.title
            ?? principal.name
    }

    private func approvalDeclarations() -> ApprovalDeclarations {
        var result = ApprovalDeclarations()
        let enabled = config.island?.components.filter(\.enabled) ?? []
        for state in widgets.values {
            result.hosts[sourceInput(of: state.sourceURL, name: state.name).principal, default: []]
                .formUnion(state.declaredHosts)
            for descriptor in state.componentDescriptors {
                let instances = enabled.filter { $0.widget == descriptor.widget }
                guard !instances.isEmpty else { continue }
                let extended = instances.flatMap { $0.capabilities?.network ?? [] }
                result.hosts[descriptor.principal, default: []]
                    .formUnion((descriptor.capabilities.network + extended).map(ShellHTTPPolicy.canonicalHost))
                if descriptor.capabilities.provider, let command = descriptor.providerCommand {
                    result.programs.insert(ShellProviderApproval.Key(principal: descriptor.principal, command: command))
                }
            }
        }
        if let menu = config.widget("hidden-bar-menu") ?? ShellConfig.bundledWidget("hidden-bar-menu") {
            result.hosts[sourceInput(of: menu, name: "hidden-bar-menu").principal, default: []]
                .formUnion(hiddenBarMenuHosts)
        }
        return result
    }

    private func isPending(_ key: ShellNetworkApproval.Key) -> Bool {
        permissions.undecided(key.hosts, for: key.principal).hosts == key.hosts
    }
}
