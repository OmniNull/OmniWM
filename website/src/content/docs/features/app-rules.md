---
title: App Rules
description: Match windows by app, title, or role and control how OmniWM tiles, places, and sizes them.
sidebar:
  order: 7
---

Open **App Rules** from OmniWM's status-bar menu to configure window-matching behavior. Rules can match by bundle ID, app-name substring, title substring or regex, and AX role/subrole. When several rules match a window, each setting (layout, destination (workspace or, **Unreleased:** when building from `main`, scratchpad), minimum width, minimum height, and initial container span) comes from the most specific matching rule that sets it; ties follow list order. A setting left on Automatic or turned off adds nothing, so it never erases another rule's value.

## Create a rule from a window

1. Focus the window you want to match, then open **App Rules** from the status-bar menu.
2. In **Focused Window Inspector**, click **Refresh**, then **New Rule from Focused Window**.
3. Review the populated app, title, and AX role/subrole matchers. Remove any narrowing matcher you do not want, then choose the rule’s actions.
4. Click **Save** or press `Command + S` to save your edits.

For the observed AX values and classification details, expand **Advanced / Troubleshooting** in the inspector and use **Copy Debug Dump**. This avoids guessing the role and subrole needed by a precise inclusion rule.

## Structural admission

Rules do not turn every macOS surface into a window OmniWM owns. Structural admission runs first: help tags,
input-method surfaces, and WindowServer children of another window stay unmanaged and cannot be opted in by a
rule. At ordinary WindowServer levels, a closeable, parentless accessory-app `AXWindow` proceeds through normal
classification.

Buttonless accessory roots, prohibited-app roots, non-`AXWindow` roles, and otherwise unsupported AX subroles
require a precise inclusion rule. The rule must identify the app or window, set both `axRole` and `axSubrole` to
the observed values, and choose Tile or Float rather than Automatic. Parentless roots at status-window level or
higher use the same precise shape, but only a user-authored rule can opt them in; built-in rules cannot. For example:

```toml
[[appRules]]
bundleId = "com.example.overlay"
axRole = "AXWindow"
axSubrole = "AXStandardWindow"
layout = "float"
```

Use the target's actual bundle ID and AX values. This escape hatch does not admit a parented surface.

## Rule actions

- **Layout (Automatic / Tile / Float)** — leave classification automatic, or request tiling or floating.
  **Unreleased**. In builds from `main`, when admitting a window or promoting it from Float to Tile, OmniWM uses Float
  if the window has a usable frame and its `AXSize` is read-only or unsupported. A tiling request can wait for another
  read when writability is unknown.
- **Assign to Workspace** — use a valid workspace assignment as the initial default whenever the matching app currently has no tracked windows. Additional windows open on the workspace active when creation began. Automatic rule reevaluation leaves managed windows in place, while explicit rule application can move them. Readmission, structural replacements, and unique persisted boot-restore matches preserve their existing placement continuity.
- **Assign to Scratchpad** — **Unreleased — available when building from `main`.** Add each matching window to a [scratchpad](/features/scratchpads/#joining-by-app-rule) slot, 1–10, when OmniWM starts managing it. The picker shows slot labels, but the rule stores the slot number. See [Rule destination](#rule-destination).
- **Initial Container Primary Span (Niri)** — start matching resizable windows at 5–100% when they create or claim a new container; the container remains freely resizable afterward.
- **Minimum Size** — prevent the layout engine from sizing windows below a threshold.

:::note
Initial container primary span is a one-time seed. It controls width in horizontal orientation and height in vertical orientation. Niri's Single Window Fit still takes visual precedence for a lone window, and physical minimum-size constraints can clamp the resolved pixel size without changing the stored initial proportion.
:::

## Rule destination

**Unreleased — available when building from `main`.** Assign to Workspace and Assign to Scratchpad are one setting, the rule's destination. A rule sets one or the other, never both. When several matching rules set a destination, the most specific one wins and ties follow list order, so a more specific workspace rule beats a less specific scratchpad rule, and the other way round. If the winning workspace destination is skipped because the app already has tracked windows or the workspace doesn't exist, the window gets default placement. It doesn't fall back to a scratchpad rule that lost.

A scratchpad destination works differently from a workspace destination:

- It applies to every matching window when OmniWM starts managing it, including windows already open at startup. Assign to Workspace's limit to apps with no tracked windows doesn't apply.
- Joining the slot floats the window, as assigning it by hand does. The rule never floats a window that doesn't join. Adding or editing a scratchpad rule, or a title change, leaves windows OmniWM already manages as they are. A member stays floating and stays in its slot after its title stops matching or the rule is removed.
- Scratchpad can't be combined with Assign to Workspace or with Layout set to Tile. The App Rules window, `omniwmctl`, and IPC refuse such a rule. In `settings.toml` the rule still loads, but its scratchpad is ignored and the rule list shows a validation message. `omniwmctl` and IPC also refuse a slot outside 1–10, and `settings.toml` ignores one the same way.
- Scratchpad alone doesn't admit a surface that needs a precise inclusion rule (see [Structural admission](#structural-admission)). For such a surface, also set Layout to Float and set `axRole` and `axSubrole`.

`omniwmctl rule apply` is the only way to apply a scratchpad destination to a window OmniWM already manages. When the winning destination is a scratchpad:

- A window already in that slot is left as it is, whether it's parked or visible, so applying twice changes nothing.
- A window in another slot, or in none, joins that slot.
- A joining window that you set to tile by hand is floated again.

When a workspace destination now wins for a scratchpad member, the window leaves its slot, comes back on screen if it was parked, and moves to that workspace with its layout from the rules. When no rule sets a destination, scratchpad membership doesn't change.

## TOML

Rules can also be written in `settings.toml` (see [Configuration](/config/configuration/)). The equivalent TOML rule uses a proportion:

```toml
[[appRules]]
bundleId = "net.kovidgoyal.kitty"
initialContainerPrimarySpan = 0.5
```

## Default rules

OmniWM ships 13 default rules — minimum-size rules for apps whose windows misbehave when squeezed too small — covering browsers (Chrome, Safari, Zen, Firefox, Dia), Ghostty, Spotify, Discord, Outlook, Messages, and more. A new rule inherits each default minimum-size value it leaves unset. To change or remove a default minimum, edit or remove the default rule.
