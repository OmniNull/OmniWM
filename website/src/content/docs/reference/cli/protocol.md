---
title: Wire Protocol & Errors
description: NDJSON request, response, and event envelope formats, error codes, output formats, and environment variables.
sidebar:
  order: 7
---

This reference follows **Unreleased `main` (protocol 22)**. Stable v0.7.6 uses protocol 19; see [protocol compatibility](/reference/cli/overview/#ipc-protocol) before using these commands or payloads.

## Wire Protocol Details

### Request Format

```json
{
  "version": 22,
  "id": "<uuid>",
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|window-gather|shell|subscribe>",
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
  "fields": ["id", "title", "app", "focus-rank"],
  "sort": "mru"
}
```

`sort` is optional and accepted only by the `windows` query; `"mru"` orders windows most recently focused first.

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

Each window action accepts at most one argument field, and requires exactly the one it uses; every other argument field is rejected:

| Field | Type | Required by |
|-------|------|-------------|
| `workspaceTarget` | workspace target object | `move-to-workspace` |
| `columnIndex` | integer, one-based (>= 1) | `move-column-to-index` |
| `direction` | `left` \| `right` \| `up` \| `down` | `move-column` |
| `change` | size-change object | `set-container-primary-span`, `set-window-primary-span`, `set-window-secondary-span` |
| `cycle` | `forward` \| `backward` | `cycle-window-primary-span`, `cycle-window-secondary-span` |
| `scratchpadIndex` | integer, 1-10 | `assign-to-scratchpad` |

All other window actions take no argument field.

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
  "from": "monitor"
}
```

Both fields are required. `from` is `workspace`, `monitor`, or `all`; `omniwmctl` sends `workspace` unless `--from` is given.

**Shell widget values:**

```json
{
  "name": "set",
  "key": "weather",
  "value": "12° sunny"
}
```

`unset` sends only `name` and `key`; a `value` field on `unset` is rejected. `toggle` sends `name` and `widget`. All three return `status: "executed"` without a result payload. `eject` and `init` also send `name` and `widget`, `profile` and `theme` send the profile or theme name as `key`, and `trigger` sends `widget`, the event name as `key` and an optional `value`; their statuses are listed under [Shell Widgets](/reference/cli/actions/#shell-widgets).

### Response Format

```json
{
  "version": 22,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|window-gather|shell|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "result": {
    "kind": "<pong|version|capture|workspace-bar|active-workspace|focused-monitor|apps|metrics|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|subscribed|window-marks|window-gather|shell-widgets>",
    "payload": { ... }
  }
}
```

Optional response fields are omitted when unavailable. For example, a successful response has no `code` key; it does not send `"code": null`.

A `window mark list` response has `kind: "window-mark"` and `result.kind: "window-marks"`. Its `result.payload.marks` array contains each mark's `name`, `id` (session-scoped opaque window id), `workspace` (`id`, `rawName`, `displayName`, optional `number`), `app` (`name`, optional `bundleId`), and optional window `title`. Other mark actions return `status: "executed"` without a result payload.

A `window-gather` response has `kind: "window-gather"` and, unless OmniWM is disabled or Overview is open, `result.kind: "window-gather"` with this payload:

- `outcome`: `gathered`, `unchanged`, or `refused`.
- `workspace`: the destination, in the same shape as `window mark list` workspaces; omitted when there is no destination.
- `reason`: why the request was refused: `no_windows`, `destination_unavailable`, `unsupported_layout`, `does_not_fit`, or `window_refused` when one of the windows caused the refusal.
- `windows`: one entry per requested ID, in request order, with `windowId`, `status`, and an optional `reason`. The status is `moved` or `unchanged` after a gather, `unchanged` when nothing changed, and otherwise `blocked` (no problem was found with it before the request was refused), `refused`, or `unresolved` (the ID does not name a managed window). The per-window reasons are `invalid_window_id`, `stale_window_id`, `duplicate_window`, `not_found`, `outside_reach`, `scratchpad`, `native_fullscreen`, `app_hidden`, `minimized`, `native_withdrawn`, `floating`, `unsupported_layout`, `layout_conflict`, and `layout_fullscreen`.

A gather returns `status: "executed"` once OmniWM has published the whole change in one model update and requested one relayout; window frames settle afterwards. An already satisfied request returns `no_change` with `status: "ignored"`. A refusal changes nothing and returns `status: "error"`; its `code` comes from the request-level reason, or for `window_refused` from the first refused window in request order: `invalid_arguments` for malformed or duplicate IDs and an empty list, `stale_window_id`, `not_found` for unknown windows or no destination, `unsupported_layout`, `ineligible_window`, `does_not_fit`, or `workspace_state_conflict` for `layout_conflict`. While OmniWM is disabled or Overview is open, the request returns `ignored_disabled` or `ignored_overview` with `status: "ignored"`.

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 22,
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
  "version": 22,
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
| `workspace_state_conflict` | Current fullscreen, scratchpad, or pending focus state prevents the requested workspace move |
| `capture_state_conflict` | Capture state does not permit the requested start or stop transition |
| `stale_mark` | A mark points to a window that is no longer available; the mark is removed |
| `unknown_mark` | No window has this mark |
| `no_focused_window` | Setting or summoning a mark requires a focused managed window |
| `self_summon` | The marked window is also the summon anchor |
| `hidden_window` | A hidden app's marked window cannot be summoned |
| `unsupported_layout` | The source or target layout cannot summon the marked window, or a gathered window or the gather destination is not on a Niri workspace |
| `duplicate_mark` | The name is already assigned to another window |
| `invalid_mark` | The mark name is empty or contains control characters |
| `ineligible_window` | A gathered window is outside the requested reach, hidden, minimized, withdrawn, in the scratchpad, fullscreen, or floating |
| `does_not_fit` | The gathered windows' minimum sizes do not fit one destination column |
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
