---
title: Wire Protocol & Errors
description: NDJSON request, response, and event envelope formats, error codes, output formats, and environment variables.
sidebar:
  order: 7
---

## Wire Protocol Details

### Request Format

```json
{
  "version": 21,
  "id": "<uuid>",
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|window-gather|subscribe>",
  "authorizationToken": "<token>",
  "payload": { ... }
}
```

**Payload varies by kind:**

**Command:**
```json
{
  "name": "focus",
  "arguments": {
    "direction": "left"
  }
}
```

**Dwindle axis resize:**
```json
{
  "name": "resize",
  "arguments": {
    "axis": "vertical",
    "operation": "shrink"
  }
}
```

**Query:**
```json
{
  "name": "windows",
  "selectors": {
    "workspace": "main",
    "visible": true
  },
  "fields": ["id", "title", "app"]
}
```

**Capture start:**
```json
{
  "name": "start",
  "profile": "trace"
}
```

**Capture stop or status:**
```json
{
  "name": "status"
}
```

**Rule (add):**
```json
{
  "name": "add",
  "arguments": {
    "rule": {
      "bundleId": "com.apple.finder",
      "layout": "float"
    }
  }
}
```

**Subscribe:**
```json
{
  "channels": ["focus", "active-workspace"],
  "allChannels": false,
  "sendInitial": true
}
```

**Workspace focus:**
```json
{
  "name": "focus-name",
  "workspaceTarget": {
    "kind": "display-name",
    "value": "S"
  }
}
```

**Workspace move:**
```json
{
  "name": "move-to-monitor",
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "12"
  },
  "direction": "right",
  "force": true
}
```

**Workspace rename:**
```json
{
  "name": "rename",
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "3"
  },
  "displayName": "🚨 Alerts"
}
```

Workspace requests use this flat wire shape. For `move-to-monitor`, `force` is optional while decoding; omitting it is equivalent to `false`. For `rename`, `displayName` is required; an empty string clears the label so the workspace shows its raw ID.

**Window:**
```json
{
  "name": "focus",
  "windowId": "ow_..."
}
```

**Window move:**
```json
{
  "name": "move-to-workspace",
  "windowId": "ow_...",
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "3"
  }
}
```

`workspaceTarget` is required by `move-to-workspace` and rejected by every other window action.

**Window marks:**

```json
{
  "name": "set",
  "mark": "editor"
}
```

`focus`, `summon`, and `remove` use the same `mark` field. `list` sends only `{"name":"list"}`; a `mark` field on `list` is rejected.

**Window gather:**

```json
{
  "windowIds": ["ow_...", "ow_..."],
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "3"
  }
}
```

Alternatively, select windows by runtime mark (protocol 21):

```json
{
  "markNames": ["editor", "chat"],
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "3"
  }
}
```

`window-gather` requires `workspaceTarget` and exactly one of `windowIds` or `markNames`; mixing selectors is rejected. It places the selected windows, in the given order, as the only windows of the leading (first) Niri column of an existing workspace. The workspace is never created. The windows may come from several workspaces, including inactive ones; OmniWM does not switch workspaces, reveal hidden windows or move focus to perform the gather.

Marks are resolved server-side during the same read-only preflight, not by listing, focusing, or summoning them first. Names use the existing runtime mark rules (surrounding whitespace is trimmed; names remain case-sensitive and UTF-8 exact). Missing, invalid, or stale marks refuse the whole request without pruning the mark namespace. Repeating a name, or selecting two aliases for the same window, also refuses the whole request. No saved groups or profiles are involved.

If the destination's first column already holds only listed windows, it is reused, keeping its width and display mode, including tabbed. Otherwise a new first column with the workspace's default width is inserted. Windows that change column lose their column-local sizes; other columns keep their windows, order and sizes.

The request is validated as a whole before anything changes. One ineligible window refuses the whole request, and nothing moves. Ineligible windows include:

- app-hidden, minimized, or natively withdrawn windows
- scratchpad windows, whether hidden or revealed
- native or layout fullscreen windows
- floating windows
- non-Niri windows

The request is also refused, with nothing moved, when:

- an ID is invalid, stale, duplicated, or no longer managed
- a mark is invalid, missing, or stale, or several marks resolve to the same window
- the destination is missing or not a Niri workspace
- the combined minimum sizes do not fit the destination column

Windows on inactive workspaces, inactive tabs, or scrolled out of view are eligible.

The repository's `Scripts/gather-windows.py` sends one such request:

```sh
python3 Scripts/gather-windows.py --workspace 3 ow_... ow_...
python3 Scripts/gather-windows.py --workspace 3 --mark editor --mark chat
```

Repeat `--mark NAME` in column order, or supply positional window IDs; do not mix the modes. `--workspace` is required. A positive whole number names a workspace ID, as in `omniwmctl`; any other value is a display name. The script prints the response, never queries marks or sends follow-up focus/move commands, and exits like `omniwmctl`: 0 gathered, 1 rejected (including `no_change`), 2 transport failure, 3 invalid CLI arguments, 4 internal or malformed-response error. `--dry-run` prints the request without the authorization token and contacts nothing.

### Response Format

```json
{
  "version": 21,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|window-gather|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "result": {
    "kind": "<pong|version|capture|workspace-bar|active-workspace|focused-monitor|apps|metrics|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|subscribed|window-marks|window-gather>",
    "payload": { ... }
  }
}
```

Optional response fields are omitted when unavailable. For example, a successful response has no `code` key; it does not send `"code": null`.

A `window mark list` response has `kind: "window-mark"` and `result.kind: "window-marks"`. Its `result.payload.marks` array contains each mark's `name`, `workspace` (`id`, `rawName`, `displayName`, optional `number`), `app` (`name`, optional `bundleId`), and optional window `title`. Other mark actions return `status: "executed"` without a result payload.

A `window-gather` response has `kind: "window-gather"` and, whenever its arguments were evaluated, `result.kind: "window-gather"`. The payload has these fields:

- `outcome`: `gathered`, `unchanged`, or `refused`.
- `workspace`: the destination, using the same shape as `window mark list` workspaces; omitted when the destination is unresolved.
- `reason`: a request-level reason, present only when refused.
- `windows`: one entry per requested ID or mark, in request order. Each entry has `status` and an optional `reason`. ID mode always includes the requested `windowId`. Mark mode includes the original requested `markName` and the resolved `windowId` only when live resolution succeeded; unresolved marks have no fabricated ID. The status is one of:
  - `moved`
  - `unchanged`
  - `blocked`: eligible, but the request was refused for another reason
  - `refused`
  - `unresolved`
- `moved`: the IDs whose placement changed.
- `relayoutWorkspaces`: the destination first, then each source workspace once.
- `modelCommitted` and `relayoutRequested`.

Every outcome returns a different envelope:

- **Gathered:** returns `status: "executed"`. It means OmniWM published the new layout in one model update and requested one relayout for `relayoutWorkspaces`. It does not mean window frames have already settled.
- **Already satisfied:** returns `no_change` with `status: "ignored"`. Nothing is published, and no relayout is requested.
- **Refused:** returns `status: "error"` and requests no relayout. The `code` comes from the first failing input in request order, after any destination failure:
  - `invalid_arguments`: malformed or duplicate ID, duplicate resolved window (including mark aliases), an empty list, or an invalid target.
  - `invalid_mark`, `unknown_mark`, `stale_mark`: an invalid name, a missing mark, or a mark whose exact target is no longer live.
  - `stale_window_id`: an ID from a previous session.
  - `not_found`: a missing window or workspace.
  - `unsupported_layout`: a non-Niri source or destination.
  - `ineligible_window`: any other ineligible window.
  - `does_not_fit`: the combined minimum sizes do not fit the destination column.
  - `workspace_state_conflict`: a layout/model conflict, or a plan that went stale before publication.

Per-window `reason` values are:

- `invalid_window_id`
- `stale_window_id`
- `invalid_mark`
- `unknown_mark`
- `stale_mark`
- `duplicate_window`
- `not_found`
- `scratchpad`
- `native_fullscreen`
- `app_hidden`
- `minimized`
- `native_withdrawn`
- `floating`
- `unsupported_layout`
- `layout_conflict`
- `layout_fullscreen`

Request-level `reason` values are:

- `no_windows`
- `destination_not_found`
- `invalid_destination`
- `unsupported_layout`
- `window_refused`
- `does_not_fit`
- `stale_plan`

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 21,
  "id": "<request-id>",
  "ok": false,
  "kind": "query",
  "status": "error",
  "code": "unauthorized"
}
```

Requests that fail JSON or payload decoding are reported as `kind: "error"` with `code: "invalid_request"` and an empty request id. A request line exceeding 65,536 bytes, excluding its newline, receives the same error and the connection closes. Invalid UTF-8 closes the connection without an error response.

### Event Envelope Format

Events are sent on subscription connections after the initial response.

```json
{
  "version": 21,
  "id": "<event-id>",
  "kind": "event",
  "channel": "focus",
  "ok": true,
  "status": "success",
  "result": {
    "kind": "focused-window",
    "payload": { ... }
  }
}
```

The `result` type corresponds to the channel's result kind (see [Channels](/reference/cli/events/#channels)).

### CLI-Local JSON Errors

When JSON output is active and `omniwmctl` fails before or outside the IPC request/response path, it emits a client-side failure envelope instead of an `IPCResponse`. This is used for argument parsing failures, transport failures, and unexpected internal CLI errors. `query` and `subscribe` default to JSON output even without an explicit `--json` flag.

```json
{
  "ok": false,
  "source": "cli",
  "status": "error",
  "code": "<invalid_arguments|transport_failure|internal_error>",
  "message": "<human-readable error>",
  "exitCode": 3
}
```

This envelope is produced locally by the CLI, so it does not include IPC fields like `version`, `id`, `kind`, or `result`. The `exitCode` matches the CLI-local failure class: `2` for transport failures, `3` for invalid arguments, and `4` for internal errors.

---

## Error Codes

| Code | Meaning |
|------|---------|
| `invalid_request` | Malformed, oversized, or unparseable request |
| `invalid_arguments` | Bad arguments for the command/rule |
| `protocol_mismatch` | Client/server protocol version mismatch |
| `ignored_disabled` | Window manager is disabled, or the requested Overview or Quake Terminal feature is off |
| `ignored_overview` | Overview is open, so `CommandHandler` rejects external/IPC commands (except `toggle-overview`) before normal execution |
| `layout_mismatch` | Command incompatible with the active workspace layout |
| `unauthorized` | Missing or invalid authorization token |
| `stale_window_id` | Well-formed window ID belongs to a different IPC session |
| `not_found` | Target window, workspace, monitor, or rule does not exist |
| `window_action_failed` | The requested close, mark focus, or summon could not complete |
| `no_change` | Request resolved to the current state (workspace already active and holding keyboard focus, window already on the target, nothing to raise or rescue); status is `ignored`. `switch-workspace`, `switch-workspace slot`, `switch-workspace anywhere`, and `workspace focus-name` return `executed` instead when the workspace is already visible but keyboard focus must be handed back to it |
| `workspace_assignment_conflict` | Configured monitor assignment prevents the requested workspace move |
| `workspace_state_conflict` | Current fullscreen, scratchpad, or pending focus state prevents the requested workspace move, or a `window-gather` layout conflicts with the window model or changed before publication |
| `capture_state_conflict` | Capture state does not permit the requested start or stop transition |
| `stale_mark` | A mark points to a window that is no longer available; the mark is removed |
| `unknown_mark` | No window has this mark |
| `no_focused_window` | Setting or summoning a mark requires a focused managed window |
| `self_summon` | The marked window is also the summon anchor |
| `hidden_window` | A hidden app's marked window cannot be summoned |
| `unsupported_layout` | The source or target layout cannot summon the marked window, or a `window-gather` window or destination is not in a Niri workspace |
| `duplicate_mark` | The name is already assigned to another window |
| `invalid_mark` | The mark name is empty or contains control characters |
| `ineligible_window` | A `window-gather` window is hidden, minimized, withdrawn, in the scratchpad, fullscreen, or floating |
| `does_not_fit` | The windows of a `window-gather` request do not fit in one destination column |
| `internal_error` | Unexpected server-side error |

Malformed opaque window IDs return `invalid_arguments`. For window actions, a valid current-session ID whose window is no longer managed returns `not_found`.

---

## Output Formats

| Format | Description | Default for |
|--------|-------------|-------------|
| `json` | Pretty-printed JSON | queries, subscribe |
| `ndjson` | One compact JSON envelope per line | — |
| `table` | Aligned columns with headers | — |
| `tsv` | Tab-separated values | — |
| `text` | Simple human-readable text | commands, ping, version |

**Table output example (windows):**

```
ID    PID    APP       TITLE         WORKSPACE  DISPLAY   MODE     FOCUSED  VISIBLE  SCRATCHPAD  WINDOW ID
ow_…  1234   Terminal  ~             main       Built-in  tiling   yes      yes      no          4021
ow_…  5678   Safari    GitHub        web        Built-in  tiling   no       yes      no          4188
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `OMNIWM_SOCKET` | Override the default IPC socket path |
| `OMNIWM_EVENT_CHANNEL` | (watch child) Subscription channel name |
| `OMNIWM_EVENT_KIND` | (watch child) Event result kind |
| `OMNIWM_EVENT_ID` | (watch child) Event ID |
