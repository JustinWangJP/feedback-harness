English | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# scripts/ — feedback-harness execution engine

This directory contains the feedback harness's executable scripts. When a README.md exists at the project root, it provides the overview of the complete harness. This document describes the **role, specification, and usage** of each script.

The scripts and accumulated data (`.feedback/`) are **fully shared between Claude Code and Codex**. Only the entry point—who starts each script and when—is environment-specific, as described later.

## Layout

```text
scripts/
├── check.sh          # Full check: stack detection → 8 stages and cross-cutting checks, then summary
├── check_file.sh     # Fast single-file check based on file extension
├── lib.sh            # Shared utilities for check.sh / check_file.sh, including has()
├── harness_config.py # Sole parser for .feedback/config.yaml (YAML subset, schema validation, 3-level resolution)
├── feedback_log.py   # Feedback CLI: record, promote, review, aggregate, and report by period
├── audit.sh          # On-demand vulnerability audit (the only networked check; never called by Stop hooks)
├── init.sh           # Installer for environments without Hooks (not copied into target projects)
└── hooks/
    ├── on_session_start.sh  # Claude Code / Codex SessionStart → initial .feedback/ seed
    ├── post_edit.sh         # Claude Code / Codex PostToolUse → check_file.sh
    └── on_stop.sh           # Claude Code / Codex Stop → check.sh
```

The scripts fall into three groups:

| Group | Scripts | Role |
|------|-----------|------|
| Automated checks (offline) | `check.sh`, `check_file.sh`, `hooks/*` | Returns lint/test/build results to the agent so it can fix problems itself |
| Feedback accumulation and measurement | `feedback_log.py` | Records and generalizes human feedback for future sessions; produces metrics and period summaries |
| On-demand audit (networked) | `audit.sh` | Checks dependencies for vulnerabilities; never called by Hooks |

There are two distribution models. With a **plugin installation**, all files remain in the plugin. Codex uses `PLUGIN_ROOT` (Hooks also set the compatibility variable `CLAUDE_PLUGIN_ROOT`), while Claude Code uses `CLAUDE_PLUGIN_ROOT`. With an **`init.sh` installation**, `check.sh`, `check_file.sh`, `lib.sh`, `audit.sh`, `harness_config.py`, `feedback_log.py`, and all three language versions of this README are copied into the target project's `scripts/` directory. `hooks/` and `init.sh` itself are not copied: Hooks are plugin-only, and `init.sh` runs from the source repository.

## Shared design principles

1. **Output is designed for agents:** Show concise results per check and a final status. For a failure, show only a configured number of trailing log lines instead of the entire log.
2. **Permissive detection:** A stage whose tool is not installed becomes `SKIP`, not a failure. The harness does not impose a stack.
3. **Declarations determine strictness:** A check declared by the project in configuration becomes `FAIL` and blocks completion. A check inferred by the harness becomes `WARN`, which is reported but keeps exit code 0. Blocking undeclared checks would make existing projects unusable on the first day. WARNs are recorded in `events.jsonl` and appear under frequent WARNs in `stats` and `report`.
4. **Never install tools automatically:** Missing tools produce `SKIP` with a reason. The user decides whether to modify the environment.
5. **Stack-independent operation:** Detect the project type automatically from manifests such as `pyproject.toml` and `package.json`; no configuration is required.
6. **Keep state separate:** Scripts contain no embedded state. Everything is stored under `.feedback/`. Shared data such as `rules.md` and `log/` can be tracked by Git, while runtime state such as `events.jsonl`, `.last-check`, `.last-retro`, and `.last-audit` is ignored by Git and is not shared across machines.

---

## Script specifications

### `check.sh` — full check (pre-completion / CI)

```bash
bash scripts/check.sh [project-root]          # Defaults to the current directory
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # Skip selected stages
bash scripts/check.sh --list-checks           # List check IDs, effective decisions, and sources without running checks
bash scripts/check.sh --list-checks --json    # Print the same information as JSON
```

**Behavior:** Runs stages for every detected stack, runs stack-independent cross-cutting checks, and prints a `PASS`/`FAIL`/`WARN`/`SKIP` summary.

**Commands by stage** (a missing tool produces `SKIP` with a reason):

| Stage | Python | Node | Go | Rust | Java | Shell |
|---|---|---|---|---|---|---|
| `lint` | `ruff check` | `run lint` / `npm ls --all` | `go vet` / `go mod verify` | `clippy` / `cargo metadata --offline` | — | `bash -n` / `shellcheck` |
| `typecheck` | `mypy` (when declared) | `run typecheck` / `tsc --noEmit` | — | — | — | — |
| `test` | `pytest` (+`--cov`) | `test` or `test:coverage` | `go test -cover` | `cargo test` | `mvn verify` / `gradle check` | — |
| `build` | — | `run build` | `go build` | `cargo check` (when clippy is absent) | — | — |
| `format` | `ruff format` | `prettier` (when declared) | `gofmt -l` | `cargo fmt` | — | — |
| `contract` | — | — | — | `cargo semver-checks` (`[lib]`) | — | — |

**Cross-cutting checks** (stack-independent; part of the `security`, `docs`, `lint`, and `contract` stages): configuration syntax, internal links, secrets, CI configuration, Dockerfiles, and OpenAPI contract differences.

**What this script does not do:**

- **Use the network** — vulnerability auditing is isolated in `audit.sh`. `npx` always includes `--no-install`, and a missing tool produces `SKIP` without downloading anything
- **Install tools** — a missing tool produces `SKIP` with a reason
- **Run tests twice** — coverage comes from instrumenting the existing test command or replacing it with `test:coverage`
- **Block completion on an undeclared check** — such findings are `WARN` and keep exit code 0
- **Consult a remote** — the contract baseline is `git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`, falling back to `HEAD` when it cannot be resolved

- **Detected targets:** Python (`pyproject.toml` / `setup.py` / `requirements.txt`; when absent but `*.py` exists, only `ruff` runs) / Node (`package.json`) / Go (`go.mod`) / Rust (`Cargo.toml`) / Java (`pom.xml` / `build.gradle`) / Shell (`*.sh`) / generic (`check` target in a `Makefile`)
- **Cross-cutting checks (stack-independent):** Validate `*.json`, `*.yaml`, and `*.yml`. `tsconfig*.json`, `jsconfig*.json`, `devcontainer.json`, and files below `.vscode/` are excluded because comments (JSONC) are conventional there. YAML supports multiple documents separated by `---`, and unknown custom tags such as `!Ref` are not treated as syntax errors. If PyYAML is missing, YAML validation produces `SKIP` with a reason
- **Documentation consistency:** Detect broken internal Markdown links in the `docs` stage. External URLs, `mailto:`, fragment-only links, and absolute paths are excluded to preserve offline operation. Link-like text inside code blocks and inline code is not validated
- **Secrets (`security` stage):** Run `secretlint` when `.secretlintrc.*` exists. **Without configuration it produces SKIP**, because secretlint cannot run unconfigured. Values are masked by default and never appear in failure logs. Also run `gitleaks` when it is on PATH, but only versions that support `--no-git --redact`
- **CI configuration and Dockerfiles:** Run `actionlint` for `.github/workflows/*.y*ml`; run `dockerfilelint`, falling back to `hadolint`, for `Dockerfile*`. Missing tools produce SKIP
- **Dependency presence (offline):** Node uses `npm ls --all` only for npm projects and only when `node_modules` exists; Go uses `go mod verify`; Rust uses `cargo metadata --offline`; Python uses `deptry`. These checks detect nonexistent package names and mismatches between declarations and installed dependencies
- **API contracts and breaking changes (`contract` stage):** When `openapi.yaml` or `openapi.json` exists at the root or under `api/`, run `oasdiff breaking` against the Git-derived baseline (`git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`, falling back to `HEAD`). Rust crates with `[lib]` run `cargo semver-checks check-release --baseline-rev <git-derived-SHA>`. Neither operation consults remotes or registries
- **Coverage piggybacking:** Add instrumentation instead of running tests twice. Python adds `--cov --cov-report=term-missing` when pytest-cov is detected (a configured `--cov-fail-under` automatically becomes a FAIL gate); Go runs `go test -cover`; Node runs `test:coverage` **instead of** `test` when that script exists
- **Configuration:** Commit `.feedback/config.yaml` to configure stage skips, FAIL/WARN behavior, exclusions (`exclude`), log line limits, tool thresholds (shellcheck severity, vulture confidence, oasdiff baseline), audit intervals, and more. Precedence is **environment variable > individual check (`checks.<id>`) > stack (`check.<stack>`) > global (`check`) > default**. Environment variables such as `FEEDBACK_CHECK_SKIP` are temporary overrides. See `docs/configuration.md` in the source plugin for every setting; no link is used here because a distributed `scripts/` directory does not include `docs/`
- **`--list-checks`:** List the check ID, label, stage, effective decision, and **source** (the layer that determined it) without running the check commands. An applicable check whose tool is missing still appears as `skip` with a reason. The leftmost check ID can be used directly as a key under `checks:`. With `--json`, output is machine-readable. When config is invalid, the command prints the table using defaults, reports the error to stderr, and exits 1
- **Stage skipping:** `FEEDBACK_CHECK_SKIP` accepts `lint`, `typecheck`, `test`, `build`, `format`, `security`, `docs`, and `contract`, separated by spaces. This vocabulary matches `check.skip` in config
- **Make recursion guard:** Only when running `make check`, pass `FEEDBACK_CHECK_RECURSION_GUARD` to descendants so a nested check.sh skips the Make fallback. This prevents an infinite loop where `CLAUDE_PROJECT_DIR` propagates into tests, a nested check.sh resolves the root back to this repository, and Make reruns the tests until the Stop hook times out. **Normal Make commands and direct lint/test/build stages are unaffected**
- **SKIP reasons:** Output always includes a reason: `(<tool> not installed)`, `(<tool> cannot start — check the environment)`, `(not executable)`, `(env.FEEDBACK_CHECK_SKIP)` for environment-driven skipping, `(config: <key-path>)` for config-driven skipping, or a stack-level `(<stack>: all stages …)`. A missing or broken tool alone is **never a FAIL**, because it is not a problem in the user's code
- **Files checked:** In a Git repository, use `git ls-files --cached --others --exclude-standard`. This includes **new uncommitted files** and excludes ignored files
- **No network access:** The Node type-check fallback is `npx --no-install tsc`. If TypeScript is missing, it produces `SKIP` without trying to download it
- **shellcheck severity:** Defaults to `warning` (`-S warning`). Including `style` and `info` findings would block existing projects on the first day. Set `FEEDBACK_SHELLCHECK_SEVERITY=style` for stricter checking
- **Failure output:** Collect the final 40 log lines from every failed stage in `failures.txt`, then print them together at the end
- **Final line** (except on FAIL; all of these exit 0):

  | Final line | Meaning |
  |---|---|
  | `ALL PASS` | Every stage succeeded |
  | `ALL PASS (N件WARN — 未対応の指摘があります)` | Success with non-blocking findings; review the WARNs |
  | `ALL PASS (N件WARN・M件SKIP — 未検証/未対応の項目があります)` | Success with both unresolved findings and unverified checks |
  | `ALL PASS (N件SKIP — 未検証の項目があります)` | Success with unverified checks |
  | `実行できたステージがありません(すべてSKIP)` | Nothing could be verified |
  | `検出できたスタックがありません …` | No supported manifest or target file was found |

  Never present an all-SKIP or partial-SKIP run as an unqualified `ALL PASS`.
- **WARN:** A non-blocking finding with exit code 0. Its count appears in the final line, for example `ALL PASS (1件WARN — 未対応の指摘があります)`. WARNs come from checks without a project declaration: `python: ruff format` (FAIL when `[tool.ruff` exists), `python: deptry` and `python: vulture` (FAIL when `[tool.deptry` or `[tool.vulture` exists), and `rust: cargo fmt` (FAIL when `rustfmt.toml` exists)
- **Exit codes:** `0` = no FAIL (including all-SKIP and no detected stack) / `1` = at least one FAIL / `2` = invalid root directory. **Agents must decide from the exit code, not from the final-line text**

### `check_file.sh` — fast single-file check (immediately after editing)

```bash
bash scripts/check_file.sh <file-path>
```

**Behavior:** Runs only static checks that do not require a full build, selected by file extension. It applies per-check decisions from `.feedback/config.yaml`: `skip` does not run, `warn` prints the finding and exits 0, and `fail` exits 1. Invalid configuration is also reported and exits 1.

| Extension | Checks |
|---|---|
| `.py` | `ruff check`, falling back to `python3 -m py_compile` |
| `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs` | `eslint` when configured; otherwise `.js`/`.mjs`/`.cjs` use `node --check` |
| `.go` | `gofmt -l` (detects unformatted files) |
| `.rs` | `rustfmt --check` |
| `.sh` | `bash -n`, plus `shellcheck` when available |
| `.json`/`.yaml`/`.yml` | Parse validation with `python3` |

- **Exit codes:** `0` = no issue, WARN only, no file argument, or target file does not exist / `1` = FAIL or invalid config (details are printed)

### `feedback_log.py` — feedback recording CLI

```bash
python3 scripts/feedback_log.py <subcommand> [arguments]
```

Entries are stored as Markdown with frontmatter under `.feedback/log/`; generalized rules are promoted into `.feedback/rules.md`. **Never create or edit log files directly; always use this CLI**, because inconsistent frontmatter breaks `list` and `promote`.

| Subcommand | Arguments | Description |
|---|---|---|
| `add` | `--category <cat>` `--summary "<summary>"` `[--detail "<detail>"]` `[--source human\|hook\|agent]` `[--signal <context\|instruction\|workflow\|failure>]` | Records an entry. Notifies you when three or more entries are open and candidates for promotion. `--signal` identifies what happened and is inferred from detail/category when omitted. A `根因:` line must contain exactly one of the five defined classifications |
| `list` | `[--status open\|promoted\|closed\|retired\|all]` `[--category <cat>]` `[--signal <context\|instruction\|workflow\|failure\|unknown>]` | Lists entries (default: `open`). `--signal unknown` selects legacy entries without a signal |
| `search` | `<keyword>` | Full-text search over entries |
| `promote` | `<entry-id>` `--rule "<one generalized rule>"` | **Adds a new rule** to `rules.md` and marks the entry `promoted` |
| `merge` | `<entry-id>` `--into <existing-rule-source-id>` `[--rule "<updated-text>"]` | Adds provenance to an **existing rule** without creating a new line, then marks the entry `promoted`. Use for recurrence of the same principle |
| `close` | `<entry-id>` `[--reason "<reason>"]` | Marks an entry `closed` without promotion. Use for one-off feedback that cannot be generalized |
| `retire` | `<source-entry-id>` `--reason "<retirement-reason>"` | **Removes a promoted rule** from rules.md and marks its source entries, including merged ones, as `retired`. Use after a human decision during rule review |
| `rules` | (none) | Prints the current `rules.md` |
| `stats` | `[--since <date>]` `[--days <N>]` | Aggregates Hook results and logs: PostToolUse first-pass rate, average recheck count, Stop first-pass rate, top failures, counts by signal/root cause, and **recurrence candidates** (a new failure in the same category after promotion — these are **material to investigate, not a verdict**: whether it is the same principle recurring is decided by an agent reading the entries. The number beside each candidate is surface character overlap, a reading-order hint only). Frequent WARNs and top failures carry a **last-seen date**, and an item that has not recurred for `feedback.stale_days` (default 7) is annotated as such. Transient files such as scratchpads are excluded |
| `report` | `--since <date\|yesterday>` or `--last`, `[--mark]` | Period digest (new entries, promote/close/retire activity, open review, recurrence candidates, and numbers). `--last` starts at `.feedback/.last-retro`; `--mark` advances that marker after the review |

- **category:** `style` / `architecture` / `testing` / `naming` / `workflow` / `domain`
- **entry-id:** Recording time in `%Y%m%d-%H%M%S` format. Multiple entries in the same second receive `-2`, `-3`, and so on to remain unique; duplicates would otherwise make `promote` capture only the first entry and leave the rest impossible to promote

### `audit.sh` — on-demand vulnerability audit (explicit invocation only)

```bash
bash scripts/audit.sh [project-root]
```

Unlike `check.sh`, this script **uses the network** through pip-audit, `npm audit --audit-level=high`, govulncheck, or cargo audit. Node auditing runs only when the package-manager check (`harness_node_pm` in `lib.sh`, shared with `check.sh`) returns npm and `package-lock.json` exists, because npm audit cannot read another package manager's lockfile and fails with ENOLOCK. When `pnpm-lock.yaml` or `yarn.lock` is present, the script reports SKIP and suggests running `pnpm audit` or `yarn npm audit` directly. A leftover `package-lock.json` alongside them still counts as non-npm: auditing an npm tree while tests run under pnpm would audit a different dependency graph than the one actually resolved. Stop hooks never call it; it runs only after an explicit request, including through the `feedback-loop` skill. On success it writes the date to `.feedback/.last-audit`, and `stats` / `report` shows the last audit date. **When the audit is more than seven days old or has never run, a recommendation appears**, following the same non-blocking, visible-when-needed philosophy as WARNs. A failed audit does not update the marker, so the recommendation remains while vulnerabilities are unresolved.

### `hooks/` — Claude Code / Codex Hook wrappers

Thin wrappers started by Claude Code and Codex Hooks. They delegate decisions and execution to `check_file.sh` or `check.sh` and handle only Hook-specific concerns: parsing stdin JSON, returning failures to the agent with exit code 2, and preventing infinite loops. **They are not copied by `init.sh`**, because they run from the plugin.

- **`on_session_start.sh` (SessionStart):** Seeds `.feedback/log/` and `rules.md` from the template on first use. Plugin-only target projects never run `init.sh`, so the Hook performs initialization. It **never touches an existing `.feedback/` directory** and does not block the session if initialization fails.
- **`post_edit.sh` (PostToolUse: `Edit|Write|MultiEdit`):** For Claude Code, reads `tool_input.file_path` from stdin. For Codex `apply_patch`, extracts target files from patch headers in `tool_input.command`, then runs `check_file.sh`. A problem returns **exit 2 plus stderr** to the agent and starts the self-correction loop. If no target file can be identified, it records nothing.
  - Appends one result line, successful or failed, to `.feedback/events.jsonl`, which supplies first-pass-rate data to `stats`. This is local state and is not shared.
- **`on_stop.sh` (Stop):** Runs `check.sh` before response completion. A failure returns **exit 2**, blocks completion, and sends the failure details back. When `stop_hook_active` is `true` on the second or later pass, it exits 0 without doing anything, preventing an **infinite loop**.
  - **Run condition:** Run only when the worktree changed after the previous successful check marker (`.feedback/.last-check` mtime). Running unconditionally would trigger a full build such as `mvn verify` or `npm run build` after question-only turns with no edits. The mtime check catches Bash edits as well as Edit/Write, and uncertainty always falls back to running the check.
  - Advance the marker **only after a successful check**. Marking a failure would make the next turn appear unchanged and allow completion with broken code.
  - The second pass does not rerun `check.sh` because successful exit output is not returned to the agent, and expensive targets would impose delay with no benefit.
  - Append a result to `events.jsonl` only when `check.sh` actually runs; skipped runs are not recorded.

---

## Usage: plugin versus manual fallback

The scripts are identical, but **who starts them** depends on whether the environment supports plugins.

### Claude Code / Codex app and CLI — Hook-driven (automatic)

Claude Code and the Codex app / CLI use the Hooks supplied by the plugin (`hooks/hooks.json`) as their driver, so **the agent does not need to invoke scripts explicitly**. In Codex, review and trust them through `/hooks` the first time.

| Timing | Hook | Execution chain | Effect |
|---|---|---|---|
| Immediately after editing | `PostToolUse` (`Edit\|Write\|MultiEdit`) | `post_edit.sh` → `check_file.sh` | Detects Claude Edit/Write and Codex `apply_patch`. A problem returns exit 2 immediately, triggering automatic correction |
| Before response completion | `Stop` | `on_stop.sh` → `check.sh` | A FAIL blocks completion and correction continues; the check itself is skipped when nothing changed after the previous successful run |

- **Apply rules:** The `apply-feedback` skill reads `.feedback/rules.md`. When `init.sh` is also in use, CLAUDE.md / AGENTS.md describes the manual fallback for disabled Hooks.
- **Record feedback:** The `capture-feedback` and `feedback-loop` skills call `feedback_log.py`.
- See “Using Skills, Agents, and Commands (plugin installations)” in the project-root README.md for Skill and Agent triggers. That section is not distributed by `init.sh`; the rules-driven workflow below replaces it.
- **Configuration:** The plugin uses `hooks/hooks.json` plus `skills/`. Claude Code reads `.claude-plugin/plugin.json`; Codex reads `.codex-plugin/plugin.json`. Rules in CLAUDE.md / AGENTS.md are added only when `init.sh` is also used.

### Claude Code init-only / Codex IDE extension / general-purpose agent — rule-driven (manual)

In an `init.sh`-only installation or when Hooks are disabled or untrusted, Claude Code uses CLAUDE.md, while the Codex IDE extension and general-purpose agents use AGENTS.md as the fallback loop. The agent follows the rules and invokes scripts itself; this is not automatic.

| Timing | Command | Basis |
|---|---|---|
| Session start | `python3 scripts/feedback_log.py rules` | Apply rules to the task (§1) |
| After every code change | `bash scripts/check_file.sh <edited-file>` | Immediate check and correction (§2) |
| Before completion | `bash scripts/check.sh` | Confirm `ALL PASS` before completion; never report completion while FAIL remains (§3) |
| After feedback | `python3 scripts/feedback_log.py add --category … --summary … --source human` | Record immediately—the only persistence mechanism (§4) |
| Retrospective / stand-up | `python3 scripts/feedback_log.py report --last --mark` | Discuss the period digest, then advance its marker |
| When prompted to audit | `bash scripts/audit.sh` | Run when `stats` or `report` recommends an audit after seven days or when none has run |

- **Apply rules:** CLAUDE.md / AGENTS.md §1 requires reading `.feedback/rules.md`.
- **Configuration:** CLAUDE.md or AGENTS.md; Hooks are unnecessary.

### Comparison

| Concern | Plugin (Claude Code / Codex) | `init.sh` (Claude Code / Codex IDE extension / general-purpose agent) |
|---|---|---|
| Driver | Hooks (automatic) | CLAUDE.md / AGENTS.md rules (agent-driven) |
| Check after editing | Automatic through `PostToolUse` | Run `check_file.sh` manually each time |
| Pre-completion check | Automatic through `Stop`, with blocking | Run `check.sh` manually before completion |
| Apply rules | `apply-feedback` skill | CLAUDE.md / AGENTS.md §1 |
| Record feedback | `capture-feedback` / `feedback-loop` skills | Manual CLAUDE.md / AGENTS.md §4 procedure |
| Main configuration / instruction files | `hooks/hooks.json`, `.claude-plugin/plugin.json` / `.codex-plugin/plugin.json` | CLAUDE.md / AGENTS.md |
| Shared scripts | `scripts/*`, `.feedback/` | Same |

---

## Required tools

- **Required:** `bash`, `python3` (used for Hook JSON parsing, `feedback_log.py`, JSON/YAML validation, and internal-link validation)
- **Optional — stack standards** (detected automatically; missing tools produce `SKIP`): `ruff`, `mypy`, `pytest` / `npm`/`pnpm`/`yarn`, `eslint`, `tsc` / `go`, `gofmt` / `cargo`, `rustfmt`, `clippy` / `mvn`, `gradle` / `shellcheck`
- **Optional — extended checks:** `pytest-cov` (coverage) / `deptry`, `vulture`, `import-linter` (Python dependencies, dead code, architecture constraints) / `secretlint`, `dockerfilelint`, `knip`, `prettier` (through npm; this repository's `package.json` is an example) / `gitleaks`, `actionlint`, `hadolint`, `oasdiff`, `cargo-semver-checks` (used when OS-specific binaries are already on PATH)
- **Optional — audit only** (`audit.sh`, networked): `pip-audit` / `npm` / `govulncheck` / `cargo-audit`

The harness never installs any of them. It uses `npx --no-install` so missing packages are not downloaded from the network without permission.

## Install in another project

> This section describes operations in the **source harness repository**. Because `scripts/init.sh` itself and `docs/` are not copied into target projects, rerun installation or update from the source repository.

`scripts/init.sh` copies `scripts/`, including all three versions of this file, into the target project. `scripts/README.md`, `scripts/README.ja.md`, and `scripts/README.zh-CN.md` remain available there.

Only the **harness mechanism** is transferred; source-repository-specific content is not:

- `.feedback/rules.md` is seeded from `.feedback/rules.template.md`, which contains headers only. Promoted rules and source IDs from the source repository do not leak into the target
- CLAUDE.md / AGENTS.md receives fragments from `docs/pointer_claude.md` / `docs/pointer_agents.md`. On rerun, only content inside `feedback-harness:pointer` management markers is replaced; user text outside the markers is preserved. A legacy pointer created before management markers is migrated only when its known heading and end can be identified safely

```bash
bash scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # Verify stack detection
```
