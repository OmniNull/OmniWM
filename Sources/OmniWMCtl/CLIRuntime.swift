// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import OmniWMIPC

struct CLIRuntimeEnvironment: Sendable {
    let openConnection: @Sendable () throws -> IPCClientConnection
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = CLIRuntimeEnvironment(
        openConnection: { try IPCClient().openConnection() },
        sleep: { try await Task.sleep(for: $0) }
    )
}

enum CLIRuntime {
    static func run(arguments: [String], environment: CLIRuntimeEnvironment = .live) async -> Int32 {
        let outputFormat = CLIParser.outputFormat(arguments: arguments)

        do {
            if let command = arguments.dropFirst().first, command == "__launch" || command == "__environment" {
                guard arguments.count == 3 else { throw CLIParseError.usage("Invalid launcher helper invocation") }
                return try command == "__launch"
                    ? CLILauncherHelper.launch(socket: arguments[2])
                    : CLILauncherHelper.environment(marker: arguments[2])
            }
            if arguments.dropFirst().first == "__complete" {
                let words = try CLICompletionInput.words(arguments: Array(arguments.dropFirst(2)))
                let suggestions = CLICompletionSelector.suggestions(
                    words: words, filterPrefix: arguments[2] != CLIShell.fish.rawValue
                )
                let text = suggestions.isEmpty ? "" : suggestions.joined(separator: "\n") + "\n"
                CLIRenderer.write(CLIRenderedOutput(data: Data(text.utf8), destination: .standardOutput))
                return CLIExitCode.success.rawValue
            }
            let parsed = try CLIParser.parse(arguments: arguments)

            switch parsed.invocation {
            case let .local(action):
                CLIRenderer.write(try localActionOutput(action))
                return CLIExitCode.success.rawValue
            case let .remote(request):
                if case let .subscribe(subscription) = request.payload {
                    return await runSubscription(
                        request: request,
                        subscription: subscription,
                        parsed: parsed,
                        environment: environment
                    )
                }

                let connection = try environment.openConnection()
                defer {
                    Task {
                        await connection.close()
                    }
                }

                try await connection.send(request)
                let response = try await connection.readResponse()
                CLIRenderer.write(try CLIRenderer.responseOutput(response, format: parsed.outputFormat))
                return CLIRenderer.exitCode(for: response).rawValue
            }
        } catch let error as CLIParseError {
            return CLIRuntimeOutput.reportParseError(error, format: outputFormat)
        } catch {
            return CLIRuntimeOutput.report(error, format: outputFormat)
        }
    }

    private static func runSubscription(
        request: IPCRequest,
        subscription: IPCSubscribeRequest,
        parsed: ParsedCLICommand,
        environment: CLIRuntimeEnvironment
    ) async -> Int32 {
        let processState = CLIWatchProcessState()
        let connections = CLIConnectionBox()
        let outputFormat = parsed.outputFormat

        return await withTaskCancellationHandler {
            defer {
                connections.closeCurrent()
            }
            do {
                var session = try await CLISubscriptionSession.open(
                    requestID: request.id,
                    subscription: subscription,
                    sendInitial: subscription.sendInitial,
                    connections: connections,
                    environment: environment
                )
                if !session.response.ok || parsed.watchConfiguration == nil {
                    CLIRenderer.write(try CLIRenderer.responseOutput(session.response, format: outputFormat))
                }
                guard session.response.ok else {
                    return CLIRenderer.exitCode(for: session.response).rawValue
                }

                while true {
                    do {
                        try await forwardEvents(from: session.connection, parsed: parsed, processState: processState)
                    } catch let error
                        where parsed.reconnect && CLIRuntimeOutput.isTransportError(error) && !Task.isCancelled
                    {
                        connections.closeCurrent()
                        CLIRuntimeOutput.writeNotice("omniwmctl: connection lost: \(error); reconnecting")
                        session = try await CLISubscriptionSession.reconnect(
                            requestID: request.id,
                            subscription: subscription,
                            connections: connections,
                            environment: environment
                        )
                        guard session.response.ok else {
                            CLIRenderer.write(try CLIRenderer.responseOutput(session.response, format: outputFormat))
                            return CLIRenderer.exitCode(for: session.response).rawValue
                        }
                        CLIRuntimeOutput.writeNotice("omniwmctl: reconnected")
                    }
                }
            } catch {
                return CLIRuntimeOutput.reportSubscriptionError(error, format: outputFormat)
            }
        } onCancel: {
            processState.terminateCurrent()
            connections.interruptCurrent()
        }
    }

    private static func forwardEvents(
        from connection: IPCClientConnection,
        parsed: ParsedCLICommand,
        processState: CLIWatchProcessState
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let event = try await connection.readEvent() else {
                throw POSIXError(.ECONNRESET)
            }
            try await deliver(event, parsed: parsed, processState: processState)
        }
    }

    private static func deliver(
        _ event: IPCEventEnvelope,
        parsed: ParsedCLICommand,
        processState: CLIWatchProcessState
    ) async throws {
        guard let watchConfiguration = parsed.watchConfiguration else {
            CLIRenderer.write(try CLIRenderer.eventOutput(event, format: parsed.outputFormat))
            return
        }
        do {
            let result = try await CLIWatchChild.run(
                event: event,
                childArguments: watchConfiguration.childArguments,
                processState: processState
            )
            if result.terminationReason != .exit || result.terminationStatus != 0 {
                CLIWatchChild.reportFailure(result: result, command: watchConfiguration.childArguments)
            }
        } catch {
            throw CLIWatchChild.Failure.childLaunch(error)
        }
    }

    private static func localActionOutput(_ action: CLILocalAction) throws -> CLIRenderedOutput {
        let text: String

        switch action {
        case .help:
            text = CLIParser.usageText
        case let .completion(shell):
            text = CLICompletionGenerator.script(for: shell)
        }

        let terminated = text.hasSuffix("\n") ? text : text + "\n"
        return CLIRenderedOutput(data: Data(terminated.utf8), destination: .standardOutput)
    }
}
