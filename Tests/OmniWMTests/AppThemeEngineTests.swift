// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

final class AppThemeEngineTests: XCTestCase {
    private var sandbox: AppThemeSandbox!
    private var fake: AppThemeFakeEnvironment!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
        fake = AppThemeFakeEnvironment()
        fake.runningApps = [AppThemeReloader.ghosttyBundleIdentifier]
    }

    override func tearDown() {
        sandbox.remove()
    }

    private func targets(_ apps: [AppThemeBuiltIn], machines: Bool = true) -> [AppThemeTarget] {
        var settings = SettingsExport.AppTheming()
        for app in apps { settings.setEnabled(app, true) }
        settings.herdr.reloadSavedMachines = machines
        return settings.targets(configHome: sandbox.policy.configHome)
    }

    private func run(
        _ targets: [AppThemeTarget],
        palette: AppThemePalette = AppThemeFixtures.palette,
        dark: Bool = true,
        appearanceChanged: Bool = false,
        takeOver: Set<String> = []
    ) -> AppThemeRunReport {
        sandbox.engine(fake).run(AppThemeJob(
            palette: palette,
            dark: dark,
            appearanceChanged: appearanceChanged,
            targets: targets,
            takeOver: takeOver
        ))
    }

    private func inode(_ relative: String) -> UInt64? {
        var info = stat()
        return stat(sandbox.path(relative).path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    func testGhosttyWritesLightAndDarkThemesAndReloadsOnce() throws {
        let report = run(targets([.ghostty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .updated)
        XCTAssertTrue(report.ghosttyThemesChanged)
        let light = try XCTUnwrap(sandbox.read(".config/ghostty/themes/omniwm-light"))
        let dark = try XCTUnwrap(sandbox.read(".config/ghostty/themes/omniwm-dark"))
        XCTAssertTrue(light.contains("background = #eff1f5\n"))
        XCTAssertTrue(dark.contains("background = #11111b\n"))
        XCTAssertEqual(fake.calls.map(\.executable), ["/usr/bin/osascript"])
        XCTAssertEqual(report.results["ghostty"]?.reload, String(localized: "Reloaded Ghostty"))
    }

    func testUnchangedPaletteWritesNothingAndReloadsNothing() throws {
        _ = run(targets([.ghostty, .kitty]))
        let before = inode(".config/ghostty/themes/omniwm-dark")
        let calls = fake.calls.count
        let report = run(targets([.ghostty, .kitty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(inode(".config/ghostty/themes/omniwm-dark"), before)
        XCTAssertEqual(fake.calls.count, calls)
        XCTAssertFalse(report.ghosttyThemesChanged)
    }

    func testWritesAreAtomicReplacementsWithNoLeftovers() throws {
        try sandbox.write("old contents\n", to: ".config/scratch/omniwm.conf")
        let url = sandbox.path(".config/scratch/omniwm.conf")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try AppThemeFileWriter.writeAtomically(Data("new contents\n".utf8), to: url)
        XCTAssertEqual(String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self), "old contents\n")
        XCTAssertEqual(sandbox.read(".config/scratch/omniwm.conf"), "new contents\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["omniwm.conf"])
    }

    func testAtomicWriteKeepsThePermissionsOfTheReplacedFile() throws {
        try sandbox.write("x\n", to: ".config/scratch/private.conf")
        let url = sandbox.path(".config/scratch/private.conf")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try AppThemeFileWriter.writeAtomically(Data("y\n".utf8), to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLightAndDarkSwitchRewritesOnlyCurrentModeOutputs() throws {
        _ = run(targets([.ghostty, .herdr]))
        let herdrDark = try XCTUnwrap(sandbox.read(".config/herdr/config.toml"))
        XCTAssertTrue(herdrDark.contains("text = \"#cdd6f4\""))
        let ghosttyInode = inode(".config/ghostty/themes/omniwm-dark")
        let report = run(targets([.ghostty, .herdr]), dark: false, appearanceChanged: true)
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["herdr"]?.outcome, .updated)
        XCTAssertEqual(inode(".config/ghostty/themes/omniwm-dark"), ghosttyInode)
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("text = \"#4c4f69\""))
    }

    func testNewKittyThemeFilesTellOlderKittyToRestart() throws {
        let first = run(targets([.kitty]))
        XCTAssertEqual(
            first.results["kitty"]?.reload,
            String(localized: "Reloaded kitty; kitty 0.49 or older uses new theme files after a restart")
        )
        let second = run(targets([.kitty]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(second.results["kitty"]?.outcome, .updated)
        XCTAssertEqual(second.results["kitty"]?.reload, String(localized: "Reloaded kitty"))
    }

    func testAReloadFailureDoesNotBlockOtherApps() throws {
        fake.responses["/usr/bin/osascript"] = AppThemeCommandResult(status: 1, output: "execution error: (-1743)")
        let report = run(targets([.ghostty, .kitty, .herdr]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .updated)
        XCTAssertEqual(report.results["ghostty"]?.reloadFailed, true)
        XCTAssertEqual(report.results["kitty"]?.reloadFailed, false)
        XCTAssertEqual(report.results["herdr"]?.reloadFailed, false)
        XCTAssertNotNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertNotNil(sandbox.read(".config/herdr/config.toml"))
        XCTAssertTrue(fake.calls.contains { $0.executable == "/usr/bin/pkill" })
        XCTAssertTrue(fake.calls.contains { $0.arguments == ["server", "reload-config"] })
    }

    func testAForcedReloadRunsOnceEvenWhenNothingChanged() throws {
        _ = run(targets([.ghostty]))
        let before = fake.calls.count
        var job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: targets([.ghostty])
        )
        job.forceReload = ["ghostty"]
        let report = sandbox.engine(fake).run(job)
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["ghostty"]?.reload, String(localized: "Reloaded Ghostty"))
        XCTAssertEqual(fake.calls.dropFirst(before).map(\.executable), ["/usr/bin/osascript"])
        _ = run(targets([.ghostty]))
        XCTAssertEqual(fake.calls.count, before + 1)
    }

    func testAFailedReloadIsRetriedOnTheNextRun() throws {
        fake.responses["/usr/bin/osascript"] = AppThemeCommandResult(status: 1, output: "boom")
        _ = run(targets([.ghostty]))
        fake.responses = [:]
        let report = run(targets([.ghostty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["ghostty"]?.reloadFailed, false)
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count, 2)
        XCTAssertTrue(sandbox.store.load().reloadPending.isEmpty)
    }

    func testAFailingTemplateDoesNotBlockOtherApps() throws {
        let bad = SettingsExport.AppTheming.Custom(
            name: "Broken",
            template: sandbox.path("missing.template").path,
            output: "~/.config/broken/colors.conf"
        )
        let report = run([bad.target] + targets([.kitty]))
        XCTAssertEqual(report.results[bad.targetID]?.outcome, .failed)
        XCTAssertEqual(report.results["kitty"]?.outcome, .updated)
    }

    func testTerminalReloadsComeBeforeHerdrAndItsSavedMachines() throws {
        fake.responses["/opt/homebrew/bin/herdr machine list"] = AppThemeCommandResult(
            status: 0,
            output: #"[{"id":"1","label":"netrunner","enabled":true},{"id":"2","label":"off","enabled":false},{"id":"3","label":"-x","enabled":true}]"#
        )
        let report = run(targets([.herdr, .ghostty]))
        let order = fake.calls.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
        XCTAssertEqual(order, [
            "/usr/bin/osascript -e \(AppThemeReloader.ghosttyScript)",
            "/opt/homebrew/bin/herdr server reload-config",
            "/opt/homebrew/bin/herdr machine list --json",
            "/opt/homebrew/bin/herdr --machine netrunner server reload-config"
        ])
        XCTAssertTrue(report.results["herdr"]?.reload?.contains("1 of 1") == true)
    }

    func testHerdrReloadsSavedMachinesWhenOnlyTheTerminalChanged() throws {
        fake.responses["/opt/homebrew/bin/herdr machine list"] = AppThemeCommandResult(
            status: 0,
            output: #"[{"label":"netrunner","enabled":true}]"#
        )
        _ = run(targets([.herdr, .ghostty]))
        var dark = AppThemeFixtures.dark
        dark[.accentForeground] = AppThemeColor(hex: "#000001")
        let calls = fake.calls.count
        let report = run(
            targets([.herdr, .ghostty]),
            palette: AppThemePalette(light: AppThemeFixtures.light, dark: dark)
        )
        XCTAssertEqual(report.results["ghostty"]?.outcome, .updated)
        XCTAssertEqual(report.results["herdr"]?.outcome, .unchanged)
        XCTAssertEqual(fake.calls.dropFirst(calls).map(\.arguments.last), [
            AppThemeReloader.ghosttyScript, "reload-config", "--json", "reload-config"
        ])
        let before = fake.calls.count
        _ = run(targets([.herdr, .ghostty], machines: false))
        XCTAssertFalse(fake.calls.dropFirst(before).contains { $0.arguments.contains("--machine") })
        XCTAssertTrue(fake.calls.dropFirst(before).contains { $0.arguments == ["server", "reload-config"] })
    }

    func testCommandOutputIsKeptWhole() {
        let result = AppThemeProcessRunner.run(
            "/bin/sh",
            ["-c", "head -c 10000 /dev/zero | tr '\\0' x"],
            timeout: 10
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output.count, 10000)
    }

    func testHerdrNotRunningIsFine() throws {
        fake.responses["/opt/homebrew/bin/herdr server"] = AppThemeCommandResult(
            status: 1,
            output: "error: server_not_running"
        )
        let report = run(targets([.herdr], machines: false))
        XCTAssertEqual(report.results["herdr"]?.reloadFailed, false)
        XCTAssertTrue(sandbox.store.load().reloadPending.isEmpty)
    }

    func testHerdrKeepsTheRestOfItsConfigAndNeedsConsentForAnExistingFile() throws {
        let config = "[keys]\nprefix = \"ctrl+b\"\n\n[theme]\nname = \"terminal\"\n"
        try sandbox.write(config, to: ".config/herdr/config.toml")
        let refused = run(targets([.herdr]))
        XCTAssertEqual(refused.results["herdr"]?.outcome, .conflict)
        XCTAssertEqual(sandbox.read(".config/herdr/config.toml"), config)
        let path = sandbox.path(".config/herdr/config.toml").path
        let report = run(targets([.herdr]), takeOver: [path])
        XCTAssertEqual(report.results["herdr"]?.outcome, .updated)
        let written = try XCTUnwrap(sandbox.read(".config/herdr/config.toml"))
        XCTAssertTrue(written.hasPrefix(config))
        XCTAssertTrue(written.contains("[theme.custom]\n"))
        XCTAssertEqual(run(targets([.herdr])).results["herdr"]?.outcome, .unchanged)
    }

    func testFilesChangedOutsideOmniWMAreNotOverwritten() throws {
        _ = run(targets([.kitty]))
        try sandbox.write("foreground #ffffff\n", to: ".config/kitty/dark-theme.auto.conf")
        let report = run(targets([.kitty]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(report.results["kitty"]?.conflictPaths, ["~/.config/kitty/dark-theme.auto.conf"])
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "foreground #ffffff\n")
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/pkill" }.count, 1)
    }

    func testAnExistingFileOmniWMDidNotWriteNeedsConsent() throws {
        try sandbox.write("include mine.conf\n", to: ".config/kitty/light-theme.auto.conf")
        XCTAssertEqual(run(targets([.kitty])).results["kitty"]?.outcome, .conflict)
        let path = sandbox.path(".config/kitty/light-theme.auto.conf").path
        XCTAssertEqual(run(targets([.kitty]), takeOver: [path]).results["kitty"]?.outcome, .updated)
    }

    func testAnUnreadableExistingFileIsNeverReplaced() throws {
        try sandbox.write("mine\n", to: ".config/kitty/dark-theme.auto.conf")
        let path = sandbox.path(".config/kitty/dark-theme.auto.conf").path
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: path)
        let report = run(targets([.kitty]))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertEqual(report.results["kitty"]?.outcome, .failed)
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "mine\n")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAnExistingOutputThatIsNotTextIsNeverReplaced() throws {
        try sandbox.write("{{mode}}\n", to: "templates/app.conf")
        let url = sandbox.path(".config/app/colors.conf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0x66, 0xFF, 0xFE, 0x0A])
        try original.write(to: url)
        let custom = SettingsExport.AppTheming.Custom(
            name: "App",
            template: sandbox.path("templates/app.conf").path,
            output: "~/.config/app/colors.conf"
        )
        let job = AppThemeJob(palette: AppThemeFixtures.palette, dark: true, appearanceChanged: false, targets: [])
        XCTAssertThrowsError(try sandbox.engine(fake).render(custom.target.outputs[0], job: job))
        let report = run([custom.target], takeOver: [url.path])
        XCTAssertEqual(report.results[custom.targetID]?.outcome, .failed)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTwoAppsCannotShareAnOutputFile() throws {
        try sandbox.write("custom {{colors.background.default.hex}}\n", to: "templates/app.conf")
        try FileManager.default.createDirectory(at: sandbox.path(".config/kitty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sandbox.path(".config/alias"),
            withDestinationURL: sandbox.path(".config/kitty")
        )
        let customs = ["kitty", "alias"].map { folder in
            SettingsExport.AppTheming.Custom(
                name: folder,
                template: sandbox.path("templates/app.conf").path,
                output: "~/.config/\(folder)/dark-theme.auto.conf"
            )
        }
        let all = targets([.kitty]) + customs.map(\.target)
        let first = run(all)
        XCTAssertEqual(first.results["kitty"]?.outcome, .updated)
        for custom in customs {
            XCTAssertEqual(first.results[custom.targetID]?.outcome, .failed, custom.output)
            XCTAssertTrue(first.results[custom.targetID]?.message.contains("kitty") == true, custom.output)
        }
        XCTAssertTrue(sandbox.read(".config/kitty/dark-theme.auto.conf")?.hasPrefix("# Generated by OmniWM") == true)
        let calls = fake.calls.count
        let second = run(all)
        XCTAssertEqual(second.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(fake.calls.count, calls)
    }

    func testAnInterruptedWriteIsRecognisedAsOmniWMsOwn() throws {
        _ = run(targets([.kitty]))
        let url = sandbox.path(".config/kitty/dark-theme.auto.conf")
        let next = try sandbox.engine(fake).render(
            AppThemeBuiltIn.kitty.outputs(configHome: sandbox.policy.configHome)[1],
            job: AppThemeJob(
                palette: AppThemeFixtures.shifted("#000000"),
                dark: true,
                appearanceChanged: false,
                targets: []
            )
        )
        var state = sandbox.store.load()
        state.pending[url.path] = AppThemeFileWriter.digest(next.ownedText)
        try sandbox.store.save(state)
        try AppThemeFileWriter.writeAtomically(next.after, to: url)
        let report = run(targets([.kitty]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(report.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(sandbox.store.load().owned[url.path], AppThemeFileWriter.digest(next.ownedText))
        XCTAssertTrue(sandbox.store.load().pending.isEmpty)
    }

    func testHostileCustomTemplatesCannotRunOrWriteOutsideAllowedFolders() throws {
        let marker = sandbox.root.appendingPathComponent("ran")
        try sandbox.write("x = $(touch \(marker.path))\n`touch \(marker.path)`\n", to: "templates/evil.conf")
        let outputs = [
            "~/.zshrc",
            "~/.config/../.zshrc",
            "/tmp/evil",
            "~/.config/omniwm/settings.toml",
            "~/Library/LaunchAgents/evil.plist"
        ]
        for output in outputs {
            let custom = SettingsExport.AppTheming.Custom(
                name: "Evil",
                template: sandbox.path("templates/evil.conf").path,
                output: output
            )
            let report = run([custom.target])
            XCTAssertEqual(report.results[custom.targetID]?.outcome, .failed, output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path(".zshrc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("Library/LaunchAgents/evil.plist").path))
        let allowed = SettingsExport.AppTheming.Custom(
            name: "Evil",
            template: sandbox.path("templates/evil.conf").path,
            output: "~/.config/evil/evil.conf"
        )
        XCTAssertEqual(run([allowed.target]).results[allowed.targetID]?.outcome, .updated)
        XCTAssertEqual(sandbox.read(".config/evil/evil.conf"), "x = $(touch \(marker.path))\n`touch \(marker.path)`\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testCustomDarkTemplateFollowsTheAppearance() throws {
        try sandbox.write("light {{colors.background.default.hex}}\n", to: "templates/app.conf")
        try sandbox.write("dark {{colors.background.default.hex}}\n", to: "templates/app-dark.conf")
        let custom = SettingsExport.AppTheming.Custom(
            name: "App",
            template: sandbox.path("templates/app.conf").path,
            darkTemplate: sandbox.path("templates/app-dark.conf").path,
            output: "~/.config/app/colors.conf"
        )
        _ = run([custom.target], dark: true)
        XCTAssertEqual(sandbox.read(".config/app/colors.conf"), "dark #11111b\n")
        _ = run([custom.target], dark: false, appearanceChanged: true)
        XCTAssertEqual(sandbox.read(".config/app/colors.conf"), "light #eff1f5\n")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAnOldReloadCommandInSettingsDecodesAndRunsNothing() throws {
        let marker = sandbox.root.appendingPathComponent("ran")
        try sandbox.write("{{mode}}\n", to: "templates/app.conf")
        var inAppTheming = false
        var legacy = String(decoding: try SettingsTOMLCodec.encode(SettingsExport.defaults()), as: UTF8.self)
            .components(separatedBy: "\n")
            .filter { line in
                if line
                    .hasPrefix("[") { inAppTheming = line.hasPrefix("[appTheming") || line.hasPrefix("[[appTheming") }
                return !inAppTheming
            }
            .joined(separator: "\n")
        legacy += """

        [[appTheming.custom]]
        name = "Old"
        enabled = true
        template = "\(sandbox.path("templates/app.conf").path)"
        output = "~/.config/old/mode"
        reload = "command"
        reloadCommand = ["/usr/bin/touch", "\(marker.path)"]

        """
        let custom = try XCTUnwrap(SettingsTOMLCodec.decode(Data(legacy.utf8)).appTheming.custom.first)
        XCTAssertEqual(custom.name, "Old")
        XCTAssertEqual(custom.reload, AppThemeCustomReload.none)
        XCTAssertNil(custom.target.reload)
        let report = run([custom.target])
        XCTAssertEqual(report.results[custom.targetID]?.outcome, .updated)
        XCTAssertNil(report.results[custom.targetID]?.reload)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testResultsArePersistedAndRunsAreSerialised() throws {
        let engine = sandbox.engine(fake)
        let job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: targets([.kitty])
        )
        DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = engine.run(job) }
        XCTAssertEqual(sandbox.store.load().results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/pkill" }.count, 1)
    }

    func testBackupsArePrivate() throws {
        try FileManager.default.createDirectory(
            at: sandbox.store.backupsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let backup = try sandbox.store.backup(Data("token = secret\n".utf8), of: sandbox.path(".config/herdr/config.toml"))
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try manager.attributesOfItem(atPath: sandbox.store.backupsDirectory.path)[.posixPermissions] as? Int,
            0o700
        )
    }

    func testBackupsAreBounded() throws {
        let url = sandbox.path(".config/kitty/kitty.conf")
        for index in 0 ..< AppThemeStateStore.backupLimit + 5 {
            _ = try sandbox.store.backup(
                Data("\(index)".utf8),
                of: url,
                date: Date(timeIntervalSince1970: Double(index))
            )
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.store.backupsDirectory.path)
        XCTAssertEqual(names.count, AppThemeStateStore.backupLimit)
    }
}
