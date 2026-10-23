// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

extension ShellProvider {
    func spawn(_ identity: ShellProviderIdentity, configuration: ShellProviderConfiguration) throws -> Spawned {
        let declaration = try launchDeclaration(configuration)
        let input = Pipe()
        let output = Pipe()
        let diagnostic = Pipe()
        let inputFD = try duplicate(input.fileHandleForWriting.fileDescriptor, write: true)
        var outputFD: Int32 = -1
        var diagnosticFD: Int32 = -1
        do {
            outputFD = try duplicate(output.fileHandleForReading.fileDescriptor, write: false)
            diagnosticFD = try duplicate(diagnostic.fileHandleForReading.fileDescriptor, write: false)
            let process = Process()
            process.executableURL = declaration.executable
            process.arguments = Array(configuration.command.dropFirst())
            process.currentDirectoryURL = declaration.folder
            process.environment = processEnvironment(configuration, declaration: declaration)
            process.standardInput = input
            process.standardOutput = output
            process.standardError = diagnostic
            let signals = signals
            process.terminationHandler = { _ in signals.post(.exited, identity: identity) }
            try process.run()
            var cleanupError: String?
            for handle in [input.fileHandleForWriting, output.fileHandleForReading, diagnostic.fileHandleForReading] {
                do { try handle.close() }
                catch {
                    if cleanupError == nil {
                        cleanupError = "Could not close original provider pipe: \(error.localizedDescription)"
                    }
                }
            }
            return Spawned(
                process: process,
                input: inputFD,
                output: outputFD,
                diagnostic: diagnosticFD,
                cleanupError: cleanupError
            )
        } catch {
            _ = Darwin.close(inputFD)
            if outputFD >= 0 { _ = Darwin.close(outputFD) }
            if diagnosticFD >= 0 { _ = Darwin.close(diagnosticFD) }
            throw error
        }
    }

    func duplicate(_ fd: Int32, write: Bool) throws -> Int32 {
        let copy = Darwin.dup(fd)
        guard copy >= 0 else { throw failure("Could not duplicate provider pipe: \(errno)") }
        let flags = fcntl(copy, F_GETFL)
        guard flags >= 0, fcntl(copy, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(copy, F_SETFD, FD_CLOEXEC) == 0,
              !write || fcntl(copy, F_SETNOSIGPIPE, 1) == 0
        else {
            let code = errno
            _ = Darwin.close(copy)
            throw failure("Could not configure nonblocking provider pipe: \(code)")
        }
        return copy
    }

    private struct LaunchDeclaration {
        let folder: URL
        let executable: URL
        let options: String
    }

    private func launchDeclaration(_ configuration: ShellProviderConfiguration) throws -> LaunchDeclaration {
        guard configuration.authorized
        else { throw failure("Provider execution is not enabled in the user configuration") }
        guard let executable = configuration.command.first, !executable.isEmpty,
              !executable.hasPrefix("/"), !executable.hasPrefix("~"), !executable.contains("\0"),
              !executable.split(separator: "/", omittingEmptySubsequences: false)
                  .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              configuration.command.allSatisfy({ !$0.contains("\0") }),
              configuration.options.count <= 256 * 1024,
              let options = String(data: configuration.options, encoding: .utf8)
        else { throw failure("Invalid provider declaration or options") }
        let folder = configuration.folder.resolvingSymlinksInPath().standardizedFileURL
        let url = folder.appendingPathComponent(executable).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/"), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw failure("Provider executable must be an executable file inside its component folder")
        }
        return LaunchDeclaration(folder: folder, executable: url, options: options)
    }

    private func processEnvironment(
        _ configuration: ShellProviderConfiguration,
        declaration: LaunchDeclaration
    ) -> [String: String] {
        var environment = environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["OMNIWM_PROVIDER_PROTOCOL"] = "1"
        environment["OMNIWM_WIDGET"] = configuration.widget
        environment["OMNIWM_WIDGET_DIR"] = declaration.folder.path
        environment["OMNIWM_INSTANCE"] = configuration.instance
        environment["OMNIWM_PROVIDER_OPTIONS"] = declaration.options
        return environment
    }
}
