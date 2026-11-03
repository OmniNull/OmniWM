// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

enum LauncherShell: String, Codable, CaseIterable, Sendable {
    case defaultShell
    case system
    case nushell
    case fish
    case zsh
    case bash

    var title: String {
        switch self {
        case .defaultShell: String(localized: "Default Shell")
        case .system: String(localized: "System Login Shell")
        case .nushell: "Nushell"
        case .fish: "fish"
        case .zsh: "zsh"
        case .bash: "Bash"
        }
    }

    var executableName: String {
        self == .nushell ? "nu" : rawValue
    }

    static func kind(for executable: String) throws -> Self {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard let kind = allCases.first(where: { $0 != .system && $0 != .defaultShell && $0.executableName == name })
        else {
            throw LauncherFailure(String(localized: "Choose Nushell, fish, zsh, or Bash in Launcher settings."))
        }
        return kind
    }

    func commandArguments(_ text: String, interactive: Bool) -> [String] {
        if self == .nushell {
            return (interactive ? ["--login", "--interactive"] : []) + ["--commands", text]
        }
        return (interactive ? ["-l", "-i"] : []) + ["-c", text]
    }
}

enum LauncherTerminal: String, Codable, CaseIterable, Sendable {
    case defaultTerminal
    case builtIn
    case terminal
    case ghostty
    case iterm
    case kitty
    case background

    var title: String {
        switch self {
        case .defaultTerminal: String(localized: "Default Terminal")
        case .builtIn: String(localized: "Built-in Quake Terminal")
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm2"
        case .kitty: "kitty"
        case .background: String(localized: "Background")
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm: "com.googlecode.iterm2"
        case .kitty: "net.kovidgoyal.kitty"
        default: nil
        }
    }
}

struct LauncherEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case application
        case command
        case script
        case executable

        var title: String {
            switch self {
            case .application: String(localized: "Application")
            case .command: String(localized: "Command")
            case .script: String(localized: "Script")
            case .executable: String(localized: "CLI")
            }
        }
    }

    var id = UUID()
    var name = ""
    var kind: Kind = .command
    var path = ""
    var command = ""
    var arguments: [String] = []
    var keywords = ""
    var workingDirectory = ""
    var shell: LauncherShell = .defaultShell
    var shellExecutable = ""
    var interpreter = ""
    var terminal: LauncherTerminal = .defaultTerminal

    var symbol: String {
        switch kind {
        case .application: "app.fill"
        case .script: "doc.text"
        case .command,
             .executable: "terminal"
        }
    }

    var bundleIdentifier: String? {
        guard kind == .application else { return nil }
        return ApplicationCatalogFilter.resolvedBundleURL(LauncherPaths.expanded(path))
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    func matches(_ query: String) -> Bool {
        let fields = [name, keywords, path, command]
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

extension LauncherEntry {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .command
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        keywords = try values.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        shell = try values.decodeIfPresent(LauncherShell.self, forKey: .shell) ?? .defaultShell
        shellExecutable = try values.decodeIfPresent(String.self, forKey: .shellExecutable) ?? ""
        interpreter = try values.decodeIfPresent(String.self, forKey: .interpreter) ?? ""
        terminal = try values.decodeIfPresent(LauncherTerminal.self, forKey: .terminal) ?? .defaultTerminal
    }
}

struct LauncherConfiguration: Codable, Equatable, Sendable {
    var entries: [LauncherEntry] = []
    var appFolders: [String] = []
    var cliFolders: [String] = []
    var shell: LauncherShell = .system
    var shellExecutable = ""
    var terminal: LauncherTerminal = .terminal

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([LauncherEntry].self, forKey: .entries) ?? []
        appFolders = try values.decodeIfPresent([String].self, forKey: .appFolders) ?? []
        cliFolders = try values.decodeIfPresent([String].self, forKey: .cliFolders) ?? []
        shell = try values.decodeIfPresent(LauncherShell.self, forKey: .shell) ?? .system
        shellExecutable = try values.decodeIfPresent(String.self, forKey: .shellExecutable) ?? ""
        terminal = try values.decodeIfPresent(LauncherTerminal.self, forKey: .terminal) ?? .terminal
    }
}

struct LauncherFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

enum LauncherPaths {
    static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func binFolders(home: String, environment: [String: String]) -> [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.nix-profile/bin",
            "/etc/profiles/per-user/" + URL(fileURLWithPath: home).lastPathComponent + "/bin",
            "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
            (environment["XDG_STATE_HOME"] ?? home + "/.local/state") + "/nix/profile/bin"
        ]
    }

    static func shell(
        _ selection: LauncherShell,
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (kind: LauncherShell, path: String) {
        if !executable.isEmpty {
            let path = expanded(executable)
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw LauncherFailure(String(localized: "The selected shell is not executable: \(path)"))
            }
            let kind = try LauncherShell.kind(for: path)
            guard selection == .system || selection == .defaultShell || selection == kind else {
                throw LauncherFailure(
                    "The selected executable is \(kind.title), not \(selection.title). Choose a matching shell executable."
                )
            }
            return (kind, path)
        }
        if selection == .system || selection == .defaultShell {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 16_384)
            let path: String? = buffer.withUnsafeMutableBufferPointer { buffer in
                guard getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result) == 0,
                      result != nil, let shell = record.pw_shell else { return nil }
                return String(cString: shell)
            }
            return try loginShell(path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + binFolders(home: home, environment: environment) + ["/bin", "/usr/bin"]
        for folder in folders where folder.hasPrefix("/") {
            let path = folder + "/" + selection.executableName
            if FileManager.default.isExecutableFile(atPath: path) { return (selection, path) }
        }
        throw LauncherFailure(
            String(localized: "\(selection.title) is not installed. Choose its executable in Launcher settings.")
        )
    }

    static func loginShell(_ path: String?) throws -> (kind: LauncherShell, path: String) {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            throw LauncherFailure(String(localized: "The system login shell could not be found."))
        }
        guard let kind = try? LauncherShell.kind(for: path) else { return (.zsh, "/bin/zsh") }
        return (kind, path)
    }
}
