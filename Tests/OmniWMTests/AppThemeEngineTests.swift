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
        fake.runGhostty()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private func targets(_ apps: [AppThemeBuiltIn]) -> [AppThemeTarget] {
        var settings = SettingsExport.AppTheming()
        for app in apps { settings.setEnabled(app, true) }
        return settings.targets(configHome: sandbox.policy.configHome)
    }

    private func run(
        _ targets: [AppThemeTarget],
        palette: AppThemePalette = AppThemeFixtures.palette,
        dark: Bool = true,
        takeOver: Set<String> = []
    ) -> AppThemeRunReport {
        sandbox.engine(fake).run(AppThemeJob(
            palette: palette,
            dark: dark,
            targets: targets,
            takeOver: Dictionary(uniqueKeysWithValues: takeOver.map { path in
                (path, AppThemeFileWriter.digest((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()))
            })
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
        XCTAssertEqual(fake.events, ["signal \(AppThemeFakeEnvironment.ghosttyPID) \(SIGUSR2)"])
        XCTAssertEqual(report.results["ghostty"]?.reload, String(localized: "Reloaded Ghostty"))
    }

    func testUnchangedPaletteWritesNothingAndReloadsNothing() throws {
        _ = run(targets([.ghostty, .kitty]))
        let before = inode(".config/ghostty/themes/omniwm-dark")
        let calls = fake.events.count
        let report = run(targets([.ghostty, .kitty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(inode(".config/ghostty/themes/omniwm-dark"), before)
        XCTAssertEqual(fake.events.count, calls)
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
        try sandbox.write("{{mode}}", to: "templates/mode")
        let mode = AppThemingCustom(
            name: "Mode", template: sandbox.path("templates/mode").path, output: "~/.config/custom/mode"
        )
        let apps = targets([.ghostty]) + [mode.target]
        _ = run(apps)
        XCTAssertEqual(sandbox.read(".config/custom/mode"), "dark")
        let ghosttyInode = inode(".config/ghostty/themes/omniwm-dark")
        let report = run(apps, dark: false)
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results[mode.targetID]?.outcome, .updated)
        XCTAssertEqual(inode(".config/ghostty/themes/omniwm-dark"), ghosttyInode)
        XCTAssertEqual(sandbox.read(".config/custom/mode"), "light")
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
        fake.signalErrors[AppThemeFakeEnvironment.ghosttyPID] = EPERM
        let report = run(targets([.ghostty, .kitty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .updated)
        XCTAssertEqual(report.results["ghostty"]?.reloadFailed, true)
        XCTAssertEqual(report.results["kitty"]?.reloadFailed, false)
        XCTAssertNotNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertTrue(fake.signals.contains { $0.signal == SIGUSR1 })
    }

    func testEachAppIsReloadedOncePerRunHoweverManyTargetsAskForIt() throws {
        try sandbox.write("{{mode}}\n", to: "templates/mode.conf")
        let customs = [AppThemeCustomReload.ghostty, .kitty].map { reload in
            SettingsExport.AppTheming.Custom(
                name: reload.rawValue,
                template: sandbox.path("templates/mode.conf").path,
                output: "~/.config/extra/\(reload.rawValue).conf",
                reload: reload
            ).target
        }
        let report = run(targets([.ghostty, .kitty]) + customs)
        XCTAssertEqual(fake.events, [
            "signal \(AppThemeFakeEnvironment.ghosttyPID) \(SIGUSR2)",
            "signal \(AppThemeFakeEnvironment.kittyPID) \(SIGUSR1)"
        ])
        for target in targets([.ghostty, .kitty]) + customs {
            XCTAssertNotNil(report.results[target.id]?.reload, target.name)
        }
        XCTAssertTrue(try sandbox.store.load().reloadPending.isEmpty)
    }

    func testAForcedReloadRunsOnceEvenWhenNothingChanged() throws {
        _ = run(targets([.ghostty]))
        let before = fake.events.count
        var job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            targets: targets([.ghostty])
        )
        job.forceReload = ["ghostty"]
        let report = sandbox.engine(fake).run(job)
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["ghostty"]?.reload, String(localized: "Reloaded Ghostty"))
        XCTAssertEqual(fake.events.dropFirst(before), ["signal \(AppThemeFakeEnvironment.ghosttyPID) \(SIGUSR2)"])
        _ = run(targets([.ghostty]))
        XCTAssertEqual(fake.events.count, before + 1)
    }

    func testAFailedReloadIsRetriedOnTheNextRun() throws {
        fake.signalErrors[AppThemeFakeEnvironment.ghosttyPID] = EPERM
        _ = run(targets([.ghostty]))
        fake.signalErrors = [:]
        let report = run(targets([.ghostty]))
        XCTAssertEqual(report.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(report.results["ghostty"]?.reloadFailed, false)
        XCTAssertEqual(fake.signals.count, 2)
        XCTAssertTrue(try sandbox.store.load().reloadPending.isEmpty)
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

    func testFilesChangedOutsideOmniWMAreNotOverwritten() throws {
        _ = run(targets([.kitty]))
        try sandbox.write("foreground #ffffff\n", to: ".config/kitty/dark-theme.auto.conf")
        let report = run(targets([.kitty]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(report.results["kitty"]?.conflictPaths, ["~/.config/kitty/dark-theme.auto.conf"])
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "foreground #ffffff\n")
        XCTAssertEqual(fake.signals.filter { $0.signal == SIGUSR1 }.count, 1)
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
        XCTAssertEqual(
            report.results["kitty"]?.message,
            AppThemeEngineError.unreadable(
                "~/.config/kitty/dark-theme.auto.conf",
                String(cString: strerror(EACCES))
            ).localizedDescription
        )
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "mine\n")
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testAnExistingOutputThatIsNotARegularFileIsNeverRead() throws {
        try FileManager.default.createDirectory(at: sandbox.path(".config/kitty"), withIntermediateDirectories: true)
        let fifo = sandbox.path(".config/kitty/dark-theme.auto.conf").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let report = run(targets([.kitty]))
        XCTAssertEqual(report.results["kitty"]?.outcome, .failed)
        XCTAssertEqual(
            report.results["kitty"]?.message,
            AppThemeOutputError.notRegularFile("~/.config/kitty/dark-theme.auto.conf").localizedDescription
        )
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testADanglingOutputLinkIsRefusedNotReplaced() throws {
        let folder = sandbox.path(".config/kitty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("dark-theme.auto.conf")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: sandbox.path(".config/themes/missing.conf")
        )
        let report = run(targets([.kitty]))
        XCTAssertEqual(report.results["kitty"]?.outcome, .failed)
        XCTAssertEqual(
            report.results["kitty"]?.message,
            AppThemeOutputError.notRegularFile("~/.config/kitty/dark-theme.auto.conf").localizedDescription
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            sandbox.path(".config/themes/missing.conf").path
        )
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testATemplateThatIsNotARegularFileIsNeverRead() throws {
        try FileManager.default.createDirectory(at: sandbox.path("templates"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(sandbox.path("templates/app.conf").path, 0o600), 0)
        let custom = SettingsExport.AppTheming.Custom(
            name: "App",
            template: sandbox.path("templates/app.conf").path,
            output: "~/.config/app/colors.conf"
        )
        let report = run([custom.target])
        XCTAssertEqual(report.results[custom.targetID]?.outcome, .failed)
        XCTAssertNil(sandbox.read(".config/app/colors.conf"))
    }

    func testAnUnreadableStateFileStopsEveryAppWithAMessage() throws {
        _ = run(targets([.kitty]))
        let state = sandbox.store.stateURL.path
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: state)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state) }
        let events = fake.events.count
        let report = run(targets([.kitty, .neovim]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(report.results["kitty"]?.outcome, .failed)
        XCTAssertEqual(report.results["neovim"]?.outcome, .failed)
        XCTAssertTrue(report.results["kitty"]?.message.contains("state.json") == true)
        XCTAssertNil(sandbox.read(".config/nvim/lua/omniwm.lua"))
        XCTAssertEqual(fake.events.count, events)
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
        let job = AppThemeJob(palette: AppThemeFixtures.palette, dark: true, targets: [])
        XCTAssertThrowsError(try sandbox.engine(fake).render(custom.target.outputs[0], job: job))
        let report = run([custom.target], takeOver: [url.path])
        XCTAssertEqual(report.results[custom.targetID]?.outcome, .failed)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testASaveMadeJustBeforeTheReplaceIsKept() throws {
        _ = run(targets([.kitty]))
        let path = sandbox.path(".config/kitty/dark-theme.auto.conf")
        let edited = try XCTUnwrap(sandbox.read(".config/kitty/dark-theme.auto.conf")) + "\nbackground #123456\n"
        var engine = sandbox.engine(fake)
        let prepared = AppThemeSeen()
        engine.willReplace = { url in
            guard url == path else { return }
            prepared.note(AppThemeSeen.replacementIsPrepared(beside: url))
            try? Data(edited.utf8).write(to: url)
        }
        let events = fake.events.count
        var dark = AppThemeFixtures.dark
        dark[.accent] = AppThemeColor(hex: "#000001")
        let report = engine.run(AppThemeJob(
            palette: AppThemePalette(light: AppThemeFixtures.light, dark: dark),
            dark: true,
            targets: targets([.kitty])
        ))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), edited)
        XCTAssertEqual(fake.events.count, events)
        XCTAssertNil(try sandbox.store.load().pending[path.path])
        XCTAssertTrue(prepared.value)
        XCTAssertEqual(AppThemeSeen.leftovers(beside: path), [])
    }

    func testAnAppsEarlierFilesAreRestoredWhenALaterOneCannotBeReplaced() throws {
        _ = run(targets([.kitty]))
        let light = try XCTUnwrap(sandbox.read(".config/kitty/light-theme.auto.conf"))
        let dark = sandbox.path(".config/kitty/dark-theme.auto.conf")
        var engine = sandbox.engine(fake)
        engine.willReplace = { url in
            guard url == dark else { return }
            try? Data("foreground #ffffff\n".utf8).write(to: url)
        }
        var lightRoles = AppThemeFixtures.light
        lightRoles[.background] = AppThemeColor(hex: "#ffffff")
        var darkRoles = AppThemeFixtures.dark
        darkRoles[.background] = AppThemeColor(hex: "#000000")
        let events = fake.events.count
        let report = engine.run(AppThemeJob(
            palette: AppThemePalette(light: lightRoles, dark: darkRoles),
            dark: true,
            targets: targets([.kitty])
        ))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(sandbox.read(".config/kitty/light-theme.auto.conf"), light)
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "foreground #ffffff\n")
        XCTAssertEqual(fake.events.count, events)
        XCTAssertEqual(run(targets([.kitty])).results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(sandbox.read(".config/kitty/light-theme.auto.conf"), light)
    }

    func testAnAppsNewFilesAreRemovedWhenALaterOneCannotBeReplaced() throws {
        let dark = sandbox.path(".config/kitty/dark-theme.auto.conf")
        var engine = sandbox.engine(fake)
        engine.willReplace = { url in
            guard url == dark else { return }
            try? Data("foreground #ffffff\n".utf8).write(to: url)
        }
        let report = engine.run(AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            targets: targets([.kitty])
        ))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertNil(sandbox.read(".config/kitty/light-theme.auto.conf"))
        XCTAssertEqual(AppThemeSeen.leftovers(beside: dark), [])
    }

    func testAnApprovedFileThatChangesBeforeTheReplaceAsksForAnotherReview() throws {
        try sandbox.write("include mine.conf\n", to: ".config/kitty/dark-theme.auto.conf")
        let url = sandbox.path(".config/kitty/dark-theme.auto.conf")
        var engine = sandbox.engine(fake)
        let prepared = AppThemeSeen()
        engine.willReplace = { replaced in
            guard replaced == url else { return }
            prepared.note(AppThemeSeen.replacementIsPrepared(beside: replaced))
            try? Data("include newer.conf\n".utf8).write(to: replaced)
        }
        let report = engine.run(AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            targets: targets([.kitty]),
            takeOver: [url.path: AppThemeFileWriter.digest(Data("include mine.conf\n".utf8))]
        ))
        XCTAssertEqual(report.results["kitty"]?.outcome, .conflict)
        XCTAssertEqual(report.reviewAgain, ["kitty"])
        XCTAssertTrue(prepared.value)
        XCTAssertEqual(AppThemeSeen.leftovers(beside: url), [])
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "include newer.conf\n")
    }

    func testAReviewedConfigEditIsCheckedAgainRightBeforeTheReplace() throws {
        try sandbox.write("theme = a\n", to: ".config/ghostty/config")
        let url = sandbox.path(".config/ghostty/config")
        let change = AppThemeChange(
            url: url,
            display: "~/.config/ghostty/config",
            before: "theme = a\n",
            after: "# theme = a\n",
            beforeDigest: AppThemeFileWriter.digest(Data("theme = a\n".utf8))
        )
        var engine = sandbox.engine(fake)
        let prepared = AppThemeSeen()
        engine.willReplace = { replaced in
            prepared.note(AppThemeSeen.replacementIsPrepared(beside: replaced))
            try? Data("theme = b\n".utf8).write(to: replaced)
        }
        XCTAssertThrowsError(try engine.store.withLock { try engine.commit([change]) }) { error in
            XCTAssertEqual(error as? AppThemeEngineError, .changedOutsideOmniWM(["~/.config/ghostty/config"]))
        }
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = b\n")
        XCTAssertTrue(prepared.value)
        XCTAssertEqual(AppThemeSeen.leftovers(beside: url), [])
    }

    private func ghosttyConfigEdit() throws -> AppThemeChange {
        try sandbox.write("theme = a\n", to: ".config/ghostty/config")
        return AppThemeChange(
            url: sandbox.path(".config/ghostty/config"),
            display: "~/.config/ghostty/config",
            before: "theme = a\n",
            after: "# theme = a\n",
            beforeDigest: AppThemeFileWriter.digest(Data("theme = a\n".utf8))
        )
    }

    private func gatedJob(_ apps: [AppThemeBuiltIn], enabled: AppThemeEnabledTargets) -> AppThemeJob {
        var job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            targets: targets(apps)
        )
        job.enabled = enabled
        return job
    }

    func testAGhosttyConfigEditIsDroppedWhenGhosttyWasTurnedOffBeforeItsRun() throws {
        var job = gatedJob([.ghostty, .kitty], enabled: AppThemeEnabledTargets(["kitty"]))
        job.selection = try [ghosttyConfigEdit()]
        _ = sandbox.engine(fake).run(job)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
        XCTAssertNotNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
    }

    func testARunThatWaitedForTheLockAfterEverythingWasTurnedOffDoesNothing() throws {
        let enabled = AppThemeEnabledTargets(["ghostty", "kitty"])
        var job = gatedJob([.ghostty, .kitty], enabled: enabled)
        job.selection = try [ghosttyConfigEdit()]
        var engine = sandbox.engine(fake)
        engine.willLock = { enabled.set([]) }
        let report = engine.run(job)
        XCTAssertTrue(report.results.isEmpty)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.store.stateURL.path))
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testAnAppTurnedOffJustBeforeAReplaceIsNotReplaced() throws {
        let enabled = AppThemeEnabledTargets(["kitty"])
        var engine = sandbox.engine(fake)
        engine.willReplace = { _ in enabled.set([]) }
        let report = engine.run(gatedJob([.kitty], enabled: enabled))
        XCTAssertNil(report.results["kitty"])
        XCTAssertNil(sandbox.read(".config/kitty/light-theme.auto.conf"))
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testAGhosttyConfigEditStopsWhenGhosttyIsTurnedOffJustBeforeTheReplace() throws {
        let enabled = AppThemeEnabledTargets(["ghostty", "kitty"])
        var job = gatedJob([.ghostty, .kitty], enabled: enabled)
        job.selection = try [ghosttyConfigEdit()]
        var engine = sandbox.engine(fake)
        let config = sandbox.path(".config/ghostty/config")
        engine.willReplace = { url in
            if url == config { enabled.set(["kitty"]) }
        }
        _ = engine.run(job)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
    }

    func testReloadsStopForAnAppTurnedOffDuringAnEarlierReload() throws {
        let enabled = AppThemeEnabledTargets(["kitty", "neovim"])
        fake.onEvent = { event in
            if event.hasPrefix("signal") { enabled.set(["kitty"]) }
        }
        let report = sandbox.engine(fake).run(gatedJob([.kitty, .neovim], enabled: enabled))
        XCTAssertEqual(fake.events, ["signal \(AppThemeFakeEnvironment.kittyPID) \(SIGUSR1)"])
        XCTAssertNil(report.results["neovim"]?.reload)
    }

    func testAGhosttyConfigEditIsUndoneWhenALaterFileCannotBeReplaced() throws {
        let support = "Library/Application Support/com.mitchellh.ghostty/config"
        try sandbox.write("theme = a\n", to: ".config/ghostty/config")
        try sandbox.write("theme = b\n", to: support)
        func edit(_ relative: String, _ before: String, _ after: String) -> AppThemeChange {
            AppThemeChange(
                url: sandbox.path(relative),
                display: "~/" + relative,
                before: before,
                after: after,
                beforeDigest: AppThemeFileWriter.digest(Data(before.utf8))
            )
        }
        let changes = [
            edit(".config/ghostty/config", "theme = a\n", "# theme = a\n"),
            edit(support, "theme = b\n", "theme = b\n\(AppThemeBuiltIn.ghosttyThemeLine)\n")
        ]
        var engine = sandbox.engine(fake)
        let later = sandbox.path(support)
        engine.willReplace = { url in
            guard url == later else { return }
            try? Data("theme = c\n".utf8).write(to: url)
        }
        XCTAssertThrowsError(try engine.store.withLock { try engine.commit(changes) })
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
        XCTAssertEqual(sandbox.read(support), "theme = c\n")
    }

    func testTwoOutputsOfOneAppCannotShareAFile() throws {
        let themes = sandbox.path(".config/ghostty/themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try sandbox.write("mine\n", to: ".config/ghostty/themes/shared")
        for name in ["omniwm-light", "omniwm-dark"] {
            try FileManager.default.createSymbolicLink(
                at: themes.appendingPathComponent(name),
                withDestinationURL: themes.appendingPathComponent("shared")
            )
        }
        let shared = themes.appendingPathComponent("shared").path
        let report = run(targets([.ghostty]), takeOver: [shared])
        XCTAssertEqual(report.results["ghostty"]?.outcome, .failed)
        XCTAssertEqual(
            report.results["ghostty"]?.message,
            AppThemeEngineError.sharedOutput(path: "~/.config/ghostty/themes/shared", owner: "Ghostty")
                .localizedDescription
        )
        XCTAssertEqual(sandbox.read(".config/ghostty/themes/shared"), "mine\n")
        XCTAssertTrue(fake.events.isEmpty)
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
        let all = targets([.kitty]) + customs.map { $0.target }
        let first = run(all)
        XCTAssertEqual(first.results["kitty"]?.outcome, .updated)
        for custom in customs {
            XCTAssertEqual(first.results[custom.targetID]?.outcome, .failed, custom.output)
            XCTAssertTrue(first.results[custom.targetID]?.message.contains("kitty") == true, custom.output)
        }
        XCTAssertTrue(sandbox.read(".config/kitty/dark-theme.auto.conf")?.hasPrefix("# Generated by OmniWM") == true)
        let calls = fake.events.count
        let second = run(all)
        XCTAssertEqual(second.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(fake.events.count, calls)
    }

    func testATakeoverBacksUpExactlyTheBytesItReplaces() throws {
        try sandbox.write("include mine.conf\n", to: ".config/kitty/light-theme.auto.conf")
        let path = sandbox.path(".config/kitty/light-theme.auto.conf").path
        XCTAssertEqual(run(targets([.kitty]), takeOver: [path]).results["kitty"]?.outcome, .updated)
        let folder = sandbox.store.backupsDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 1)
        let backup = try XCTUnwrap(names.first.map { folder.appendingPathComponent($0) })
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "include mine.conf\n")
    }

    func testAnInterruptedWriteIsRecognisedAsOmniWMsOwn() throws {
        _ = run(targets([.kitty]))
        let url = sandbox.path(".config/kitty/dark-theme.auto.conf")
        let next = try sandbox.engine(fake).render(
            AppThemeBuiltIn.kitty.outputs(configHome: sandbox.policy.configHome)[1],
            job: AppThemeJob(
                palette: AppThemeFixtures.shifted("#000000"),
                dark: true,
                targets: []
            )
        )
        var state = try sandbox.store.load()
        state.pending[url.path] = AppThemeFileWriter.digest(next.after)
        try sandbox.store.save(state)
        try AppThemeFileWriter.writeAtomically(next.after, to: url)
        let report = run(targets([.kitty]), palette: AppThemeFixtures.shifted("#000000"))
        XCTAssertEqual(report.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(try sandbox.store.load().owned[url.path], AppThemeFileWriter.digest(next.after))
        XCTAssertTrue(try sandbox.store.load().pending.isEmpty)
    }

    func testHostileCustomTemplatesCannotRunOrWriteOutsideAllowedFolders() throws {
        let marker = sandbox.root.appendingPathComponent("ran")
        try sandbox.write("x = $(touch \(marker.path))\n`touch \(marker.path)`\n", to: "templates/evil.conf")
        let outputs = [
            "~/.zshrc",
            "~/.config/../.zshrc",
            "/tmp/evil",
            "~/.config/omniwm/settings.luau",
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
        XCTAssertTrue(fake.events.isEmpty)
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
        _ = run([custom.target], dark: false)
        XCTAssertEqual(sandbox.read(".config/app/colors.conf"), "light #eff1f5\n")
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testAnUnknownReloadOptionNeverRunsAProgram() throws {
        let marker = sandbox.root.appendingPathComponent("ran")
        try sandbox.write("{{mode}}\n", to: "templates/app.conf")
        let entry: [String: SettingsLuauValue] = [
            "name": .string("Old"), "enabled": .boolean(true),
            "template": .string(sandbox.path("templates/app.conf").path), "output": .string("~/.config/old/mode"),
            "reload": .string("command")
        ]
        func source(_ entry: [String: SettingsLuauValue]) -> Data {
            SettingsLuauFixture.source(["appTheming": .record(["custom": .list([.record(entry)])])])
        }
        var withCommand = entry
        withCommand["reloadCommand"] = .list([.string("/usr/bin/touch"), .string(marker.path)])
        XCTAssertThrowsError(try SettingsLuauFixture.decode(source(withCommand)))
        let custom = try XCTUnwrap(SettingsLuauFixture.decode(source(entry)).appTheming.custom.first)
        XCTAssertEqual(custom.name, "Old")
        XCTAssertEqual(custom.reload, AppThemeCustomReload.none)
        XCTAssertNil(custom.target.reload)
        let report = run([custom.target])
        XCTAssertEqual(report.results[custom.targetID]?.outcome, .updated)
        XCTAssertNil(report.results[custom.targetID]?.reload)
        XCTAssertTrue(fake.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testResultsArePersistedAndRunsAreSerialised() throws {
        let engine = sandbox.engine(fake)
        let job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            targets: targets([.kitty])
        )
        let simultaneousRuns = 4
        DispatchQueue.concurrentPerform(iterations: simultaneousRuns) { _ in _ = engine.run(job) }
        XCTAssertEqual(try sandbox.store.load().results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(fake.signals.filter { $0.signal == SIGUSR1 }.count, 1)
    }

    func testBackupsArePrivate() throws {
        try FileManager.default.createDirectory(
            at: sandbox.store.backupsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let backup = try sandbox.store.backup(
            Data("token = secret\n".utf8),
            of: sandbox.path(".config/kitty/dark-theme.auto.conf")
        )
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try manager.attributesOfItem(atPath: sandbox.store.backupsDirectory.path)[.posixPermissions] as? Int,
            0o700
        )
    }

    func testTwoBackupsMadeAtTheSameMomentAreBothKept() throws {
        let url = sandbox.path(".config/kitty/kitty.conf")
        let moment = Date(timeIntervalSince1970: 0)
        let first = try sandbox.store.backup(Data("first\n".utf8), of: url, date: moment)
        let second = try sandbox.store.backup(Data("second\n".utf8), of: url, date: moment)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second\n")
    }

    func testBackupsAreBounded() throws {
        let url = sandbox.path(".config/kitty/kitty.conf")
        let beyondTheLimit = 5
        for index in 0 ..< AppThemeStateStore.backupLimit + beyondTheLimit {
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
