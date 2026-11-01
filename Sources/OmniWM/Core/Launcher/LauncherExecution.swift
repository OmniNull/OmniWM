// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import Observation

struct LauncherLaunchRequest: Sendable {
    let executable: String
    let arguments: [String]
    let directory: String
    let environment: [String: String]

    private static let terminalEnvironmentKeys: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO", "TERMINFO_DIRS",
        "TTY"
    ]

    var terminalEnvironment: [String: String] {
        environment.filter { !Self.terminalEnvironmentKeys.contains($0.key) }
    }

    static func prepare(entry: LauncherEntry, configuration: LauncherConfiguration) async throws -> Self {
        var configuration = configuration
        if entry.shell != .defaultShell || !entry.shellExecutable.isEmpty {
            configuration.shell = entry.shell
            configuration.shellExecutable = entry.shellExecutable
        }
        let environment = try await LauncherEnvironmentCache.shared.environment(for: configuration)
        let directory = entry.workingDirectory.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path : LauncherPaths.expanded(entry.workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LauncherFailure(String(localized: "The working directory does not exist: \(directory)"))
        }
        let executable: String
        let arguments: [String]
        switch entry.kind {
        case .command:
            guard !entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LauncherFailure(String(localized: "Enter a command to run."))
            }
            executable = environment.executable
            arguments = environment.shell.commandArguments(entry.command, interactive: false)
        case .script,
             .executable:
            let path = LauncherPaths.expanded(entry.path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw LauncherFailure(String(localized: "The selected file does not exist: \(path)"))
            }
            if !entry.interpreter.isEmpty {
                executable = LauncherPaths.expanded(entry.interpreter)
                arguments = [path] + entry.arguments
            } else {
                executable = path
                arguments = entry.arguments
            }
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw LauncherFailure(
                    String(localized: "The file is not executable. Choose an interpreter or an executable script.")
                )
            }
        case .application:
            throw LauncherFailure(String(localized: "Applications use the application launcher."))
        }
        return Self(executable: executable, arguments: arguments, directory: directory, environment: environment.values)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var shellCommand: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    var terminalShellCommand: String {
        let inherited = Self.terminalEnvironmentKeys.sorted().map { "${\($0)+\"\($0)=$\($0)\"}" }
        let captured = terminalEnvironment.sorted { $0.key < $1.key }.map { Self.quote($0.key + "=" + $0.value) }
        return (["/usr/bin/env", "-i"] + inherited + captured + ["/usr/bin/nice", "-n", "0", shellCommand])
            .joined(separator: " ")
    }

    func makeTerminalHelper(holdOutput: Bool = true, transfer: LauncherEnvironmentTransfer? = nil) throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/omniwm-launch-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = folder.appendingPathComponent("run")
        let execution: String
        if let transfer {
            execution = """
            omniwm_environment=$(/usr/bin/nc -U \(Self.quote(transfer.endpoint)) </dev/null) || exit 1
            case "$omniwm_environment" in
                *\(Self.quote(transfer.marker))) omniwm_environment=${omniwm_environment%\(Self.quote(transfer.marker))} ;;
                *) exit 1 ;;
            esac
            eval "$omniwm_environment"
            """
        } else {
            execution = shellCommand
        }
        let hold = holdOutput ? """
        /usr/bin/printf '%s\\n' \(Self.quote(String(localized: "Press Return to close.")))
        IFS= read -r omniwm_reply
        """ : ""
        let content = """
        #!/bin/sh
        /bin/rm -f "$0"
        /bin/rmdir \(Self.quote(folder.path))
        cd \(Self.quote(directory)) || exit 1
        PATH=\(Self.quote(environment["PATH"] ?? "/usr/bin:/bin"))
        export PATH
        \(execution)
        omniwm_status=$?
        /usr/bin/printf '\\n%s %s.\\n' \(Self.quote(String(localized: "Exit status"))) "$omniwm_status"
        \(hold)
        exit "$omniwm_status"

        """
        do {
            try Data(content.utf8).write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }
}

actor LauncherEnvironmentCache {
    static let shared = LauncherEnvironmentCache()
    private struct Key: Hashable {
        let shell: LauncherShell
        let executable: String
        let folders: [String]
    }

    private var environments: [Key: Task<LauncherEnvironment, Error>] = [:]

    func environment(
        for configuration: LauncherConfiguration,
        refresh: Bool = false
    ) async throws -> LauncherEnvironment {
        let key = Key(
            shell: configuration.shell,
            executable: configuration.shellExecutable,
            folders: configuration.cliFolders
        )
        if refresh { environments.removeAll() }
        if let task = environments[key] { return try await task.value }
        let task = Task { try await LauncherEnvironment.load(configuration: configuration) }
        environments[key] = task
        do {
            return try await task.value
        } catch {
            environments[key] = nil
            throw error
        }
    }
}

@MainActor @Observable
final class LauncherExecution {
    static let shared = LauncherExecution()
    struct Outcome: Identifiable {
        let id = UUID()
        let name: String
        let message: String
        let output: String
        let failed: Bool
    }

    private(set) var running: [UUID: String] = [:]
    var outcome: Outcome?

    func run(_ entry: LauncherEntry, controller: WMController, query: String = "") {
        let configuration = controller.settings.launcher
        let runID = UUID()
        running[runID] = entry.name
        Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            defer { self.running[runID] = nil }
            do {
                let request = try await LauncherLaunchRequest.prepare(entry: entry, configuration: configuration)
                let terminal = entry.terminal == .defaultTerminal ? configuration.terminal : entry.terminal
                if terminal == .background {
                    let result = try await LauncherProcess.run(
                        executable: request.executable, arguments: request.arguments,
                        environment: request.environment, directory: request.directory
                    )
                    var output = String(decoding: result.output, as: UTF8.self)
                    if result.truncated { output += "\n" + String(localized: "Output truncated.") }
                    outcome = Outcome(
                        name: entry.name, message: String(localized: "Exited with status \(result.status)"),
                        output: output, failed: result.status != 0
                    )
                    if result.status != 0 { Self.showOutcome(settings: controller.settings, controller: controller) }
                    if result.status == 0 {
                        controller.settings.recordLauncherLaunch(
                            targetID: entry.id.uuidString,
                            query: query,
                            displayName: entry.name
                        )
                    }
                } else {
                    try await launchTerminal(terminal, request: request, controller: controller)
                    controller.settings.recordLauncherLaunch(
                        targetID: entry.id.uuidString,
                        query: query,
                        displayName: entry.name
                    )
                }
            } catch {
                outcome = Outcome(name: entry.name, message: error.localizedDescription, output: "", failed: true)
                Self.showOutcome(settings: controller.settings, controller: controller)
            }
        }
    }

    private static func showOutcome(settings: SettingsStore, controller: WMController) {
        SettingsWindowController.shared.show(settings: settings, controller: controller, section: .launcher)
    }

    private func launchTerminal(
        _ terminal: LauncherTerminal, request: LauncherLaunchRequest, controller: WMController
    ) async throws {
        if terminal == .builtIn {
            guard controller.appliedQuakeTerminalSelection == .ghostty else {
                throw LauncherFailure(
                    String(localized: "Enable the built-in Ghostty Quake Terminal, or choose an external terminal.")
                )
            }
            guard controller.quakeTerminalController.launch(request) else {
                throw LauncherFailure(String(localized: "The built-in terminal could not create a command tab."))
            }
            return
        }
        _ = try await LauncherExternalTerminal.launch(terminal, request: request)
    }
}

struct LauncherTerminalReference: Sendable {
    let type: DescType
    let data: Data
}

@MainActor
struct LauncherTerminalSession {
    let application: NSRunningApplication
    let terminal: LauncherTerminal
    let reference: LauncherTerminalReference?

    func sendReturn() async throws {
        _ = try await LauncherExternalTerminal.sessionEvent(
            terminal: terminal, pid: application.processIdentifier, reference: reference, action: .returnInput
        )
    }

    func close() async throws {
        _ = try await LauncherExternalTerminal.sessionEvent(
            terminal: terminal, pid: application.processIdentifier, reference: reference, action: .close
        )
    }
}

@MainActor
enum LauncherExternalTerminal {
    enum SessionAction: Sendable {
        case launch(String)
        case returnInput
        case close
    }

    static func launch(
        _ terminal: LauncherTerminal,
        request: LauncherLaunchRequest
    ) async throws -> LauncherTerminalSession {
        guard let identifier = terminal.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else {
            throw LauncherFailure(String(localized: "The selected terminal is not installed."))
        }
        let reused = terminal == .terminal || terminal == .iterm
        let transfer = reused ? try LauncherEnvironmentTransfer(request: request) : nil
        let helper: URL
        do {
            helper = try request.makeTerminalHelper(holdOutput: reused, transfer: transfer)
        } catch {
            transfer?.cancel()
            throw error
        }
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = !reused
        options.environment = request.terminalEnvironment
        if terminal == .ghostty {
            options.arguments = ["--wait-after-command=true", "-e", "/bin/sh", helper.path]
        } else if terminal == .kitty {
            options.arguments = [
                "-o",
                "macos_quit_when_last_window_closed=yes",
                "--hold",
                "--session=none",
                "--directory",
                request.directory,
                "/bin/sh",
                helper.path
            ]
        }
        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: options)
            let reference = reused ? try await sessionEvent(
                terminal: terminal, pid: app.processIdentifier, reference: nil, action: .launch(helper.path)
            ) : nil
            try await transfer?.waitForDelivery()
            return LauncherTerminalSession(application: app, terminal: terminal, reference: reference)
        } catch {
            transfer?.cancel()
            try? FileManager.default.removeItem(at: helper.deletingLastPathComponent())
            throw error
        }
    }

    nonisolated static func sessionEvent(
        terminal: LauncherTerminal, pid: pid_t, reference: LauncherTerminalReference?, action: SessionAction
    ) async throws -> LauncherTerminalReference? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let event = try makeEvent(terminal: terminal, pid: pid, reference: reference, action: action)
                    let reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
                    if case .launch = action {
                        guard let object = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
                              object.descriptorType == typeObjectSpecifier
                        else {
                            throw LauncherFailure(String(localized: "The terminal did not return its new session."))
                        }
                        continuation.resume(returning: LauncherTerminalReference(
                            type: object.descriptorType,
                            data: object.data
                        ))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    if case .close = action, (error as NSError).code == -1728 {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: LauncherFailure(error.localizedDescription))
                    }
                }
            }
        }
    }

    private nonisolated static func makeEvent(
        terminal: LauncherTerminal, pid: pid_t, reference: LauncherTerminalReference?, action: SessionAction
    ) throws -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event: NSAppleEventDescriptor
        if case let .launch(helper) = action {
            event = makeEvent(
                pid: target,
                eventClass: terminal == .terminal ? 0x636F7265 : 0x4974726D,
                id: terminal == .terminal ? 0x646F7363 : 0x6E77776E
            )
            event.setParam(
                NSAppleEventDescriptor(string: helper),
                forKeyword: terminal == .terminal ? AEKeyword(keyDirectObject) : 0x4E77636D
            )
            return event
        }
        guard let reference,
              let object = NSAppleEventDescriptor(descriptorType: reference.type, data: reference.data)
        else {
            throw LauncherFailure(String(localized: "The terminal session is unavailable."))
        }
        if case .close = action {
            event = makeEvent(pid: target, eventClass: 0x636F7265, id: 0x636C6F73)
            let window = terminal == .terminal ? object.forKeyword(AEKeyword(keyAEContainer)) : object
            guard let window else { throw LauncherFailure(String(localized: "The terminal window is unavailable.")) }
            event.setParam(window, forKeyword: AEKeyword(keyDirectObject))
            if terminal == .terminal { event.setParam(
                NSAppleEventDescriptor(enumCode: kAENo),
                forKeyword: AEKeyword(keyAESaveOptions)
            ) }
        } else if terminal == .terminal {
            event = makeEvent(pid: target, eventClass: 0x636F7265, id: 0x646F7363)
            event.setParam(NSAppleEventDescriptor(string: ""), forKeyword: AEKeyword(keyDirectObject))
            event.setParam(object, forKeyword: 0x6B66696C)
        } else {
            let session = try currentITermSession(object)
            event = makeEvent(pid: target, eventClass: 0x4974726D, id: 0x736E7478)
            event.setParam(session, forKeyword: AEKeyword(keyDirectObject))
            event.setParam(NSAppleEventDescriptor(string: ""), forKeyword: 0x54657874)
            event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: 0x57746E6C)
        }
        return event
    }

    private nonisolated static func currentITermSession(
        _ object: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(
            NSAppleEventDescriptor(typeCode: typeProperty),
            forKeyword: AEKeyword(keyAEDesiredClass)
        )
        property.setDescriptor(
            NSAppleEventDescriptor(enumCode: OSType(formPropertyID)),
            forKeyword: AEKeyword(keyAEKeyForm)
        )
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x5763736E), forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(object, forKeyword: AEKeyword(keyAEContainer))
        guard let session = property.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw LauncherFailure(String(localized: "The terminal session could not be addressed."))
        }
        return session
    }

    private nonisolated static func makeEvent(
        pid: NSAppleEventDescriptor, eventClass: AEEventClass, id: AEEventID
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: id,
            targetDescriptor: pid,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}
