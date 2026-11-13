// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppThemeNeovimTests: XCTestCase {
    private var sandbox: AppThemeSandbox!
    private var fake: AppThemeFakeEnvironment!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
        fake = AppThemeFakeEnvironment()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private func module(_ palette: AppThemePalette, dark: Bool) throws -> String {
        try AppThemeTemplate.render(AppThemeBuiltIn.neovim.template, palette: palette, dark: dark)
    }

    private func table(_ dark: Bool, in lua: String) throws -> String {
        let start = try XCTUnwrap(lua.range(of: "\n  \(dark ? "dark" : "light") = {\n"))
        let end = try XCTUnwrap(lua.range(of: "\n  },", range: start.upperBound ..< lua.endIndex))
        return String(lua[start.upperBound ..< end.lowerBound])
    }

    private func base16(in lua: String, dark: Bool) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: table(dark, in: lua).matches(of: /(base0[0-9A-F]) = "(#[0-9a-f]{6})",/)
            .map {
                (String($0.1), String($0.2))
            })
    }

    private var wallpaper: AppThemePalette {
        AppThemePalette(
            light: AppThemeFixtures.light,
            dark: AppThemeFixtures.dark,
            terminalColors: .palette,
            ownHues: false
        )
    }

    func testModuleSetsEveryBase16SlotInBothModesAndTerminalModes() throws {
        let standard = AppThemePalette(
            light: AppThemeFixtures.light,
            dark: AppThemeFixtures.dark,
            terminalColors: .standard
        )
        for palette in [AppThemeFixtures.palette, standard, wallpaper] {
            for dark in [false, true] {
                let lua = try module(palette, dark: dark)
                let scheme = palette.scheme(dark: dark)
                XCTAssertTrue(lua.contains("require(\"base16-colorscheme\").setup(scheme)"))
                XCTAssertFalse(lua.contains("{{"))
                let slots = try base16(in: lua, dark: dark)
                XCTAssertEqual(Set(slots.keys), Set(AppThemeBase16.slots))
                XCTAssertEqual(slots["base00"], scheme.roles[.background]?.hex)
                XCTAssertEqual(slots["base05"], scheme.ansi[15].hex)
                XCTAssertEqual(slots["base08"], scheme.ansi[1].hex)
                let quoted = lua.matches(of: /"(#[^"]*)"/).map { String($0.1) }
                XCTAssertTrue(quoted.allSatisfy { $0.wholeMatch(of: /#[0-9a-f]{6}/) != nil })
                let background = try XCTUnwrap(scheme.roles[.background])
                for slot in AppThemeBase16.slots.suffix(8) {
                    let color = try XCTUnwrap(AppThemeColor(hex: slots[slot]!))
                    XCTAssertGreaterThanOrEqual(color.contrast(background), AppThemeANSI.readableContrast, slot)
                }
            }
        }
        for palette in [wallpaper, standard] {
            let slots = try base16(in: module(palette, dark: true), dark: true)
            let ansi = palette.dark.ansi.map(\.hex)
            XCTAssertEqual(
                [slots["base08"], slots["base0A"], slots["base0B"], slots["base0C"], slots["base0D"], slots["base0E"]],
                [ansi[1], ansi[3], ansi[2], ansi[6], ansi[4], ansi[5]]
            )
        }
    }

    func testModuleReloadsOnSignalOnceAndKeepsPickerGroups() throws {
        let lua = try module(AppThemeFixtures.palette, dark: true)
        XCTAssertTrue(lua.contains("local events = vim.api.nvim_create_augroup(\"OmniWM\", { clear = true })"))
        XCTAssertTrue(lua.contains(
            "vim.api.nvim_create_autocmd(\"Signal\", { group = events, pattern = \"SIGUSR1\", callback = reapply })"
        ))
        XCTAssertTrue(lua.contains("package.loaded[\"omniwm\"] = nil"))
        for group in [
            "TelescopeNormal",
            "TelescopeSelection",
            "TelescopeMatching",
            "MiniPickNormal",
            "MiniPickMatchRanges"
        ] {
            XCTAssertTrue(lua.contains("\n    \(group) = { "), group)
        }
    }

    func testReloadSignalsNeovimWithoutRunningAnything() {
        let outcome = AppThemeReloader(environment: fake.environment).reload(.neovim)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(fake.signals, [.init(pid: AppThemeFakeEnvironment.neovimPID, signal: SIGUSR1)])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testNoNeovimRunningIsSuccess() {
        fake.processes = [:]
        let outcome = AppThemeReloader(environment: fake.environment).reload(.neovim)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(
            outcome.message,
            String(localized: "Neovim isn’t running; it loads the new colors when it starts")
        )
    }

    func testNeovimReloadsAfterTerminalsAndBeforeHerdr() throws {
        fake.runGhostty()
        var settings = SettingsExport.AppTheming()
        settings.herdr = .init(enabled: true, reloadSavedMachines: false)
        settings.neovim.enabled = true
        settings.ghostty.enabled = true
        let report = sandbox.engine(fake).run(AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: settings.targets(configHome: sandbox.policy.configHome)
        ))
        XCTAssertEqual(fake.events.map { $0.components(separatedBy: " ").last }, [
            "\(SIGUSR2)", "\(SIGUSR1)", "server.reload_config"
        ])
        XCTAssertEqual(report.results["neovim"]?.outcome, .updated)
        XCTAssertNotNil(sandbox.read(".config/nvim/lua/omniwm.lua"))
    }

    func testAnExistingModuleNeedsConsent() throws {
        try sandbox.write("return {}\n", to: ".config/nvim/lua/omniwm.lua")
        var settings = SettingsExport.AppTheming()
        settings.neovim.enabled = true
        var job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: settings.targets(configHome: sandbox.policy.configHome)
        )
        XCTAssertEqual(sandbox.engine(fake).run(job).results["neovim"]?.outcome, .conflict)
        XCTAssertEqual(sandbox.read(".config/nvim/lua/omniwm.lua"), "return {}\n")
        job.takeOver = [sandbox.path(".config/nvim/lua/omniwm.lua").path: AppThemeFileWriter.digest("return {}\n")]
        XCTAssertEqual(sandbox.engine(fake).run(job).results["neovim"]?.outcome, .updated)
    }

    func testNeovimSettingRoundTripsAndIsOffByDefault() throws {
        XCTAssertFalse(SettingsExport.defaults().appTheming.neovim.enabled)
        var settings = SettingsExport.defaults()
        settings.appTheming.neovim.enabled = true
        let data = try SettingsTOMLCodec.encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("[appTheming.neovim]"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).appTheming.neovim.enabled)
    }

    func testModuleCarriesBothPalettesAndFollowsTheBackgroundOption() throws {
        let lua = try module(AppThemeFixtures.palette, dark: false)
        XCTAssertEqual(lua, try module(AppThemeFixtures.palette, dark: true))
        XCTAssertEqual(
            try base16(in: lua, dark: false)["base00"],
            AppThemeFixtures.palette.light.roles[.background]?.hex
        )
        XCTAssertEqual(try base16(in: lua, dark: true)["base00"], AppThemeFixtures.palette.dark.roles[.background]?.hex)
        XCTAssertTrue(lua.contains("local colors = palettes[background] or palettes.dark"))
        XCTAssertTrue(lua.contains("vim.api.nvim_create_autocmd(\"OptionSet\", {"))
        XCTAssertTrue(lua.contains("pattern = \"background\","))
        XCTAssertNotEqual(
            AppThemeBuiltIn.neovim.outputs(configHome: sandbox.policy.configHome).first?.variant,
            .current
        )
    }

    func testModuleOffersTransparencyRemembersOptionsAndAnnouncesColors() throws {
        let lua = try module(AppThemeFixtures.palette, dark: true)
        XCTAssertTrue(lua
            .contains("if opts ~= nil then\n    state.opts = opts\n  end"))
        XCTAssertTrue(lua.contains("pcall(apply, state.opts or {})"))
        XCTAssertTrue(lua.contains("if opts.transparent then"))
        for group in ["Normal", "NormalNC", "SignColumn", "EndOfBuffer", "LineNr", "FoldColumn"] {
            XCTAssertTrue(lua.contains("\"\(group)\""), group)
        }
        XCTAssertTrue(lua.contains("pcall(omniwm.setup)"))
        XCTAssertTrue(lua.contains("vim.g.colors_name = \"omniwm\""))
        XCTAssertTrue(lua.contains(#"vim.api.nvim_exec_autocmds("User", { pattern = "OmniWMColors""#))
        for key in [
            "bg",
            "surface",
            "text",
            "accent",
            "secondary",
            "tertiary",
            "error",
            "red",
            "green",
            "yellow",
            "blue",
            "magenta",
            "cyan"
        ] + AppThemeBase16.slots {
            XCTAssertNotNil(try table(true, in: lua).firstMatch(of: Regex("\n?    \(key) = \"#[0-9a-f]{6}\",")), key)
            XCTAssertNotNil(try table(false, in: lua).firstMatch(of: Regex("\n?    \(key) = \"#[0-9a-f]{6}\",")), key)
        }
    }

    #if OMNIWM_LIVE_CHECKS
        func testAColorschemeChosenAfterOmniWMIsKeptOnReload() throws {
            guard let nvim = AppThemeEnvironment.live.executable("nvim") else {
                throw MissingTestPrerequisite("Neovim is not installed here")
            }
            let runtime = sandbox.root.appendingPathComponent("rtp", isDirectory: true)
            for (relative, text) in [
                ("lua/omniwm.lua", try module(AppThemeFixtures.palette, dark: true)),
                ("colors/omniwm.lua", AppThemeBuiltIn.neovimColorscheme)
            ] {
                let file = runtime.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            let script = runtime.appendingPathComponent("probe.lua")
            try #"""
            package.preload["base16-colorscheme"] = function()
              return { setup = function(c) vim.api.nvim_set_hl(0, "Normal", { fg = c.base05, bg = c.base00 }) end }
            end
            local seen = 0
            vim.api.nvim_create_autocmd("User", { pattern = "OmniWMColors", callback = function() seen = seen + 1 end })
            require("omniwm").setup({ transparent = true })
            vim.cmd.colorscheme("retrobox")
            vim.api.nvim_exec_autocmds("Signal", { pattern = "SIGUSR1" })
            vim.o.background = vim.o.background == "dark" and "light" or "dark"
            local kept = vim.g.colors_name .. " " .. seen
            vim.cmd.colorscheme("omniwm")
            vim.api.nvim_exec_autocmds("Signal", { pattern = "SIGUSR1" })
            io.write(kept .. " " .. vim.g.colors_name .. " " .. seen)
            """#.write(to: script, atomically: true, encoding: .utf8)
            let result = AppThemeProcessRunner.run(nvim, [
                "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set rtp^=\(runtime.path)",
                "--cmd", "set background=dark", "-c", "luafile \(script.path)", "-c", "qa!"
            ], timeout: failureBound)
            XCTAssertEqual(result.output, "retrobox 1 omniwm 3", "status \(result.status)")
        }

        func testModuleLoadsReloadsAndAnnouncesInHeadlessNeovim() throws {
            guard let nvim = AppThemeEnvironment.live.executable("nvim") else {
                throw MissingTestPrerequisite("Neovim is not installed here")
            }
            let runtime = sandbox.root.appendingPathComponent("rtp", isDirectory: true)
            let file = runtime.appendingPathComponent("lua/omniwm.lua")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try module(AppThemeFixtures.palette, dark: true).write(to: file, atomically: true, encoding: .utf8)
            let colors = runtime.appendingPathComponent("colors/omniwm.lua")
            try FileManager.default.createDirectory(
                at: colors.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AppThemeBuiltIn.neovimColorscheme.write(to: colors, atomically: true, encoding: .utf8)
            let script = runtime.appendingPathComponent("probe.lua")
            try #"""
            local seen = {}
            package.preload["base16-colorscheme"] = function()
              return { setup = function(c) vim.api.nvim_set_hl(0, "Normal", { fg = c.base05, bg = c.base00 }) end }
            end
            vim.api.nvim_create_autocmd("User", { pattern = "OmniWMColors", callback = function(event)
              table.insert(seen, event.data.accent .. "," .. event.data.base08)
            end })
            local ok = pcall(dofile, "MODULE_PATH")
            require("omniwm").setup({ transparent = true })
            vim.api.nvim_exec_autocmds("Signal", { pattern = "SIGUSR1" })
            local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
            local before = seen[#seen]
            vim.o.background = vim.o.background == "dark" and "light" or "dark"
            io.write(table.concat({ tostring(ok), tostring(normal.bg), tostring(normal.fg ~= nil),
              vim.g.colors_name, #seen, before, seen[#seen] }, " "))
            """#.replacingOccurrences(of: "MODULE_PATH", with: file.path).write(
                to: script,
                atomically: true,
                encoding: .utf8
            )
            func expected(_ scheme: AppThemePalette.Scheme) -> String {
                "\(scheme.roles[.accent]!.hex),\(scheme.ansi[1].hex)"
            }
            let palette = AppThemeFixtures.palette
            for (background, first, second) in [
                ("dark", palette.dark, palette.light),
                ("light", palette.light, palette.dark)
            ] {
                let result = AppThemeProcessRunner.run(nvim, [
                    "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set rtp^=\(runtime.path)",
                    "--cmd", "set background=\(background)", "-c", "luafile \(script.path)", "-c", "qa!"
                ], timeout: failureBound)
                XCTAssertEqual(
                    result.output,
                    "true nil true omniwm 3 \(expected(first)) \(expected(second))",
                    "background \(background), status \(result.status)"
                )
            }
        }
    #endif
}
