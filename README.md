<p align="center"><img src="assets/wordmark.svg" width="520" alt="blackpane"></p>

# blackpane

**English** | [Русский](README.ru.md)

[![Build](https://github.com/extdesign/blackpane/actions/workflows/build.yml/badge.svg)](https://github.com/extdesign/blackpane/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/github/license/extdesign/blackpane)](LICENSE)
[![Version](https://img.shields.io/github/v/tag/extdesign/blackpane?label=version&sort=semver)](https://github.com/extdesign/blackpane/tags)
[![macOS](https://img.shields.io/badge/macOS-27-black?logo=apple)](#blackpane)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20Pro%20tested-black?logo=apple)](#blackpane)
[![Language](https://img.shields.io/github/languages/top/extdesign/blackpane)](src/blackpane.m)
[![Last commit](https://img.shields.io/github/last-commit/extdesign/blackpane)](https://github.com/extdesign/blackpane/commits/master)

Turns a MacBook's built-in display off and on while the lid stays open — like a
blackout curtain on a window: the window is still there, no light gets through. Useful
when you work on an external monitor but don't want to close the lid: Touch ID stays
within reach, the built-in panel stays dark.

- **A single tap of the right Option key** turns the built-in display off; another tap
  turns it back on.
- **When no external monitor is left** (cable unplugged, including while asleep with the
  lid closed), the built-in display comes back on by itself.
- **Without an external monitor** the built-in display can't be turned off.

Developed and tested on a MacBook Pro 16″ (M1 Pro) with macOS 27.0.1 (26A434).

```text
src/blackpane.m                        the program
launchd/extdesign.blackpane.plist.in   launchd agent template
Makefile                               build, install, uninstall
assets/wordmark.svg                    the name for the README header
build/                                 build output (not in git)
```

## Contents

- [Install](#install)
- [Permission troubleshooting](#permission-troubleshooting)
- [If you rebuild often: keep the permission](#if-you-rebuild-often-keep-the-permission)
- [Uninstall](#uninstall)
- [Commands](#commands)
- [Log](#log)
- [Important](#important)
- [The key](#the-key)
- [How it works](#how-it-works)
- [What testing showed](#what-testing-showed)
- [Similar tools](#similar-tools)
- [License](#license)

## Install

1. Install Xcode Command Line Tools, if not yet:

   ```bash
   xcode-select --install
   ```

2. Get the source:

   ```bash
   git clone https://github.com/extdesign/blackpane.git
   cd blackpane
   ```

3. Build and install. There's no separate build step: `make install` compiles the
   program into `build/` first (and recompiles it whenever the source or `VERSION`
   changed), then installs it. `make` alone only builds.

   ```bash
   make install
   ```

   This installs:

   | What | Where |
   |---|---|
   | the program | `~/.local/bin/blackpane` |
   | the launchd agent (starts at login, restarted if it exits) | `~/Library/LaunchAgents/extdesign.blackpane.plist` |

   The agent starts right away, and from then on at every login: launchd loads the
   agents from your `~/Library/LaunchAgents` at login and starts those marked
   `RunAtLoad`. It runs for your user only. `make install` again after a change
   overwrites both files and restarts the agent — nothing piles up.

4. Grant **Input Monitoring** permission. Right after the start macOS shows a request
   for `blackpane`; click it through to System Settings → Privacy & Security → Input
   Monitoring and turn `blackpane` on. If no request appeared, open that page yourself:
   `blackpane` is already in the list, turned off. If it's not there, click “+” and choose
   `~/.local/bin/blackpane` (`.local` is hidden — press `Cmd+Shift+.` in the file dialog).

   Nothing needs restarting: the watcher picks the permission up within 10–20 seconds
   (see “Permission troubleshooting” for why).

5. Check: a single tap of the right Option turns the built-in display off, another tap
   turns it on. The log shows `watching the right Option key`:

   ```bash
   tail ~/Library/Logs/blackpane.log
   ```

Without the permission only the key doesn't work; restoring the display when the monitor
is unplugged works anyway.

## Permission troubleshooting

Problems met while developing, and fixes:

| Symptom | Why | Fix |
|---|---|---|
| The key does nothing right after the permission was granted | macOS caches the permission answer for the lifetime of a process; a watcher started without permission doesn't see it | wait 10–20 seconds — without permission the watcher exits every 10 seconds and launchd starts it again; or restart it now: `launchctl kickstart -k gui/$(id -u)/extdesign.blackpane` |
| System Settings says the app will be restarted, but nothing changes | that restart applies to apps; the watcher is a launchd agent, not an app | as above |
| After a rebuild (`make install`) the key stopped working, the switch is still on | the program is signed locally (ad hoc); a rebuild is a new program for macOS, the old permission no longer matches | remove `blackpane` with “−” and add `~/.local/bin/blackpane` with “+” (turning the switch off and on is not enough); to avoid this, see “If you rebuild often” |
| The log says `no Input Monitoring permission — restarting every 10 s until granted` | the permission isn't granted (or no longer matches after a rebuild); the line is written once, later restarts stay silent | grant it as in step 4; the log then says `Input Monitoring permission granted` |
| The log says `watching the right Option key`, but the key does nothing | an event tap created before the permission was granted gets no events | `launchctl kickstart -k gui/$(id -u)/extdesign.blackpane` |
| The key doesn't work on the lock screen | macOS doesn't pass key presses to apps while the screen is locked | by design; unplugging the monitor still brings the display back |
| The permission was turned off, but the next tap… | macOS keeps feeding a tap created while the permission was on | since 0.6.1 every tap is checked by a fresh process: the first tap after the permission is turned off doesn't switch the display, the log says `Input Monitoring permission revoked — key ignored, restarting`; if the built-in display was off, it's turned on (the key won't work any more), and the watcher restarts without permission |

## If you rebuild often: keep the permission

Not needed for a normal install — skip this if you update blackpane now and then.

By default the program is signed locally (ad hoc). macOS then ties the Input Monitoring
permission to the exact build, so every rebuild needs it granted again. Apps from the
App Store or from developers keep their permissions across updates because they're
signed with a certificate: macOS remembers “this identifier from this certificate”.
blackpane can do the same with a certificate you make yourself, for free:

```bash
make cert
```

It creates a self-signed code-signing certificate `blackpane-signing`, valid 10 years,
in your login keychain, and asks for your login password once — to trust it for code
signing. From then on `make install` signs with it automatically (the build prints
`signed with: blackpane-signing`). Grant the permission one last time (“−”, then “+”, as
after any rebuild); later rebuilds keep it. If `make cert` was interrupted (say, the
password dialog was cancelled), run it again: it trusts the already imported certificate.

The certificate is used only to sign blackpane on this Mac. To remove it:

```bash
make cert-remove
```

The next build is signed ad hoc again. You can also sign with any other code-signing
certificate you have: `make install SIGN="certificate name"` — the program is re-signed
even if nothing else changed. A `SIGN` variable in your environment is ignored; only
the one on the `make` command line counts.

## Uninstall

From the project folder:

```bash
make uninstall
```

It stops the agent (the watcher turns the built-in display on as it exits), runs
`blackpane light` in case the watcher wasn't running, and removes everything blackpane
leaves behind:

| What | Where |
|---|---|
| the launchd agent | `~/Library/LaunchAgents/extdesign.blackpane.plist` |
| the program | `~/.local/bin/blackpane` |
| the saved built-in display ID | `~/Library/Application Support/blackpane/` |
| the “no permission” mark | `blackpane.no-access` in `getconf DARWIN_USER_TEMP_DIR` |

The log `~/Library/Logs/blackpane.log` is kept for later analysis; delete it by hand if
not needed.

**The Input Monitoring permission has to be removed by hand:** System Settings → Privacy
& Security → Input Monitoring → select `blackpane` → “−”. It can't be scripted:
`tccutil reset ListenEvent <id>` accepts only apps known to LaunchServices and fails for
a command-line program with `No such bundle identifier … (OSStatus error -10814)` — signed
with a certificate or not — and
`tccutil reset ListenEvent` without an ID would reset the permission for every app.

`make clean` removes the build folder.

## Commands

```text
blackpane toggle    dark if lit, light if dark
blackpane dark      built-in display off — only if an external monitor is connected
blackpane light     built-in display on
blackpane status    displays macOS sees
blackpane version   version
blackpane access    is Input Monitoring granted (exit code 0 — yes)
blackpane watch     the watcher; started by the launchd agent
```

`blackpane access` run from Terminal reports Terminal's permission, not blackpane's:
macOS checks the app the program was launched from. The watcher runs it for itself.

## Log

`~/Library/Logs/blackpane.log` — a plain text file. In Console.app it's under “Log
Reports” as `blackpane.log`, with the whole history; in Terminal — `tail` or `less`.

What gets written: watcher start and stop, every `dark`/`light` (from the key, the watcher or
the command line) with its result, refusals, display checks with the list of active
displays, permission state. Errors come with a non-zero `err=`. Each line carries the
version and the process ID:

```text
2026-10-25 00:42:10 [0.8.2 4512] watcher 0.8.2 started err=0
2026-10-25 00:42:10 [0.8.2 4512] watching the right Option key err=0
2026-10-25 00:42:31 [0.8.2 4512] dark (key) id=1 err=0
2026-10-25 00:42:33 [0.8.2 4512] check: 1 online — 3:3840x1600:vendor=0x1e6d
2026-10-25 00:45:02 [0.8.2 4517] light (cli) id=1 err=0
```

`(key)` — the right Option, `(cli)` — the command line. A `check` line lists the online
displays the decision was made on; `:inactive` marks one that's online but not shown
(hardware mirroring), `:virtual` the placeholder macOS creates when no monitor is left,
and `lid closed` is added when the lid is closed.

It's a few lines a day, so the file is never rotated — a megabyte takes years. The
watcher without permission restarts every 10 seconds but writes about it only once.

## Important

By itself the built-in display stays off through screen lock, sleep and logout — only a
reboot resets it. The watcher is what brings it back:

- **External monitor gone** — the watcher turns the built-in display on.
- **Watcher stopped** (logout, `launchctl bootout`, `make install`, `make uninstall`,
  `kill` with SIGTERM, SIGINT, SIGHUP or SIGQUIT) — it turns the built-in display on
  before exiting, so the login window appears on it too.
- **Watcher killed with `kill -9` or crashed** — this can't be caught. launchd starts the
  watcher again (`KeepAlive` restarts it after any exit that isn't clean), and on start
  it turns the built-in display on if no external monitor is connected.

A watcher that has the permission runs without polling anything and is never restarted;
launchd restarts it only after a crash, `kill -9`, or the “no permission” exit.

The one case left: the agent is gone for good (its plist removed by hand without
`make uninstall`) while the display is off and the external monitor gets unplugged. Then
the Mac has no display — reboot; after a reboot the display always comes back.

## The key

The watcher listens to keys, mouse buttons and scrolling and changes nothing.

- The right Option is told apart from the left one by key code (61) and the
  `NX_DEVICERALTKEYMASK` flag.
- Only a **single short** tap counts. The display is left alone when the right Option
  goes together with another key, a mouse click or scroll (Option-click), or with
  another modifier already held (Command, Shift, Control, Fn, left Option); when it's
  held longer than 0.5 s; and on a double tap — a second press starting within 0.35 s of
  the first release. A double tap is left to other apps that react to it.
- That's why the display switches 0.35 s after the tap: the watcher waits to see whether
  a second press starts; the moment it does, the pending switch is cancelled.
- While the screen is locked, macOS doesn't pass key presses to apps — the key doesn't
  work there.
- With the lid closed the key does nothing: the built-in display is out of the list
  then as if it were dark, so there's nothing to toggle. `blackpane light` still works
  with the lid closed — the panel lights up when the lid is opened.

## How it works

The display is turned off with the private `CGSConfigureDisplayEnabled` call (SkyLight,
reachable through CoreGraphics) inside a `CGBeginDisplayConfiguration` …
`CGCompleteDisplayConfiguration` transaction with `kCGConfigureForSession`. The
transaction follows Apple's standard display configuration pattern (begin, change,
complete, cancel on error); only the change itself is the private call. A private API
may break in a future macOS — then `dark` returns an error and the display stays on.

A turned-off display disappears from the display list, so its ID is kept in
`~/Library/Application Support/blackpane/builtin-id` — not in the temporary folder, which
macOS clears of files untouched for a few days, while the display may stay dark longer.
Without the file, the watcher uses ID 1 — the built-in display on Apple Silicon;
`blackpane light` reports the missing ID instead of guessing.

With the lid closed the built-in display also drops out of the list. blackpane tells the
two apart by the lid state (`AppleClamshellState` of `IOPMrootDomain`).

The watcher (`watch`) is a process without windows, Dock icon or menu. It sleeps waiting
for events and uses no CPU. Memory: about 9–10 MB physical footprint (`footprint <pid>`);
`ps` shows about 35 MB RSS, mostly shared system frameworks.

## What testing showed

Without the watcher:

| With the built-in display off | Built-in display |
|---|---|
| `dark`, then the process exits | stays off — no process needs to hold it |
| `light` from a separate run | turns on |
| Screen lock, sleep, displays asleep | stays off |
| Lid closed with a monitor connected | nothing flickers: there's nothing to switch to |
| Monitor unplugged (lid open or closed) | **stays off** — the Mac has no display |
| Logout | **stays off**, the login window is on the external monitor only |
| Reboot | turns on |

`kCGConfigureForSession` lasts until the end of the WindowServer session, which lives
until reboot: logging out doesn't bring the display back. Hence the watcher.

With the watcher, unplugging the monitor turns the built-in display on within about two
seconds; with the lid closed it turns on before the Mac goes to sleep.

Things that weren't obvious:

- **The watcher is an `NSApplication`.** WindowServer delivers
  `CGDisplayRegisterReconfigurationCallback` events only to a process registered as an
  application; a command-line tool running `CFRunLoopRun` gets none.
- **The virtual display doesn't count.** When no monitor is left, macOS creates a virtual
  one — 1×1 or 1920×1080, vendor `0x756e6b6e` (`unkn`). A real one has an IOKit service
  (`CGDisplayIOServicePort`) or a 16-bit vendor number.
- **The key is caught directly, not remapped.** The alternative — `hidutil` turns the
  right Option into F19 and F19 is registered with `RegisterEventHotKey` — needs no
  permission, but `hidutil` has a single system-wide remapping list and `--set` replaces
  it entirely (breaking other remappings), the F-key may already be taken on another Mac,
  and a remapped Option no longer acts as Option for other apps.
- **The permission answer is cached per process.** Without Input Monitoring an event tap
  is still created, but no events arrive — not even after the permission is granted;
  macOS remembers the answer for the lifetime of the process. So without permission the
  watcher exits after 10 seconds with an error code and launchd starts it again; a clean
  exit (code 0, e.g. on logout) is not restarted.
- **launchd keeps the plist in memory.** `launchctl kickstart` restarts an agent with its
  old arguments; a changed plist is picked up only via `bootout` and `bootstrap`.
  `bootout` returns before the agent is unloaded — `make install` waits, otherwise
  `bootstrap` fails with “5: Input/output error”.

## Similar tools

[BetterDisplay](https://github.com/waydabber/BetterDisplay) and
[blackoutd](https://github.com/toobuntu/blackoutd) do the same with the same private call.
Both are much larger: in BetterDisplay disconnecting a display is part of a big paid
toolkit (not in the free version); blackoutd is about 3,000 lines of daemon around it
(menu bar icon, re-applying after sleep, recovering a stalled external monitor).
blackpane is one program of about 650 lines, comments included, with no menu and no
settings. Its code is written from scratch; the public documentation of these projects
helped when analysing problems along the way.

## License

[MIT](LICENSE) © 2026 Sergey Teterlev.
