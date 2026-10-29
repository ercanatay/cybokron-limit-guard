# Security Policy

## Supported versions

Cybokron Limit Guard is in early development. Security fixes are made on the `main` branch and
included in the next release; only the latest release is supported. Releases are Developer ID
signed and notarized.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub:
[Security → Report a vulnerability](https://github.com/ercanatay/cybokron-limit-guard/security/advisories/new).

Include what you found, steps to reproduce, the affected version and macOS version, and the
impact you expect. You can expect an initial reply within a few days. Once a fix is available,
the advisory will be published and you'll be credited unless you prefer otherwise.

## Scope

The app runs locally and stores its data in `~/Library/Application Support/Cybokron Limit Guard/`.
It talks to the `codex app-server` that Codex itself provides, over stdio and Codex's local
control socket, and to GitHub over HTTPS (update checks, Other Versions…, Settings → Changelog,
and the download of a release's disk image, which is checked against its published size and
SHA-256 and its code signature before it is installed).

- It never reads `~/.codex/auth.json` or any other credential; sign-in state is judged from the
  app-server's answers. It opens Codex's session database read-only and never writes into `~/.codex`.
- It copies no conversation text into its own files; the activity log holds only the continue text
  it sent. No analytics, nothing about you or your sessions is sent anywhere.
- It sends keystrokes to no one: a continue is a turn started in the intended conversation through
  the app-server, and it asks for no Automation or Accessibility permission.
- A reset credit is used only when you press the button or turn on auto-use (off by default). Every
  use is written to a ledger before the call and carries an idempotency key, so a retry cannot spend
  a second credit; automatic use is limited to one per account every 7 days.

Of particular interest are issues that let another process, a crafted data file or a tampered
update make the app send a message to a session or spend a reset credit that you did not intend.
