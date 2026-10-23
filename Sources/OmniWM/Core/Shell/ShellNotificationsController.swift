// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum ShellNotificationsCommand: Equatable, Sendable {
    case refresh
    case open(bundle: String)
    case dismiss(bundle: String, id: UUID)
    case reply(bundle: String, id: UUID, text: String)

    init?(words: [String]) {
        if words == ["refresh"] {
            self = .refresh
        } else if words.count == 2, words[0] == "open", Self.validBundle(words[1]) {
            self = .open(bundle: words[1])
        } else if words.count == 3, words[0] == "dismiss", Self.validBundle(words[1]),
                  let id = Self.identifier(words[2])
        {
            self = .dismiss(bundle: words[1], id: id)
        } else if words.count == 4, words[0] == "reply", Self.validBundle(words[1]),
                  let id = Self.identifier(words[2]), let text = Self.replyText(words[3])
        {
            self = .reply(bundle: words[1], id: id, text: text)
        } else {
            return nil
        }
    }

    private static func validBundle(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func identifier(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), value.lowercased() == id.uuidString.lowercased() else { return nil }
        return id
    }

    private static func replyText(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 8192, value.utf8.count.isMultiple(of: 2) else { return nil }
        let hex = Array(value.utf8)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48 ... 57: byte - 48
            case 65 ... 70: byte - 55
            case 97 ... 102: byte - 87
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        guard let text = String(bytes: bytes, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}

private actor ShellNotificationsWorker {
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.notifications", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func read(at url: URL) -> ShellNotificationsData {
        ShellNotificationStore.read(at: url)
    }
}

@MainActor
final class ShellNotificationsController {
    enum RefreshReason: String {
        case manual
        case initial
        case filesystem
        case action
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

    private let url: URL
    private let load: Loader
    private let performAction: ActionPerformer
    private var observation: ShellDirectoryObservation?
    private(set) var task: Task<Void, Never>?
    private(set) var actionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pending = false
    private var readSequence: UInt64 = 0
    private var lastRead: ReadDiagnostics?
    private(set) var isListening = false
    private(set) var current = ShellNotificationsData(state: "loading")
    var onChange: (@MainActor (ShellNotificationsData) -> Void)?

    init(url: URL = ShellNotificationStore.defaultURL, load: Loader? = nil, perform: ActionPerformer? = nil) {
        self.url = url
        let worker = ShellNotificationsWorker()
        self.load = load ?? { await worker.read(at: $0) }
        let accessibility = ShellNotificationAccessibility()
        performAction = perform ?? { request in
            guard let notificationPID = NSRunningApplication.runningApplications(
                      withBundleIdentifier: "com.apple.notificationcenterui"
                  ).first?.processIdentifier,
                  let menuPID = NSRunningApplication.runningApplications(
                      withBundleIdentifier: "com.apple.MenuBarAgent"
                  ).first?.processIdentifier
            else {
                ShellNotificationTrace.record("native.processes.missing", target: request.id)
                return .unavailable
            }
            return await accessibility.perform(request, notificationPID: notificationPID, menuPID: menuPID)
        }
    }

    isolated deinit {
        task?.cancel()
        actionTask?.cancel()
        observation?.cancel()
    }

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
        if listening {
            observation = ShellDirectoryObservation { [weak self] in self?.refresh(.filesystem) }
            refresh(.initial)
        } else {
            observation?.cancel()
            observation = nil
            current = ShellNotificationsData(state: "loading")
        }
    }

    func refresh(_ reason: RefreshReason = .manual) {
        ShellNotificationTrace.record(
            "read.request", fields: "source=\(reason.rawValue) listening=\(isListening) inFlight=\(task != nil)"
        )
        guard isListening else { return }
        let directory = url.deletingLastPathComponent()
        observation?.sync(paths: [
            directory.deletingLastPathComponent(),
            directory,
            url,
            URL(fileURLWithPath: url.path + "-wal")
        ])
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
            completeRead(next, reason: reason, start: start)
        }
    }

    private func completeRead(_ value: ShellNotificationsData, reason: RefreshReason, start: TimeInterval) {
        var next = value
        next.action = current.action
        let changed = current != next
        let duration = ProcessInfo.processInfo.systemUptime - start
        lastRead = ReadDiagnostics(reason: reason, completed: Date(), duration: duration, changed: changed)
        ShellNotificationTrace.record(
            "read.complete", fields: "read=\(readSequence) generation=\(generation) source=\(reason.rawValue)"
                + " durationMs=\(Int(duration * 1000)) changed=\(changed) \(Self.snapshotSummary(next))"
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

    @discardableResult
    func perform(_ command: ShellNotificationsCommand) -> Bool {
        let bundle: String
        let id: UUID
        let kind: String
        switch command {
        case let .dismiss(source, identifier):
            bundle = source
            id = identifier
            kind = "dismiss"
        case let .reply(source, identifier, _):
            bundle = source
            id = identifier
            kind = "reply"
        case .refresh,
             .open:
            return false
        }
        ShellNotificationTrace.record(
            "action.request", target: id,
            fields: "kind=\(kind) bundle=\(bundle) generation=\(generation) listening=\(isListening) busy=\(actionTask != nil)"
        )
        guard isListening, actionTask == nil else {
            ShellNotificationTrace.record(
                "action.rejected",
                target: id,
                fields: "reason=\(isListening ? "busy" : "stopped")"
            )
            return false
        }
        guard let target = retainedTarget(bundle: bundle, id: id, kind: kind) else { return false }
        let operation: ShellNotificationActionRequest.Operation
        if case let .reply(_, _, text) = command {
            guard let reply = replyOperation(text: text, item: target.item, bundle: bundle, id: id)
            else { return false }
            operation = reply
        } else {
            operation = .dismiss
        }
        let request = ShellNotificationActionRequest(
            bundle: bundle,
            id: id,
            peers: target.peers,
            operation: operation
        )
        ShellNotificationTrace.record(
            "action.accepted",
            target: id,
            fields: "kind=\(kind) peers=\(request.peers.count)"
        )
        start(request, kind: kind)
        return true
    }

    private func retainedTarget(
        bundle: String, id: UUID, kind: String
    ) -> (item: [String: ShellServiceValue], peers: Set<UUID>)? {
        guard current.complete, current.state == "ready" || current.state == "empty" else {
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

    private func start(_ request: ShellNotificationActionRequest, kind: String) {
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
            publishAction(id: request.id, bundle: request.bundle, kind: kind, state: outcome.rawValue)
            refresh(.action)
        }
        publishAction(id: request.id, bundle: request.bundle, kind: kind, state: "pending")
    }

    private func replyOperation(
        text: String,
        item: [String: ShellServiceValue],
        bundle: String,
        id: UUID
    ) -> ShellNotificationActionRequest.Operation? {
        let actions = item["actions"]?.values?.compactMap(\.fields) ?? []
        let replies = actions.filter {
            $0["title"]?.string?.isEmpty == false && $0["textInputButtonTitle"]?.string?.isEmpty == false
        }
        guard replies.count == 1, let reply = replies.first, let title = reply["title"]?.string,
              let sendTitle = reply["textInputButtonTitle"]?.string
        else {
            let outcome: ShellNotificationActionOutcome = replies.isEmpty ? .unsupported : .ambiguous
            publishAction(id: id, bundle: bundle, kind: "reply", state: outcome.rawValue)
            return nil
        }
        guard actions.filter({ $0["title"]?.string == title }).count == 1 else {
            publishAction(
                id: id,
                bundle: bundle,
                kind: "reply",
                state: ShellNotificationActionOutcome.ambiguous.rawValue
            )
            return nil
        }
        return .reply(text: text, title: title, sendTitle: sendTitle)
    }

    private func publishAction(id: UUID, bundle: String, kind: String, state: String) {
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
            Self.snapshotSummary(current),
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

    private static func snapshotSummary(_ value: ShellNotificationsData) -> String {
        var summary = "state=\(value.state) complete=\(value.complete) items=\(value.items.count) apps=\(value.apps.count)"
        if let action = value.action?.fields, let id = action["id"]?.string {
            let target = UUID(uuidString: id)
            let retained = target != nil && value.items.contains {
                $0.fields?["id"]?.string.flatMap(UUID.init(uuidString:)) == target
                    && $0.fields?["bundle"]?.string == action["bundle"]?.string
            }
            summary += " action=\(action["kind"]?.string ?? "none") outcome=\(action["state"]?.string ?? "none")"
                + " target=\(id) targetRetained=\(value.complete ? String(retained) : "unknown")"
        }
        return summary
    }
}
