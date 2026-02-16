REPO_DIR := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
BINDIR   := $(shell if [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then echo /opt/homebrew/bin; elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then echo /usr/local/bin; else echo ""; fi)

.PHONY: all install setup uninstall clean status help

all: help

install:
	@chmod +x "$(REPO_DIR)/bin/fire" "$(REPO_DIR)/lib/fcctl"
ifeq ($(BINDIR),)
	@printf '\033[0;33m⚠\033[0m no writable bin directory found (/opt/homebrew/bin or /usr/local/bin)\n'
	@printf '  add this to your shell profile:\n'
	@printf '    export PATH="$(REPO_DIR)/bin:$$PATH"\n'
else
	@ln -sf "$(REPO_DIR)/bin/fire" "$(BINDIR)/fire"
	@printf '\033[0;32m✓\033[0m fire installed to $(BINDIR)/fire\n'
endif

setup: install
	@"$(REPO_DIR)/bin/fire" setup

uninstall:
ifneq ($(BINDIR),)
	@rm -f "$(BINDIR)/fire"
	@printf '\033[0;32m✓\033[0m fire removed from $(BINDIR)\n'
else
	@printf '\033[0;33m⚠\033[0m no symlink to remove — fire was added to PATH manually\n'
endif

clean: uninstall
	@printf '\033[0;33m⚠\033[0m to delete the lima VM and all microVMs:\n'
	@printf '  fire vm delete\n'

status:
	@"$(REPO_DIR)/bin/fire" version
	@printf '\n'
	@"$(REPO_DIR)/bin/fire" list 2>/dev/null || true

help:
	@printf '\033[1mfirecracker-macos\033[0m — run firecracker microVMs on macOS\n'
	@printf '\n'
	@printf '  make install     symlink fire into PATH\n'
	@printf '  make setup       install + bootstrap everything (~5 min first run)\n'
	@printf '  make uninstall   remove fire symlink\n'
	@printf '  make status      show current state\n'
	@printf '\n'
	@printf 'quickstart:\n'
	@printf '  make setup           # one-time: installs deps, creates VM\n'
	@printf '  fire create myvm     # create a microVM\n'
	@printf '  fire start myvm      # boot it (~6s)\n'
	@printf '  fire ssh myvm        # shell in\n'
