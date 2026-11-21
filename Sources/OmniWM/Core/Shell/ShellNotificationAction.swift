// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellNotificationActionRequest: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case dismiss
        case reply(text: String, title: String, sendTitle: String)
    }

    let bundle: String
    let id: UUID
    let peers: Set<UUID>
    let operation: Operation
}

enum ShellNotificationActionOutcome: String, Sendable {
    case dispatched
    case dispatchedPanelOpen
    case notFound
    case historyClosed
    case denied
    case unavailable
    case ambiguous
    case unsupported
    case failed
    case failedPanelOpen
    case cancelled
    case timeout
}

enum ShellNotificationAction {
    static func dismiss<Target>(
        resolve: () throws -> Target,
        actions: (Target) throws -> [String],
        press: (Target, String) throws -> Bool
    ) throws -> ShellNotificationActionOutcome {
        let target = try resolve()
        var close: String?
        for action in try actions(target) where action.hasPrefix("Name:Close\n") {
            guard close == nil else { return .ambiguous }
            close = action
        }
        guard let close else { return .unsupported }
        return try press(target, close) ? .dispatched : .failed
    }

    static func clearStack(actions: () throws -> [String]?, press: (String) throws -> Bool) rethrows -> Bool {
        guard let names = try actions() else { return false }
        let clearAll = names.filter { $0.split(separator: "\n", maxSplits: 1).first == "Name:Clear All" }
        guard clearAll.count == 1 else { return false }
        return try press(clearAll[0])
    }
}
