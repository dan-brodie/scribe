.PHONY: build test lint format format-fix download-models download-fixtures check-licenses clean help phase

PROJECT     = Scribe.xcodeproj
SCHEME      = Scribe
TEST_SCHEME = ScribeTests

help:
	@echo "Scribe — available targets:"
	@echo "  make build           xcodebuild Scribe scheme"
	@echo "  make test            run ScribeTests"
	@echo "  make lint            swiftlint --strict"
	@echo "  make format          swift-format lint (check only)"
	@echo "  make format-fix      swift-format in-place"
	@echo "  make download-models fetch Qwen3-4B + Parakeet to ~/.cache/scribe-models/"
	@echo "  make download-fixtures fetch ASR test audio into Tests/Fixtures/"
	@echo "  make check-licenses  fail on non-allowlisted dependency licenses"
	@echo "  make clean           remove .build/ and DerivedData/"
	@echo "  make phase           show current phase completion status"

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

test:
	xcodebuild test -project $(PROJECT) -scheme $(TEST_SCHEME) \
		-destination 'platform=macOS'

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
	rm -rf ~/Library/Developer/Xcode/DerivedData/Scribe-*

phase:
	@grep -rh "^status:" specs/ | sort \
		| paste - <(ls specs/phase-*.md | xargs -I{} basename {} .md) \
		| awk '{printf "  %-12s %s\n", $$2, $$1}' || \
	  grep -rn "^status:" specs/ | sed 's|specs/||;s|\.md:| |' | sort
