# check: — feedback-harness の check.sh から `make check` として呼ばれる。
# check.sh 自身を呼び返さないこと(無限再帰になる)。
PYTHON ?= python3
DEV_VENV ?= .venv
DEV_BIN := $(abspath $(DEV_VENV))/bin

.PHONY: check test install-dev-tools
check: test

install-dev-tools:
	$(PYTHON) -m venv "$(DEV_VENV)"
	"$(DEV_BIN)/python" -m pip install --requirement requirements-dev.txt
	@. scripts/dev_tool_versions.sh; \
		GOBIN="$(DEV_BIN)" go install \
		"github.com/rhysd/actionlint/cmd/actionlint@$${ACTIONLINT_VERSION}"

test:
	@PATH="$(DEV_BIN):$$PATH" bash tests/run_tests.sh
