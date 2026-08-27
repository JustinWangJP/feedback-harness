English | [日本語](configuration.ja.md) | [简体中文](configuration.zh-CN.md)

# Configuration guide (config.yaml)

Harness behavior is adjusted through `.feedback/config.yaml`. Because this file **lives in the repository**, everyone on the team gets the same settings and nobody has to be asked to `export` anything. Every key you leave out keeps its default, so there is no need to write them all.

Copy the [template](../.feedback/config.example.yaml) to `.feedback/config.yaml` to get started:

```bash
cp .feedback/config.example.yaml .feedback/config.yaml
```

### How it is used day to day

```
[install]  run check.sh once            → see what currently fails
   ↓
[adjust]   --list-checks                → see check IDs and current verdicts
   ↓       copy config.example.yaml to .feedback/config.yaml
[confirm]  --list-checks                → confirm the "source" column now says config
   ↓
[share]    commit config.yaml           → the whole team gets the same settings
   ↓
[repay]    delete the line once fixed   → the default comes back
```

**The config diff becomes the record of debt repayment.** Being able to delete `warn_on: [format]` is the proof that the debt was paid, and the diff is the record. That is why even a temporary relaxation belongs in the config — not in shell history or someone's personal environment variables.

## Three minutes to start

First, look at the current settings. This command does not run the checks themselves, so it is always safe.

```bash
bash scripts/check.sh --list-checks
```

Output (an example from this repository, feedback-harness, itself; which rows appear depends on the project's stacks and which tools are installed):

```
検査ID       ラベル               ステージ  判定  出所
ruff         python: ruff         lint      fail  既定
ruff-format  python: ruff format  format    warn  既定
npm-ls       node: npm ls         lint      fail  既定
bash-syntax  shell: bash -n       lint      fail  既定
shellcheck   shell: shellcheck    lint      fail  既定
json-syntax  config: json 構文    lint      fail  既定
md-links     docs: 内部リンク     docs      fail  既定
make-check   make check           test      fail  既定
```

**The leftmost column is the configuration key.** If it bothers you that `ruff-format` is `warn`, add one line to the config you copied:

```yaml
checks:
  ruff-format:
    severity: fail
```

Run `--list-checks` again and both the verdict and the **source** change:

```
ruff-format  python: ruff format  format    fail  checks.ruff-format
```

The source moving from `既定` (default) to `checks.ruff-format` confirms that what you wrote is in effect. This round trip — write it, then confirm the source with `--list-checks` — is the basic shape of every configuration task.

## Look it up by problem

### Day one: the existing code fails everywhere

**Symptom**: you installed the harness and format or lint fails en masse, so nothing can be completed.

**YAML to write**:

```yaml
check:
  warn_on: [format]   # demote FAIL to WARN — still checked, but does not block completion
```

**How the output changes**: the verdict column of `--list-checks` shows `warn` where it showed `fail`. The last line of `check.sh` becomes `ALL PASS (N件WARN …)` and it exits 0. WARNs are recorded to `events.jsonl` through the plugin hooks and appear under "頻出WARN" (frequent WARNs) in `stats`, so what you have not fixed stays visible (they are not recorded in environments installed only through `init.sh`, which have no hooks).

Remove the stage from `warn_on` once you have fixed it. **Use `skip` only when you want the check itself gone** — `skip` does not run the check, so breakage goes unnoticed. `warn_on` is for "I cannot fix it now but I want to keep seeing it".

### Silencing a check with too many false positives

**Symptom**: one check (here, `vulture`) always produces meaningless findings in this project.

**YAML to write**:

```yaml
checks:
  vulture:
    severity: skip
```

**How the output changes**: the matching line of `check.sh` becomes `SKIP  python: vulture (config: checks.vulture)`. Because the reason says `config: …`, you can tell a deliberate decision from default behavior.

You can also stop a whole stage (`check.skip: [security]` and so on; the accepted values are `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract`). Note that `lint` contains 18 checks, so name individual check IDs if you want to keep syntax detection (`bash-syntax` / `json-syntax`).

### A monorepo where each language has its own situation

**Symptom**: the same repository holds Python and Node; the Python tests are too heavy, and the Node lint is messy for historical reasons.

**YAML to write**:

```yaml
check:
  python:
    skip: [test]
  node:
    warn_on: [lint]
```

**How the output changes**: only the Python test stage is SKIPped and only the Node lint checks become WARN. **Nothing leaks into other stacks** — writing `check.python.skip` does not remove the Go tests. The six stacks are `python` / `node` / `go` / `rust` / `java` / `shell`.

### Keeping generated and vendored code out of sight

**Symptom**: shell scripts under `vendor/` or generated Markdown get caught by `bash-syntax` or `md-links`.

**YAML to write**:

```yaml
check:
  exclude:
    - vendor/**
    - dist/**
```

**How the output changes**: the glob drops out of the files the harness enumerates, and the PASS / FAIL / WARN lines caused by those files disappear.

**Where it applies (important)**: `exclude` applies **only to checks where the harness itself enumerates the files** — shell's `bash -n` / `shellcheck`, config's `json-syntax` / `yaml-syntax`, docs' `md-links`, and so on. **It does not apply to tools that walk the tree themselves, such as ruff, pytest, or go test.** Those follow their own ignore settings (ruff's `exclude` / `per-file-ignores`, pytest's `testpaths` / `--ignore`, and so on). See "[When it does not take effect](#when-it-does-not-take-effect)".

### Changing behavior in CI only

**Symptom**: you want to keep the everyday config as it is, and only in CI drop the heavy stages or tighten shellcheck.

**What to write**: environment variables. They take precedence over the config:

```bash
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # drop heavy stages in CI only
FEEDBACK_SHELLCHECK_SEVERITY=style bash scripts/check.sh # tighten in CI only
```

**How the output changes**: the source in `--list-checks` starts with `env.`, for example `env.FEEDBACK_CHECK_SKIP`. **Only these three settings can be switched by environment variable** (`FEEDBACK_CHECK_SKIP` / `FEEDBACK_SHELLCHECK_SEVERITY` / `FEEDBACK_CONTRACT_BASE`); there is no environment variable that overrides a verdict (`severity` / `fail_on` / `warn_on`).

### Making one specific check always block

**Symptom**: checks the project has not declared become WARN, but this one must always FAIL (for example, whether dependencies really exist).

**YAML to write**:

```yaml
checks:
  deptry:
    severity: fail
```

**How the output changes**: `--list-checks` shows `fail` instead of `warn`, with `checks.deptry` as the source. Any finding makes `check.sh` exit 1 and blocks completion.

## Precedence

**environment variable > `checks.<check>` > `check.<stack>` > `check` (global) > default**

The most specific setting wins. A guideline for choosing: **settings you want committed belong in the config; one-off overrides belong in environment variables.** Environment variables written into a CI workflow are committed too, but they express "the default for the CI environment".

### There are two configuration layers

| File | Tracking | Purpose |
|---|---|---|
| `.feedback/config.yaml` | committed and shared | The team's settings. Everyone gets the same verdicts |
| `.feedback/local/config.yaml` | already in `.gitignore` | Settings for this machine only. **Takes precedence over the shared settings** |

Both accept the same keys. Personal settings exist so you can reflect local circumstances without rewriting the shared settings — turning off checks for a tool you do not use, temporarily dropping a heavy check. If you want to change the team's verdicts, edit the shared settings.

Anything decided by a personal setting shows a source starting with `local.` in `--list-checks` (for example `local.checks.ruff`), and the SKIP reason reads `(個人設定: …)` rather than `(config: …)`. Personal settings are invisible to everybody else, so this distinction avoids a situation where reading the shared settings never explains the behavior.

If either file is broken, the error names that file and the checks continue with defaults.

When the same stage is named by several keys in the same layer, `fail_on` > `warn_on` > `skip` wins, so that a check is not disabled by accident: the stricter verdict is preferred.

## Reference

A chapter to look things up in. There is no need to read it through. Copy check IDs from the leftmost column of `--list-checks`.

**① Global (`check`)**

| Key | Type | Default | Environment variable | Effect |
|---|---|---|---|---|
| `skip` | stage list | `[]` | `FEEDBACK_CHECK_SKIP` | Skip the given stages. The vocabulary is `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract` |
| `fail_on` | stage list | `[]` | — | FAIL rather than WARN even without a declaration |
| `warn_on` | stage list | `[]` | — | Demote failing stages to WARN |
| `exclude` | glob list | `[]` | — | Exclude from the files the harness enumerates (scope as described above) |
| `log_tail_lines` | integer | `40` | — | How many log lines to print on FAIL / WARN. Directly affects how much context the agent receives |
| `stage_timeout_seconds` | integer | `0` | 0-3600 | Per-stage time limit. `0` leaves it to the harness: runs from the CLI / CI are unlimited, while the Stop hook cuts each stage off at 240s — shorter than its own hook limit, so the agent still learns which stage never finished. A value you set applies to every run path. A cut-off is reported as `TIMEOUT`, not `FAIL` |

**② Per stack (`check.<stack>`)**

Only the three keys `skip` / `fail_on` / `warn_on`. They mean the same as in ① but apply only to that stack's checks. The stacks are `python` / `node` / `go` / `rust` / `java` / `shell`.

**③ Per check (`checks.<id>`)**

| Key | Type | Default | Effect |
|---|---|---|---|
| `severity` | `fail` \| `warn` \| `skip` | per check (the default follows from whether it is declared) | The verdict for this check. `skip` does not run it |
| tool-specific keys | — | — | See the table below |

| Check ID | Specific key | Type | Default | Environment variable |
|---|---|---|---|---|
| `shellcheck` | `min_severity` | `style`\|`info`\|`warning`\|`error` | `warning` | `FEEDBACK_SHELLCHECK_SEVERITY` |
| `vulture` | `min_confidence` | integer 0–100 (higher detects less) | `80` | — |
| `oasdiff` | `base` | string | `main` | `FEEDBACK_CONTRACT_BASE` |

**Other sections**

| Key | Type | Default | Effect |
|---|---|---|---|
| `audit.interval_days` | integer | `7` | Days before `stats` / `report` recommend running an audit |
| `audit.npm_audit_level` | string | `high` | `npm audit --audit-level=<value>` (`low` / `moderate` / `high` / `critical`) |
| `feedback.open_threshold` | integer | `3` | How many open entries make `add` / `stats` / `report` prompt for promotion |
| `feedback.lock_timeout_seconds` | integer | `10` | Seconds to wait for the repository lock when several agents or sessions update at once (1–300) |
| `feedback.stale_days` | integer | `7` | Days before `stats` / `report` annotate a frequent WARN or top failure with "this has not recurred lately" |
| `feedback.retro_interval_days` | integer | `90` | Days before `stats` / `report` recommend a rule review (the baseline is `.feedback/.last-retro`) |

### The check IDs (41)

Do not memorize them. Copy from the leftmost column of `--list-checks` when you need one. The list below is for an overview.

| Stack / group | Check IDs |
|---|---|
| python | `ruff` / `ruff-format` / `mypy` / `pytest` / `deptry` / `vulture` / `import-linter` |
| node | `node-lint` / `node-typecheck` / `tsc` / `node-test` / `node-test-coverage` / `node-build` / `npm-ls` / `prettier` / `knip` |
| go | `go-vet` / `go-build` / `go-test` / `go-mod-verify` / `gofmt` |
| rust | `clippy` / `cargo-check` / `cargo-test` / `cargo-metadata` / `cargo-fmt` / `cargo-semver-checks` |
| java | `mvn` / `gradle` |
| shell | `bash-syntax` / `shellcheck` |
| cross-cutting | `json-syntax` / `yaml-syntax` / `md-links` / `secretlint` / `gitleaks` / `actionlint` / `dockerfilelint` / `hadolint` / `oasdiff` / `make-check` |

`gradle` covers both `./gradlew check` and `gradle check` (a difference in how it is launched, not a different check).

**Derived check IDs (per module)**

In a Maven monorepo without a root `pom.xml`, each discovered `pom.xml` gets its own check ID, `mvn-<module-slug>` (for example `services/api/pom.xml` → `mvn-services-api`). The slug is reduced to lowercase letters, digits, and hyphens, and a numeric suffix is appended when two modules would produce the same slug (`mvn-services-api-2`). The actual IDs are visible in the leftmost column of `--list-checks`.

The verdict resolves as **the derived ID's explicit setting → the `mvn` setting**. In other words `check.skip: [test]` and `checks.mvn.severity: skip` reach every module, while `checks.mvn-tools-cli.severity: skip` stops only that one. You do not have to disable Maven checking wholesale to drop a single heavy module.

## When it does not take effect

### First, look at the source with `--list-checks`

Almost every "it does not take effect" is a symptom of **the verdict being decided in a different layer than you assumed**.

```bash
bash scripts/check.sh --list-checks
```

- The source is still `既定` (default) → the config is not being read. See "A broken config" below
- The source is a config path (for example `check.python.warn_on`) but not the key you expected (you meant to write `check.python.warn_on` but `check.warn_on` is what took effect) → a precedence mistake
- The source is `env.<variable>` → an environment variable is still exported. It takes precedence over the config, so the config has no effect until you `unset` it

### A broken config prints to stderr after the table (by design)

If the config contains a typo (an unknown key, an unknown check ID, a type mismatch), `--list-checks` prints the table **with defaults** and then writes the error to stderr and exits 1:

```
$ bash scripts/check.sh --list-checks
検査ID       ラベル               ステージ  判定  出所
(… the table is printed with defaults …)

ERROR: .feedback/config.yaml を読めませんでした。以下はすべて既定値です。
.feedback/config.yaml: check.skip の 'lnit' は未知のステージです。使えるのは lint / typecheck / test / build / format / security / docs / contract
```

This is safer than silently falling back to defaults — it tells you that the reason "the settings do not work" is an error in the config itself. A normal `check.sh` run also raises `FAIL  config: 設定エラー`; the detail block below it names the source — the config file or the environment variable.

### The scope of `exclude`

`exclude` applies only to **checks where the harness itself enumerates the files** (`bash-syntax` / `shellcheck` / `json-syntax` / `yaml-syntax` / `md-links`, and so on). It **does not apply to tools that walk the tree themselves**, such as ruff, pytest, go test, or vulture — those follow their own ignore settings (ruff's `exclude` / `per-file-ignores`, pytest's `testpaths`, and so on). The harness does not translate into each tool's exclusion syntax, because the semantics differ per tool and any translation would drift.

One asymmetry is worth knowing: `check_file.sh` (the PostToolUse hook) always applies `exclude`, because it is handed a single file. So an excluded `vendor/foo.py` passes silently right after you edit it, while the Stop hook's `ruff check .` still reports it. Set the tool's own ignore rules too when you want both paths to agree.

### Some checks do not appear in `--list-checks`

`--list-checks` shows only the checks that apply to the target project's layout. When a check applies but its tool is not installed, the row is not omitted: it is shown as `skip` with the reason. When there is no configuration or no target file, so the check's own applicability condition is not met, it is not shown at all. For example, `import-linter` does not appear in a project without an import-linter configuration, but it is shown as `skip` when the configuration exists and only the tool is missing.

To retrieve every row for machine processing, use the JSON output:

```bash
bash scripts/check.sh --list-checks --json
```

### If you still cannot tell

`bash -c '. scripts/lib.sh; harness_python scripts/harness_config.py --json'` prints every resolved effective value. Also check whether you have hit "[YAML notation that is and is not supported](#yaml-notation-that-is-and-is-not-supported)".

## YAML notation that is and is not supported

The config YAML is read by an in-house parser rather than requiring PyYAML (so as not to add an optional dependency). As a result, **the supported notation is a subset of YAML**.

**Supported**:

- Comments (starting with `#`, and after a value)
- Nested maps (space indentation, no depth limit)
- Scalars: bare strings / `'...'` / `"..."` / integers / `true` and `false` / empty (= null)
- Lists: block form (`- item`) and flow form (`[a, b]`), and the empty list `[]`

**Not supported (an error with the line number and the reason)**:

- Anchors and aliases (`&` / `*`)
- Multiple documents (`---` separators)
- Multi-line strings (`|` / `>`)
- Nested list elements (a list whose elements are maps or lists)
- Tab indentation

An unclosed quote (`'` / `"`) or an unclosed flow list (`[`) is also an error with a line number. This prevents a broken value from being accepted as an ordinary string and silently disabling later checks.

Silently ignoring unsupported notation would produce the worst state — "I wrote it and it does not work" — so all of these FAIL. An unknown key (a typo such as `shelcheck_severity`) is an error for the same reason.
