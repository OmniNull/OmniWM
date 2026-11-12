// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

enum CLICompletionTestSupport {
    static func complete(shell: CLIShell, words: [String]) throws -> [String] {
        let registration = CLICompletionGenerator.script(for: shell)
        let encodedWords = words.map(Self.quote).joined(separator: " ")
        let line = words.dropLast().map(Self.quote).joined(separator: " ") + " " + (words.last ?? "")
        let script: String
        let executable: String
        switch shell {
        case .zsh:
            executable = "/bin/zsh"
            script = "omniwmctl __complete zsh \(words.count) \(encodedWords)"
        case .bash:
            executable = "/bin/bash"
            script = "complete() { builtin complete \"$@\"; completion_command=\"$2\"; }; " + registration
                + "\nexport COMP_LINE=\(Self.quote(line)) COMP_POINT=\(line.utf8.count); "
                + "eval \"$completion_command\""
        case .fish:
            executable = try fishExecutable()
            script = registration + "\ncomplete -C " + Self.quote(line)
        case .nu:
            return try NuCompletionTestSupport.completions([line])[0]
        }
        return try run(executable, arguments: ["-c", script])
            .split(separator: "\n").map { String($0.split(separator: "\t", maxSplits: 1)[0]) }
    }

    static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let products = Bundle(for: CLICompletionTemplateTests.self).bundleURL.deletingLastPathComponent().path
        environment["PATH"] = products + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        XCTAssertTrue(errorText.isEmpty, errorText)
        return String(decoding: data, as: UTF8.self)
    }

    static func fishExecutable() throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executable = path.split(separator: ":").map { String($0) + "/fish" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return try XCTUnwrap(executable, "Fish must be available for registration checks")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
