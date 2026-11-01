// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellNotificationsController {
    @discardableResult
    func perform(_ command: ShellNotificationsCommand) -> Bool {
        if command == .dismissAll { return dismissAll() }
        if command == .cancelDismissAll { return cancelDismissAll() }
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
             .open,
             .dismissAll,
             .cancelDismissAll:
            return false
        }
        ShellNotificationTrace.record(
            "action.request", target: id,
            fields: "kind=\(kind) bundle=\(bundle) generation=\(generation) listening=\(isListening) busy=\(actionTask != nil)"
        )
        guard isListening, actionTask == nil, !hasDispatched(id) else {
            ShellNotificationTrace.record(
                "action.rejected",
                target: id,
                fields: "reason=\(isListening ? "busy" : "stopped")"
            )
            return false
        }
        guard let target = retainedTarget(bundle: bundle, id: id, kind: kind) else { return false }
        guard let operation = nativeOperation(for: command, item: target.item, bundle: bundle, id: id)
        else { return false }
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

    private func nativeOperation(
        for command: ShellNotificationsCommand,
        item: [String: ShellServiceValue],
        bundle: String,
        id: UUID
    ) -> ShellNotificationActionRequest.Operation? {
        if case let .reply(_, _, text) = command {
            return replyOperation(text: text, item: item, bundle: bundle, id: id)
        }
        return .dismiss
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
}
