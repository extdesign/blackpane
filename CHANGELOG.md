# Changelog

Versions follow `MAJOR.MINOR.PATCH`: a fix bumps the patch, a new feature bumps the minor.

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
