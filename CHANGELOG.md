# Changelog

Versions follow `MAJOR.MINOR.PATCH`: a fix bumps the patch, a new feature bumps the minor.

## 0.8.1 — 2026-10-25

- A failed `codesign` no longer leaves an unsigned build behind: the program is built and
  signed as a temporary file that replaces the previous build only after signing
  succeeds. Before, switching back to the previous `SIGN` took the unsigned build for a
  finished one, and `make install` could install it.

## 0.8.0 — 2026-10-25

- Commands `off` and `on` are renamed to `dark` (turn the built-in display off) and
  `light` (turn it on): “blackpane on” read both as “display on” and as “black pane on”.
  The log says `dark`/`light` too.

## 0.7.1 — 2026-10-25

Fixes from code review:

- The right Option no longer switches the display when used with a mouse click or
  scroll (Option-click), or with another modifier already held.
- A double tap whose second press starts within the window but ends after it no longer
  switches the display twice: the second press cancels the pending switch when it starts.
- A press half-seen while the event tap was disabled no longer breaks the next tap.
- The permission check on a tap gives up after 2 s instead of blocking the watcher.
- When the permission is revoked and the built-in display is off, it's turned on before
  the restart — the key no longer works.
- Turning the display on before exit is retried; if it still fails, the watcher exits
  with an error so launchd can start it again.
- An external monitor in hardware mirroring is recognised (online displays, not only
  active ones).
- `make install` creates `~/Library/LaunchAgents` if it doesn't exist.
- `make install SIGN="…"` and a newly created certificate re-sign the program even when
  the source is unchanged; an unrelated `SIGN` in the environment is ignored; only valid
  certificates are picked automatically.
- `make cert` run after an interrupted run trusts the already imported certificate.
- `make uninstall` no longer prints an ignored error when the program is already gone.

## 0.7.0 — 2026-10-25

- `make cert` creates a self-signed code-signing certificate (`blackpane-signing`,
  10 years, login keychain); builds are then signed with it automatically, and the
  Input Monitoring permission survives rebuilds. `make cert-remove` deletes it.
  `make install SIGN="name"` signs with any other certificate. Without a certificate
  builds stay ad hoc, as before.
- Every build is signed with the identifier `extdesign.blackpane`.

## 0.6.1 — 2026-10-25

- Turning Input Monitoring off now takes effect on the next tap. macOS keeps feeding an
  event tap created while the permission was on, and the watcher's own answer is cached,
  so every tap is checked by a fresh process (`blackpane access`). If the permission is
  gone, the tap leaves the display alone and the watcher restarts without permission.
- New command `access`: exit code 0 if Input Monitoring is granted.

## 0.6.0 — 2026-10-25

- The log is a plain file, `~/Library/Logs/blackpane.log`, instead of the unified system
  log: Console.app shows it under “Log Reports” with its whole history. Every line
  carries the version and the process ID. `on`/`off` from the command line are logged
  too, with refusals and errors.
- Without permission the watcher writes about it once, not on every 10-second restart;
  `Input Monitoring permission granted` marks the moment it got the permission.
- `make uninstall` keeps the log for later analysis.

## 0.5.2 — 2026-10-25

- Without Input Monitoring permission the watcher restarts every 10 seconds instead of
  every minute, so a newly granted permission is picked up sooner.
- launchd restarts the watcher only after an unclean exit (crash, `kill -9`, the
  “no permission” exit with code 75); a clean exit on logout or `bootout` is final.

## 0.5.1 — 2026-10-24

- `make uninstall` also removes the saved display ID and reminds to remove the Input
  Monitoring permission by hand (`tccutil` can't do it for a command-line program).
- Program output and log messages are in English.
- README: step-by-step install, permission troubleshooting, full uninstall.

## 0.5.0 — 2026-10-24

- The watcher turns the built-in display on before exiting on SIGTERM, SIGINT, SIGHUP
  and SIGQUIT — logout, `launchctl bootout`, `make install`/`uninstall` no longer leave
  the display off. After `kill -9` or a crash launchd restarts the watcher, which turns
  the display on at start if no external monitor is connected.

## 0.4.9 — 2026-10-24

First public release.

- A single tap of the right Option key turns the built-in display off and on while the
  lid stays open; a double tap, Option with another key, or a long press are ignored.
- The built-in display turns back on by itself when no external monitor is left,
  including when the cable is unplugged while asleep with the lid closed.
- `off` refuses to turn off the only display.
- Commands: `toggle`, `off`, `on`, `status`, `version`, `watch`.
- launchd agent `extdesign.blackpane`; events go to the unified log.
- Without Input Monitoring permission the watcher restarts once a minute, so a newly
  granted permission is picked up without manual restart.
