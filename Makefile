# Common tasks. Run `make` for the list.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

APP_NAME := Donut Fill
APP := build/$(APP_NAME).app
INSTALLED := /Applications/$(APP_NAME).app
# The version lives in scripts/build-app.sh; `make bump` edits it.
VERSION := $(shell sed -n 's/^VERSION="\(.*\)"/\1/p' scripts/build-app.sh)
TAG := v$(VERSION)
ZIP := build/Donut-Fill-$(VERSION).zip

.PHONY: help build app debug run test bench install uninstall dist bump release icon cert clean

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo "  Version $(VERSION)"

build: ## Compile everything (debug)
	swift build

app: ## Build and sign build/Donut Fill.app (release)
	scripts/build-app.sh release

debug: ## Build and sign the app in debug
	scripts/build-app.sh debug

run: app ## Build the app and open it
	open "$(APP)"

test: ## Run the tests
	scripts/test.sh

bench: ## Benchmark engines against du: make bench P=~/Library [E="bulk-threads posix"]
	@[ -n "$(P)" ] || { echo "usage: make bench P=<path> [E=\"engine[:workers] ...\"]" >&2; exit 1; }
	scripts/bench.sh "$(P)" $(E)

install: app ## Build the app and replace the copy in /Applications
	@if pgrep -xq DonutFill; then osascript -e 'tell application "$(APP_NAME)" to quit'; sleep 1; fi
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	@echo "Installed $(APP_NAME) $(VERSION) in /Applications"

uninstall: ## Remove the app from /Applications
	rm -rf "$(INSTALLED)"

dist: app ## Zip the app for a release (build/Donut-Fill-<version>.zip)
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "Wrote $(ZIP)"

bump: ## Set the version and commit it: make bump V=1.2.0
	@[[ "$(V)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "usage: make bump V=<major.minor.patch>" >&2; exit 1; }
	@[ -z "$$(git status --porcelain)" ] || { echo "the working tree has changes; commit them first" >&2; exit 1; }
	build=$$(sed -n 's|.*<key>CFBundleVersion</key><string>\([0-9]*\)</string>.*|\1|p' scripts/build-app.sh); \
	sed -i '' \
		-e 's/^VERSION=".*"/VERSION="$(V)"/' \
		-e "s|<key>CFBundleVersion</key><string>$$build</string>|<key>CFBundleVersion</key><string>$$((build + 1))</string>|" \
		scripts/build-app.sh
	git commit -q -m "Version $(V)" scripts/build-app.sh
	@echo "Committed version $(V); publish it with make release"

release: ## Test, tag, push and publish the current version on GitHub
	@[ "$$(git branch --show-current)" = main ] || { echo "release from main" >&2; exit 1; }
	@[ -z "$$(git status --porcelain)" ] || { echo "the working tree has changes; commit them first" >&2; exit 1; }
	@! git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null || { echo "$(TAG) already exists; run make bump V=<next version>" >&2; exit 1; }
	gh auth status >/dev/null
	$(MAKE) test dist
	notes=$$(mktemp); \
	previous=$$(git describe --tags --abbrev=0 2>/dev/null || true); \
	{ echo "### What's new"; echo; \
	  git log --no-merges --format='- %s' $${previous:+$$previous..}HEAD | grep -v '^- Version ' || true; \
	  echo; sed 's/{{VERSION}}/$(VERSION)/g' scripts/release-notes.md; } > "$$notes"; \
	git tag -a "$(TAG)" -m "$(APP_NAME) $(VERSION)"; \
	git push origin main "$(TAG)"; \
	gh release create "$(TAG)" "$(ZIP)" --title "$(APP_NAME) $(VERSION)" --notes-file "$$notes"; \
	rm -f "$$notes"

icon: ## Regenerate the app icon (needs librsvg)
	python3 scripts/make_icon.py
	scripts/make_icns.sh

cert: ## Create the local signing identity (once per machine)
	scripts/create-signing-cert.sh

clean: ## Remove build products
	rm -rf build .build
