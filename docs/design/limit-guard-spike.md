# Cybokron Limit Guard — Phase 1 spike results (2026-10-29, codex-cli 0.165.0-alpha.1.2)

Environment: Terminal.app, a fresh Codex TUI in a scratch directory, 5-hour limit reached
(`ordinaryUsageAllowed = false`), so every test turn ended immediately with
`usage_limit_exceeded` and consumed no model tokens. No reset credit was touched.

## S5 — delivery via app-server: **WORKS → primary (and only) Phase 1 delivery path**

- The Terminal TUI is a client of the shared app-server daemon
  (`codex app-server --listen unix://`, control socket `~/.codex/app-server-control/app-server-control.sock`).
- `codex app-server proxy` relays raw bytes between stdio and that socket. The socket speaks
  **WebSocket**: plain JSON lines fail with "Broken pipe". Sending an HTTP/1.1 upgrade request
  (`GET / HTTP/1.1`, `Upgrade: websocket`, `Sec-WebSocket-Key`, version 13) through the proxy's
  stdin returns `HTTP/1.1 101 Switching Protocols`; afterwards each JSON-RPC message is one
  masked text frame (client → server) / unmasked text frame (server → client). Same
  `initialize` / `initialized` handshake as the stdio server.
- `thread/loaded/list {}` → `{"data": [threadId…], "nextCursor": null}` — the threads currently
  loaded by TUI clients (here: the long-running session and the new scratch session).
- `thread/read {"threadId", "includeTurns": false}` → `thread.cwd`, `thread.status.type`
  (`idle` | `active` | `systemError` — the session stopped on the usage limit reported
  `systemError`), `name`, `preview`, `source`.
- `turn/start {"threadId", "input":[{"type":"text","text":…}], "clientUserMessageId": <uuid>}`
  → `{"turn": {"id", "status": "inProgress", …}}`, followed by notifications
  `thread/status/changed` (active → systemError on the limit). **The message appears in the
  Terminal TUI exactly like a typed message** (`› Reply with the single word PONG`) and the TUI
  then shows the limit message. No model/approval overrides were passed.
- **Delivery confirmation:** the rollout records the user message with
  `"client_id": "<our clientUserMessageId>"` — exact match. `SessionState.seenClientMessageIds`
  (Task 6) can confirm delivery.
- Side effect seen once: a `thread/started` notification for an extra internal thread
  (`ephemeral`, no preview) right after `turn/start`. It is not a TUI thread; scanners must keep
  filtering by `originator == codex-tui` and non-subagent.

## S1 — typing into Terminal: **does not submit → dropped for Phase 1**

- `do script "<text>" in tab 1 of window id <w>` inserts the text into the Codex composer but
  does **not** submit it (the newline is not treated as Enter; the text arrives as a paste).
- A Return key event via System Events did not submit either (no Accessibility grant for the
  sender). A keystroke path would need Accessibility, focus stealing and draft-safety logic.
- Decision: Phase 1 ships **without** keystroke typing. Delivery is app-server only. If the
  daemon is unreachable, the app does not type; it notifies ("Continue it by hand").

## S3 — Terminal scripting reads: **works** (only needed for display)

- `tty of tab` (`/dev/ttys009`), `busy`, `processes` (`login, -zsh, codex`), `custom title`
  (Codex sets it to the working folder name, with a spinner prefix while busy) and `contents`
  are all readable. Reading them needs Automation consent for Terminal.
- Not required for Phase 1: tty + cwd + thread come from `ps`/`lsof` and app-server. Tab titles
  are optional cosmetics.

## S2 — tab ↔ thread: **solved via cwd**

- Codex TUI processes: `ps -t <tty>` (comm `codex`, CodexCLI binary); their cwd via
  `lsof -a -p <pid> -d cwd`. Loaded threads and their `cwd` via `thread/loaded/list` +
  `thread/read`. Match on cwd; two TUIs in the same cwd remain ambiguous (D18 applies: notify,
  no auto-continue for those).

## S4 — app-server lifetime

- `codex app-server proxy` requires the shared daemon (it is started by Codex itself and was
  running for days). If `proxy` fails to connect, the app reports "Codex daemon not running" and
  stays read-only for delivery (reads still work via a private `codex app-server` stdio child).
- Reads (rateLimits/usage) keep using the private stdio `codex app-server` (Task 3 transport,
  proven); delivery uses a separate WebSocket-over-proxy transport.

## Limit-stop screen (Step 6)

Plain text, no picker: `■ Usage limit reached. You've reached your usage limit. Increase your
limits to continue using codex.` followed by the normal composer `› Ask Codex to do anything`.
With app-server delivery the screen content no longer matters for safety.
