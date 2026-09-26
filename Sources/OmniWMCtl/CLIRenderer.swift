// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIOutputDestination: Equatable {
    case standardOutput
    case standardError

    var handle: FileHandle {
        switch self {
        case .standardOutput:
            FileHandle.standardOutput
        case .standardError:
            FileHandle.standardError
        }
    }
}

struct CLIRenderedOutput: Equatable {
    let data: Data
    let destination: CLIOutputDestination
}

enum CLILocalErrorCode: String, Codable, Equatable, Sendable {
    case invalidArguments = "invalid_arguments"
    case transportFailure = "transport_failure"
    case internalError = "internal_error"
}

struct CLILocalFailureEnvelope: Codable, Equatable, Sendable {
    let ok: Bool
    let source: String
    let status: IPCResponseStatus
    let code: CLILocalErrorCode
    let message: String
    let exitCode: Int32

    init(code: CLILocalErrorCode, message: String, exitCode: CLIExitCode) {
        ok = false
        source = "cli"
        status = .error
        self.code = code
        self.message = message
        self.exitCode = exitCode.rawValue
    }
}

enum CLIRenderer {
    static func exitCode(for response: IPCResponse) -> CLIExitCode {
        guard !response.ok else { return .success }

        switch response.code {
        case .internalError:
            return .internalError
        case .disabled,
             .overviewOpen,
             .layoutMismatch,
             .protocolMismatch,
             .unauthorized,
             .staleWindowId,
             .notFound,
             .noChange,
             .windowActionFailed,
             .workspaceAssignmentConflict,
             .workspaceStateConflict,
             .captureStateConflict,
             .staleMark,
             .unknownMark,
             .noFocusedWindow,
             .selfSummon,
             .hiddenWindow,
             .unsupportedLayout,
             .duplicateMark,
             .invalidMark,
             .invalidArguments,
             .invalidRequest,
             .none:
            return .rejected
        }
    }

    static func responseOutput(_ response: IPCResponse, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        if format.prefersJSON {
            return CLIRenderedOutput(
                data: try IPCWire.encodeResponseLine(response, prettyPrinted: format.prettyPrintsJSON),
                destination: .standardOutput
            )
        }

        return CLIRenderedOutput(
            data: Data((formattedResponseText(response, format: format) + "\n").utf8),
            destination: .standardOutput
        )
    }

    static func eventOutput(_ event: IPCEventEnvelope, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        CLIRenderedOutput(
            data: try IPCWire.encodeEventLine(event, prettyPrinted: format.prettyPrintsJSON),
            destination: .standardOutput
        )
    }

    static func parseErrorOutput(_ error: CLIParseError, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        switch error {
        case let .usage(text):
            return try localFailureOutput(
                code: .invalidArguments,
                message: text,
                exitCode: .invalidArguments,
                format: format
            )
        }
    }

    static func transportErrorOutput(_ error: Error, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        try localFailureOutput(
            code: .transportFailure,
            message: "omniwmctl: \(error)",
            exitCode: .transportFailure,
            format: format
        )
    }

    static func internalErrorOutput(_ error: Error, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        try localFailureOutput(
            code: .internalError,
            message: "omniwmctl: \(error)",
            exitCode: .internalError,
            format: format
        )
    }

    static func write(_ output: CLIRenderedOutput) {
        output.destination.handle.write(output.data)
    }

    private static func localFailureOutput(
        code: CLILocalErrorCode,
        message: String,
        exitCode: CLIExitCode,
        format: CLIOutputFormat
    ) throws -> CLIRenderedOutput {
        if format.prefersJSON {
            let envelope = CLILocalFailureEnvelope(code: code, message: message, exitCode: exitCode)
            return CLIRenderedOutput(
                data: try encodeLocalEnvelope(envelope, prettyPrinted: format.prettyPrintsJSON),
                destination: .standardOutput
            )
        }

        let text = message.hasSuffix("\n") ? message : message + "\n"
        return CLIRenderedOutput(data: Data(text.utf8), destination: .standardError)
    }

    private static func formattedResponseText(_ response: IPCResponse, format: CLIOutputFormat) -> String {
        guard response.ok else {
            let status = humanReadableStatus(for: response)
            guard let result = response.result,
                  case let .capture(capture) = result.payload
            else { return status }
            return "\(status)\n\(CLIDiagnosticsRenderer.formattedCapture(capture, format: format))"
        }
        guard let result = response.result else { return humanReadableStatus(for: response) }

        switch result.payload {
        case let .pong(pong):
            return pong.message
        case let .version(version):
            return humanReadableVersion(version)
        case let .workspaceBar(payload):
            return "workspace-bar monitors: \(payload.monitors.count)"
        case let .activeWorkspace(payload):
            return CLIStateRenderer.formattedActiveWorkspace(payload, format: format)
        case let .focusedMonitor(payload):
            return CLIStateRenderer.formattedFocusedMonitor(payload, format: format)
        case let .apps(payload):
            return CLIStateRenderer.formatAppSummary(payload.apps, format: format)
        case let .focusedWindow(payload):
            return CLIStateRenderer.formattedFocusedWindow(payload, format: format)
        case let .windows(payload):
            return CLIStateRenderer.formattedWindows(payload, format: format)
        case let .workspaces(payload):
            return CLIStateRenderer.formattedWorkspaces(payload, format: format)
        case let .displays(payload):
            return CLIStateRenderer.formattedDisplays(payload, format: format)
        case let .rules(payload):
            return CLIStateRenderer.formattedRules(payload, format: format)
        case let .ruleActions(payload):
            return formattedRuleActions(payload, format: format)
        case let .queries(payload):
            return formattedQueries(payload, format: format)
        case let .commands(payload):
            return formattedCommands(payload, format: format)
        case let .subscriptions(payload):
            return formattedSubscriptions(payload, format: format)
        case let .capabilities(payload):
            return formattedCapabilities(payload, format: format)
        case let .capture(payload):
            return CLIDiagnosticsRenderer.formattedCapture(payload, format: format)
        case let .subscribed(payload):
            return "subscribed: \(payload.channels.map(\.rawValue).joined(separator: ", "))"
        case let .metrics(payload):
            return CLIDiagnosticsRenderer.formattedMetrics(payload, format: format)
        case let .windowMarks(payload):
            return formattedWindowMarks(payload, format: format)
        }
    }

    private static func humanReadableStatus(for response: IPCResponse) -> String {
        if response.ok {
            return response.status.rawValue
        }

        if response.code == .protocolMismatch,
           let result = response.result,
           case let .version(version) = result.payload
        {
            return "error: protocol_mismatch (server protocol \(version.protocolVersion), app \(version.appVersion ?? "unknown"))"
        }

        if let code = response.code {
            return "\(response.status.rawValue): \(code.rawValue)"
        }

        return response.status.rawValue
    }

    private static func humanReadableVersion(_ version: IPCVersionResult) -> String {
        let detail = [
            "protocol \(version.protocolVersion)",
            version.gitHash.map { "build \($0)" },
            version.buildConfiguration,
            version.executableSHA256.map { "sha256 \($0.prefix(12))" }
        ].compactMap(\.self).joined(separator: ", ")
        if let appVersion = version.appVersion {
            return "\(appVersion) (\(detail))"
        }
        return detail
    }

    private static func formattedQueries(_ payload: IPCQueriesQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.queries.map { query in
            [
                query.name.rawValue,
                query.summary,
                dashIfEmpty(query.selectors.map(\.name.flag).joined(separator: ", ")),
                dashIfEmpty(query.fields.joined(separator: ", "))
            ]
        }

        return CLITableRenderer.formatRows(
            headers: ["NAME", "SUMMARY", "SELECTORS", "FIELDS"],
            rows: rows,
            format: format
        )
    }

    private static func formattedRuleActions(
        _ payload: IPCRuleActionsQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = payload.ruleActions.map { descriptor in
            [
                descriptor.path,
                descriptor.summary,
                dashIfEmpty(descriptor.arguments.joined(separator: ", ")),
                dashIfEmpty(
                    descriptor.options.map { option in
                        if let valuePlaceholder = option.valuePlaceholder {
                            return "\(option.flag) \(valuePlaceholder)"
                        }
                        return option.flag
                    }
                    .joined(separator: ", ")
                )
            ]
        }

        return CLITableRenderer.formatRows(
            headers: ["PATH", "SUMMARY", "ARGUMENTS", "OPTIONS"],
            rows: rows,
            format: format
        )
    }

    private static func formattedCommands(_ payload: IPCCommandsQueryResult, format: CLIOutputFormat) -> String {
        let commandRows = payload.commands.map {
            [$0.path, $0.summary, $0.layoutCompatibility.rawValue]
        }
        let workspaceRows = payload.workspaceActions.map { [$0.path, $0.summary, "workspace"] }
        let windowRows = payload.windowActions.map { [$0.path, $0.summary, "window"] }
        let windowMarkRows = payload.windowMarkActions.map { [$0.path, $0.summary, "window-mark"] }

        return CLITableRenderer.formatRows(
            headers: ["PATH", "SUMMARY", "SURFACE"],
            rows: commandRows + workspaceRows + windowRows + windowMarkRows,
            format: format
        )
    }

    private static func formattedSubscriptions(
        _ payload: IPCSubscriptionsQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = payload.subscriptions.map { subscription in
            [subscription.channel.rawValue, subscription.resultKind.rawValue, subscription.summary]
        }
        return CLITableRenderer.formatRows(headers: ["CHANNEL", "RESULT", "SUMMARY"], rows: rows, format: format)
    }

    private static func formattedCapabilities(
        _ payload: IPCCapabilitiesQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = [
            ["protocol-version", String(payload.protocolVersion)],
            ["app-version", payload.appVersion ?? "-"],
            ["authorization-required", payload.authorizationRequired ? "true" : "false"],
            ["window-id-scope", payload.windowIdScope],
            ["queries", String(payload.queries.count)],
            ["commands", String(payload.commands.count)],
            ["rule-actions", String(payload.ruleActions.count)],
            ["capture-actions", String(payload.captureActions.count)],
            ["workspace-actions", String(payload.workspaceActions.count)],
            ["window-actions", String(payload.windowActions.count)],
            ["window-mark-actions", String(payload.windowMarkActions.count)],
            ["subscriptions", String(payload.subscriptions.count)]
        ]

        return CLITableRenderer.formatRows(headers: ["CAPABILITY", "VALUE"], rows: rows, format: format)
    }

    private static func formattedWindowMarks(
        _ payload: IPCWindowMarksResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = payload.marks.map { mark in
            [
                mark.name,
                mark.workspace.displayName,
                mark.app.name,
                dashIfEmpty(mark.title ?? "")
            ]
        }
        return CLITableRenderer.formatRows(
            headers: ["MARK", "WORKSPACE", "APP", "TITLE"],
            rows: rows,
            format: format
        )
    }

    private static func dashIfEmpty(_ value: String) -> String {
        value.isEmpty ? "-" : value
    }

    private static func encodeLocalEnvelope(_ envelope: CLILocalFailureEnvelope, prettyPrinted: Bool) throws -> Data {
        var data = try IPCWire.makeEncoder(prettyPrinted: prettyPrinted).encode(envelope)
        data.append(0x0A)
        return data
    }
}
