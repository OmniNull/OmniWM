// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import SQLite3

extension ShellNotificationStore {
    struct RecordIdentity {
        let bytes: Data
        let id: String
    }

    enum Column {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case record(identity: RecordIdentity, payload: Data?)

        var value: ShellServiceValue {
            switch self {
            case .null: .null
            case let .integer(value): ShellNotificationMetadata.integer(value)
            case let .real(value): .number(value)
            case let .text(value): .text(value)
            case let .blob(value): ShellNotificationMetadata.opaque(value)
            case let .record(_, bytes): bytes.map(ShellNotificationMetadata.opaque) ?? .null
            }
        }

        var integer: Int64? {
            if case let .integer(value) = self { value } else { nil }
        }

        var text: String? {
            if case let .text(value) = self { value } else { nil }
        }

        var blob: Data? {
            if case let .blob(value) = self { value } else { nil }
        }
    }

    static func rows(
        _ sql: String,
        _ database: OpaquePointer,
        _ budget: inout ShellNotificationReadBudget,
        memberColumns: Set<String> = [],
        memberApps: Set<Int64>? = nil,
        retained: [Int64: Set<String>]? = nil
    ) throws -> [[String: Column]] {
        let statement = try prepare(sql, database)
        defer { sqlite3_finalize(statement) }
        var result: [[String: Column]] = []
        let names = (0 ..< sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Failure.query }
            if memberApps != nil, !budget.acceptIdentityRow(.app) { return result }
            if retained != nil, !budget.acceptIdentityRow(.record) { return result }
            var identity: RecordIdentity?
            if let retained {
                identity = recordIdentity(statement, names: names, retained: retained, budget: &budget)
                if identity == nil { continue }
            }
            let member = !memberColumns.isEmpty && isMember(
                statement, names: names, apps: memberApps
            )
            let scope: ShellNotificationReadIssue.Scope = member ? .membership : .metadata
            guard budget.acceptRow(scope: scope) else {
                if scope == .membership || memberColumns.isEmpty { return result }
                continue
            }
            if let row = row(
                statement, names: names, budget: &budget, memberColumns: member ? memberColumns : [], identity: identity
            ) {
                result.append(row)
            }
        }
    }

    private static func prepare(_ sql: String, _ database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.query }
        return statement
    }

    private static func isMember(
        _ statement: OpaquePointer, names: [String], apps: Set<Int64>?
    ) -> Bool {
        guard let apps, let appIndex = names.firstIndex(of: "app_id") else { return true }
        return apps.contains(sqlite3_column_int64(statement, Int32(appIndex)))
    }

    private static func recordIdentity(
        _ statement: OpaquePointer, names: [String], retained: [Int64: Set<String>],
        budget: inout ShellNotificationReadBudget
    ) -> RecordIdentity? {
        guard let appIndex = names.firstIndex(of: "app_id"), let uuidIndex = names.firstIndex(of: "uuid"),
              let dataIndex = names.firstIndex(of: "data")
        else {
            budget.mark(.invalidRecord)
            return nil
        }
        let appID = sqlite3_column_int64(statement, Int32(appIndex))
        guard let members = retained[appID] else { return nil }
        let index = Int32(uuidIndex)
        var columnID: Data?
        if sqlite3_column_type(statement, index) == SQLITE_BLOB, sqlite3_column_bytes(statement, index) == 16,
           let pointer = sqlite3_column_blob(statement, index) { columnID = Data(bytes: pointer, count: 16) }
        let retainedColumn = columnID.flatMap(ShellNotificationMetadata.guid).map(members.contains) ?? false
        guard let identity = payloadIdentity(
            statement, index: Int32(dataIndex), required: retainedColumn, budget: &budget
        ) else { return nil }
        let retainedRoot = members.contains(identity.id)
        if retainedColumn || retainedRoot, columnID != identity.bytes { budget.mark(.identifierMismatch) }
        return retainedRoot ? identity : nil
    }

    private static func payloadIdentity(
        _ statement: OpaquePointer, index: Int32, required: Bool, budget: inout ShellNotificationReadBudget
    ) -> RecordIdentity? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else {
            if required { budget.mark(.invalidRecord) }
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard budget.acceptIdentityBytes(count) else { return nil }
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            if required { budget.mark(.invalidRecord) }
            return nil
        }
        // The borrowed payload is used only while SQLite owns this row's bytes.
        let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: count, deallocator: .none)
        guard let identity = rootIdentity(in: bytes) else {
            if required { budget.mark(.invalidRecord) }
            return nil
        }
        return identity
    }

    private static func row(
        _ statement: OpaquePointer,
        names: [String],
        budget: inout ShellNotificationReadBudget,
        memberColumns: Set<String>,
        identity: RecordIdentity?
    ) -> [String: Column]? {
        var row: [String: Column] = [:]
        var accepted = true
        for (index, name) in names.enumerated() {
            let scope: ShellNotificationReadIssue.Scope = memberColumns.contains(name) ? .membership : .metadata
            do {
                if let value = try column(statement, index: Int32(index), budget: &budget, scope: scope) {
                    row[name] = value
                } else if scope == .membership { accepted = false }
            } catch {
                budget.mark(scope == .membership ? .invalidRecord : .invalidMetadata, scope: scope)
                if scope == .membership { accepted = false }
            }
        }
        if let identity { row["data"] = .record(identity: identity, payload: row["data"]?.blob) }
        return accepted ? row : nil
    }

    private static func column(
        _ statement: OpaquePointer, index: Int32, budget: inout ShellNotificationReadBudget,
        scope: ShellNotificationReadIssue.Scope
    ) throws -> Column? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, index)
            guard value.isFinite else { throw Failure.malformed(.invalidRecord) }
            return .real(value)
        default:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard budget.acceptBytes(count, scope: scope) else { return nil }
            if sqlite3_column_type(statement, index) == SQLITE_TEXT {
                guard let value = sqlite3_column_text(statement, index), let text = String(
                    data: Data(bytes: value, count: count),
                    encoding: .utf8
                ) else { throw Failure.malformed(.invalidRecord) }
                return .text(text)
            }
            let pointer = sqlite3_column_blob(statement, index)
            guard count == 0 || pointer != nil else { throw Failure.malformed(.invalidRecord) }
            return .blob(pointer.map { Data(bytes: $0, count: count) } ?? Data())
        }
    }
}
