// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ShellNotificationReadIssue: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable {
        case membership
        case metadata
    }

    enum Reason: String, Hashable, Sendable {
        case rowLimit
        case byteLimit
        case encodingLimit
        case notificationLimit
        case missingRecord
        case identifierMismatch
        case duplicateIdentifier
        case invalidMembership
        case invalidRecord
        case invalidApp
        case decodeLimit
        case invalidMetadata
        case unsupportedText
    }

    let scope: Scope
    let reason: Reason
}

struct ShellNotificationsData: Equatable, Sendable, ShellValueWritable {
    let state: String
    let items: [ShellServiceValue]
    var apps: [ShellServiceValue]
    let membershipComplete: Bool
    let metadataComplete: Bool
    let issues: [ShellNotificationReadIssue]
    let error: String?
    var action: ShellServiceValue?
    var dismissAll: ShellServiceValue?
    var dispatched: [String]
    var kept: Int

    var complete: Bool {
        membershipComplete && metadataComplete
    }

    var canDismiss: Bool {
        membershipComplete && (state == "ready" || state == "empty" || state == "incomplete")
    }

    init(
        state: String,
        items: [ShellServiceValue] = [],
        apps: [ShellServiceValue] = [],
        complete: Bool = true,
        membershipComplete: Bool? = nil,
        metadataComplete: Bool? = nil,
        issues: [ShellNotificationReadIssue] = [],
        error: String? = nil,
        action: ShellServiceValue? = nil,
        dismissAll: ShellServiceValue? = nil,
        dispatched: [String] = [],
        kept: Int = 0
    ) {
        self.state = state
        self.items = items
        self.apps = apps
        self.membershipComplete = membershipComplete ?? complete
        self.metadataComplete = metadataComplete ?? complete
        self.issues = issues.sorted {
            $0.scope == $1.scope ? $0.reason.rawValue < $1.reason.rawValue : $0.scope.rawValue < $1.scope.rawValue
        }
        self.error = error
        self.action = action
        self.dismissAll = dismissAll
        self.dispatched = dispatched
        self.kept = kept
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(11)
        writer.key("state")
        writer.string(state)
        writer.key("complete")
        writer.bool(complete)
        writer.key("membershipComplete")
        writer.bool(membershipComplete)
        writer.key("metadataComplete")
        writer.bool(metadataComplete)
        writer.key("items")
        ShellServiceValue.array(items).write(to: &writer)
        writer.key("apps")
        ShellServiceValue.array(apps).write(to: &writer)
        writer.key("error")
        error.map { writer.string($0) } ?? writer.null()
        writer.key("action")
        (action ?? .null).write(to: &writer)
        writer.key("dismissAll")
        (dismissAll ?? .null).write(to: &writer)
        writer.key("dispatched")
        ShellServiceValue.array(dispatched.map(ShellServiceValue.text)).write(to: &writer)
        writer.key("kept")
        writer.number(Double(kept))
    }
}
