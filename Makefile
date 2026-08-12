# check: — feedback-harness の check.sh から `make check` として呼ばれる。
# check.sh 自身を呼び返さないこと(無限再帰になる)。
.PHONY: check test
check: test

test:
	@bash tests/run_tests.sh
