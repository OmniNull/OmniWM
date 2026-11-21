// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AppThemeBuiltIn {
    static let neovimColorscheme = """
    require("omniwm").setup()

    """

    static let neovimTemplate = #"""
    local M = {}

    local palettes = {
      light = {
    \#(AppThemeBase16.slots.map { "    \($0) = \"{{colors.\($0).light.hex}}\"," }.joined(separator: "\n"))
        bg = "{{colors.background.light.hex}}",
        surface = "{{colors.surface.light.hex}}",
        text = "{{colors.ansi15.light.hex}}",
        accent = "{{colors.accent.light.hex}}",
        secondary = "{{colors.secondaryAccent.light.hex}}",
        tertiary = "{{colors.tertiaryAccent.light.hex}}",
        error = "{{colors.error.light.hex}}",
        red = "{{colors.ansi1.light.hex}}",
        green = "{{colors.ansi2.light.hex}}",
        yellow = "{{colors.ansi3.light.hex}}",
        blue = "{{colors.ansi4.light.hex}}",
        magenta = "{{colors.ansi5.light.hex}}",
        cyan = "{{colors.ansi6.light.hex}}",
      },
      dark = {
    \#(AppThemeBase16.slots.map { "    \($0) = \"{{colors.\($0).dark.hex}}\"," }.joined(separator: "\n"))
        bg = "{{colors.background.dark.hex}}",
        surface = "{{colors.surface.dark.hex}}",
        text = "{{colors.ansi15.dark.hex}}",
        accent = "{{colors.accent.dark.hex}}",
        secondary = "{{colors.secondaryAccent.dark.hex}}",
        tertiary = "{{colors.tertiaryAccent.dark.hex}}",
        error = "{{colors.error.dark.hex}}",
        red = "{{colors.ansi1.dark.hex}}",
        green = "{{colors.ansi2.dark.hex}}",
        yellow = "{{colors.ansi3.dark.hex}}",
        blue = "{{colors.ansi4.dark.hex}}",
        magenta = "{{colors.ansi5.dark.hex}}",
        cyan = "{{colors.ansi6.dark.hex}}",
      },
    }

    local state = _G.omniwm_state or {}
    _G.omniwm_state = state

    local see_through = {
      "Normal", "NormalNC", "SignColumn", "EndOfBuffer", "LineNr", "FoldColumn",
      "CursorLineNr", "CursorLineSign", "CursorLineFold",
    }

    local function picker_highlights(c)
      return {
        TelescopeNormal = { link = "NormalFloat" },
        TelescopeBorder = { link = "FloatBorder" },
        TelescopeTitle = { fg = c.bg, bg = c.base0D, bold = true },
        TelescopePromptPrefix = { fg = c.base0D },
        TelescopeSelection = { link = "CursorLine" },
        TelescopeMatching = { fg = c.base0A, bold = true },
        MiniPickNormal = { link = "NormalFloat" },
        MiniPickBorder = { link = "FloatBorder" },
        MiniPickBorderText = { fg = c.base0D, bold = true },
        MiniPickPrompt = { fg = c.base05 },
        MiniPickMatchCurrent = { link = "CursorLine" },
        MiniPickMatchRanges = { fg = c.base0A, bold = true },
      }
    end

    local function apply(opts)
      local background = vim.o.background
      local colors = palettes[background] or palettes.dark
      state.active = true
      state.background = background

      local scheme = {}
      for name, value in pairs(colors) do
        if name:match("^base0%x$") then
          scheme[name] = value
        end
      end
      local announced = false
      local watch = vim.api.nvim_create_autocmd("ColorScheme", {
        once = true,
        callback = function()
          announced = true
        end,
      })
      require("base16-colorscheme").setup(scheme)
      pcall(vim.api.nvim_del_autocmd, watch)
      if vim.o.background ~= background then
        vim.o.background = background
      end

      for group, spec in pairs(picker_highlights(colors)) do
        vim.api.nvim_set_hl(0, group, spec)
      end
      if opts.transparent then
        for _, group in ipairs(see_through) do
          local spec = vim.api.nvim_get_hl(0, { name = group, link = false })
          spec.bg, spec.ctermbg = nil, nil
          vim.api.nvim_set_hl(0, group, spec)
        end
      end

      vim.g.colors_name = "omniwm"
      if not announced then
        vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "omniwm", modeline = false })
      end
      vim.api.nvim_exec_autocmds("User", { pattern = "OmniWMColors", modeline = false, data = vim.deepcopy(colors) })
    end

    function M.setup(opts)
      if state.busy then
        return
      end
      if opts ~= nil then
        state.opts = opts
      end
      state.busy = true
      local ok, problem = pcall(apply, state.opts or {})
      state.busy = false
      if not ok then
        error(problem, 0)
      end
    end

    local function reapply()
      if not state.active then
        return
      end
      local current = vim.g.colors_name
      if current ~= nil and current ~= "omniwm" then
        return
      end
      package.loaded["omniwm"] = nil
      local ok, omniwm = pcall(require, "omniwm")
      if ok then
        pcall(omniwm.setup)
      end
    end

    local events = vim.api.nvim_create_augroup("OmniWM", { clear = true })
    vim.api.nvim_create_autocmd("Signal", { group = events, pattern = "SIGUSR1", callback = reapply })
    vim.api.nvim_create_autocmd("OptionSet", {
      group = events,
      pattern = "background",
      callback = function()
        if state.background ~= vim.o.background then
          reapply()
        end
      end,
    })

    return M

    """#
}
