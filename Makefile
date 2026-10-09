# kup itself needs no build step; this only drives the test suite.
PROVE ?= prove
N ?= $(shell nproc 2>/dev/null || echo 1)

check:
	$(PROVE) -w -j$(N) -It/lib t/

# For a single test: make check-one T=t/put.t
check-one:
	$(PROVE) -vw -It/lib $(T)

# Needs Devel::Cover; the report ends up in cover_db/coverage.html
cover:
	rm -rf cover_db
	# No -j: parallel runs clobber each other's coverage data
	KUP_TEST_COVER=1 $(PROVE) -w -It/lib t/
	cover -report html -report text cover_db

.PHONY: check check-one cover
