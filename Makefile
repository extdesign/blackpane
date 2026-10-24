NAME    := blackpane
LABEL   := extdesign.blackpane
VERSION := $(shell cat VERSION)
BIN     := build/$(NAME)
PREFIX  := $(HOME)/.local/bin
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
TMP     := $(shell getconf DARWIN_USER_TEMP_DIR)
STATE   := $(TMP)$(NAME).builtin-id $(TMP)$(NAME).no-access
DOMAIN  := gui/$(shell id -u)

$(BIN): src/$(NAME).m VERSION
	mkdir -p build
	clang -O2 -Wall -DBLACKPANE_VERSION='"$(VERSION)"' -o $@ $< -framework AppKit

install: $(BIN)
	mkdir -p $(PREFIX)
	install -m 755 $(BIN) $(PREFIX)/$(NAME)
	sed 's|@HOME@|$(HOME)|g' launchd/$(LABEL).plist.in > $(AGENT)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@# bootout returns before the old watcher is unloaded; without waiting,
	@# bootstrap fails with "5: Input/output error".
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	  launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1 || break; sleep 0.5; done
	launchctl bootstrap $(DOMAIN) $(AGENT)

# The watcher turns the display on as it stops; `on` covers a watcher that wasn't running.
# The log ~/Library/Logs/blackpane.log is kept for later analysis.
# Input Monitoring can't be reset by a command: tccutil accepts only apps known to
# LaunchServices, and a command-line program isn't one.
uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	-@test -x $(PREFIX)/$(NAME) && $(PREFIX)/$(NAME) on
	rm -f $(AGENT) $(PREFIX)/$(NAME) $(STATE)
	@echo "Remove blackpane from System Settings → Privacy & Security → Input Monitoring (“−”)."
	@echo "The log ~/Library/Logs/blackpane.log is kept; delete it by hand if not needed."

clean:
	rm -rf build

.PHONY: install uninstall clean
