# kup itself needs no build step; this only drives the test suite.
PROVE ?= prove
N ?= $(shell nproc 2>/dev/null || echo 1)

check:
	$(PROVE) -w -j$(N) -It/lib t/

# For a single test: make check-one T=t/put.t
check-one:
	$(PROVE) -vw -It/lib $(T)

.PHONY: check check-one
