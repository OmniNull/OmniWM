# Window switcher

Enable **Settings → Window Switcher → Replace Command-Tab** to switch individual windows with thumbnail previews. Disable AltTab’s Command-Tab binding first. The feature is off by default, including when loading an existing OmniWM configuration.

| Input | Action |
| --- | --- |
| Hold Command, press Tab | Open and select the next recently focused window |
| Tab / Shift-Tab | Cycle forward / backward, wrapping at either end |
| Arrow keys | Cycle forward / backward |
| Release Command, or Return | Focus the selected window |
| Escape or click outside | Cancel without selecting a window |
| Click a thumbnail | Focus that window |
| W or the workspace scope button | Toggle all workspaces / active workspace and remember the choice |

**All Workspaces** includes windows tracked by OmniWM across monitors and workspaces, including floating windows and hidden applications. **Active Workspace** uses the workspace on the interaction monitor when the switcher opens. The list stays in its initial recency order while cycling. Closing or moving a window is checked again before cycling or committing a selection. Opening the switcher again refreshes the inventory.

The panel displays a bounded row around the selection; continuing to press Tab reaches every candidate. Thumbnails are captured on demand for the visible row, once per presentation, using the existing Overview capture service. Capture work and retained images are released on dismissal. Missing permission and unavailable captures are labeled explicitly. Screen Recording permission is required for thumbnails; keyboard selection remains available without it.

Minimized or natively withdrawn windows and windows excluded from OmniWM’s tracked inventory are omitted. This feature does not duplicate AltTab’s independent application/window discovery. ScreenCaptureKit may not provide a preview for every offscreen or native fullscreen window; those windows retain their title and an explicit unavailable-preview label.

## Configuration

```toml
[windowSwitcher]
enabled = true
scope = "allWorkspaces" # or "activeWorkspace"
```

The modifier is Command in this implementation. Command-Tab is intercepted through OmniWM’s existing input event tap. Input Monitoring must be granted. Disabling OmniWM’s hotkeys, entering Secure Input, locking the screen, stopping services, or losing the event tap cancels the current presentation. Overview and the command palette must be closed before invoking the switcher.

## Source investigation

Reviewed upstream revisions:

- [OmniWM 9fae5f7](https://github.com/OmniNull/OmniWM/tree/9fae5f76e77b01d54be501a3df8832e766a29dcc)
- [AltTab 0d9d710](https://github.com/lwouis/alt-tab-macos/tree/0d9d710779333b1b2279f04b53d919fb35557120)

AltTab publishes its source, so decompilation is unnecessary. Its `src/events/KeyboardEvents.swift` handles cycling and modifier release. `src/events/WindowCaptureEvents.swift` discovers shareable windows, caches capture metadata, and requests previews with ScreenCaptureKit, with an older capture path for older systems.

OmniWM already provides the main integration points:

- `WorkspaceManager.allEntries()` and `windowFocusRecencyOrder`: tracked windows, workspace ownership, and recency.
- `OverviewThumbnailCapture`: bounded capture startup, window identity checks, preview delivery, and cleanup.
- `WindowActionHandler.activateExplicitlySelectedWindow`: the activation path shared with the workspace bar, including workspace navigation, application reveal, and native fullscreen activation.
- `HotkeyCenter`: the existing keyboard event tap and lifecycle.
- `OwnedWindowRegistry` and `FocusPolicyEngine`: capture exclusion and suppression of mouse-driven focus during selection.

The implementation is original code using these OmniWM components. No AltTab source or assets were copied. The inspected AltTab repository carries GPLv3; OmniWM declares GPL-2.0-only.

## Developer validation

Follow [CONTRIBUTING.md](../CONTRIBUTING.md) for dependency setup and the development app. This branch has focused input, selection, persistence, and focus-lease tests. Before using the replacement, run `make verify`, `swift test`, and `swift test --parallel` with the required dependencies installed.

Manually check fast Command-Tab release, held-key repetition, reverse cycling, Escape, scope changes across two monitors, selection on an inactive workspace, a window closing during selection, hidden applications, native fullscreen, missing Screen Recording permission, and more windows than fit in the row. Confirm stopping OmniWM restores normal Command-Tab behavior. The implementation has not been built or runtime-tested as part of its creation.
