// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public struct LauncherHelperRequest: Codable, Sendable {
    public static let terminalEnvironmentKeys: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO", "TERMINFO_DIRS",
        "TTY"
    ]

    public let argv: [String]
    public let directory: String
    public let environment: [String: String]
    public let isolateEnvironment: Bool
    public let holdOutput: Bool
    public let exitStatusLabel: String
    public let holdPrompt: String

    public init(
        argv: [String],
        directory: String,
        environment: [String: String],
        isolateEnvironment: Bool,
        holdOutput: Bool,
        exitStatusLabel: String,
        holdPrompt: String
    ) {
        self.argv = argv
        self.directory = directory
        self.environment = environment
        self.isolateEnvironment = isolateEnvironment
        self.holdOutput = holdOutput
        self.exitStatusLabel = exitStatusLabel
        self.holdPrompt = holdPrompt
    }
}
