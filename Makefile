NVIM ?= nvim

# Auto-discovered: any tests/phase*_spec.lua is part of the suite.
SPECS := $(sort $(wildcard tests/phase*_spec.lua))

.PHONY: test test-plugin-stub

test:
	@set -e; for spec in $(SPECS); do echo "== $$spec"; $(NVIM) -l $$spec; done
	$(NVIM) -l tests/smoke.lua
	$(MAKE) test-plugin-stub

# :Mya must be a no-op-with-message stub, and plugin/mya.lua must not error
# on load, even when setup() was never called.
test-plugin-stub:
	@out=$$($(NVIM) --clean -u NONE --headless --cmd "set rtp+=$(CURDIR)" -c "Mya" -c "qa" 2>&1); \
	code=$$?; \
	echo "$$out"; \
	if [ $$code -ne 0 ]; then echo "plugin stub: nvim exited nonzero ($$code)"; exit 1; fi; \
	if echo "$$out" | grep -qE "E[0-9]+:|rror executing"; then echo "plugin stub: error detected in output"; exit 1; fi; \
	echo "plugin stub OK"
