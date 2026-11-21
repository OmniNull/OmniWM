// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppThemeOutputPolicyTests: XCTestCase {
    private var sandbox: AppThemeSandbox!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    func testAllowsFilesUnderTheConfigFolders() throws {
        let policy = sandbox.policy
        XCTAssertEqual(
            try policy.destination(for: "~/.config/ghostty/themes/omniwm-dark").path,
            sandbox.path(".config/ghostty/themes/omniwm-dark").path
        )
        XCTAssertNoThrow(try policy.destination(for: "~/Library/Application Support/com.example/colors.json"))
        XCTAssertEqual(policy.display(sandbox.path(".config/kitty/x.conf")), "~/.config/kitty/x.conf")
    }

    func testRootsResolvedOnceGiveTheSameAnswers() throws {
        let policy = sandbox.policy
        let roots = policy.resolvedRoots()
        try FileManager.default.createDirectory(at: sandbox.path(".config/kitty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sandbox.path(".config/link"), withDestinationURL: sandbox.home)
        for path in [
            "~/.config/ghostty/themes/omniwm-dark", "~/Library/Application Support/x/y.json", "~/.zshrc",
            "~/.config/link/.ssh/config", "~/.config/omniwm/settings.toml", "~/.config/kitty", "relative/theme"
        ] {
            let once = Result { try policy.destination(for: path, roots: roots) }.map(\.path)
            let each = Result { try policy.destination(for: path) }.map(\.path)
            XCTAssertEqual(
                String(describing: once),
                String(describing: each),
                path
            )
        }
    }

    func testRefusesPathsOutsideTheAllowedFolders() {
        let policy = sandbox.policy
        for path in ["~/.zshrc", "~/Documents/theme", "/etc/hosts", "/tmp/theme", "~/.config"] {
            XCTAssertThrowsError(try policy.destination(for: path), path)
        }
        XCTAssertThrowsError(try policy.destination(for: "relative/theme")) {
            XCTAssertEqual($0 as? AppThemeOutputError, .notAbsolute("relative/theme"))
        }
    }

    func testRefusesParentAndCurrentFolderSteps() {
        for path in ["~/.config/../.zshrc", "~/.config/ghostty/../../.ssh/config", "~/.config/./kitty/a.conf"] {
            XCTAssertThrowsError(try sandbox.policy.destination(for: path)) {
                XCTAssertEqual($0 as? AppThemeOutputError, .parentReference(path))
            }
        }
    }

    func testRefusesOmniWMsOwnFoldersAndSensitiveFolders() {
        for path in [
            "~/.config/omniwm/settings.toml", "~/.config/omniwm-dev/settings.toml",
            "~/.local/state/omniwm/app-theming/state.json"
        ] {
            XCTAssertThrowsError(try sandbox.policy.destination(for: path), path)
        }
        XCTAssertThrowsError(try sandbox.policy.destination(for: "~/.config/omniwm/shell/themes/x.toml")) {
            XCTAssertEqual($0 as? AppThemeOutputError, .protectedFolder("~/.config/omniwm/shell/themes/x.toml"))
        }
    }

    func testSymlinkedFolderCannotEscapeTheAllowedFolders() throws {
        let outside = sandbox.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sandbox.path(".config/escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try sandbox.policy.destination(for: "~/.config/escape/theme")) {
            XCTAssertEqual($0 as? AppThemeOutputError, .outsideAllowedFolders("~/.config/escape/theme"))
        }
        let agents = sandbox.path("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sandbox.path(".config/agents"), withDestinationURL: agents)
        XCTAssertThrowsError(try sandbox.policy.destination(for: "~/.config/agents/evil.plist")) {
            XCTAssertEqual($0 as? AppThemeOutputError, .protectedFolder("~/.config/agents/evil.plist"))
        }
    }

    func testSymlinkedDotfilesInsideHomeResolveToTheirTarget() throws {
        let dotfiles = sandbox.path("dotfiles/herdr")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try "".write(to: dotfiles.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sandbox.path(".config/herdr"), withDestinationURL: dotfiles)
        XCTAssertEqual(
            try sandbox.policy.destination(for: "~/.config/herdr/config.toml").path,
            dotfiles.appendingPathComponent("config.toml").path
        )
    }

    func testRefusesAFolderAsTheOutput() throws {
        try FileManager.default.createDirectory(at: sandbox.path(".config/kitty"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try sandbox.policy.destination(for: "~/.config/kitty")) {
            XCTAssertEqual($0 as? AppThemeOutputError, .notRegularFile("~/.config/kitty"))
        }
    }

    func testXDGConfigHomeIsAllowedAndFirst() {
        let custom = sandbox.root.appendingPathComponent("xdg", isDirectory: true)
        let policy = AppThemeOutputPolicy.live(environment: ["XDG_CONFIG_HOME": custom.path], home: sandbox.home)
        XCTAssertEqual(policy.configHome.path, custom.path)
    }
}
