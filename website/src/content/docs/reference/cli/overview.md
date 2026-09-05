---
title: CLI & IPC Overview
description: How omniwmctl and the OmniWM IPC server fit together, how to install and enable them, and the protocol's security model.
sidebar:
  order: 1
---

These pages cover the OmniWM automation surface. For internal architecture, see the [Architecture guide](/developers/architecture/). For contribution process, see the [Contribution Guide](/developers/contributing/).

## Architecture

OmniWM's IPC system is split across three Swift modules:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  OmniWMCtl (CLI binary)                                                  │
│  CLIEntry → CLIRuntime → CLIParser → IPCClient                           │
│  CLIRenderer, CLICompletionGenerator                                     │
│  Depends on: OmniWMIPC only                                             │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ Unix domain socket (NDJSON)
┌────────────────────────────┴─────────────────────────────────────────────┐
│  OmniWMIPC (shared library)                                              │
│  IPCModels, IPCWire, IPCSocketPath, IPCAutomationManifest                │
│  IPCRuleValidator, ScratchpadSlots, WorkspaceAddressing                  │
│  No dependencies                                                         │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
┌────────────────────────────┴─────────────────────────────────────────────┐
│  OmniWM (app)                                                            │
│  IPCServer → IPCConnection → IPCApplicationBridge                        │
│  IPCCommandRouter, IPCQueryRouter, IPCRuleRouter, IPCEventBroker         │
│  Depends on: OmniWMIPC, AppKit, SkyLight, etc.                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Request flow:**

```
omniwmctl command focus left
    │
    ▼
CLIEntry.main()
    │
    ▼
CLIRuntime.run()
    ├─ local commands: help / completion
    ▼
CLIParser.parse()  ──▶  IPCRequest model
    │
    ▼
IPCClientConnection.send()
    │
    ▼
IPCWire.encodeRequestLine()  ──▶  Unix socket  ──▶  IPCServer
                                           │
                                           ▼
                                   IPCConnection (actor)
                                           │
                                           ▼
                                   IPCApplicationBridge
                                     ├─ auth check
                                     ├─ version check
                                     └─ route to IPCCommandRouter
                                           │
                                           ▼
                                   WMController.commandHandler
                                     (semantic command path only;
                                      no physical trigger metadata)
                                           │
                                           ▼
                                   ExternalCommandResult
                                           │
                                           ▼
IPCWire.decodeResponse()  ◀──  IPCResponse (JSON)
    │
    ▼
CLIRenderer  ──▶  stdout
```

Local commands such as `help`, `--help`, `-h`, and `completion` never open the IPC socket. `watch` uses the same subscribe request path, then stays client-side to launch one child process per received event.

---

## Installation

### CLI Binary Location

The `omniwmctl` binary is bundled inside the OmniWM app at:

```
OmniWM.app/Contents/MacOS/omniwmctl
```

### Installing to PATH

Use the OmniWM status bar menu: **Install CLI to PATH**. OmniWM chooses the first writable directory already on `PATH` inside your home directory. If none is available, it falls back to `~/.local/bin`, then `~/bin`.

The menu also shows current CLI status:
- **Homebrew-managed** — CLI is already available from a Homebrew path, and OmniWM leaves it alone
- **App-managed** — symlink created by OmniWM, removable via menu
- **Not installed** — no OmniWM-managed CLI link is present yet
- **Conflict** — another file exists at the target path

### Enabling IPC

IPC is disabled by default. Enable it via:
- Status bar menu: **Enable IPC**
- The setting persists across sessions

Turning **Enable IPC** on starts the server immediately and creates the Unix socket plus the authorization secret file. Turning it off stops the server and removes both files.

---

## Community Integrations

- **[OmniWM Computer Use](https://github.com/nick-s5/omniwm-computer-use)** is a community-maintained Codex skill that uses `omniwmctl` to preserve and restore the active window while Computer Use, browser automation, and app testing operate across OmniWM workspaces and displays. Installation, verification, requirements, and support are maintained in its repository.

---

## IPC Protocol

**Protocol version:** 15

The client and server versions must match exactly. A mismatched client can still call `version`, but every other remote request returns `protocol_mismatch`; there is no cross-version compatibility path.

### Socket & Authorization

| Item | Path |
|------|------|
| Socket | `~/Library/Caches/com.barut.OmniWM/ipc.sock` |
| Secret | `~/Library/Caches/com.barut.OmniWM/ipc.sock.secret` |

The socket path can be overridden with the `OMNIWM_SOCKET` environment variable. The secret file path is always `<socket-path>.secret`. For custom socket paths, prefer a private same-user directory such as `$TMPDIR/omniwm/ipc.sock` after creating the parent directory with mode `0700`. Avoid shared directories such as `/tmp`.

The authorization token is a random UUID generated each time the IPC server starts. Clients must include this token in every request. The CLI reads it automatically from the secret file.

### Wire Format

The protocol uses **newline-delimited JSON (NDJSON)** — one JSON object per line, terminated by `0x0A`.

- Maximum request size: **64 KB**
- Encoding: UTF-8
- JSON keys: sorted, `camelCase`

Examples in these pages are pretty-printed for readability. The actual wire format is compact single-line JSON with the same field names.

### Security Model

1. **Socket permissions:** `0600` (owner-only read/write)
2. **Socket directory permissions:** newly created socket directories are created with `0700`
3. **Secret file permissions:** `0600` (owner-only read/write)
4. **Peer UID check:** server verifies connecting client is the same user via `getpeereid()`
5. **Authorization token:** every request must carry the authorization token stored in plaintext at `<socket-path>.secret`
6. **Session-scoped window IDs:** opaque IDs embed a separate internal session token and are invalidated across restarts — format: `ow_` + base64url(`sessionToken:pid:windowId`)
7. **FD_CLOEXEC:** server-side listening and accepted socket file descriptors are not inherited by child processes
8. **SO_NOSIGPIPE:** prevents SIGPIPE crashes on broken connections
9. **Stale socket cleanup:** server checks existing sockets before overwriting

The trust boundary is the local macOS user account, not individual client processes. Any process running as the same user can read the secret file and use the IPC API once IPC is enabled.

If `OMNIWM_SOCKET` points into an existing directory, OmniWM reuses that directory as-is instead of re-permissioning it. For custom socket paths, prefer a private directory owned by the same user and avoid shared locations such as `/tmp`.

---

## Shell Completion

Generate shell completion scripts for `omniwmctl`.

```
omniwmctl completion <zsh|bash|fish>
```

**Setup:**

```bash
# Zsh — add to ~/.zshrc
eval "$(omniwmctl completion zsh)"

# Bash — add to ~/.bashrc
eval "$(omniwmctl completion bash)"

# Fish — add to ~/.config/fish/config.fish
omniwmctl completion fish | source
```

Completions are context-aware: query names, selectors, field names, command paths, capture actions and profiles, channel names, rule actions, and argument values are all completed dynamically based on the automation manifest.
