// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

actor ShellProvider {
    struct Capture: Equatable, Sendable {
        let framing: ShellProviderLineFramer.Capture
        let wakes: ShellCaptureWakeCounters

        var id: UInt64 {
            framing.id
        }

        var detail: String {
            framing.detail + " " + wakes.detail
        }
    }

    struct Signal: OptionSet, Sendable {
        let rawValue: UInt8
        static let output = Signal(rawValue: 1)
        static let diagnostic = Signal(rawValue: 2)
        static let writable = Signal(rawValue: 4)
        static let exited = Signal(rawValue: 8)
        static let kill = Signal(rawValue: 16)
        static let inputClosed = Signal(rawValue: 32)
    }

    struct Spawned {
        let process: Process
        let input: Int32
        let output: Int32
        let diagnostic: Int32
        let cleanupError: String?
    }

    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.provider", qos: .utility)
    let signals = Signals()
    let actions = ShellProviderActions()
    let inbox: ShellProviderInbox
    let diagnostics: @Sendable (ShellProviderIdentity, ShellProviderDiagnostics.Line) -> Void
    let environment: [String: String]
    let permissions: ShellNetworkPermissions
    let trustNeeded: @Sendable (ShellProviderApproval) -> Void
    var declaration: ShellProviderConfiguration?
    enum Rejection: Equatable {
        case trust(ShellProviderApproval, ShellNetworkDecision)
        case failure(ShellProviderConfiguration, String)
    }

    var lastRejection: Rejection?
    var lastReportedApproval: ShellProviderApproval?
    var approvalRevision: UInt64 = 0
    var executableObservation: ShellProviderObservation.Subscription?
    var executableWatchPaths: Set<String> = []
    var lifecycle: ShellProviderLifecycle
    var process: Process?
    var inputFD: Int32?
    var outputFD: Int32?
    var diagnosticFD: Int32?
    var inputSource: (any DispatchSourceWrite)?
    var outputSource: (any DispatchSourceRead)?
    var diagnosticSource: (any DispatchSourceRead)?
    var inputResumed = false
    var killSource: (any DispatchSourceTimer)?
    var writer = ShellProviderWriteQueue()
    var framer = ShellProviderLineFramer()
    var diagnosticFramer = ShellProviderDiagnostics()
    var outputFinished = false
    var diagnosticFinished = false
    var discardOutput = false
    var readBuffer = [UInt8](repeating: 0, count: 16_384)
    var closeWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(
        owner: ShellServiceOwner,
        inbox: ShellProviderInbox,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        permissions: ShellNetworkPermissions = ShellNetworkPermissions(),
        trustNeeded: @escaping @Sendable (ShellProviderApproval) -> Void = { _ in },
        diagnostics: @escaping @Sendable (ShellProviderIdentity, ShellProviderDiagnostics.Line) -> Void = { _, _ in }
    ) {
        lifecycle = ShellProviderLifecycle(owner: owner)
        self.inbox = inbox
        self.environment = environment
        self.permissions = permissions
        self.trustNeeded = trustNeeded
        self.diagnostics = diagnostics
        signals.attach { [weak self] in Task { await self?.consumeSignals() } }
    }

    func reconcile(_ configuration: ShellProviderConfiguration?) {
        let changed = declaration != configuration
        declaration = configuration
        guard let configuration else {
            stopExecutableWatches()
            lastReportedApproval = nil
            lastRejection = nil
            perform(lifecycle.reconcile(nil))
            return
        }
        refreshTrust(configuration, configurationChanged: changed)
    }

    nonisolated func permissionsChanged() {
        Task { await recheckPermissions() }
    }

    private func recheckPermissions() {
        guard let declaration else { return }
        refreshTrust(declaration)
    }

    func captureBegin(_ id: UInt64) {
        framer.captureBegin(id)
        signals.captureBegin(id)
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        guard let framing = framer.captureEnd(id), let wakes = signals.captureEnd(id) else { return nil }
        return Capture(framing: framing, wakes: wakes)
    }

    nonisolated func send(_ id: ShellServiceID, identity: ShellProviderIdentity, frame: Data) {
        guard inbox.isPending(id, identity: identity) else {
            inbox.actionUnsent(ShellResourceLeaseKey(id: id, incarnation: identity.incarnation))
            return
        }
        if let error = actions.append(frame, id: id, identity: identity) {
            inbox.actionUnsent(ShellResourceLeaseKey(id: id, incarnation: identity.incarnation))
            inbox.failAction(id, identity: identity, error: error)
        } else {
            signals.post(.writable, identity: identity)
        }
    }

    nonisolated func cancel(_ id: ShellServiceID, identity: ShellProviderIdentity) {
        inbox.cancel(id)
        if actions.cancel(id, identity: identity) {
            inbox.actionUnsent(ShellResourceLeaseKey(id: id, incarnation: identity.incarnation))
        }
        signals.post(.writable, identity: identity)
    }

    func close() async {
        declaration = nil
        stopExecutableWatches()
        perform(lifecycle.close())
        await ShellProviderObservation.shared.finishCancellations()
        guard !lifecycle.isClosed else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func failure(_ message: String) -> ShellProviderProtocol.Failure {
        ShellProviderProtocol.Failure(message: message)
    }
}
