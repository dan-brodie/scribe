.PHONY: build release install dmg attributions test lint format format-fix download-models download-fixtures check-licenses security-scan clean help phase

PROJECT     = Scribe.xcodeproj
SCHEME      = Scribe
TEST_SCHEME = ScribeTests
DERIVED     = build
APP         = $(DERIVED)/Build/Products/Release/Scribe.app
INSTALL_DIR = /Applications
# Optional: re-sign the installed app with a stable local code-signing identity
# so macOS TCC permissions (microphone, etc.) persist across local rebuilds.
# Set to a code-signing identity name, e.g.:
#   make install CODESIGN_IDENTITY="Scribe Dev"
# Leave empty (default) for the ad-hoc signature used by CI and release builds.
CODESIGN_IDENTITY ?=

help:
	@echo "Scribe — available targets:"
	@echo "  make build           xcodebuild Scribe scheme (Debug)"
	@echo "  make release         build a Release Scribe.app into $(DERIVED)/"
	@echo "  make install         build Release and copy Scribe.app to $(INSTALL_DIR)"
	@echo "  make dmg             build Release and package a drag-to-Applications DMG in dist/"
	@echo "  make attributions    regenerate THIRD-PARTY-LICENSES.md from resolved deps"
	@echo "  make test            run ScribeTests"
	@echo "  make lint            swiftlint --strict"
	@echo "  make format          swift-format lint (check only)"
	@echo "  make format-fix      swift-format in-place"
	@echo "  make download-models explain in-app model downloads (they happen inside Scribe)"
	@echo "  make download-fixtures fetch ASR test audio into Tests/Fixtures/"
	@echo "  make check-licenses  fail on non-allowlisted dependency licenses"
	@echo "  make security-scan   secret scan (gitleaks) over the working tree"
	@echo "  make clean           remove .build/ and DerivedData/"
	@echo "  make phase           show current phase completion status"

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-skipMacroValidation build

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) -skipMacroValidation build
	@echo "Built $(APP)"

install: release
	@test -d "$(APP)" || { echo "error: $(APP) not found"; exit 1; }
	@echo "Installing Scribe.app to $(INSTALL_DIR)/ …"
	rm -rf "$(INSTALL_DIR)/Scribe.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/Scribe.app"
ifneq ($(CODESIGN_IDENTITY),)
	@echo "Re-signing with identity '$(CODESIGN_IDENTITY)' for stable TCC permissions …"
	# No --options runtime: the app isn't configured with the hardened-runtime
	# microphone/audio entitlements, and enabling it would block mic capture.
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(INSTALL_DIR)/Scribe.app"
endif
	@echo "Installed. Launch from Applications or run: open $(INSTALL_DIR)/Scribe.app"

dmg: release attributions
ifneq ($(CODESIGN_IDENTITY),)
	@echo "Signing release with identity '$(CODESIGN_IDENTITY)' for a stable TCC identity …"
	# A stable, identity-based designated requirement (vs an ad-hoc cdhash) lets
	# macOS keep TCC grants across app updates. No --options runtime: the app has
	# no hardened-runtime audio entitlements and enabling it would block capture.
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(APP)"
endif
	bash Scripts/make-dmg.sh "$(APP)"

attributions:
	bash Scripts/generate-attributions.sh

test:
	xcodebuild test -project $(PROJECT) -scheme $(TEST_SCHEME) \
		-skipMacroValidation -destination 'platform=macOS'

lint:
	swiftlint lint --strict

format:
	swift-format lint -r App/ Core/ Services/

format-fix:
	swift-format format -r -i App/ Core/ Services/

download-models:
	bash Scripts/download-models.sh

download-fixtures:
	bash Scripts/download-fixtures.sh

check-licenses:
	bash Scripts/check-licenses.sh

security-scan:
	bash Scripts/security-scan.sh

clean:
	rm -rf .build/
	rm -rf $(DERIVED)/
	rm -rf ~/Library/Developer/Xcode/DerivedData/Scribe-*

phase:
	@grep -rh "^status:" specs/ | sort \
		| paste - <(ls specs/phase-*.md | xargs -I{} basename {} .md) \
		| awk '{printf "  %-12s %s\n", $$2, $$1}' || \
	  grep -rn "^status:" specs/ | sed 's|specs/||;s|\.md:| |' | sort
