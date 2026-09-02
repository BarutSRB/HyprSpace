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
  "version": 14,
  "id": "<uuid>",
  "kind": "<ping|version|command|capture|query|rule|workspace|window|subscribe>",
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

Workspace requests use this flat wire shape. For `move-to-monitor`, `force` is optional while decoding; omitting it is equivalent to `false`.

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

### Response Format

```json
{
  "version": 14,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|capture|query|rule|workspace|window|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "code": null,
  "result": {
    "kind": "<pong|version|capture|workspace-bar|active-workspace|focused-monitor|apps|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|subscribed>",
    "payload": { ... }
  }
}
```

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 14,
  "id": "<request-id>",
  "ok": false,
  "kind": "query",
  "status": "error",
  "code": "unauthorized"
}
```

Malformed or oversized request lines fail before routing and are reported as `kind: "error"` with `code: "invalid_request"` and an empty request id.

### Event Envelope Format

Events are sent on subscription connections after the initial response.

```json
{
  "version": 14,
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
| `ignored_disabled` | Window manager is disabled |
| `ignored_overview` | Overview is open, so `CommandHandler` rejects external/IPC commands (except `toggle-overview`) before normal execution |
| `layout_mismatch` | Command incompatible with the active workspace layout |
| `unauthorized` | Missing or invalid authorization token |
| `stale_window_id` | Window ID is from a previous session or no longer valid |
| `not_found` | Target window, workspace, monitor, or rule does not exist |
| `window_action_failed` | The window exists but its close button is missing or refused the action |
| `no_change` | Request resolved to the current state (workspace already active, window already on the target, nothing to raise or rescue); status is `ignored` |
| `workspace_assignment_conflict` | Configured monitor assignment prevents the requested workspace move |
| `workspace_state_conflict` | Current fullscreen, scratchpad, or pending focus state prevents the requested workspace move |
| `capture_state_conflict` | Capture state does not permit the requested start or stop transition |
| `internal_error` | Unexpected server-side error |

---

## Output Formats

| Format | Description | Default for |
|--------|-------------|-------------|
| `json` | Pretty-printed JSON | queries, subscribe |
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
