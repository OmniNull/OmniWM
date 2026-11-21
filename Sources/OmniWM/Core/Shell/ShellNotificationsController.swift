// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class ShellNotificationsController {
    static let dismissalPersistenceGrace: Duration = .seconds(6)

    enum RefreshReason: String {
        case manual
        case initial
        case filesystem
        case action
        case dismissalConfirmation
        case coalesced
    }

    private struct ReadDiagnostics {
        let reason: RefreshReason
        let completed: Date
        let duration: TimeInterval
        let changed: Bool
    }

    typealias Loader = @Sendable (URL) async -> ShellNotificationsData
    typealias ActionPerformer = @MainActor @Sendable (ShellNotificationActionRequest) async
        -> ShellNotificationActionOutcome
    typealias AppNameResolver = @MainActor @Sendable (String) -> String?
    typealias DismissAllPerformer = @MainActor @Sendable (
        [ShellNotificationActionRequest],
        @escaping @MainActor @Sendable (ShellNotificationActionOutcome) -> Void
    ) async -> ShellNotificationActionOutcome
    typealias CenterPerformer = @MainActor @Sendable () async -> ShellNotificationActionOutcome

    private let url: URL
    private let preferencesURL: URL
    private let load: Loader
    private let performAction: ActionPerformer
    private let performDismissAll: DismissAllPerformer
    let performShowCenter: CenterPerformer
    private let resolveName: AppNameResolver
    private let revision: @MainActor @Sendable () -> StorageRevision
    private let now: @MainActor @Sendable () -> SuspendingClock.Instant
    private let sleepUntil: @MainActor @Sendable (SuspendingClock.Instant) async throws -> Void
    private var appNames: [String: String] = [:]
    private var observation: ShellDirectoryObservation?
    private(set) var task: Task<Void, Never>?
    private(set) var actionTask: Task<Void, Never>?
    private var dismissalConfirmationTask: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    private var pending = false
    private var readSequence: UInt64 = 0
    private var dispatched: [UUID: SuspendingClock.Instant] = [:]
    private var keptIDs: Set<UUID> = []
    private var lastRead: ReadDiagnostics?
    private(set) var isListening = false
    private(set) var current = ShellNotificationsData(state: "loading")
    var onChange: (@MainActor (ShellNotificationsData) -> Void)?

    init(
        url: URL = ShellNotificationStore.defaultURL,
        preferencesURL: URL? = nil,
        load: Loader? = nil,
        perform: ActionPerformer? = nil,
        dismissAll: DismissAllPerformer? = nil,
        showCenter: CenterPerformer? = nil,
        resolveName: AppNameResolver? = nil,
        revision: (@MainActor @Sendable () -> StorageRevision)? = nil,
        now: @escaping @MainActor @Sendable () -> SuspendingClock.Instant = { SuspendingClock.now },
        sleepUntil: @escaping @MainActor @Sendable (SuspendingClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .suspending)
        }
    ) {
        self.url = url
        let preferencesURL = preferencesURL ?? ShellNotificationPreferences.url(forDatabase: url)
        self.preferencesURL = preferencesURL
        self.revision = revision ?? { StorageRevision.read(at: url) }
        self.now = now
        self.sleepUntil = sleepUntil
        let worker = ShellNotificationsWorker()
        self.load = load ?? { await worker.read(at: $0, preferencesURL: preferencesURL) }
        self.resolveName = resolveName ?? { bundle in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        let accessibility = ShellNotificationAccessibility()
        performAction = perform ?? { request in
            guard let (notificationPID, menuPID) = Self.nativeProcesses() else {
                ShellNotificationTrace.record("native.processes.missing", target: request.id)
                return .unavailable
            }
            return await accessibility.perform(request, notificationPID: notificationPID, menuPID: menuPID)
        }
        performDismissAll = dismissAll ?? Self.nativeDismissAll(accessibility)
        performShowCenter = showCenter ?? {
            guard let (notificationPID, menuPID) = Self.nativeProcesses() else { return .unavailable }
            return await accessibility.showCenter(notificationPID: notificationPID, menuPID: menuPID)
        }
    }

    isolated deinit {
        task?.cancel()
        actionTask?.cancel()
        dismissalConfirmationTask?.cancel()
        observation?.cancel()
    }
}

extension ShellNotificationsController {
    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        generation &+= 1
        ShellNotificationTrace.record("provider.listening", fields: "listening=\(listening) generation=\(generation)")
        pending = false
        task?.cancel()
        task = nil
        actionTask?.cancel()
        actionTask = nil
        dismissalConfirmationTask?.cancel()
        dismissalConfirmationTask = nil
        if listening {
            observation = ShellDirectoryObservation { [weak self] in self?.refresh(.filesystem) }
            refresh(.initial)
        } else {
            observation?.cancel()
            observation = nil
            current = ShellNotificationsData(state: "loading")
            dispatched.removeAll(keepingCapacity: true)
            keptIDs.removeAll(keepingCapacity: true)
        }
    }

    func refresh(_ reason: RefreshReason = .manual) {
        ShellNotificationTrace.record(
            "read.request", fields: "source=\(reason.rawValue) listening=\(isListening) inFlight=\(task != nil)"
        )
        guard isListening else { return }
        observation?.sync(
            paths: Self.observedPaths(at: url, preferencesURL: preferencesURL),
            recursivePaths: [url.deletingLastPathComponent(), preferencesURL.deletingLastPathComponent()]
        )
        guard task == nil else {
            pending = true
            ShellNotificationTrace.record(
                "read.coalesced",
                fields: "source=\(reason.rawValue) generation=\(generation)"
            )
            return
        }
        let generation = self.generation
        readSequence &+= 1
        let sequence = readSequence
        let startedAt = now()
        let revision = self.revision()
        let start = ProcessInfo.processInfo.systemUptime
        ShellNotificationTrace.record(
            "read.start", fields: "read=\(sequence) source=\(reason.rawValue) generation=\(generation)"
        )
        task = Task { [weak self, load, url] in
            let next = await load(url)
            guard !Task.isCancelled, let self, isListening, self.generation == generation else {
                ShellNotificationTrace.record("read.discarded", fields: "read=\(sequence) generation=\(generation)")
                return
            }
            task = nil
            completeRead(next, reason: reason, start: start, revision: revision, startedAt: startedAt)
        }
    }

    private func completeRead(
        _ value: ShellNotificationsData, reason: RefreshReason, start: TimeInterval,
        revision: StorageRevision, startedAt: SuspendingClock.Instant
    ) {
        var next = value
        let retainedBundles = Set(value.items.compactMap { $0.fields?["bundle"]?.string })
        next.apps = value.apps.map { app in
            guard var fields = app.fields, let bundle = fields["bundle"]?.string,
                  retainedBundles.contains(bundle), fields["name"]?.string?.isEmpty != false
            else { return app }
            let name: String
            if let cached = appNames[bundle] {
                name = cached
            } else {
                if let resolved = resolveName(bundle), !resolved.isEmpty { name = resolved }
                else { name = bundle }
                appNames[bundle] = name
            }
            guard name != bundle else { return app }
            fields["name"] = .text(name)
            return .object(fields)
        }
        next.action = current.action
        next.dismissAll = current.dismissAll
        reconcileDispatched(into: &next, revision: revision, startedAt: startedAt)
        let changed = current != next
        let duration = ProcessInfo.processInfo.systemUptime - start
        lastRead = ReadDiagnostics(reason: reason, completed: Date(), duration: duration, changed: changed)
        ShellNotificationTrace.record(
            "read.complete", fields: "read=\(readSequence) generation=\(generation) source=\(reason.rawValue)"
                + " durationMs=\(Int(duration * 1000)) changed=\(changed) \(ShellNotificationTrace.snapshotSummary(next))"
        )
        if changed {
            current = next
            onChange?(next)
        }
        if pending {
            pending = false
            refresh(.coalesced)
        }
    }

    private func reconcileDispatched(
        into next: inout ShellNotificationsData, revision: StorageRevision, startedAt: SuspendingClock.Instant
    ) {
        let hadDispatched = !dispatched.isEmpty
        var restored = Set<UUID>()
        if next.membershipComplete, hadDispatched || !keptIDs.isEmpty {
            let retained = Set(next.items.compactMap { $0.fields?["id"]?.string.flatMap(UUID.init(uuidString:)) })
            let stable = hadDispatched && revision == self.revision()
            for (id, deadline) in dispatched {
                if !retained.contains(id) {
                    dispatched.removeValue(forKey: id)
                } else if stable, startedAt >= deadline {
                    dispatched.removeValue(forKey: id)
                    restored.insert(id)
                }
            }
            keptIDs.formIntersection(retained)
            keptIDs.formUnion(restored)
        }
        next.dispatched = dispatched.keys.map { $0.uuidString.lowercased() }.sorted()
        next.kept = keptIDs.count
        if let action = next.action?.fields, action["kind"]?.string == "dismiss",
           let id = action["id"]?.string.flatMap(UUID.init(uuidString:)), restored.contains(id)
        {
            next.action = nil
        }
        let resolvedDispatches = hadDispatched && dispatched.isEmpty
        if resolvedDispatches {
            dismissalConfirmationTask?.cancel()
            dismissalConfirmationTask = nil
        }
        let empty = next.membershipComplete && next.items.isEmpty
        if empty || resolvedDispatches, next.dismissAll?.fields?["active"] != .bool(true) {
            next.dismissAll = nil
        }
    }

    func hasDispatched(_ id: UUID) -> Bool {
        dispatched[id] != nil
    }

    private func recordDispatched(_ id: UUID) {
        let deadline = now().advanced(by: Self.dismissalPersistenceGrace)
        dispatched[id] = deadline
        current.dispatched = dispatched.keys.map { $0.uuidString.lowercased() }.sorted()
        scheduleDismissalConfirmation(at: deadline)
    }

    private func scheduleDismissalConfirmation(at deadline: SuspendingClock.Instant) {
        dismissalConfirmationTask?.cancel()
        dismissalConfirmationTask = Task { [weak self, sleepUntil] in
            try? await sleepUntil(deadline)
            guard !Task.isCancelled, let self else { return }
            dismissalConfirmationTask = nil
            refresh(.dismissalConfirmation)
        }
    }

    private func clearKept() {
        keptIDs.removeAll(keepingCapacity: true)
        current.kept = 0
    }

    func retainedTarget(
        bundle: String, id: UUID, kind: String
    ) -> (item: [String: ShellServiceValue], peers: Set<UUID>)? {
        let ready = kind == "dismiss" ? current.canDismiss
            : current.complete && (current.state == "ready" || current.state == "empty")
        guard ready else {
            publishAction(
                id: id,
                bundle: bundle,
                kind: kind,
                state: ShellNotificationActionOutcome.unavailable.rawValue
            )
            return nil
        }
        let items = current.items.compactMap(\.fields).filter { $0["bundle"]?.string == bundle }
        let matches = items.filter { $0["id"]?.string.flatMap(UUID.init(uuidString:)) == id }
        guard matches.count == 1, let item = matches.first else {
            let outcome: ShellNotificationActionOutcome = matches.isEmpty ? .notFound : .ambiguous
            publishAction(id: id, bundle: bundle, kind: kind, state: outcome.rawValue)
            return nil
        }
        return (item, Set(items.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }))
    }

    func start(_ request: ShellNotificationActionRequest, kind: String) {
        let generation = self.generation
        actionTask = Task { [weak self, performAction] in
            guard !Task.isCancelled, self?.isListening == true, self?.generation == generation else {
                ShellNotificationTrace.record("action.cancelledBeforeNative", target: request.id)
                return
            }
            ShellNotificationTrace.record(
                "action.native.begin",
                target: request.id,
                fields: "kind=\(kind) generation=\(generation)"
            )
            let outcome = await performAction(request)
            ShellNotificationTrace.record(
                "action.native.end",
                target: request.id,
                fields: "outcome=\(outcome.rawValue) generation=\(generation)"
            )
            guard !Task.isCancelled, let self, isListening, self.generation == generation else {
                ShellNotificationTrace.record(
                    "action.discarded",
                    target: request.id,
                    fields: "generation=\(generation)"
                )
                return
            }
            actionTask = nil
            if outcome == .dispatched || outcome == .dispatchedPanelOpen {
                recordDispatched(request.id)
            }
            publishAction(id: request.id, bundle: request.bundle, kind: kind, state: outcome.rawValue)
            refresh(.action)
        }
        clearKept()
        publishAction(id: request.id, bundle: request.bundle, kind: kind, state: "pending")
    }

    func publishAction(id: UUID, bundle: String, kind: String, state: String) {
        ShellNotificationTrace.record("action.status", target: id, fields: "kind=\(kind) state=\(state)")
        let action: ShellServiceValue = .object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(bundle),
            "kind": .text(kind), "state": .text(state)
        ])
        guard current.action != action else { return }
        current.action = action
        onChange?(current)
    }

    var diagnosticsSummary: String {
        var lines = [
            "listening=\(isListening) generation=\(generation) read=\(readSequence)"
                + " readInFlight=\(task != nil) queued=\(pending) actionInFlight=\(actionTask != nil)",
            ShellNotificationTrace.snapshotSummary(current),
            "detailedCaptureActive=\(ShellNotificationTrace.shared.isActive)"
        ]
        if let lastRead {
            lines.append(
                "lastReadAt=\(lastRead.completed.ISO8601Format()) source=\(lastRead.reason.rawValue)"
                    + " durationMs=\(Int(lastRead.duration * 1000)) changed=\(lastRead.changed)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

extension ShellNotificationsController {
    func dismissAll() -> Bool {
        guard isListening, actionTask == nil else { return false }
        guard current.canDismiss else {
            publishDismissAll(total: current.items.count, state: "failed", outcome: .unavailable)
            return false
        }
        guard let requests = dismissAllRequests() else { return false }
        guard !requests.isEmpty else {
            guard current.items.isEmpty else { return false }
            clearKept()
            publishDismissAll(total: 0, state: "completed", outcome: .dispatched)
            return true
        }
        let generation = self.generation
        actionTask = Task { [weak self, performDismissAll] in
            let outcome: ShellNotificationActionOutcome
            if Task.isCancelled {
                outcome = .cancelled
            } else {
                outcome = await performDismissAll(requests) { [weak self] result in
                    guard let self, isListening, self.generation == generation else { return }
                    let index = Int(current.dismissAll?.fields?["completed"]?.number ?? 0)
                    guard requests.indices.contains(index) else { return }
                    recordDismissAllProgress(result, request: requests[index])
                }
            }
            guard let self, isListening, self.generation == generation else { return }
            actionTask = nil
            finishDismissAll(outcome)
            refresh(.action)
        }
        clearKept()
        publishDismissAll(total: requests.count, active: true, state: "pending")
        return true
    }

    private func dismissAllRequests() -> [ShellNotificationActionRequest]? {
        var targets: [(bundle: String, id: UUID)] = []
        var peers: [String: Set<UUID>] = [:]
        var identifiers = Set<UUID>()
        for value in current.items {
            guard let item = value.fields, let bundle = item["bundle"]?.string,
                  ShellNotificationsCommand.validBundle(bundle),
                  let id = item["id"]?.string.flatMap(UUID.init(uuidString:))
            else {
                publishDismissAll(total: current.items.count, state: "failed", outcome: .unavailable)
                return nil
            }
            guard identifiers.insert(id).inserted else {
                publishDismissAll(total: current.items.count, state: "failed", outcome: .ambiguous)
                return nil
            }
            if dispatched[id] == nil { targets.append((bundle, id)) }
            peers[bundle, default: []].insert(id)
        }
        return targets.map {
            ShellNotificationActionRequest(
                bundle: $0.bundle,
                id: $0.id,
                peers: peers[$0.bundle] ?? [],
                operation: .dismiss
            )
        }
    }

    func cancelDismissAll() -> Bool {
        guard isListening, current.dismissAll?.fields?["active"] == .bool(true), let actionTask else { return false }
        actionTask.cancel()
        updateDismissAll(state: "cancelling")
        return true
    }

    private func recordDismissAllProgress(
        _ outcome: ShellNotificationActionOutcome, request: ShellNotificationActionRequest
    ) {
        guard var fields = current.dismissAll?.fields, fields["active"] == .bool(true) else { return }
        fields["completed"] = .number((fields["completed"]?.number ?? 0) + 1)
        if outcome == .dispatched || outcome == .dispatchedPanelOpen {
            recordDispatched(request.id)
        } else {
            fields["failed"] = .number((fields["failed"]?.number ?? 0) + 1)
        }
        current.dismissAll = .object(fields)
        ShellNotificationTrace.record("batch.progress", fields: "outcome=\(outcome.rawValue)")
        onChange?(current)
    }

    private func finishDismissAll(_ outcome: ShellNotificationActionOutcome) {
        let fields = current.dismissAll?.fields ?? [:]
        let complete = fields["completed"] == fields["total"]
        let failed = fields["failed"]?.number ?? 0
        let state: String
        switch outcome {
        case .cancelled: state = "cancelled"
        case .failedPanelOpen where fields["state"]?.string == "cancelling": state = "cancelled"
        case .dispatched where complete,
             .dispatchedPanelOpen where complete: state = failed == 0 ? "completed" : "partial"
        default: state = "failed"
        }
        updateDismissAll(active: false, state: state, outcome: outcome)
    }

    private func updateDismissAll(active: Bool? = nil, state: String, outcome: ShellNotificationActionOutcome? = nil) {
        guard var fields = current.dismissAll?.fields else { return }
        if let active { fields["active"] = .bool(active) }
        fields["state"] = .text(state)
        if let outcome { fields["outcome"] = .text(outcome.rawValue) }
        current.dismissAll = .object(fields)
        ShellNotificationTrace.record("batch.status", fields: "state=\(state)")
        onChange?(current)
    }

    private func publishDismissAll(
        total: Int, active: Bool = false, state: String, outcome: ShellNotificationActionOutcome? = nil
    ) {
        current.dismissAll = .object([
            "total": .number(Double(total)), "completed": .number(0), "failed": .number(0),
            "active": .bool(active), "state": .text(state), "outcome": outcome.map { .text($0.rawValue) } ?? .null
        ])
        ShellNotificationTrace.record("batch.status", fields: "state=\(state) total=\(total)")
        onChange?(current)
    }
}
