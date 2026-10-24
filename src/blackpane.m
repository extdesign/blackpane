// blackpane — turn a MacBook's built-in display off and on while the lid stays open.
//
//   blackpane toggle    dark if lit, light if dark
//   blackpane dark      turn the built-in display off (only with an external monitor)
//   blackpane light     turn the built-in display on
//   blackpane status    displays macOS sees
//   blackpane version   version
//   blackpane access    is Input Monitoring granted (exit code 0 — yes)
//   blackpane watch     watcher for the launchd agent: no external monitor left — turn
//                       the built-in display on; a single right Option tap — toggle
//
// Log: ~/Library/Logs/blackpane.log — actions, errors, the version on every line.
//
// dark, light and toggle do their job and exit. dark/light rather than off/on:
// "blackpane on" would read both as "display on" and as "black pane on". A turned-off
// display stays off through screen lock, sleep, unplugging the external monitor and
// logout — only a reboot brings it back. Hence watch: it sleeps waiting for events, uses
// no CPU, and turns the display on when it exits (logout, agent stopped).
//
// The display is turned off with the private CGSConfigureDisplayEnabled call
// (SkyLight, reachable through CoreGraphics).
//
// Build: make (from the project root), output — build/blackpane

#import <AppKit/AppKit.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// The Makefile passes the version from the VERSION file; "dev" marks a build made
// without it (e.g. plain clang).
#ifndef BLACKPANE_VERSION
#define BLACKPANE_VERSION "dev"
#endif

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);

#define MAX_DISPLAYS 16
// Pause after a display event: let macOS finish reconfiguring, and handle the burst of
// events from one cable unplug with a single check.
#define SETTLE_SEC 1.5
// Retries if turning on fails (CoreGraphics returns an error while the Mac sleeps).
#define MAX_RETRIES 10

// The log is a plain file, ~/Library/Logs/blackpane.log, so Console.app shows it under
// “Log Reports” with its history. Actions and errors only — a few lines a day — so one
// file, no rotation. The version and pid on every line show which build did what. The
// file is opened for every write: writes are rare.
// quiet: without permission the watcher restarts every 10 s; repeating the same lines
// every 10 s is pointless.
static int quiet;

static void log_line(const char *fmt, ...) {
  const char *home = getenv("HOME");
  char path[PATH_MAX];
  if (quiet || !home)
    return;
  snprintf(path, sizeof path, "%s/Library/Logs/blackpane.log", home);
  FILE *f = fopen(path, "a");
  if (!f)
    return;
  char ts[32];
  time_t t = time(NULL);
  strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
  fprintf(f, "%s [%s %d] ", ts, BLACKPANE_VERSION, getpid());
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}

// The ID of the turned-off display (it drops out of the display list) lives in
// ~/Library/Application Support/blackpane — not in the temporary folder, which macOS
// clears of files untouched for a few days, while the display may stay dark longer.
// The mark “no permission, already logged” is disposable and stays in the temporary
// folder. Each path has its own buffer, so holding one while asking for the other is safe.
#define STATE_DIR "Library/Application Support/blackpane"

static const char *state_path(void) {
  static char path[PATH_MAX];
  const char *home = getenv("HOME");
  if (!home)
    return NULL;
  snprintf(path, sizeof path, "%s/" STATE_DIR "/builtin-id", home);
  return path;
}

static const char *no_access_path(void) {
  static char path[PATH_MAX];
  char dir[PATH_MAX];
  if (confstr(_CS_DARWIN_USER_TEMP_DIR, dir, sizeof dir) == 0)
    return NULL;
  snprintf(path, sizeof path, "%sblackpane.no-access", dir);
  return path;
}

static void save_id(CGDirectDisplayID id) {
  const char *p = state_path();
  char dir[PATH_MAX];
  if (p) {
    snprintf(dir, sizeof dir, "%s/" STATE_DIR, getenv("HOME"));
    mkdir(dir, 0755);
  }
  FILE *f = p ? fopen(p, "w") : NULL;
  if (!f)
    return;
  fprintf(f, "%u\n", id);
  fclose(f);
}

static CGDirectDisplayID load_id(void) {
  const char *p = state_path();
  FILE *f = p ? fopen(p, "r") : NULL;
  unsigned id = 0;
  if (f) {
    if (fscanf(f, "%u", &id) != 1)
      id = 0;
    fclose(f);
  }
  return id;
}

static uint32_t online(CGDirectDisplayID *ids) {
  uint32_t n = 0;
  if (CGGetOnlineDisplayList(MAX_DISPLAYS, ids, &n) != kCGErrorSuccess)
    return 0;
  return n;
}

// Is the lid closed? With the lid closed the built-in display drops out of the list just
// as when it's turned off, so callers that would otherwise read "not found" as "dark"
// check this first.
static int lid_closed(void) {
  io_service_t root =
      IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
  if (!root)
    return 0;
  CFTypeRef v = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"),
                                                kCFAllocatorDefault, 0);
  IOObjectRelease(root);
  int closed = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v);
  if (v)
    CFRelease(v);
  return closed;
}

// The built-in display if it's in the list; 0 — it's off or the lid is closed
// (lid_closed tells which).
static CGDirectDisplayID find_builtin(void) {
  CGDirectDisplayID ids[MAX_DISPLAYS];
  uint32_t n = online(ids);
  for (uint32_t i = 0; i < n; i++)
    if (CGDisplayIsBuiltin(ids[i]))
      return ids[i];
  return 0;
}

// A real external monitor. When no monitor is left, macOS creates a virtual one
// (1x1 or 1920x1080) — it doesn't count. A real one has an IOKit service; a virtual one
// has none and a made-up vendor number above 0xFFFF (real ones are 16-bit). blackoutd
// uses the same test.
static int is_hardware(CGDirectDisplayID id) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (CGDisplayIOServicePort(id) != MACH_PORT_NULL)
    return 1;
#pragma clang diagnostic pop
  return CGDisplayVendorNumber(id) <= 0xFFFF;
}

static int is_external(CGDirectDisplayID id) {
  return !CGDisplayIsBuiltin(id) && is_hardware(id);
}

// Online, not active: in hardware mirroring only the primary display is active, so an
// external mirrored onto the built-in would be missed by the active list.
static int has_external(void) {
  CGDirectDisplayID ids[MAX_DISPLAYS];
  uint32_t n = online(ids);
  for (uint32_t i = 0; i < n; i++)
    if (is_external(ids[i]))
      return 1;
  return 0;
}

static CGError set_enabled(CGDirectDisplayID id, bool enabled) {
  CGDisplayConfigRef cfg;
  CGError err = CGBeginDisplayConfiguration(&cfg);
  if (err != kCGErrorSuccess)
    return err;
  err = CGSConfigureDisplayEnabled(cfg, id, enabled);
  if (err != kCGErrorSuccess) {
    CGCancelDisplayConfiguration(cfg);
    return err;
  }
  return CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
}

#define GUESSED_BUILTIN_ID 1 // the built-in display is 1 on Apple Silicon

// One attempt to turn the built-in display on, by the ID saved when it was turned off.
// Without a saved ID: the `light` command gives up (it reports the problem), the watcher
// guesses GUESSED_BUILTIN_ID — it must not leave the Mac without a display. Retries are
// the caller's business. *used gets the ID tried, 0 if none.
static CGError light_once(bool guess_if_unknown, CGDirectDisplayID *used) {
  CGDirectDisplayID b = load_id();
  if (!b && guess_if_unknown)
    b = GUESSED_BUILTIN_ID;
  if (used)
    *used = b;
  if (!b)
    return kCGErrorIllegalArgument;
  return set_enabled(b, true);
}

static int cmd_status(void) {
  CGDirectDisplayID ids[MAX_DISPLAYS];
  uint32_t n = online(ids);
  printf("displays online: %u\n", n);
  for (uint32_t i = 0; i < n; i++) {
    CGRect b = CGDisplayBounds(ids[i]);
    printf("  id=%u %s active=%d main=%d %.0fx%.0f\n", ids[i],
           CGDisplayIsBuiltin(ids[i]) ? "built-in" : "external",
           CGDisplayIsActive(ids[i]), CGDisplayIsMain(ids[i]), b.size.width,
           b.size.height);
  }
  printf("saved built-in id: %u (%s)\n", load_id(), state_path());
  return 0;
}

// src — who asked: "cli" (command line) or "key" (the right Option); it goes into the
// log line, one line per action.

static int cmd_dark(const char *src) {
  if (lid_closed()) {
    fprintf(stderr, "the lid is closed: nothing to turn off\n");
    log_line("dark (%s) refused: lid closed", src);
    return 1;
  }
  CGDirectDisplayID b = find_builtin();
  if (!b) {
    fprintf(stderr, "built-in display not found: already dark\n");
    return 1;
  }
  if (!has_external()) {
    fprintf(stderr, "no external monitor: not turning the built-in display off\n");
    log_line("dark (%s) refused: no external monitor", src);
    return 1;
  }
  save_id(b);
  CGError err = set_enabled(b, false);
  printf("dark id=%u err=%d\n", b, err);
  log_line("dark (%s) id=%u err=%d", src, b, err);
  return err != kCGErrorSuccess;
}

// With the lid closed this still enables the panel in the display configuration, so it
// lights up when the lid is opened.
static int cmd_light(const char *src) {
  CGDirectDisplayID b = find_builtin();
  if (b) {
    printf("built-in id=%u is already lit\n", b);
    return 0;
  }
  CGError err = light_once(false, &b);
  if (!b) {
    fprintf(stderr, "built-in display id unknown\n");
    log_line("light (%s) failed: built-in display id unknown", src);
    return 1;
  }
  printf("light id=%u err=%d\n", b, err);
  log_line("light (%s) id=%u err=%d", src, b, err);
  return err != kCGErrorSuccess;
}

// With the lid closed "not in the list" doesn't mean dark, so there's nothing to toggle.
static int cmd_toggle(const char *src) {
  if (lid_closed()) {
    fprintf(stderr, "the lid is closed: nothing to toggle\n");
    log_line("toggle (%s) ignored: lid closed", src);
    return 1;
  }
  return find_builtin() ? cmd_dark(src) : cmd_light(src);
}

// --- watch ---

static int pending;
static int retries;

static void log_event(const char *msg, CGError err) { log_line("%s err=%d", msg, err); }

static void schedule_check(double sec);

// The displays the decision is made on — the online list, as find_builtin and
// has_external use — logged so the reason for a decision is visible. “:inactive” marks
// one that's online but not shown (e.g. the mirrored one in hardware mirroring).
static void log_displays(void) {
  CGDirectDisplayID ids[MAX_DISPLAYS];
  uint32_t n = online(ids);
  char buf[512] = "";
  for (uint32_t i = 0; i < n; i++) {
    CGRect b = CGDisplayBounds(ids[i]);
    char one[96];
    snprintf(one, sizeof one, " %u:%.0fx%.0f:vendor=0x%x%s%s", ids[i], b.size.width,
             b.size.height, CGDisplayVendorNumber(ids[i]),
             CGDisplayIsBuiltin(ids[i]) ? ":builtin"
             : is_hardware(ids[i])      ? ""
                                        : ":virtual",
             CGDisplayIsActive(ids[i]) ? "" : ":inactive");
    strlcat(buf, one, sizeof buf);
  }
  log_line("check: %u online%s —%s", n, lid_closed() ? ", lid closed" : "", buf);
}

static void check(void *ctx) {
  (void)ctx;
  pending = 0;
  log_displays();
  if (find_builtin() || has_external()) {
    retries = 0;
    quiet = 0; // quiet covers only the start-up lines
    return;
  }
  quiet = 0;
  CGError err = light_once(true, NULL);
  log_event("no external monitor — turning the built-in display on", err);
  if (err != kCGErrorSuccess && ++retries <= MAX_RETRIES)
    schedule_check(2.0);
  else
    retries = 0;
}

static void schedule_check(double sec) {
  if (pending)
    return;
  pending = 1;
  dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), NULL, check);
}

static void on_reconfig(CGDirectDisplayID id, CGDisplayChangeSummaryFlags flags,
                        void *ctx) {
  (void)id;
  (void)ctx;
  if (flags & kCGDisplayBeginConfigurationFlag)
    return;
  schedule_check(SETTLE_SEC);
}

// --- right Option ---
//
// A single tap of the right Option with no other key, modifier, mouse button or scroll —
// toggle. A double tap (second press starting within TAP_GAP_SEC of the first release)
// — nothing: it's left to other apps. That's why toggle runs TAP_GAP_SEC after the tap
// — waiting for a possible second one; the second press cancels it as soon as it starts.
// Option together with anything else is plain Option and doesn't count.
//
// The tap only listens (kCGEventTapOptionListenOnly) and changes nothing; it needs the
// Input Monitoring permission. Signed ad hoc (the default), every rebuild is a new
// program and macOS asks for the permission again; signed with a certificate
// (`make cert`), the permission survives rebuilds. A revoked permission doesn't stop an
// existing tap, so every tap is checked against a fresh process (access_still_granted).
// With the lid closed the key does nothing (cmd_toggle).

#define RIGHT_OPTION 61         // kVK_RightOption
#define RIGHT_ALT_MASK 0x40     // NX_DEVICERALTKEYMASK: right Option is down
#define TAP_GAP_SEC 0.35        // window for a second tap
#define TAP_HOLD_SEC 0.5        // held longer — not a tap
#define LEFT_ALT_MASK 0x20      // NX_DEVICELALTKEYMASK: left Option is down
// Modifiers that must not be held when the right Option goes down.
#define OTHER_MODIFIERS                                                                \
  (kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskCommand |       \
   kCGEventFlagMaskSecondaryFn | LEFT_ALT_MASK)
#define NO_ACCESS_EXIT_SEC 10.0 // no permission — exit, launchd starts us again
#define EXIT_NO_ACCESS 75       // EX_TEMPFAIL: launchd restarts only after an error exit
#define ACCESS_CHECK_SEC 2.0    // `blackpane access` didn't answer — give up waiting
#define RESTORE_TRIES 5         // turning the display on before exit: attempts …
#define RESTORE_PAUSE_US 500000 // … and the pause between them

static CFMachPortRef tap;
static int ropt_down;           // right Option is down now
static int ropt_clean;          // nothing else was held or pressed with it
static int ropt_second;         // this press started while a tap was pending: double
static CFAbsoluteTime ropt_since;
static unsigned tap_gen;        // ID of the pending toggle; any other ID — cancelled
static int tap_waiting;

// Termination signals: the watcher catches them to turn the display on before exiting
// (restore_on_signals) and gives the permission-check child default handling for them
// back (access_still_granted). One list for both, so they can't drift apart.
static const int exit_signals[] = {SIGTERM, SIGINT, SIGHUP, SIGQUIT};
#define EXIT_SIGNALS_COUNT (sizeof exit_signals / sizeof exit_signals[0])

// Turn the built-in display on, retrying: CoreGraphics may refuse for a moment (sleep,
// display reconfiguration). Used before exiting, when there's no later check to retry.
// With the lid closed the panel can't be seen anyway — one attempt, so that it lights up
// when the lid is opened, and no waiting (logout must not stall).
static CGError restore_builtin(void) {
  CGError err = kCGErrorSuccess;
  int tries = lid_closed() ? 1 : RESTORE_TRIES;
  for (int i = 0; i < tries; i++) {
    if (find_builtin())
      return kCGErrorSuccess;
    err = light_once(true, NULL);
    if (err == kCGErrorSuccess)
      return err;
    if (i + 1 < tries)
      usleep(RESTORE_PAUSE_US);
  }
  return err;
}

// Is the permission still granted? macOS keeps feeding an existing tap after the
// permission is revoked, and this process's own answer is cached — so ask a fresh
// process: `blackpane access`. Only on a tap, a few milliseconds. The child gets default
// signal handling back (the watcher ignores SIGTERM and friends) and is killed if it
// doesn't answer in ACCESS_CHECK_SEC, so a stuck check can't freeze the watcher. If the
// check itself can't run or doesn't answer, assume granted.
static int access_still_granted(void) {
  char self[PATH_MAX];
  uint32_t size = sizeof self;
  if (_NSGetExecutablePath(self, &size) != 0)
    return 1;
  char *args[] = {self, "access", NULL};
  posix_spawnattr_t attr;
  sigset_t dflt;
  sigemptyset(&dflt);
  for (size_t i = 0; i < EXIT_SIGNALS_COUNT; i++)
    sigaddset(&dflt, exit_signals[i]);
  posix_spawnattr_init(&attr);
  posix_spawnattr_setsigdefault(&attr, &dflt);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);
  pid_t pid;
  int rc = posix_spawn(&pid, self, NULL, &attr, args, environ);
  posix_spawnattr_destroy(&attr);
  if (rc != 0)
    return 1;
  int status;
  CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + ACCESS_CHECK_SEC;
  for (;;) {
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid)
      return !WIFEXITED(status) || WEXITSTATUS(status) == 0;
    if (r < 0)
      return 1;
    if (CFAbsoluteTimeGetCurrent() > deadline) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      log_line("permission check didn't answer — assuming granted");
      return 1;
    }
    usleep(5000);
  }
}

static void tap_fire(void *ctx) {
  if ((unsigned)(uintptr_t)ctx != tap_gen || !tap_waiting)
    return;
  tap_waiting = 0;
  if (!access_still_granted()) {
    // Revoked: the key won't work any more, so don't leave the user with a dark
    // built-in display — turn it on, then restart without permission; the new watcher
    // waits for it like after a fresh install.
    CGEventTapEnable(tap, false);
    log_line("Input Monitoring permission revoked — key ignored, restarting");
    if (!find_builtin())
      log_event("turning the built-in display on before restart", restore_builtin());
    exit(EXIT_NO_ACCESS);
  }
  cmd_toggle("key");
}

static void on_tap(void) {
  tap_waiting = 1;
  tap_gen++;
  dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TAP_GAP_SEC * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), (void *)(uintptr_t)tap_gen, tap_fire);
}

static CGEventRef on_event(CGEventTapProxy proxy, CGEventType type, CGEventRef ev,
                           void *ctx) {
  (void)proxy;
  (void)ctx;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    // Events were lost while disabled — forget a half-seen press.
    ropt_down = 0;
    ropt_clean = 0;
    ropt_second = 0;
    CGEventTapEnable(tap, true);
    return ev;
  }
  if (type != kCGEventFlagsChanged) { // a key, mouse button or scroll
    ropt_clean = 0;
    return ev;
  }
  // kCGEventFlagsChanged — a modifier went down or up
  int64_t key = CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
  if (key != RIGHT_OPTION) {
    ropt_clean = 0;
    return ev;
  }
  CGEventFlags flags = CGEventGetFlags(ev);
  int down = (flags & RIGHT_ALT_MASK) != 0;
  if (down && !ropt_down) {
    ropt_down = 1;
    ropt_clean = (flags & OTHER_MODIFIERS) == 0;
    ropt_since = CFAbsoluteTimeGetCurrent();
    ropt_second = tap_waiting;
    if (tap_waiting) { // second press within the window — cancel the pending toggle
      tap_waiting = 0;
      tap_gen++;
    }
  } else if (!down && ropt_down) {
    ropt_down = 0;
    if (ropt_second)
      ropt_second = 0; // end of a double tap — nothing to do
    else if (ropt_clean && CFAbsoluteTimeGetCurrent() - ropt_since < TAP_HOLD_SEC)
      on_tap();
  }
  return ev;
}

static void exit_for_restart(void *ctx) {
  (void)ctx;
  exit(EXIT_NO_ACCESS);
}

// Without permission the tap is still created, but no events arrive — not even after
// the permission is granted. macOS caches the permission answer for the lifetime of the
// process, so waiting inside the process is useless: without permission exit with an
// error, launchd starts us again, the new process asks again. With permission the
// watcher runs without polling anything and is never restarted.
static void start_tap(void) {
  const char *mark = no_access_path();
  if (!CGPreflightListenEventAccess()) {
    CGRequestListenEventAccess(); // shows the request only if not asked before
    log_event("no Input Monitoring permission — restarting every 10 s until granted", 1);
    FILE *f = mark ? fopen(mark, "w") : NULL;
    if (f)
      fclose(f);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                   (int64_t)(NO_ACCESS_EXIT_SEC * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, exit_for_restart);
    return;
  }
  CGEventMask mask =
      CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown) |
      CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventRightMouseDown) |
      CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventScrollWheel);
  tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap,
                         kCGEventTapOptionListenOnly, mask, on_event, NULL);
  if (!tap) {
    log_event("keyboard event tap not created", 1);
    return;
  }
  CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
  CFRelease(src);
  if (mark && unlink(mark) == 0)
    log_line("Input Monitoring permission granted");
  log_event("watching the right Option key", 0);
}

// --- exit ---
//
// A turned-off display survives logout, the watcher doesn't: at logout launchd sends it
// SIGTERM. So on termination signals the watcher first turns the built-in display on,
// then exits — the login window appears on it too. This is a clean exit (code 0), and
// launchd doesn't restart the watcher. If the display still can't be turned on after
// retries, exit with an error: where launchd still manages the agent it starts the
// watcher again, and that one turns the display on at start if no external is left.
// SIGKILL can't be caught; that's an unclean exit, launchd starts the watcher again,
// and on start it turns the display on if no external monitor is connected.

static void restore_and_exit(void *ctx) {
  int sig = (int)(intptr_t)ctx;
  CGError err = kCGErrorSuccess;
  if (!find_builtin()) {
    err = restore_builtin();
    log_line("signal %d — turning the built-in display on before exit err=%d", sig, err);
  }
  log_line("watcher stopped by signal %d", sig);
  exit(err == kCGErrorSuccess ? 0 : 1);
}

static void restore_on_signals(void) {
  for (size_t i = 0; i < EXIT_SIGNALS_COUNT; i++) {
    int sig = exit_signals[i];
    signal(sig, SIG_IGN); // otherwise the process dies before the handler runs
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0,
                                                 dispatch_get_main_queue());
    dispatch_set_context(s, (void *)(intptr_t)sig);
    dispatch_source_set_event_handler_f(s, restore_and_exit);
    dispatch_resume(s);
  }
}

// WindowServer delivers display-change events only to a process registered as an
// application; a CFRunLoopRun command-line tool gets none. Hence NSApplication — with
// no windows, Dock icon or menu.
static int cmd_watch(void) {
  // Already restarted without permission and logged it — skip the start-up lines.
  const char *mark = no_access_path();
  quiet = mark && access(mark, F_OK) == 0 && !CGPreflightListenEventAccess();
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  CGDirectDisplayID b = find_builtin();
  if (b)
    save_id(b);
  log_event("watcher " BLACKPANE_VERSION " started", kCGErrorSuccess);
  restore_on_signals();
  CGDisplayRegisterReconfigurationCallback(on_reconfig, NULL);
  start_tap();
  schedule_check(0); // in case we started with no external monitor already
  [NSApp run];
  return 0;
}

int main(int argc, char **argv) {
  const char *cmd = argc > 1 ? argv[1] : "status";
  if (!strcmp(cmd, "toggle"))
    return cmd_toggle("cli");
  if (!strcmp(cmd, "dark"))
    return cmd_dark("cli");
  if (!strcmp(cmd, "light"))
    return cmd_light("cli");
  if (!strcmp(cmd, "status"))
    return cmd_status();
  if (!strcmp(cmd, "version")) {
    puts(BLACKPANE_VERSION);
    return 0;
  }
  if (!strcmp(cmd, "access")) {
    int ok = CGPreflightListenEventAccess();
    puts(ok ? "Input Monitoring: granted" : "Input Monitoring: not granted");
    return ok ? 0 : 1;
  }
  if (!strcmp(cmd, "watch"))
    return cmd_watch();
  fprintf(stderr, "usage: blackpane [toggle|dark|light|status|version|access|watch]\n");
  return 2;
}
