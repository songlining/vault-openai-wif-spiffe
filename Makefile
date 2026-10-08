deck: ## Present the WIF config deck (presenterm)
	@command -v presenterm >/dev/null 2>&1 || { echo "presenterm not installed: brew install presenterm"; exit 1; }
	@presenterm -x presenterm/deck.md

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

.PHONY: deck help
