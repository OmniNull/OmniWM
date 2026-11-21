// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

final class CLICompletionZshTests: XCTestCase {
    func testFirstTabUsesRealCompletionInEachInstallationStyle() throws {
        let fixtures = [
            ("omniwmctl que", "omniwmctl query "),
            ("omniwmctl query windows --fields id,ti", "omniwmctl query windows --fields id,title "),
            (
                "omniwmctl workspace move-to-monitor 'Design Space' ri",
                "omniwmctl workspace move-to-monitor 'Design Space' right "
            )
        ]
        for installation in ZshInstallation.allCases {
            for (input, expected) in fixtures {
                let result = try complete(input, installation: installation)
                XCTAssertEqual(result.registration, "_omniwmctl", installation.rawValue)
                XCTAssertEqual(result.status, Int(EXIT_SUCCESS), "\(installation): \(input)")
                XCTAssertEqual(result.buffer, expected, "\(installation): \(input)")
            }
        }
    }

    func testEmptyCompletionLeavesTheBufferUnchanged() throws {
        let fixtures = ["omniwmctl ping ", "omniwmctl watch focus --exec nu --format "]
        for installation in ZshInstallation.allCases {
            for input in fixtures {
                let result = try complete(input, installation: installation)
                XCTAssertNotEqual(result.status, Int(EXIT_SUCCESS), "\(installation): \(input)")
                XCTAssertEqual(result.buffer, input, "\(installation): \(input)")
            }
        }
    }

    private enum ZshInstallation: String, CaseIterable {
        case eval
        case autoload
        case cachedAutoload
    }

    private func complete(
        _ line: String,
        installation: ZshInstallation
    ) throws -> (registration: String, status: Int, buffer: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registration = directory.appendingPathComponent("_omniwmctl")
        let cache = directory.appendingPathComponent(".zcompdump")
        let result = directory.appendingPathComponent("result")
        if installation == .cachedAutoload {
            try "#compdef omniwmctl\ncompadd -- query\n".write(
                to: registration, atomically: true, encoding: .utf8
            )
            _ = try CLICompletionTestSupport.run("/bin/zsh", arguments: ["-fc", """
            fpath=(\(quote(directory.path)) $fpath)
            autoload -Uz compinit
            compinit -u -d \(quote(cache.path))
            """])
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        }
        try CLICompletionGenerator.script(for: .zsh).write(to: registration, atomically: true, encoding: .utf8)
        let initialization: String
        switch installation {
        case .eval:
            initialization = "autoload -Uz compinit; compinit -u -D; eval \"$(<\(quote(registration.path)))\""
        case .autoload:
            initialization = "fpath=(\(quote(directory.path)) $fpath); autoload -Uz compinit; compinit -u -D"
        case .cachedAutoload:
            initialization = "fpath=(\(quote(directory.path)) $fpath); autoload -Uz compinit; compinit -u -C -d \(quote(cache.path))"
        }
        let widget = "completion_result() { zle expand-or-complete; local completion_status=$?; "
            + "print -rl -- \"${_comps[omniwmctl]:-NONE}\" \"$completion_status\" \"$BUFFER\" > \(quote(result.path)); "
            + "print -r -- OMNIWM_''DONE; }; zle -N completion_result; bindkey '^I' completion_result"
        let script = """
        zmodload zsh/zpty
        zpty completion 'TERM=dumb HISTFILE=/dev/null /bin/zsh -f -i'
        trap 'zpty -d completion 2>/dev/null' EXIT HUP INT TERM
        ready() { local response; zpty -r completion response '*OMNIWM_READY>*' }
        send_command() { zpty -w completion "$1"; ready }
        send_command "PS1='OMNIWM_''READY>'; PS2=''; unsetopt zle_bracketed_paste"
        send_command \(quote(initialization))
        send_command \(quote(widget))
        zpty -w -n completion \(quote(line))$'\\t'
        zpty -r completion response '*OMNIWM_DONE*'
        zpty -d completion
        trap - EXIT HUP INT TERM
        """
        _ = try CLICompletionTestSupport.run("/bin/zsh", arguments: ["-fc", script])
        var fields = try String(contentsOf: result, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false
        )[...]
        let installed = try XCTUnwrap(fields.popFirst())
        let status = try XCTUnwrap(fields.popFirst().flatMap { Int($0) })
        let buffer = try XCTUnwrap(fields.popFirst())
        XCTAssertEqual(fields.popFirst(), "")
        XCTAssertTrue(fields.isEmpty)
        return (String(installed), status, String(buffer))
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
