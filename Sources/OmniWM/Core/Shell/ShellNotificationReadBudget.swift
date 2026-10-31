// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ShellNotificationReadBudget {
    static let readRowLimit = 20_000
    static let readByteLimit = 4 << 20
    static let valueByteLimit = 2 << 20

    typealias Scope = ShellNotificationReadIssue.Scope
    typealias Reason = ShellNotificationReadIssue.Reason

    enum IdentityTable {
        case app, record
    }

    private struct ReadLimits {
        var rows = ShellNotificationReadBudget.readRowLimit
        var bytes = ShellNotificationReadBudget.readByteLimit
    }

    private var reads: [Scope: ReadLimits] = [:]
    private var identityRows: [IdentityTable: Int] = [:]
    private var identityBytes = Self.readByteLimit
    private var encoded = 3 << 20
    private(set) var issues = Set<ShellNotificationReadIssue>()

    var membershipComplete: Bool {
        !issues.contains { $0.scope == .membership }
    }

    var metadataComplete: Bool {
        !issues.contains { $0.scope == .metadata }
    }

    var complete: Bool {
        membershipComplete && metadataComplete
    }

    var malformed: Bool {
        issues.contains {
            $0.scope == .membership && [.invalidMembership, .invalidRecord, .invalidApp, .duplicateIdentifier]
                .contains($0.reason)
        }
    }

    mutating func mark(_ reason: Reason, scope: Scope = .membership) {
        issues.insert(ShellNotificationReadIssue(scope: scope, reason: reason))
    }

    mutating func acceptRow(scope: Scope) -> Bool {
        var limits = reads[scope, default: ReadLimits()]
        guard limits.rows > 0 else {
            mark(.rowLimit, scope: scope)
            return false
        }
        limits.rows -= 1
        reads[scope] = limits
        return true
    }

    mutating func acceptBytes(_ count: Int, scope: Scope) -> Bool {
        var limits = reads[scope, default: ReadLimits()]
        guard count <= Self.valueByteLimit, count <= limits.bytes else {
            mark(.byteLimit, scope: scope)
            return false
        }
        limits.bytes -= count
        reads[scope] = limits
        return true
    }

    mutating func acceptIdentityRow(_ table: IdentityTable) -> Bool {
        let remaining = identityRows[table, default: Self.readRowLimit]
        guard remaining > 0 else {
            mark(.rowLimit)
            return false
        }
        identityRows[table] = remaining - 1
        return true
    }

    mutating func acceptIdentityBytes(_ count: Int) -> Bool {
        guard count <= identityBytes else {
            mark(.byteLimit)
            return false
        }
        identityBytes -= count
        return true
    }

    mutating func includeMetadata(_ value: ShellServiceValue, replacing old: ShellServiceValue? = nil) -> Bool {
        let count = ShellNotificationMetadata.encodedSize(value) - (old.map(ShellNotificationMetadata.encodedSize) ?? 0)
        guard count <= encoded else {
            mark(.encodingLimit, scope: .metadata)
            return false
        }
        encoded -= count
        return true
    }

    mutating func packMembers(_ values: [ShellServiceValue]) -> [ShellServiceValue] {
        var originals: [[String: ShellServiceValue]] = []
        var packed: [[String: ShellServiceValue]] = []
        for value in values {
            guard let fields = value.fields else {
                mark(.invalidRecord)
                continue
            }
            var member = fields.mapValues { _ in ShellServiceValue.null }
            member["id"] = fields["id"]
            member["bundle"] = fields["bundle"]
            for key in ["title", "subtitle", "body"] { member[key] = .text("") }
            for key in ["attachments", "actions"] { member[key] = .array([]) }
            let count = ShellNotificationMetadata.encodedSize(.object(member))
            guard count <= encoded else {
                mark(.encodingLimit)
                continue
            }
            encoded -= count
            originals.append(fields)
            packed.append(member)
        }
        addDetails(originals, to: &packed)
        return packed.map(ShellServiceValue.object)
    }

    private mutating func addDetails(
        _ originals: [[String: ShellServiceValue]], to packed: inout [[String: ShellServiceValue]]
    ) {
        for key in [
            "title", "subtitle", "body", "date", "actions", "requestId", "thread", "category", "attachments",
            "userInfo", "communication", "metadata"
        ] {
            for index in originals.indices {
                guard let value = originals[index][key],
                      includeMetadata(value, replacing: packed[index][key]) else { continue }
                packed[index][key] = value
            }
        }
    }
}
