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
  "version": 18,
  "id": "<uuid>",
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|subscribe>",
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

### Response Format

```json
{
  "version": 18,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|capture|query|rule|workspace|window|window-mark|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "result": {
    "kind": "<pong|version|capture|workspace-bar|active-workspace|focused-monitor|apps|metrics|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|subscribed|window-marks>",
    "payload": { ... }
  }
}
```

Optional response fields are omitted when unavailable. For example, a successful response has no `code` key; it does not send `"code": null`.

A `window mark list` response has `kind: "window-mark"` and `result.kind: "window-marks"`. Its `result.payload.marks` array contains each mark's `name`, `workspace` (`id`, `rawName`, `displayName`, optional `number`), `app` (`name`, optional `bundleId`), and optional window `title`. Other mark actions return `status: "executed"` without a result payload.

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 18,
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
  "version": 18,
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
| `unsupported_layout` | The source or target layout cannot summon the marked window |
| `duplicate_mark` | The name is already assigned to another window |
| `invalid_mark` | The mark name is empty or contains control characters |
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
