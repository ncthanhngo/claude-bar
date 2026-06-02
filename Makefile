# Claude Bar — build & package
#
# Targets:
#   make backend    build csw binary          -> backend/bin/csw
#   make widget     build SwiftPM executable
#   make app        bundle ClaudeBar.app       -> release/ClaudeBar.app
#   make release    build app + create zip     -> release/ClaudeBar.zip
#   make install    copy to /Applications/ClaudeBar.app
#   make test       go vet + swift test
#   make clean      wipe release/ + .build/ + backend/bin/

SHELL        := /bin/bash
DISPLAY_NAME := ClaudeBar
EXECUTABLE   := ClaudeSwapWidget
BUNDLE_ID    := dev.ncthanhngo.claude-bar
SIGN_ID      := ClaudeSwapWidgetLocalDev

# Source Info.plist baked into the bundle. Override to build the AI Bar track:
#   make release DISPLAY_NAME=AIBar INFO_PLIST=packaging/Info-aibar.plist
INFO_PLIST   ?= packaging/Info.plist

BACKEND_BIN  := backend/bin/csw
WIDGET_BUILD := widget/.build/release/$(EXECUTABLE)
APP_BUNDLE   := release/$(DISPLAY_NAME).app

# sqlite_fts5: enables SQLite FTS5 full-text search inside the SQLCipher
# amalgamation used by chatstorage/messages_repo.go. Without this tag the
# messages_fts virtual-table migration fails with "no such module: fts5".
GO_TAGS := sqlite_fts5

.PHONY: all backend widget app release install test clean sync-check guard-identity

all: app

# Hard identity guard — the build-time backstop for the runbook preflights.
# Refuses to build an app whose bundled identity contradicts the current git
# branch, so `/rl` on ai-bar (stable plist + experimental code) or `/rl-aibar`
# on main can't ship the wrong app to the wrong users. Only the two release
# branches are enforced; feature/detached HEAD builds pass through. Escape
# hatch for a deliberate cross-build: ALLOW_IDENTITY_MISMATCH=1.
guard-identity:
	@branch=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown); \
	bid=$$(plutil -extract CFBundleIdentifier raw "$(INFO_PLIST)" 2>/dev/null || echo unknown); \
	if [ "$(ALLOW_IDENTITY_MISMATCH)" = "1" ]; then \
	  echo "guard-identity: bypassed (ALLOW_IDENTITY_MISMATCH=1)"; exit 0; fi; \
	if [ "$$branch" = "main" ] && [ "$$bid" != "dev.ncthanhngo.claude-bar" ]; then \
	  echo ""; echo "  ✗ guard-identity: on 'main' but INFO_PLIST=$(INFO_PLIST) has id '$$bid'"; \
	  echo "    (expected stable dev.ncthanhngo.claude-bar). 'main' builds Claude Bar."; \
	  echo "    For AI Bar, switch to the ai-bar branch and use /rl-aibar. Aborting."; \
	  echo ""; exit 1; fi; \
	if [ "$$branch" = "ai-bar" ] && [ "$$bid" != "dev.ncthanhngo.ai-bar" ]; then \
	  echo ""; echo "  ✗ guard-identity: on 'ai-bar' but INFO_PLIST=$(INFO_PLIST) has id '$$bid'"; \
	  echo "    (expected dev.ncthanhngo.ai-bar). Build AI Bar with:"; \
	  echo "      make release DISPLAY_NAME=AIBar INFO_PLIST=packaging/Info-aibar.plist"; \
	  echo "    or run /rl-aibar. Did you mean /rl-aibar instead of /rl? Aborting."; \
	  echo ""; exit 1; fi; \
	true

backend:
	@mkdir -p backend/bin
	cd backend && CGO_ENABLED=1 go build -trimpath -tags $(GO_TAGS) \
	  -ldflags="-s -w -X main.defaultGDriveClientID=$(GDRIVE_CLIENT_ID)" \
	  -o bin/csw ./cmd/csw

widget:
	cd widget && swift build -c release

app: guard-identity backend widget
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp $(WIDGET_BUILD)              $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE)
	cp $(BACKEND_BIN)               $(APP_BUNDLE)/Contents/Resources/csw
	cp packaging/icon.png           $(APP_BUNDLE)/Contents/Resources/icon.png
	cp packaging/AppIcon.icns       $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp $(INFO_PLIST)                $(APP_BUNDLE)/Contents/Info.plist
	# Localized strings — Foundation resolves Bundle.main.localizedString
	# against {locale}.lproj/Localizable.strings inside Contents/Resources.
	# SwiftUI's `Text("…")` literal-key lookup hits Bundle.main by default,
	# so the .strings tables live here (not in the SwiftPM resource bundle).
	cp -R packaging/en.lproj        $(APP_BUNDLE)/Contents/Resources/
	cp -R packaging/vi.lproj        $(APP_BUNDLE)/Contents/Resources/
	# Sparkle 2 lives at @rpath/Sparkle.framework — copy the built framework
	# next to the executable so dyld can resolve it. SwiftPM produces it at
	# widget/.build/<arch>-apple-macosx/release/Sparkle.framework.
	@arch=$$(uname -m); \
	  if [ "$$arch" = "arm64" ]; then triple=arm64-apple-macosx; \
	  else triple=x86_64-apple-macosx; fi; \
	  cp -R widget/.build/$$triple/release/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	# SPM's executableTarget doesn't add @executable_path/../Frameworks to
	# the binary's LC_RPATH, so dyld can't find Sparkle at runtime. Patch
	# it in post-link. install_name_tool may warn "already exists" on
	# re-runs — harmless, suppress with || true.
	install_name_tool -add_rpath @executable_path/../Frameworks \
	  $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE) 2>/dev/null || true
	codesign --force --deep --sign "$(SIGN_ID)" $(APP_BUNDLE) 2>/dev/null || \
	  codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

release: app
	@rm -f release/$(DISPLAY_NAME).zip
	cd release && zip -r --symlinks $(DISPLAY_NAME).zip $(DISPLAY_NAME).app
	@echo "SHA256: $$(shasum -a 256 release/$(DISPLAY_NAME).zip | cut -d' ' -f1)"
	@echo "Release: release/$(DISPLAY_NAME).zip"

install: app
	@rm -rf /Applications/$(DISPLAY_NAME).app
	cp -R $(APP_BUNDLE) /Applications/$(DISPLAY_NAME).app
	codesign --force --deep --sign "$(SIGN_ID)" /Applications/$(DISPLAY_NAME).app 2>/dev/null || \
	  codesign --force --deep --sign - /Applications/$(DISPLAY_NAME).app
	@echo "Installed /Applications/$(DISPLAY_NAME).app"

test:
	cd backend && CGO_ENABLED=1 go vet -tags $(GO_TAGS) ./... && \
	  CGO_ENABLED=1 go test -tags $(GO_TAGS) ./...
	cd widget && swift test

clean:
	rm -rf release backend/bin widget/.build

# Run sync health check on this Mac. Compare output against another Mac
# signed into the same Apple ID — identity hashes match and lastSeq within
# ±2 means iCloud sync is healthy across both. See scripts/sync-doctor.sh
# for --short and --json modes (the latter is friendly to cron / diff).
sync-check:
	@bash scripts/sync-doctor.sh
