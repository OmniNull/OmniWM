// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIExitCode: Int32 {
    case success = 0
    case rejected = 1
    case transportFailure = 2
    case invalidArguments = 3
    case internalError = 4
}

enum CLIParseError: Error, Equatable {
    case usage(String)
}

struct CLIWatchConfiguration: Equatable {
    let childArguments: [String]
}

struct ParsedCLICommand: Equatable {
    let invocation: CLIInvocation
    let outputFormat: CLIOutputFormat
    let expectsEventStream: Bool
    let watchConfiguration: CLIWatchConfiguration?
    var reconnect = false

    var request: IPCRequest {
        guard case let .remote(request) = invocation else {
            preconditionFailure("Local CLI invocations do not have an IPC request")
        }
        return request
    }
}

enum CLIParser {
    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ParsedCLICommand {
        let normalized = CLINormalizedArguments(arguments: arguments)
        guard let command = normalized.arguments.first else {
            throw CLIParseError.usage(usageText)
        }

        _ = environment
        let requestId = UUID().uuidString
        let commandArguments = Array(normalized.arguments.dropFirst())
        var outputFormat = normalized.outputFormat ?? CLIOutputFormat.defaultFormat(for: command)
        let invocation: CLIInvocation

        switch command {
        case "subscribe":
            return try parseSubscribeCommand(id: requestId, arguments: commandArguments, outputFormat: outputFormat)
        case "watch":
            return try parseWatchCommand(id: requestId, arguments: commandArguments, outputFormat: outputFormat)
        case "completion":
            invocation = .local(try parseCompletionCommand(arguments: commandArguments))
            outputFormat = .text
        case "help",
             "--help",
             "-h":
            invocation = .local(.help)
            outputFormat = .text
        default:
            invocation = .remote(try parseRemoteRequest(command: command, id: requestId, arguments: commandArguments))
        }

        return ParsedCLICommand(
            invocation: invocation,
            outputFormat: outputFormat,
            expectsEventStream: false,
            watchConfiguration: nil
        )
    }

    private static func parseRemoteRequest(command: String, id: String, arguments: [String]) throws -> IPCRequest {
        switch command {
        case "ping",
             "version":
            guard arguments.isEmpty else {
                throw CLIParseError.usage(usageText)
            }
            return IPCRequest(id: id, kind: command == "ping" ? .ping : .version)
        case "command":
            return try parseCommandRequest(id: id, arguments: arguments)
        case "query":
            return try IPCRequest(id: id, query: CLIQueryArguments.parse(arguments: arguments))
        case "rule":
            return try CLIRuleParser.parseRuleRequest(id: id, arguments: arguments)
        case "capture":
            return try parseCaptureRequest(id: id, arguments: arguments)
        case "workspace":
            return try parseWorkspaceRequest(id: id, arguments: arguments)
        case "window":
            return try parseWindowRequest(id: id, arguments: arguments)
        default:
            throw CLIParseError.usage(usageText)
        }
    }

    private static func parseSubscribeCommand(
        id: String,
        arguments: [String],
        outputFormat: CLIOutputFormat
    ) throws -> ParsedCLICommand {
        guard outputFormat.prefersJSON else {
            throw CLIParseError.usage(usageText)
        }
        let parsed = try CLISubscriptionParser.parse(arguments: arguments, allowExec: false)
        return ParsedCLICommand(
            invocation: .remote(IPCRequest(id: id, subscribe: parsed.request)),
            outputFormat: outputFormat,
            expectsEventStream: true,
            watchConfiguration: nil,
            reconnect: parsed.reconnect
        )
    }

    static func outputFormat(arguments: [String]) -> CLIOutputFormat {
        let normalized = CLINormalizedArguments(arguments: arguments)
        return normalized.outputFormat ?? CLIOutputFormat.defaultFormat(for: normalized.arguments.first)
    }

    private static func parseCommandRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard !arguments.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        for descriptor in IPCAutomationManifest.commandDescriptors(matching: arguments) {
            let commandWordCount = descriptor.commandWords.count
            let remainingCount = arguments.count - commandWordCount
            guard remainingCount == descriptor.arguments.count else {
                continue
            }

            let argumentTokens = Array(arguments.dropFirst(commandWordCount))
            do {
                let argumentValues = try zip(descriptor.arguments, argumentTokens)
                    .map(CLIArgumentParser.parseCommandArgumentValue)
                let request = try IPCCommandRequest(name: descriptor.name, argumentValues: argumentValues)
                return IPCRequest(id: id, command: request)
            } catch {
                continue
            }
        }

        throw CLIParseError.usage(usageText)
    }

    private static func parseWorkspaceRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard !arguments.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        for descriptor in IPCAutomationManifest.workspaceActionDescriptors(matching: arguments) {
            let actionWords = descriptor.actionWords
            let remaining = Array(arguments.dropFirst(actionWords.count))

            let workspace: IPCWorkspaceRequest
            switch descriptor.name {
            case .focusName:
                guard remaining.count == descriptor.arguments.count,
                      let targetValue = remaining.first
                else {
                    continue
                }
                workspace = .focusName(target: WorkspaceTarget(resolvingInput: targetValue))
            case .moveToMonitor:
                let flags = remaining.filter { $0.hasPrefix("--") }
                guard flags.allSatisfy(descriptor.optionalFlags.contains),
                      flags.count == Set(flags).count
                else {
                    continue
                }

                let positionals = remaining.filter { !$0.hasPrefix("--") }
                guard positionals.count == descriptor.arguments.count else {
                    continue
                }

                workspace = .moveToMonitor(
                    target: WorkspaceTarget(resolvingInput: positionals[0]),
                    direction: try CLIArgumentParser.parseDirection(positionals[1]),
                    force: flags.contains("--force")
                )
            case .rename:
                guard remaining.count == descriptor.arguments.count,
                      !remaining.contains(where: { $0.hasPrefix("--") })
                else {
                    continue
                }
                workspace = .rename(
                    target: WorkspaceTarget(resolvingInput: remaining[0]),
                    displayName: remaining[1]
                )
            }
            return IPCRequest(id: id, workspace: workspace)
        }

        throw CLIParseError.usage(usageText)
    }

    private static func parseCaptureRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCCaptureActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(usageText)
        }

        let capture: IPCCaptureRequest
        switch action {
        case .start:
            guard arguments.count == 2,
                  let profile = IPCCaptureProfile(rawValue: arguments[1])
            else {
                throw CLIParseError.usage(usageText)
            }
            capture = .start(profile)
        case .stop:
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            capture = .stop
        case .status:
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            capture = .status
        }

        return IPCRequest(id: id, capture: capture)
    }

    private static func parseWindowRequest(id: String, arguments: [String]) throws -> IPCRequest {
        if arguments.first == "mark" {
            return try parseWindowMarkRequest(id: id, arguments: Array(arguments.dropFirst()))
        }

        guard let action = arguments.first.flatMap(IPCWindowActionName.init(rawValue:)),
              let descriptor = IPCAutomationManifest.windowActionDescriptors.first(where: { $0.name == action }),
              arguments.count == 1 + descriptor.arguments.count
        else {
            throw CLIParseError.usage(usageText)
        }

        return IPCRequest(
            id: id,
            window: IPCWindowRequest(
                name: action,
                windowId: arguments[1],
                workspaceTarget: action == .moveToWorkspace ? WorkspaceTarget(resolvingInput: arguments[2]) : nil
            )
        )
    }

    private static func parseWatchCommand(
        id: String,
        arguments: [String],
        outputFormat: CLIOutputFormat
    ) throws -> ParsedCLICommand {
        let parsed = try CLISubscriptionParser.parse(arguments: arguments, allowExec: true)
        guard let execArguments = parsed.execArguments else {
            throw CLIParseError.usage(usageText)
        }

        return ParsedCLICommand(
            invocation: .remote(IPCRequest(id: id, subscribe: parsed.request)),
            outputFormat: outputFormat,
            expectsEventStream: false,
            watchConfiguration: CLIWatchConfiguration(childArguments: execArguments),
            reconnect: parsed.reconnect
        )
    }

    private static func parseCompletionCommand(arguments: [String]) throws -> CLILocalAction {
        guard arguments.count == 1,
              let shell = CLIShell(rawValue: arguments[0])
        else {
            throw CLIParseError.usage(usageText)
        }
        return .completion(shell)
    }

    static let usageText: String = {
        let queryNames = IPCAutomationManifest.queryDescriptors.map(\.name.rawValue).joined(separator: ", ")
        let subscriptionNames = IPCSubscriptionChannel.allCases.map(\.rawValue).joined(separator: ",")
        let commandLines = IPCAutomationManifest.commandDescriptors.map(\.path)
        let ruleLines = IPCAutomationManifest.ruleActionDescriptors.map(\.path)
        let ruleOptionLines = IPCAutomationManifest.ruleDefinitionOptionDescriptors.map { descriptor in
            if let valuePlaceholder = descriptor.valuePlaceholder {
                return "  \(descriptor.flag) \(valuePlaceholder)"
            }
            return "  \(descriptor.flag)"
        }
        let workspaceLines = IPCAutomationManifest.workspaceActionDescriptors.map(\.path)
        let windowLines = IPCAutomationManifest.windowActionDescriptors.map(\.path)
        let windowMarkLines = IPCAutomationManifest.windowMarkActionDescriptors.map(\.path)
        let captureLines = IPCAutomationManifest.captureActionDescriptors.map(\.path)

        var lines = [
            "Usage:",
            "  omniwmctl ping",
            "  omniwmctl version",
            "  omniwmctl help",
            "  omniwmctl completion <\(CLIShell.allCases.map(\.rawValue).joined(separator: "|"))>"
        ]
        lines += commandLines.map { "  omniwmctl \($0)" }
        lines += ruleLines.map { "  omniwmctl \($0)" }
        lines += captureLines.map { "  omniwmctl \($0)" }
        lines += [
            "  omniwmctl query <\(queryNames)> [selectors...] [--fields <csv>] [--format <json|ndjson|table|tsv|text>]"
        ]
        lines += workspaceLines.map { "  omniwmctl \($0)" }
        lines += windowLines.map { "  omniwmctl \($0)" }
        lines += windowMarkLines.map { "  omniwmctl \($0)" }
        lines += [
            "  omniwmctl subscribe <\(subscriptionNames)> [--no-send-initial] [--reconnect] [--format json|ndjson]",
            "  omniwmctl subscribe --all [--no-send-initial] [--reconnect] [--format json|ndjson]",
            "  omniwmctl watch <\(subscriptionNames)> [--no-send-initial] [--reconnect] --exec <argv...>",
            "  omniwmctl watch --all [--no-send-initial] [--reconnect] --exec <argv...>",
            "",
            "Formats:",
            "  --format json|ndjson|table|tsv|text",
            "  --json (alias for --format json)",
            "",
            "Rule Options:"
        ]
        lines += ruleOptionLines
        lines += [
            "",
            "Query Selectors:"
        ]

        for descriptor in IPCAutomationManifest.queryDescriptors where !descriptor.selectors.isEmpty {
            let selectors = descriptor.selectors
                .map { selector in
                    selector.name.expectsValue ? "\(selector.name.flag) <value>" : selector.name.flag
                }
                .joined(separator: ", ")
            lines.append("  \(descriptor.name.rawValue): \(selectors)")
        }

        lines.append("")
        lines.append("Query Fields:")
        for descriptor in IPCAutomationManifest.queryDescriptors where !descriptor.fields.isEmpty {
            lines.append("  \(descriptor.name.rawValue): \(descriptor.fields.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }()
}
