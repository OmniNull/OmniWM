// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

final class CLICompletionTemplateTests: XCTestCase {
    func testZshTemplateAndRenderedScriptHaveValidNativeSyntax() throws {
        try assertValidTemplate(PackageResources.completion_zsh, shell: .zsh, executable: "/bin/zsh")
    }

    func testZshMarkCompletionSuggestsActionsAndListFlags() throws {
        let script = CLICompletionGenerator.script(for: .zsh)
        for (words, position, expected) in [
            ("omniwmctl window mark ''", 4, "set"),
            ("omniwmctl window mark list ''", 5, "--json")
        ] {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let setup = "words=(\(words)); CURRENT=\(position); compadd() { print -r -- \"$@\" }; "
            process.arguments = ["-fc", setup + script]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let suggestions = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(process.terminationStatus, 0, errorText)
            XCTAssertTrue(suggestions.contains(Substring(expected)), words)
        }
    }

    func testBashTemplateAndRenderedScriptHaveValidNativeSyntax() throws {
        try assertValidTemplate(PackageResources.completion_bash, shell: .bash, executable: "/bin/bash")
    }

    func testFishTemplateVariablesAreAllRendered() {
        let template = String(decoding: PackageResources.completion_fish, as: UTF8.self)
        XCTAssertTrue(template.contains("#{{"))
        XCTAssertFalse(CLICompletionGenerator.script(for: .fish).contains("#{{"))
    }

    private func assertValidTemplate(_ bytes: [UInt8], shell: CLIShell, executable: String) throws {
        let template = String(decoding: bytes, as: UTF8.self)
        let script = CLICompletionGenerator.script(for: shell)
        XCTAssertTrue(template.contains("#{{"))
        XCTAssertFalse(script.contains("#{{"))
        try assertValidSyntax(template, executable: executable)
        try assertValidSyntax(script, executable: executable)
    }

    private func assertValidSyntax(_ script: String, executable: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-n", scriptURL.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
