NAME    := blackpane
LABEL   := extdesign.blackpane
VERSION := $(shell cat VERSION)
BIN     := build/$(NAME)
PREFIX  := $(HOME)/.local/bin
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
TMP     := $(shell getconf DARWIN_USER_TEMP_DIR)
STATE   := $(TMP)$(NAME).builtin-id $(TMP)$(NAME).no-access
DOMAIN  := gui/$(shell id -u)

# Signing. By default ad hoc ("-"): every rebuild is a new program for macOS and the
# Input Monitoring permission has to be granted again. With a code-signing certificate
# (`make cert` creates one) the permission survives rebuilds. If the certificate CERT
# is in the keychain it's used automatically; SIGN=... overrides.
CERT    := blackpane-signing
KEYCHAIN := $(HOME)/Library/Keychains/login.keychain-db
SIGN    ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"$(CERT)"' && echo $(CERT) || echo -)

$(BIN): src/$(NAME).m VERSION
	mkdir -p build
	clang -O2 -Wall -DBLACKPANE_VERSION='"$(VERSION)"' -o $@ $< -framework AppKit
	codesign --force --sign "$(SIGN)" --identifier $(LABEL) $@
	@echo "signed with: $(SIGN)"

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

# A self-signed code-signing certificate, valid 10 years, in the login keychain. It's
# used only to sign blackpane on this Mac. macOS asks for the login password once — to
# trust the certificate for code signing. The key and certificate files are created in a
# temporary folder and deleted.
cert:
	@if security find-identity -p codesigning 2>/dev/null | grep -q '"$(CERT)"'; then \
	  echo "$(CERT) is already in the keychain"; exit 0; fi; \
	d=$$(mktemp -d) && trap 'rm -rf "$$d"' EXIT && \
	/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(CERT)" \
	  -addext "basicConstraints=critical,CA:false" \
	  -addext "keyUsage=critical,digitalSignature" \
	  -addext "extendedKeyUsage=critical,codeSigning" \
	  -keyout "$$d/key.pem" -out "$$d/cert.pem" 2>/dev/null && \
	/usr/bin/openssl pkcs12 -export -inkey "$$d/key.pem" -in "$$d/cert.pem" \
	  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
	  -passout pass:$(CERT) -out "$$d/id.p12" && \
	security import "$$d/id.p12" -k "$(KEYCHAIN)" -P $(CERT) -T /usr/bin/codesign && \
	security add-trusted-cert -r trustRoot -p codeSign -k "$(KEYCHAIN)" "$$d/cert.pem" && \
	echo "$(CERT) created; next \`make install\` signs with it"
	rm -f $(BIN)

# Removes the certificate and its key. The next build is signed ad hoc again.
cert-remove:
	security delete-identity -c $(CERT) "$(KEYCHAIN)"
	rm -f $(BIN)

clean:
	rm -rf build

.PHONY: install uninstall cert cert-remove clean
