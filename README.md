English | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# feedback-harness

A feedback harness for both Claude Code and Codex. It provides two mechanisms:

1. **Automated feedback loop** — returns lint, type-check, test, and build results to the agent automatically so it can fix problems itself
2. **Accumulated human feedback** — records review comments and successful working patterns, consolidates them into shared rules, and applies them to future work

## Requirements

- **Required:** `bash`, Python 3.10+ (`python3` or `python`)
- **Optional:** the linting, type-checking, testing, building, and other tools used by your project

Optional tools are used only when they are already installed. Missing tools are reported as `SKIP` with a reason; the harness never installs them automatically.

On Windows, use **Git Bash** bundled with Git for Windows. The existing `*.sh` files run unchanged from Git Bash, and the harness selects `python` automatically when `python3` is unavailable. Normal operation does not require PowerShell scripts.

### Developing this repository

This repository pins its own check dependencies separately from the harness runtime. Run `make install-dev-tools` to install PyYAML and Ruff from `requirements-dev.txt` and the actionlint version declared in `scripts/dev_tool_versions.sh` into the repository-local `.venv`. Before calling `scripts/check.sh` directly, run `source .venv/bin/activate` on Linux/macOS or `source .venv/Scripts/activate` in Windows Git Bash. `make test` already prefers that local tool directory. Linux CI verifies the pinned check tools; Windows CI runs the same regression suite with Git Bash and Windows Python. This does not make the harness install tools in target projects.

## How it works

| Environment | Automated checks | Applying rules |
|------|-------------|-----------|
| Claude Code (plugin installed) | The plugin's `hooks/hooks.json` provides Hooks. It runs `check_file.sh` immediately after a file is edited and `check.sh` before the response ends (`check.sh` runs only when something has changed since the last successful check). On failure, exit code 2 returns the result to the agent. It also checks configuration syntax (JSON/YAML), secrets, internal links, dependencies, and CI configuration. Findings from checks that the project has not explicitly configured are recorded in `events.jsonl` as WARNs (non-blocking warnings). Missing tools produce SKIP; the harness never installs them automatically. | The `apply-feedback` skill reads `.feedback/rules.md` and unprocessed feedback. |
| Claude Code (`init.sh` only) | Following the rules in CLAUDE.md, the agent runs `check_file.sh` after every change and `check.sh` before completion. | CLAUDE.md requires the agent to read `.feedback/rules.md` and unprocessed feedback before starting work. |
| Codex (plugin installed) | Codex loads the same `hooks/hooks.json` as Codex Hooks. It identifies files from `apply_patch` patches and checks them immediately, then runs a full check before Stop. | The `apply-feedback` skill reads `.feedback/rules.md` and unprocessed feedback. |
| Codex IDE extension or a general-purpose agent (installed with `scripts/init.sh`) | Following the rules in AGENTS.md, the agent runs `check_file.sh` after every change and `check.sh` before completion. | AGENTS.md requires the agent to read `.feedback/rules.md` before starting work. |

In every environment, feedback is stored in each project's `.feedback/` directory. In Claude Code, Codex in the ChatGPT desktop app, and Codex CLI, plugin Hooks run checks automatically. With an `init.sh`-only installation, the agent runs checks itself by following CLAUDE.md in Claude Code or AGENTS.md in the Codex IDE extension and other general-purpose agents. In Codex, open `/hooks` the first time, review the contents, and enable them as trusted. This repository's `.claude/settings.json` is development configuration for working on the harness in Claude Code and is not distributed to target projects.

## Features

Checks **detect the project's technology stack automatically**. No advance configuration is required. If a required tool is missing, the check reports `SKIP` with a reason and never installs the tool automatically.

| Stage | What it checks | Tools / targets |
|---|---|---|
| `lint` | Static analysis | ruff / eslint / go vet / clippy / shellcheck and bash -n |
| `typecheck` | Type checking | mypy (when `[tool.mypy]` is declared) / tsc |
| `test` | Tests (**adds coverage measurement** to the existing test run) | pytest (`--cov`) / go test `-cover` / npm `test:coverage` / cargo test / `./mvnw` or `mvn verify` |
| `build` | Build | go build / npm run build / cargo check |
| `format` | Formatting drift | ruff format / prettier / gofmt / cargo fmt |
| `security` | Committed secrets | secretlint (when `.secretlintrc.*` is declared) / gitleaks |
| `docs` | Broken internal Markdown links | built-in implementation (requires only Python) |
| `contract` | Breaking API changes | oasdiff (OpenAPI) / cargo semver-checks (`[lib]` crate) |
| — | Configuration syntax | `*.json` / `*.yaml` (avoids false positives for JSONC and multi-document YAML) |
| — | Dependency presence and consistency | npm ls / go mod verify / cargo metadata / deptry |
| — | CI configuration and Dockerfiles | actionlint / dockerfilelint or hadolint |
| — | Unused code and architecture constraints | vulture / knip / import-linter (only when declared) |

The feedback accumulation features are:

| Feature | Command | Purpose |
|---|---|---|
| Record feedback | `feedback.sh add` | Records human feedback or a successful working pattern immediately, including its signal |
| Turn feedback into rules | `promote` / `merge` / `close` / `retire` | Adds or merges rules in `rules.md`, closes processed feedback, or retires obsolete rules |
| Measure | `stats` | Reports local-only first-pass rate, average recheck count, frequent WARNs, and **recurrence candidates** |
| Report | `report` | Produces a local-only period summary for stand-ups and retrospectives, including comparison with the preceding period |
| Vulnerability audit | `audit.sh` | Runs only when requested (the harness's dedicated networked operation) |

Curator automation proposals use `automation_candidates` (`candidate`, `evidence`, `recommended_check`, `human_decision`). Document proposals use `document_candidates` (`target_path`, `section`, `proposed_text`, `reason`, `read_path`, `evidence`, `human_decision`). The curator reads the target project's instruction files and their references, then chooses a destination by its role. Projects with only AGENTS.md or only CLAUDE.md remain supported; an unresolved destination uses `target_path: null`. Both proposal types remain pending until human approval.

## What it does and does not do

The harness deliberately leaves some things undone. These are design decisions, not missing features.

| What it does | What it does not do (and why) |
|---|---|
| Returns failed checks to the agent automatically so it can fix problems itself | **Does not force completion** — WARNs (findings from checks not explicitly configured by the project) keep exit code 0; only FAIL blocks completion |
| Uses tools that are available and reports missing ones as SKIP with a reason | **Does not install tools automatically.** The user decides whether to change the environment |
| Runs checks without adding dependency downloads or remote lookups of its own | **`check.sh` itself does not intentionally initiate network access.** Project-defined commands and tools may still use the network according to their configuration. The dedicated vulnerability audit is isolated in `audit.sh` and is never called by the Stop hook |
| Measures coverage | **Does not run tests twice.** It only adds coverage instrumentation to the existing test command (or switches to `test:coverage`) |
| Detects breaking changes against a Git baseline | **Does not consult a remote.** The baseline is `git merge-base HEAD <default-branch>`, falling back to `HEAD` when it cannot be resolved |
| Uses the `apply-feedback` skill to read recorded feedback and apply it to the next task | **Does not modify shared files without permission.** Changes outside `rules.md` (such as additions to shared instructions or reference documents or a new linter) are proposed and applied only after human approval |
| Produces numbers with `stats` and `report` | **Does not build a dashboard.** There are no persistent background processes, charts, or external data transmission; output is text produced on request |
| Detects secrets | **Does not print the values themselves.** secretlint masks by default, and gitleaks must use `--redact`, because failure logs are sent to the agent |

## Repository layout

```text
.claude-plugin/
  plugin.json       # Claude Code plugin definition
  marketplace.json  # Claude Code marketplace and Codex-compatible catalog
.codex-plugin/
  plugin.json       # Codex plugin definition
skills/             # feedback-loop (orchestrator) / capture-feedback / apply-feedback
agents/             # feedback-curator (rule curation) / harness-qa (consistency validation)
commands/
  init.md           # /feedback-harness:init — deploy assets for environments without Hooks
hooks/
  hooks.json        # Shared Claude Code / Codex Hooks definition for distribution
scripts/
  check.sh          # Detects stacks (Python/Node/Go/Rust/Java/Shell/Make) → 8 stages + cross-cutting checks
  checks/*.sh       # Stack and cross-cutting runners; check.sh keeps the shared execution core
  check_file.sh     # Fast single-file checks based on file extension
  audit.sh          # On-demand vulnerability audit (dedicated networked check; excluded from Stop hooks)
  lib.sh            # Shared utilities (has / harness_project_root / harness_tree_changed /
                    #   harness_node_pm / harness_validate_json|yaml / harness_check_md_links /
                    #   harness_log_event|warn)
  harness_config.py # Loads .feedback/config.yaml and resolves check settings
  feedback_store.py # Repository lock, atomic writes, and interrupted-transaction recovery
  feedback.sh       # Cross-platform Feedback CLI entry point (resolves Python executable)
  feedback_log.py   # Feedback CLI implementation (add / list / search / promote / merge / close /
                    #   retire / rules / stats / report)
  init.sh           # Installer (deploys assets for environments without Hooks)
  README.md         # Detailed script specifications and tool requirements
  README.ja.md      # Japanese version of the script documentation
  README.zh-CN.md   # Simplified Chinese version of the script documentation
  hooks/            # Claude Code / Codex Hooks wrappers (SessionStart / PostToolUse / Stop)
.feedback/
  rules.md          # Generalized permanent rules (required reading; failure/success sections)
  rules.template.md # Template used to initialize or regenerate rules.md
  config.yaml       # Optional project configuration (commit to share; start from config.example.yaml)
  config.example.yaml # Fully commented configuration template
  local/config.yaml # Machine-local personal settings that override the shared file (not tracked)
  log/              # Recorded feedback as Markdown with metadata frontmatter
  .last-check       # Local Stop-hook check marker based on modification time (not tracked by Git)
  .last-retro       # Start of the retrospective reporting period (updated by report --mark; not tracked)
  .last-audit       # Date of the last successful vulnerability audit (not tracked)
  .state.lock       # Persistent repository-wide lock for feedback CLI mutations (not tracked)
  .transaction.json # Recovery journal present only after an interrupted mutation (not tracked)
  events.jsonl      # Hook results and WARN log for stats/report (local state; not tracked)
package.json        # Declares check tools such as secretlint solely for npx --no-install resolution
tests/              # Bash tests (make check is detected and run automatically by check.sh)
docs/
  README.md         # Documentation index (current specification and historical material)
  README.ja.md      # Japanese version of the documentation index
  README.zh-CN.md   # Simplified Chinese version of the documentation index
  configuration.md  # Configuration guide (every config.yaml setting and troubleshooting)
  configuration.ja.md    # Japanese version of the configuration guide
  configuration.zh-CN.md # Simplified Chinese version of the configuration guide
  pointer_claude.md # Guidance inserted into target CLAUDE.md files
  pointer_agents.md # Guidance inserted into target AGENTS.md files
  development-guide.md # Development rationale and migration map (Japanese)
  history/          # Development history (historical material, Japanese)
  proposals/        # Pre-implementation proposals (historical material)
  references/       # External sources consulted during design (historical material)
  superpowers/      # Design specifications (specs/) and implementation plans (plans/) — historical
review/             # Dated code-review records (historical material)
.claude/
  settings.json     # Development configuration that enables the plugin in this repository (not distributed)
```

The harness itself is also checked by `check.sh` (which detects its `*.sh` and `*.py` files).

### Documentation authority

For current usage, see this README, the [configuration guide](docs/configuration.md), and the [script reference](scripts/README.md). Dated files under `docs/proposals/`, `docs/superpowers/`, and `review/` preserve decisions made when proposals, designs, and reviews were written. If they differ from the current specification, prefer the three documents listed above and the implementation. See the [documentation index](docs/README.md) for the full list.

For current Codex behavior, see OpenAI's official [plugin usage guide](https://learn.chatgpt.com/docs/plugins), [plugin package specification](https://developers.openai.com/plugins/build/plugins), and [Hooks specification](https://developers.openai.com/codex/hooks). For Claude Code, see Anthropic's official [plugin installation guide](https://code.claude.com/docs/en/discover-plugins).

## Install in another project

### Claude Code only

```text
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

Only `.feedback/`, which stores accumulated data, is created in the target project. Scripts, skills, agents, and Hooks remain in the plugin. Automatic updates are disabled by default for marketplaces outside Anthropic's official marketplace. The plugin updates at startup only when the user enables automatic updates.

To distribute the plugin to an entire team, add the following to the target project's `.claude/settings.json`. Users are prompted to install the plugin after they trust the folder.

```json
{
  "extraKnownMarketplaces": {
    "feedback-harness": {
      "source": { "source": "github", "repo": "JustinWangJP/feedback-harness" },
      "autoUpdate": true
    }
  }
}
```

### Codex in the ChatGPT desktop app or Codex CLI

```bash
codex plugin marketplace add JustinWangJP/feedback-harness
```

After registering the marketplace, install the plugin in either of these ways:

- In the ChatGPT desktop app, open Plugins and install `feedback-harness`
- In Codex CLI, open `/plugins`, then install and enable `feedback-harness`

Start a new session after installation. In Codex, open `/hooks`, review the `SessionStart`, `PostToolUse`, and `Stop` hooks, and enable them as trusted. The Codex IDE extension does not support plugins, so use `init.sh` as described next.

### Manual operation with `init.sh` (Claude Code / Codex IDE extension / general-purpose agents)

When combining `init.sh` with the Claude Code plugin:

```text
/feedback-harness:init
```

Without the plugin, or when installing from outside Claude Code:

```bash
git clone https://github.com/JustinWangJP/feedback-harness
bash feedback-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # Verify stack detection
```

The installer copies the scripts into the target project's `scripts/` directory. It does not copy CLAUDE.md or AGENTS.md; instead it adds guidance to those files inside management markers that identify the section maintained by feedback-harness, creating the files if they do not exist. Running `init.sh` again replaces only the contents inside those markers and preserves user-authored text outside them. `.feedback/rules.md` starts from an empty template.

### Assets by installation method

| Asset | Plugin | `init.sh` |
|---|---|---|
| `scripts/check.sh` `checks/*.sh` `check_file.sh` `feedback.sh` `audit.sh` `lib.sh` `harness_config.py` `feedback_store.py` `feedback_log.py` `README.md` `README.ja.md` `README.zh-CN.md` | Stored in the plugin. Codex runs them through `PLUGIN_ROOT` (Hooks also set the compatibility variable `CLAUDE_PLUGIN_ROOT`); Claude Code uses `CLAUDE_PLUGIN_ROOT` | Copied into the target project's `scripts/` directory |
| Hooks (`hooks.json`) | Yes (runs automatically after enablement) | No (CLAUDE.md / AGENTS.md rules are the fallback) |
| skills | Yes (Claude Code / Codex) | No (CLAUDE.md / AGENTS.md rules are the fallback) |
| agents / commands | Claude Code only | No |
| `scripts/hooks/*` and `init.sh` itself | Yes | No |
| `.feedback/` (accumulated data) | Created by the SessionStart hook on first use | Created by `init.sh` on first use |
| Guidance in `CLAUDE.md` / `AGENTS.md` | No (combine with `init.sh` when needed) | Both files (reruns replace only managed sections and preserve content outside the markers) |

### Updating

| Installation | How to update |
|---------|---------|
| Claude Code plugin | Automatic updates are disabled by default for third-party marketplaces. Choose `Enable auto-update` under `/plugin` → `Marketplaces`, or run `/plugin marketplace update feedback-harness` and `/plugin update feedback-harness@feedback-harness` |
| Codex plugin | Run `codex plugin marketplace upgrade feedback-harness`, check the plugin in `/plugins`, and start a new session after updating |
| `scripts/` copied by `init.sh` | Update the source feedback-harness repository, then rerun its `init.sh`. It replaces scripts and the managed sections of CLAUDE.md / AGENTS.md while preserving user content outside the markers |

## Using Skills, Agents, and Commands (plugin installations)

Marketplace installations provide **three Skills** in both Claude Code and Codex. **Two Agents and one Command are available only in Claude Code.** In Codex, the `feedback-loop` skill uses Codex's subagent capability. `init.sh` installations do not include these components; the rules added to CLAUDE.md / AGENTS.md and the copied scripts provide the same workflow.

### How each component is invoked

| Type | How it starts | Who starts it |
|---|---|---|
| **Skill** | Starts **automatically** based on the request. To invoke one explicitly, name it in your request (for example, “Apply the rules with the apply-feedback skill.”) | Claude / Codex |
| **Agent** | The `feedback-loop` skill starts it through the environment's subagent capability (also using the distributed Agent definitions in Claude Code) | The skill (**you do not need to call it directly**) |
| **Command** | Enter `/feedback-harness:init` | The user |

**With a plugin installation, you normally do not need to do anything special.** Each Skill starts automatically when the request matches. Because `init.sh` does not copy Skills, its workflow instead follows the rules added to CLAUDE.md / AGENTS.md and runs the corresponding scripts directly. The following sections show how to invoke plugin Skills explicitly.

### Skill 1: `apply-feedback` — apply previous feedback before work

**When it starts:** Before implementation, editing, review, or design. It also starts when you ask to “apply previous feedback,” “use the earlier feedback,” or “follow the rules,” and for requests to redo or correct work.

**What it does:**

1. Reads `.feedback/rules.md` (two sections: **failure-derived** constraints and **success-derived** patterns to repeat)
2. Uses `list --status open` to read open entries that have not yet become rules, so they are not ignored while awaiting promotion
3. Finds rules in categories relevant to the current task and incorporates them before implementation
4. If a rule conflicts with the current request, follows the **current request** and tells you about the conflict so the rule can be reconsidered

```text
You: Refactor the authentication code.
  → apply-feedback starts automatically and reads rules.md before work begins.
```

### Skill 2: `capture-feedback` — record corrections and successful patterns

**When it starts:** Whenever you correct or comment on an artifact, say “do it this way” or “do this next time,” or revise a direction. It also applies when you want to preserve a successful working pattern.

**What it does:**

1. Summarizes the feedback in one sentence
2. For feedback about a failure, classifies the root cause on one line (`文脈欠落` / `指示欠陥` / `実行誤り` / `モデル限界` / `未判定`)
3. Determines the signal (what happened). A correction to incorrect output or behavior is always `failure`, regardless of root cause; when omitted, the CLI infers it
4. Selects a category and records the entry with `feedback.sh add`
5. When three or more entries are open, suggests consolidating them through `feedback-loop`

```text
You: Write error messages in Japanese. Do that from now on.
  → capture-feedback starts automatically and records the correction with its root cause.
```

Root causes use these criteria:

| Root cause | Criterion |
|---|---|
| `文脈欠落` (missing context) | Facts, rules, or version information needed for the decision were absent from the loaded context. This does not include overlooking available information |
| `指示欠陥` (instruction defect) | Expected results, constraints, acceptance criteria, or procedure were missing, ambiguous, or contradictory, so ordinary quality standards could not determine a unique answer. A normal bug does not qualify merely because no specific prohibition existed |
| `実行誤り` (execution error) | The necessary context and sufficiently clear instructions existed, but the agent overlooked them, violated them, reasoned incorrectly, or implemented incorrectly. Consider this first for isolated failures |
| `モデル限界` (model limitation) | The same failure cannot be avoided reliably even with sufficient context, clear instructions, available tools, and reasonable retries. Do not choose this for a single oversight |
| `未判定` (undetermined) | Evidence is insufficient or multiple causes cannot be separated. Wait for more information instead of forcing a classification |

Record exactly one `根因:` line. The CLI rejects undefined classifications and asks you to choose from these five values.

### Skill 3: `feedback-loop` — route the overall workflow

**When it starts:** For requests such as “organize the feedback,” “turn it into rules,” “inspect the harness,” “install it in project X,” “review the rules,” “how is it doing?”, or “audit it.”

It selects a **Phase automatically** from the request.

| Example request | Phase | Action |
|---|---|---|
| “Organize the feedback” / “Turn it into rules” | 1 | Starts the **feedback-curator agent**, which decides between promote, merge, and close |
| “Inspect the harness” / “Validate it” | 2 | Starts the **harness-qa agent** and writes a consistency report under `_workspace/` |
| “Install this harness in project X” | 3 | Runs `init.sh`, then runs `check.sh` once in the target project |
| “Review the rules” / “Periodic review” | 4 | Uses `stats` to classify each rule as keep, strengthen wording, or retirement candidate |
| “How is it doing?” / “What is the first-pass rate?” / “Topics for the retrospective” | — | Runs `stats` or `report --last` (then `--mark` after the retrospective to advance the reporting period) |
| “Audit it” / “Check for vulnerabilities” | — | Runs `audit.sh` (uses the network, so Hooks never run it automatically) |

```text
You: Organize the accumulated feedback and turn it into rules.
  → feedback-loop selects Phase 1 and starts feedback-curator.
  → It presents the rule changes and the rules.md diff for your decision.
```

### Agents (started through Skills)

You do not need to invoke these agents directly, but understanding their roles makes their results easier to interpret. In Codex, same-named Markdown files are read as working rules and passed to Codex subagents.

| Agent | Started by | Role | Output |
|---|---|---|---|
| `feedback-curator` | `feedback-loop` Phase 1 (Phase 4 uses its decision framework without starting it) | Consolidates feedback into shared rules. It routes by signal and further routes failure feedback by root cause | Result and rationale for `promote`, `merge`, or `close`. Changes outside `rules.md` (such as additions to shared instructions or reference documents or a new linter) are **proposals only** |
| `harness-qa` | `feedback-loop` Phase 2 | Checks script behavior, Hook configuration, and consistency among CLAUDE.md, AGENTS.md, and rules.md | A PASS/FAIL/SKIP report at `_workspace/qa_report_{date}.md` |

Neither agent **modifies shared files automatically**. Changes outside `rules.md` are proposed, and you decide whether to apply them.

### Command: `/feedback-harness:init`

When using Codex or another general-purpose agent **alongside** Claude Code, this command copies `scripts/` into the current project and adds guidance to CLAUDE.md / AGENTS.md inside management markers. It is unnecessary when you use Claude Code alone because the scripts remain in the plugin.

```text
/feedback-harness:init
```

### Verify the installation

```text
/plugin                      # Claude Code: check that feedback-harness is enabled
/plugins                     # Codex: check that feedback-harness is installed and enabled
/hooks                       # Codex: check that all three Hooks are trusted
```

You can confirm that a Skill is active from the Skill indicator shown in the response. To confirm that Hooks are running, edit one file and check that `.feedback/events.jsonl` gains a new line.

## Usage

### Daily development (Claude Code / Codex plugin)

Checks run automatically, so you normally **do not need to run anything manually**. Editing a file triggers `check_file.sh`; before a response ends, `check.sh` runs. When a check fails, its result is returned to the agent automatically.

Use the following commands when working in this repository or when manually operating a project into which `init.sh` copied `scripts/`. A plugin-only target does not contain a copied `scripts/` directory and normally relies on Hooks.

```bash
bash scripts/check.sh                    # Full pre-completion check (also used in CI)
bash scripts/check.sh /path/to/project   # Check another project
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # Exclude expensive stages
bash scripts/audit.sh                    # Vulnerability audit (manual because it uses the network)
```

### Record feedback

```bash
# After receiving human feedback (include one root-cause line for failure feedback)
bash scripts/feedback.sh add --category style --source human \
  --summary "Write error messages in Japanese" \
  --detail "The Japanese-only requirement was absent from the instructions. 根因: 指示欠陥"

# To preserve a successful workflow or phrasing (the signal is inferred when omitted)
bash scripts/feedback.sh add --category workflow --source agent \
  --summary "Agreeing on the design before implementation prevents rework"
```

With the Claude Code or Codex plugin, the `capture-feedback` skill performs the same operation, so you do not need to run the command directly.

### Organize accumulated feedback

```bash
bash scripts/feedback.sh list                    # List open entries
bash scripts/feedback.sh list --signal failure   # Show failure signals only
bash scripts/feedback.sh promote <id> --rule "<one generalized rule>"
bash scripts/feedback.sh merge <id> --into <existing-rule-source-id>   # For recurrence
bash scripts/feedback.sh retire <source-id> --reason "<retirement reason>"    # Rule review
```

### Measure and share results

```bash
bash scripts/feedback.sh stats                      # First-pass rate, recurrence candidates, last audit date
bash scripts/feedback.sh report --since yesterday  # One stand-up question
bash scripts/feedback.sh report --last --mark       # Advance the period after the retrospective
```

### Environment variables

Environment variables are **temporary overrides that take precedence over config**. Use them for one-off changes in CI or during investigation. Put settings that should be committed and shared by the team in the configuration file.

| Variable | Default | Effect |
|---|---|---|
| `FEEDBACK_CHECK_SKIP` | (empty) | Space-separated stages to exclude (`lint typecheck test build format security docs contract`) |
| `FEEDBACK_SHELLCHECK_SEVERITY` | `warning` | shellcheck severity threshold; use `style` for stricter checking |
| `FEEDBACK_CONTRACT_BASE` | `main` | Baseline branch for API contract differences |
| `CLAUDE_PROJECT_DIR` | (automatic) | Project root set by Claude Code. Codex resolves the root from the Hook's working directory |
| `HARNESS_PYTHON` | (automatic) | Python executable to run (resolved as `python3` then `python` by default). Set it when Git Bash or a virtualenv exposes Python under a different name or path |

### Configuration file

Commit `.feedback/config.yaml` to share project settings. It can configure stage skips, FAIL/WARN behavior, excluded paths (`exclude`), log line limits, tool thresholds, audit intervals, and more without environment variables. Omitted settings use defaults.

```bash
cp .feedback/config.example.yaml .feedback/config.yaml   # Start from the template
bash scripts/check.sh --list-checks           # List check IDs, effective decisions, and sources without running checks
bash scripts/check.sh --list-checks --json    # Print the same information as machine-readable JSON
```

Configuration comes in two layers. `.feedback/local/config.yaml` (git-ignored, local to this machine) overrides the shared `.feedback/config.yaml`, so you can reflect local circumstances—such as disabling a check for a tool you do not use—without editing the team's settings. Values decided by the personal layer show a source starting with `local.` in `--list-checks`.

Precedence is environment variable > individual check > stack > global > default, and within the same level the personal layer wins over the shared one. See the [configuration guide](docs/configuration.md) for syntax and every available setting.

## Feedback workflow

```text
[record] Human correction / successful workflow / repeated check failure / pre-completion retrospective
→ feedback.sh add       (capture-feedback skill / AGENTS.md rules)
             Failure feedback includes one root cause in --detail:
               文脈欠落 | 指示欠陥 | 実行誤り | モデル限界 | 未判定
             signal (--signal) describes what happened:
               Incorrect output or behavior is failure regardless of root cause; the CLI infers it when omitted
                ↓
[open]  ├─ Read before the next task without waiting for promotion (apply-feedback skill)
        └─ feedback-curator selects the destination based on root cause (feedback-loop skill)
             promote → add a new rule to .feedback/rules.md      (mainly instruction defects)
             merge   → merge into an existing rule; strengthen wording on recurrence
             close   → close one-off feedback that cannot become a shared rule
             propose → Missing context: propose additions to the appropriate prerequisite document
                       Execution error: add a linter, test, or checklist
                       Model limitation: require human review or a deterministic tool (reproduction evidence required)
                       Undetermined: leave open and wait for more information
                       Changes outside rules.md remain proposals until approved by a human
                ↓
[apply] .feedback/rules.md → apply before work in the next session
                ↓
[review] Periodic review (feedback-loop Phase 4) → retire obsolete rules
[measure] feedback.sh stats         — first-pass rate and recurrence candidates (text, on request)
[report]  feedback.sh report --last → five-minute stand-up/retrospective topic
                                          (then --mark to advance the reporting period)
[audit]   bash scripts/audit.sh          — manual vulnerability audit (uses the network)
                                          updates .last-audit only on success; report checks its age
```

Recorded feedback is consulted from the next task onward without waiting for `promote`. Otherwise, the same problem could recur while entries wait to be turned into rules.

Measurement corresponds to “measuring the change” in the Feedback Flywheel. The harness does not build a dashboard. `stats` produces text only on request, and numbers appear only in the “Numbers” section of `report`. `events.jsonl` (Hook results) and `.last-retro` (the reporting period marker) are local state files and are not shared through Git.

Rules are not the only destination because the right shared artifact depends on the signal. Missing knowledge belongs in the prerequisite document selected from the target project's instruction files and their references. Mechanically detectable failures are prevented more reliably by a linter or test than by prose alone. See [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md).

## License

Released under the [MIT License](LICENSE).
