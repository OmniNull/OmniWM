// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellProvider {
    func refreshTrust(
        _ configuration: ShellProviderConfiguration,
        configurationChanged: Bool = false
    ) {
        watchExecutable(nil, configuration: configuration)
        do {
            let resolved = try resolveDeclaration(configuration)
            watchExecutable(resolved.executable, configuration: configuration)
            let approval = try executableApproval(configuration, executable: resolved.executable)
            let decision = permissions.decide(approval)
            guard configuration.principal == approval.principal, configuration.sha256 == approval.sha256,
                  decision == .allowed
            else {
                reportApproval(approval)
                if decision == .allowed, lifecycle.phase == .terminal, lifecycle.configuration == nil { return }
                reject(configuration, status: .notApproved, reason: .trust(approval, decision))
                return
            }
            lastReportedApproval = nil
            lastRejection = nil
            if configurationChanged || lifecycle.configuration != configuration {
                perform(lifecycle.reconcile(configuration))
            }
        } catch {
            let message = String(error.localizedDescription.prefix(1024))
            reject(configuration, status: .failed(message), reason: .failure(configuration, message))
            if let identity = lifecycle.identity {
                diagnostics(identity, ShellProviderDiagnostics.Line(
                    text: message, truncated: false, suppressed: 0
                ))
            }
        }
    }

    private func reject(
        _ configuration: ShellProviderConfiguration, status: ShellProviderInbox.Status, reason: Rejection
    ) {
        guard lastRejection != reason || lifecycle.phase != .terminal || lifecycle.configuration != nil else { return }
        lastRejection = reason
        perform(lifecycle.refuse(configuration, status: status))
    }

    func reportApproval(_ approval: ShellProviderApproval) {
        let revision = permissions.snapshot.revision
        if revision != approvalRevision {
            approvalRevision = revision
            lastReportedApproval = nil
        }
        guard permissions.decide(approval) == .notApproved, lastReportedApproval != approval else { return }
        lastReportedApproval = approval
        trustNeeded(approval)
    }

    func stopExecutableWatches() {
        executableObservation?.cancel()
        executableObservation = nil
        executableWatchPaths.removeAll()
    }

    private func watchExecutable(
        _ executable: URL?, configuration: ShellProviderConfiguration
    ) {
        guard let command = configuration.command.first else { return }
        let requested = configuration.folder.appendingPathComponent(command)
        var paths = Set([
            requested.path,
            requested.deletingLastPathComponent().path,
            configuration.folder.path,
            configuration.folder.deletingLastPathComponent().path
        ])
        if let executable {
            paths.insert(executable.path)
            paths.insert(executable.deletingLastPathComponent().path)
        } else if let executableObservation, paths.isSubset(of: executableWatchPaths) {
            executableObservation.sync(paths: executableWatchPaths)
            return
        }
        executableWatchPaths = paths
        if let executableObservation {
            executableObservation.sync(paths: paths)
        } else {
            executableObservation = ShellProviderObservation.shared.observe(paths: paths) { [weak self] in
                Task { await self?.executableChanged() }
            }
        }
    }

    private func executableChanged() {
        guard let declaration else { return }
        refreshTrust(declaration)
    }
}
