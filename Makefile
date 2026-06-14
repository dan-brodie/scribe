.PHONY: build release install test lint format format-fix download-models download-fixtures check-licenses clean help phase

PROJECT     = Scribe.xcodeproj
SCHEME      = Scribe
TEST_SCHEME = ScribeTests
DERIVED     = build
APP         = $(DERIVED)/Build/Products/Release/Scribe.app
INSTALL_DIR = /Applications

help:
	@echo "Scribe — available targets:"
	@echo "  make build           xcodebuild Scribe scheme (Debug)"
	@echo "  make release         build a Release Scribe.app into $(DERIVED)/"
	@echo "  make install         build Release and copy Scribe.app to $(INSTALL_DIR)"
	@echo "  make test            run ScribeTests"
	@echo "  make lint            swiftlint --strict"
	@echo "  make format          swift-format lint (check only)"
	@echo "  make format-fix      swift-format in-place"
	@echo "  make download-models fetch Gemma 4 E4B + Parakeet to ~/.cache/scribe-models/"
	@echo "  make download-fixtures fetch ASR test audio into Tests/Fixtures/"
	@echo "  make check-licenses  fail on non-allowlisted dependency licenses"
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
	@echo "Installed. Launch from Applications or run: open $(INSTALL_DIR)/Scribe.app"

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

clean:
	rm -rf .build/
	rm -rf $(DERIVED)/
	rm -rf ~/Library/Developer/Xcode/DerivedData/Scribe-*

phase:
	@grep -rh "^status:" specs/ | sort \
		| paste - <(ls specs/phase-*.md | xargs -I{} basename {} .md) \
		| awk '{printf "  %-12s %s\n", $$2, $$1}' || \
	  grep -rn "^status:" specs/ | sed 's|specs/||;s|\.md:| |' | sort
