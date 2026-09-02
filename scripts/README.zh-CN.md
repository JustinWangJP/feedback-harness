[English](README.md) | [日本語](README.ja.md) | 简体中文

# scripts/ — feedback-harness 执行引擎

本目录用于存放反馈工具链的执行脚本。如果项目根目录存在 README.md，则由根目录文档介绍整个工具链的概况。本文档说明各脚本的**职责、规范和使用方法**。

脚本和积累数据（`.feedback/`）在 **Claude Code 与 Codex 之间完全共享**。因环境而异的只有“由谁、在何时启动脚本”这一入口，详见后文。

## 目录结构

```text
scripts/
├── check.sh          # 完整检查：自动检测技术栈 → 8 个阶段和横向检查，输出摘要
├── checks/*.sh       # 技术栈与横向runner（共用执行core保留在check.sh）
├── check_file.sh     # 快速单文件检查：根据扩展名执行静态检查
├── lib.sh            # check.sh / check_file.sh 的共用工具函数（包括 has()）
├── harness_config.py # .feedback/config.yaml 的唯一解析器（YAML 子集、schema 验证、3 层解析）
├── feedback_store.py # repository lock、原子写入及中断事务恢复
├── feedback.sh       # 跨平台反馈 CLI 入口（解析 Python 可执行文件）
├── feedback_log.py   # 反馈 CLI 实现：记录、整理、盘点、统计和周期报告
├── audit.sh          # 按需漏洞审计（工具链中专门联网的检查；Stop hook 不会调用）
├── init.sh           # 安装脚本（为不支持 Hooks 的环境部署资源；不会复制到目标项目）
└── hooks/
    ├── on_session_start.sh  # Claude Code / Codex SessionStart → 首次初始化 .feedback/
    ├── post_edit.sh         # Claude Code / Codex PostToolUse → check_file.sh
    └── on_stop.sh           # Claude Code / Codex Stop → check.sh
```

脚本分为三类：

| 类别 | 脚本 | 职责 |
|------|-----------|------|
| 自动检查 | `check.sh`、`check_file.sh`、`hooks/*` | 不额外下载依赖或查询远程服务地将 lint/test/build 结果返回给代理 |
| 反馈积累和测量 | `feedback.sh` | 记录并通用化人工反馈，传递到后续会话；输出指标和周期摘要 |
| 按需审计（使用网络） | `audit.sh` | 检查依赖项漏洞；Hooks 不会调用 |

有两种分发方式。**插件安装**会将所有文件保留在插件中。Codex 使用 `PLUGIN_ROOT`（Hooks 还会设置兼容变量 `CLAUDE_PLUGIN_ROOT`），Claude Code 使用 `CLAUDE_PLUGIN_ROOT`。**通过 `init.sh` 安装**时，会将 `check.sh`、`checks/*.sh`、`check_file.sh`、`lib.sh`、`feedback.sh`、`audit.sh`、`harness_config.py`、`feedback_store.py`、`feedback_log.py` 以及本 README 的三种语言版本复制到目标项目的 `scripts/` 目录。`hooks/` 和 `init.sh` 本身不会复制：前者仅用于插件，后者应从分发源仓库运行。

## 共用设计原则

1. **面向代理输出：** 简洁显示每项检查的结果和最终状态；失败详情只显示末尾指定行数，不输出整段冗长日志。
2. **宽容检测：** 未安装工具的阶段标记为 `SKIP`，不视为失败。工具链不会强制项目使用某种技术栈。
3. **根据声明决定严格程度：** 项目通过配置文件声明的检查为 `FAIL`（阻塞完成）；工具链推测执行的检查为 `WARN`（仅报告，退出码为 0）。如果未声明的检查也能阻塞完成，已有项目在引入工具链的第一天就可能无法工作。WARN 会记录到 `events.jsonl`，并出现在 `stats` / `report` 的“常见 WARN”中。
4. **不自动安装工具：** 缺少工具时只标记为 `SKIP` 并说明原因。是否安装并改变环境由用户决定。
5. **与技术栈无关：** 根据 `pyproject.toml`、`package.json` 等 manifest 自动检测项目类型，无需配置。
6. **分离状态：** 脚本本身不内嵌状态，所有状态都保存在 `.feedback/` 下。`rules.md`、`log/` 等共享数据可由 Git 跟踪；`events.jsonl`、`.last-check`、`.last-retro`、`.last-audit`、`.state.lock`、`.transaction.json` 等运行时状态属于 `.gitignore` 对象，不在设备间共享。lock 会持久保留以确保所有进程锁定同一 inode；中断事务的 journal 会在下一次 CLI 调用时重放。

---

## 各脚本规范

### `check.sh` — 完整检查（完成前 / CI）

```bash
bash scripts/check.sh [项目根目录]          # 省略时使用当前目录
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 跳过指定阶段
bash scripts/check.sh --list-checks   # 不执行检查，列出检查 ID、实际判定和来源
bash scripts/check.sh --list-checks --json   # 以 JSON 输出相同信息
bash scripts/check.sh --help          # 显示用法（exit 0）
```

分发的各脚本（`check.sh` / `check_file.sh` / `feedback.sh` / `audit.sh` / `init.sh` / `harness_config.py` / `feedback_log.py`）在收到 `--help` / `-h` 时显示用法并 `exit 0`。`check.sh` / `audit.sh` / `init.sh` 会以 **`exit 2`** 拒绝未知选项——若把未知选项当作项目根目录，就会显示“找不到目录”，从而掩盖问题其实出在参数上。`check_file.sh` 是例外：除 `--help` 外，以 `-` 开头的参数一律按文件名处理，因为该脚本的非零退出码会直接导致 PostToolUse 拒绝本次编辑。

**行为：** 对每个检测到的技术栈运行相应阶段，同时执行与技术栈无关的横向检查，并输出 `PASS`/`FAIL`/`WARN`/`SKIP` 摘要。

**各阶段执行的命令**（缺少工具时标记为 `SKIP` 并说明原因）：

| 阶段 | Python | Node | Go | Rust | Java | Shell |
|---|---|---|---|---|---|---|
| `lint` | `ruff check` | `run lint` / `npm ls --all` | `go vet` / `go mod verify` | `clippy` / `cargo metadata --offline` | — | `bash -n` / `shellcheck` |
| `typecheck` | `mypy`（声明时） | `run typecheck` / `tsc --noEmit` | — | — | — | — |
| `test` | `pytest`（+`--cov`） | `test` 或 `test:coverage` | `go test -cover` | `cargo test` | `./mvnw` 或 `mvn verify` / `gradle check` | — |
| `build` | — | `run build` | `go build` | `cargo check`（没有 clippy 时） | — | — |
| `format` | `ruff format` | `prettier`（声明时） | `gofmt -l` | `cargo fmt` | — | — |
| `contract` | — | — | — | `cargo semver-checks`（`[lib]`） | — | — |

**横向检查**（与技术栈无关，属于 `security` / `docs` / `lint` / `contract` 阶段）：配置文件语法、内部链接、密钥、CI 配置、Dockerfile 和 OpenAPI 契约差异。

**本脚本不会执行的操作：**

- **由工具链本身主动访问网络** — 漏洞审计独立到 `audit.sh`。`npx` 始终带有 `--no-install`；未安装时不会下载，只标记为 `SKIP`。但项目定义的命令和外部工具仍可能根据自身配置访问网络
- **安装工具** — 缺少工具时标记为 `SKIP` 并说明原因
- **运行两次测试** — 通过在现有 test 命令中加入覆盖率测量，或改用 `test:coverage` 来获得覆盖率
- **因未声明的检查而阻塞完成** — 这类问题标记为 `WARN`（退出码为 0）
- **访问远程仓库** — 契约差异基线为 `git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`；无法解析时使用 `HEAD`

- **检测对象：** Python（`pyproject.toml` / `setup.py` / `requirements.txt`；即使没有这些文件，只要存在 `*.py` 也会仅运行 `ruff`）/ Node（`package.json`）/ Go（`go.mod`）/ Rust（`Cargo.toml`）/ Java（`pom.xml` / `build.gradle`）/ Shell（`*.sh`）/ 通用（`Makefile` 的 `check` target）
- **Maven 项目：** 根目录存在 `pom.xml` 时，将其作为 reactor 入口，只运行一次 `verify`。没有根 POM 时，对检测到的每个 `pom.xml` 使用 `-f` 独立运行。每个 POM 依次优先使用同目录的 `mvnw`、仓库根目录的 `mvnw`，最后才使用全局 `mvn`。wrapper 存在但不可执行时会标记为 `SKIP`，不会静默回退。Maven `verify` 包含项目配置的编译、测试、打包和 integration-test 生命周期阶段；Maven 可能会按照项目设置从仓库解析依赖项和插件。没有根 POM 时检测到的每个模块都拥有独立的检查 ID `mvn-<模块 slug>`（例如 `services/api/pom.xml` → `mvn-services-api`；slug 冲突时会追加序号）。判定按「该派生 ID 的显式设置 → `mvn` 的设置」顺序解析，因此 `check.skip: [test]` 会作用于所有模块，而 `checks.mvn-tools-cli.severity: skip` 只停止该模块
- **横向检查（与技术栈无关）：** 验证 `*.json`、`*.yaml` 和 `*.yml` 的语法。`tsconfig*.json`、`jsconfig*.json`、`devcontainer.json` 以及 `.vscode/` 下的文件通常允许注释（JSONC），因此不检查。YAML 支持由 `---` 分隔的多文档格式，`!Ref` 等未知自定义标签不视为语法错误。未安装 PyYAML 时，YAML 检查标记为 `SKIP` 并说明原因。JSON 语法与内部链接检查依赖 Python，因此在无法解析 Python 3.10+ 的环境中同样标记为 `SKIP` 并说明原因（不会把未验证的项目报告为 `PASS`）
- **文档一致性：** 在 `docs` 阶段检测 Markdown 内部链接失效。为保持离线运行，不检查外部 URL、`mailto:`、仅锚点链接和绝对路径。代码块和行内代码中的链接状文本不参与验证
- **密钥（`security` 阶段）：** 存在 `.secretlintrc.*` 时运行 `secretlint`。**未配置时标记为 SKIP**，因为 secretlint 无法在没有配置的情况下启动。值默认会被屏蔽，不会出现在失败日志中。PATH 中存在 `gitleaks` 时也会运行，但仅支持带有 `--no-git --redact` 的版本
- **CI 配置和 Dockerfile：** 存在 `.github/workflows/*.y*ml` 时运行 `actionlint`；存在 `Dockerfile*` 时运行 `dockerfilelint`，若不存在则使用 `hadolint`。缺少工具时标记为 SKIP
- **依赖项存在性（离线）：** Node 仅在使用 npm 且存在 `node_modules` 时运行 `npm ls --all`；Go 使用 `go mod verify`；Rust 使用 `cargo metadata --offline`；Python 使用 `deptry`。这些检查可发现不存在的包名以及声明与实际安装内容不一致的问题
- **API 契约和破坏性变更（`contract` 阶段）：** 根目录或 `api/` 中存在 `openapi.yaml` / `openapi.json` 时，使用 `oasdiff breaking` 与 Git 基线（`git merge-base HEAD <FEEDBACK_CONTRACT_BASE:-main>`，无法解析时使用 `HEAD`）比较。含有 `[lib]` 的 Rust crate 运行 `cargo semver-checks check-release --baseline-rev <Git生成的SHA>`。两者都不访问远程仓库或 registry，完全离线运行
- **复用现有测试测量覆盖率：** 不运行两次测试，只添加测量参数。检测到 pytest-cov 时，Python 添加 `--cov --cov-report=term-missing`（配置的 `--cov-fail-under` 会自动成为 FAIL gate）；Go 使用 `go test -cover`；Node 如果存在 `test:coverage` script，则用它**替代** `test`，避免运行两次
- **配置文件：** 通过提交并共享 `.feedback/config.yaml`，可调整阶段 skip、FAIL/WARN 切换、检查对象排除（`exclude`）、日志行数、工具阈值（shellcheck 严重程度、vulture confidence、oasdiff 基线）、审计间隔等。优先级为**环境变量 > 单项检查（`checks.<id>`）> 技术栈（`check.<stack>`）> 全局（`check`）> 默认值**。`FEEDBACK_CHECK_SKIP` 等环境变量用于临时覆盖配置。配置分为两层：`.feedback/local/config.yaml`（已被 `.gitignore`，仅对本机生效）优先于共享的 `config.yaml`，可在不修改团队设置的前提下反映本地情况（例如关闭未使用工具的检查）。由个人层决定的项目，其来源以 `local.` 开头。全部项目请参阅分发源插件的配置指南 `docs/configuration.zh-CN.md`；分发的 `scripts/` 不包含 `docs/`，因此此处不添加链接
- **`--list-checks`：** 不执行检查命令，只列出检查 ID、标签、阶段、实际判定和**来源**（由哪一层决定）。适用的检查即使未安装工具，也会显示 `skip` 和原因。最左侧的检查 ID 可直接用作 `checks:` 的 key。结合 `--json` 可输出机器可读格式。配置损坏时，先使用默认值显示表格，再向 stderr 输出错误并以 1 退出
- **单阶段时间上限：** `check.stage_timeout_seconds`（默认 `0`，即交给 harness 决定）可中断单个阶段。为 `0` 时，从 CLI / CI 运行不限时，只有 Stop hook 会在 240 秒（短于 hook 自身的限制）处中断（`--stage-timeout=<秒>` 是 hook 使用的入口，config 中的设置优先）。中断报告为 `TIMEOUT` 而非 `FAIL`；对 `severity: warn` 的检查则只报 `WARN`。在没有 `timeout(1)` 或其不支持 `--kill-after` 的环境中不做中断，行为与以往一致
- **跳过阶段：** `FEEDBACK_CHECK_SKIP` 可指定 `lint`、`typecheck`、`test`、`build`、`format`、`security`、`docs` 和 `contract`，多个名称以空格分隔；与配置中的 `check.skip` 使用相同词汇
- **Make 递归防护：** 仅在运行 `make check` 时将 `FEEDBACK_CHECK_RECURSION_GUARD` 传给后代进程，使其中启动的 check.sh 跳过 Make 回退。这样可阻止以下无限递归：Hook 执行时传播的 `CLAUDE_PROJECT_DIR` 让测试中的 check.sh 将根目录重新解析为本仓库，随后 make check 再次执行测试，最终耗尽 Stop hook 的 timeout。**普通 Make 命令和直接运行的 lint/test/build 阶段不受影响**
- **SKIP 原因：** 输出一定包含原因，例如 `(<tool> 未インストール)` / `(<tool> 起動不可 — 環境を確認してください)` / `(実行不可)`；由环境变量造成的跳过显示 `(env.FEEDBACK_CHECK_SKIP)`，由配置造成的跳过显示 `(config: <キーのパス>)`，按技术栈统一跳过时显示 `(<stack>: 全ステージ …)`。**仅因工具缺失或损坏不会成为 `FAIL`**，因为这不是用户代码的问题
- **检查文件：** 在 Git 仓库中使用 `git ls-files --cached --others --exclude-standard`。这会检查**尚未提交的新文件**，并排除已由 `.gitignore` 忽略的文件
- **不隐式下载工具：** Node 类型检查的回退命令为 `npx --no-install tsc`。未安装 `typescript` 时不会尝试下载，只标记为 `SKIP`。但 Maven `verify` 等项目定义的命令仍可能解析已声明的依赖项和插件
- **shellcheck 严重程度：** 默认为 `warning`（`-S warning`）。如果连 `style` / `info` 也检查，已有项目可能在引入工具链的第一天就无法继续工作。设置 `FEEDBACK_SHELLCHECK_SEVERITY=style` 可提高严格程度
- **失败输出：** 失败阶段的日志末尾 40 行会汇总到 `failures.txt`，最后统一显示
- **最终行**（FAIL 时除外；以下情况退出码均为 0）：

  | 最终行 | 含义 |
  |---|---|
  | `ALL PASS` | 所有阶段成功 |
  | `ALL PASS (N件WARN — 未対応の指摘があります)` | 成功，但存在不阻塞流程的问题；请检查 WARN 内容 |
  | `ALL PASS (N件WARN・M件SKIP — 未検証/未対応の項目があります)` | 成功，但同时存在尚未处理的问题和未经验证的项目 |
  | `ALL PASS (N件SKIP — 未検証の項目があります)` | 成功，但存在未经验证的项目 |
  | `実行できたステージがありません(すべてSKIP)` | 没有任何内容得到验证 |
  | `検出できたスタックがありません …` | 未找到支持的 manifest 或目标文件 |

  不会把全部 SKIP 或部分 SKIP 的结果伪装成不带说明的 `ALL PASS`。
- **WARN：** 不阻塞完成的问题，退出码仍为 `0`。最终行会显示数量，例如 `ALL PASS (1件WARN — 未対応の指摘があります)`。WARN 来源于没有项目声明（配置文件）的检查：`python: ruff format`（存在 `[tool.ruff` 时为 FAIL）、`python: deptry` / `python: vulture`（存在 `[tool.deptry` / `[tool.vulture` 时为 FAIL）、`rust: cargo fmt`（存在 `rustfmt.toml` 时为 FAIL）
- **退出码：** `0` = 无 FAIL（包括全部 SKIP 和未检测到技术栈）/ `1` = 存在 FAIL / `2` = 根目录无效。**代理必须根据退出码判断，而不是根据最终行文字判断**

### `check_file.sh` — 快速单文件检查（编辑后立即执行）

```bash
bash scripts/check_file.sh <文件路径>
```

**行为：** 根据扩展名，只执行不需要完整构建的静态检查。应用 `.feedback/config.yaml` 中的单项检查判定：`skip` 不执行，`warn` 显示内容并以退出码 0 结束，`fail` 以退出码 1 结束。配置本身有错误时也会显示详情并以 1 结束。

| 扩展名 | 检查内容 |
|---|---|
| `.py` | `ruff check`（不存在时使用所选 Python 的 `-m py_compile`） |
| `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs` | 存在 ESLint 配置时使用 `eslint`；否则 `.js`/`.mjs`/`.cjs` 使用 `node --check` |
| `.go` | `gofmt -l`（检测未格式化文件） |
| `.rs` | `rustfmt --check` |
| `.sh` | `bash -n`，以及存在时运行 `shellcheck` |
| `.json`/`.yaml`/`.yml` | 使用所选 Python 解析验证 |

- **退出码：** `0` = 无问题、仅 WARN、未指定文件或目标文件不存在 / `1` = FAIL 或配置错误（会显示详情）

### `feedback.sh` — 反馈记录 CLI

```bash
bash scripts/feedback.sh <子命令> [参数]
```

条目以带 frontmatter 的 Markdown 保存在 `.feedback/log/`，通用规则会被整理到 `.feedback/rules.md`。**不要直接创建或编辑 log 文件，必须使用此 CLI**，否则不一致的 frontmatter 会破坏 `list` / `promote`。

| 子命令 | 参数 | 说明 |
|---|---|---|
| `add` | `--category <cat>` `--summary "<摘要>"` `[--detail "<详情>"]` `[--source human\|hook\|agent]` `[--signal <context\|instruction\|workflow\|failure>]` | 记录条目。open 条目达到 3 个或更多时提示存在 promote 候选。`--signal` 表示信号类型，省略时根据 detail/category 推断。存在 `根因:` 行时，只允许填写定义好的五种分类之一，并且只能填写一项 |
| `list` | `[--status open\|promoted\|closed\|retired\|all]` `[--category <cat>]` `[--signal <context\|instruction\|workflow\|failure\|unknown>]` | 列出条目（默认为 `open`）。`--signal unknown` 用于选择没有 signal 的旧条目 |
| `search` | `<关键字>` | 对条目执行全文搜索 |
| `promote` | `<entry-id>` `--rule "<一条通用规则>"` | 向 `rules.md` **添加新规则**，并将目标条目标记为 `promoted` |
| `merge` | `<entry-id>` `--into <现有规则的来源id>` `[--rule "<更新后的文本>"]` | 在不增加新规则行的情况下向**现有规则**追加来源，并将目标条目标记为 `promoted`。用于同一原则再次出现时 |
| `close` | `<entry-id>` `[--reason "<原因>"]` | 不整理为规则，直接标记为 `closed`。用于无法通用化的一次性反馈 |
| `retire` | `<来源entry-id>` `--reason "<停用原因>"` | 从 rules.md **移除已整理的规则**，并将其来源条目（包括已经 merge 的条目）标记为 `retired`。在规则盘点并由人工裁定后使用 |
| `rules` | （无） | 显示当前 `rules.md` |
| `stats` | `[--since <日期>]` `[--days <N>]` | 仅汇总当前工作副本中的本地数据：PostToolUse 首次通过率、平均重新检查次数、Stop 首次通过率、常见失败、按 signal/根因统计的数量，以及**复发候选**（整理后同类别又记录了失败类反馈的规则——这是**待调查的线索而非判定结果**，是否属于同一原则的复发由阅读正文的 Agent 判断。每条候选旁的数值只是表层字符重合度，仅用于决定阅读顺序）。常见 WARN 与常见失败会附带**最近发生日期**，超过 `feedback.stale_days`（默认 7 天）未再出现的项目会加注说明。草稿目录等临时文件不计入统计。同时显示**最近审计日期**与**最近盘点日期**，分别超过 `audit.interval_days`（默认 7 天）与 `feedback.retro_interval_days`（默认 90 天，约一个季度）时会显示建议 |
| `report` | `--since <日期\|yesterday>` 或 `--last`、`[--mark]` | 仅限当前工作副本的周期摘要（新条目、promote/close/retire、open 盘点、复发候选和数值）。`--last` 以 `.feedback/.last-retro` 为起点；`--mark` 在复盘后更新起点 |

- **category：** `style` / `architecture` / `testing` / `naming` / `workflow` / `domain`
- **entry-id：** 记录时间，格式为 `%Y%m%d-%H%M%S`。同一秒记录多个条目时，依次添加 `-2`、`-3` 等以确保唯一；若重复，`promote` 只会取得第一条，其余条目将无法整理

### `audit.sh` — 按需漏洞审计（仅明确调用时执行）

```bash
bash scripts/audit.sh [项目根目录]
```

与 `check.sh` 不同，本脚本通过 pip-audit、`npm audit --audit-level=high`、govulncheck 或 cargo audit **使用网络**。Node 仅在包管理器判定（`lib.sh` 的 `harness_node_pm`，与 `check.sh` 共用）返回 npm 且存在 `package-lock.json` 时执行，因为 npm audit 无法读取其他包管理器的 lockfile，会以 ENOLOCK 失败。存在 `pnpm-lock.yaml` 或 `yarn.lock` 时标记为 SKIP，并提示直接运行 `pnpm audit` 或 `yarn npm audit`。即使迁移过程中残留了 `package-lock.json`，也仍判定为非 npm——否则测试在 pnpm 下运行而审计走 npm audit，审计的依赖树与实际解析结果不一致。Stop hook 不会调用它；仅在收到明确请求时执行，包括通过 `feedback-loop` skill 调用。成功时才会将日期写入 `.feedback/.last-audit`，`stats` / `report` 会显示“最近审计日期”。**如果超过 7 天未审计，或从未执行过审计，就会显示建议**，遵循与 WARN 相同的“不阻塞、积累后可见”原则。失败时不写入标记，因此在漏洞未解决期间建议不会消失。

### `hooks/` — Claude Code / Codex Hook 包装脚本

由 Claude Code / Codex Hooks 启动的轻量包装脚本。判断和执行委托给 `check_file.sh` / `check.sh`，这里只处理 Hook 特有逻辑：解析 stdin JSON、通过退出码 2 将问题退回代理，以及防止无限循环。**通过 `init.sh` 安装时不会复制**，因为它们从插件运行。

- **`on_session_start.sh`（SessionStart）：** 首次使用时从模板初始化 `.feedback/log/` 和 `rules.md`。仅安装插件的项目不会运行 `init.sh`，因此由 Hooks 负责初始化。它**绝不修改已有的 `.feedback/`**，即使失败也不会阻塞会话。
- **`post_edit.sh`（PostToolUse：`Edit|Write|MultiEdit`）：** 在 Claude Code 中从 stdin 读取 `tool_input.file_path`；在 Codex 的 `apply_patch` 中从 `tool_input.command` 的补丁头提取目标文件，然后运行 `check_file.sh`。发现问题时以 **退出码 2 + stderr** 返回给代理，启动自我修正循环。无法确定目标文件时不记录任何内容。
  - 将成功或失败结果各追加一行到 `.feedback/events.jsonl`，作为 `stats` 计算首次通过率的数据。该文件是本地状态，不共享。
- **`on_stop.sh`（Stop）：** 响应完成前运行 `check.sh`。失败时以**退出码 2** 阻塞完成，并返回失败详情。第二轮及以后 `stop_hook_active` 为 `true` 时不执行任何操作，直接以 0 结束，从而**防止无限循环**。
  - **执行条件：** 仅当工作树在上次成功检查（`.feedback/.last-check` 的 mtime）后发生变更时运行。如果无条件执行，即使本轮只是回答问题而未编辑文件，也会在目标项目中运行 `mvn verify` / `npm run build` 等完整构建。mtime 判定不仅能捕获 Edit/Write，也能捕获通过 Bash 进行的编辑；无法判断时始终选择执行检查。
  - **只在检查成功时**推进标记。记录失败会让下一轮被误判为“无变更”，从而允许在损坏状态下完成。
  - 第二轮不重新运行 `check.sh`，因为退出码 0 的输出不会返回代理，而在大型项目中只会增加等待时间。
  - 仅在实际运行 `check.sh` 时向 `events.jsonl` 记录结果；跳过时不记录。

---

## 使用方法：插件与手动回退的区别

脚本本身相同，但**启动主体**取决于环境是否支持插件。

### Claude Code / Codex app 和 CLI — Hooks 驱动（自动）

Claude Code 和 Codex app / CLI 使用插件提供的 Hooks（`hooks/hooks.json`）作为启动驱动，因此**代理无需明确调用脚本**。在 Codex 中，首次使用时通过 `/hooks` 检查内容并设为受信任。

| 时机 | Hook | 执行链 | 效果 |
|---|---|---|---|
| 编辑文件后立即执行 | `PostToolUse`（`Edit\|Write\|MultiEdit`） | `post_edit.sh` → `check_file.sh` | 检测 Claude 的 Edit/Write 和 Codex 的 `apply_patch`。发现问题时立即以退出码 2 退回，从而触发自动修正 |
| 响应完成前 | `Stop` | `on_stop.sh` → `check.sh` | 存在 FAIL 时阻塞完成并继续修正；如果上次成功检查后没有变更，则跳过检查本身 |

- **应用规则：** `apply-feedback` skill 读取 `.feedback/rules.md`。如果同时使用 `init.sh`，CLAUDE.md / AGENTS.md 还会说明 Hooks 禁用时的手动步骤。
- **记录反馈：** `capture-feedback` / `feedback-loop` skill 调用 `feedback.sh`。
- Skills 和 Agents 的启动条件及步骤请参阅项目根目录 README.md 中的“Skills / Agents / Commands 的使用方法（插件安装）”。通过 `init.sh` 安装时不会分发该部分内容，而由下述规则驱动流程替代。
- **配置文件：** 插件使用 `hooks/hooks.json` 和 `skills/`。Claude Code 读取 `.claude-plugin/plugin.json`，Codex 读取 `.codex-plugin/plugin.json`。CLAUDE.md / AGENTS.md 规则只在同时使用 `init.sh` 时添加。

### 仅 init 的 Claude Code / Codex IDE 扩展 / 通用代理 — 规则驱动（手动）

仅使用 `init.sh` 安装，或 Hooks 已禁用、未受信任时，Claude Code 使用 CLAUDE.md，Codex IDE 扩展和通用代理使用 AGENTS.md 作为自动循环的替代方案。代理按照规则自行调用脚本；这不是自动执行。

| 时机 | 命令 | 依据 |
|---|---|---|
| 会话开始 | `bash scripts/feedback.sh rules` | 将规则应用到工作方针（§1） |
| 每次代码变更后 | `bash scripts/check_file.sh <编辑的文件>` | 立即检查，发现问题则修正（§2） |
| 完成前 | `bash scripts/check.sh` | 确认 `ALL PASS` 后再完成；存在 FAIL 时不得报告完成（§3） |
| 收到反馈后 | `bash scripts/feedback.sh add --category … --summary … --source human` | 立即记录，这是唯一的持久化方式（§4） |
| 复盘 / 晨会 | `bash scripts/feedback.sh report --last --mark` | 将周期摘要作为议题，结束后推进统计起点 |
| 收到审计提示时 | `bash scripts/audit.sh` | 当 `stats` / `report` 在超过 7 天或从未执行时显示“建议审计”后运行 |

- **应用规则：** CLAUDE.md / AGENTS.md §1 规定必须读取 `.feedback/rules.md`。
- **配置文件：** CLAUDE.md 或 AGENTS.md（无需 Hooks）。

### 对比

| 项目 | 插件（Claude Code / Codex） | `init.sh`（Claude Code / Codex IDE 扩展 / 通用代理） |
|---|---|---|
| 启动驱动 | Hooks（自动） | CLAUDE.md / AGENTS.md 规则（代理自主执行） |
| 编辑后检查 | 通过 `PostToolUse` 自动执行 | 每次手动运行 `check_file.sh` |
| 完成前检查 | 通过 `Stop` 自动执行并可阻塞 | 完成前手动运行 `check.sh` |
| 应用规则 | `apply-feedback` skill | CLAUDE.md / AGENTS.md §1 |
| 记录反馈 | `capture-feedback` / `feedback-loop` skills | 按 CLAUDE.md / AGENTS.md §4 手动执行 |
| 主要配置 / 指示文件 | `hooks/hooks.json`、`.claude-plugin/plugin.json` / `.codex-plugin/plugin.json` | CLAUDE.md / AGENTS.md |
| 共用脚本 | `scripts/*`、`.feedback/` | 相同 |

---

## 所需工具

- **必需：** `bash`、Python 3.10 以上版本（`python3` 或 `python`；用于解析 Hooks 中的 JSON、运行反馈 CLI、验证 JSON/YAML 以及检查内部链接）
- **可选 — 技术栈标准工具**（自动检测；未安装时标记为 `SKIP`）：`ruff`、`mypy`、`pytest` / `npm`/`pnpm`/`yarn`、`eslint`、`tsc` / `go`、`gofmt` / `cargo`、`rustfmt`、`clippy` / `mvn`、`gradle` / `shellcheck`
- **可选 — 扩展检查：** `pytest-cov`（覆盖率）/ `deptry`、`vulture`、`import-linter`（Python 依赖、死代码、架构约束）/ `secretlint`、`dockerfilelint`、`knip`、`prettier`（通过 npm；本仓库的 `package.json` 是示例）/ `gitleaks`、`actionlint`、`hadolint`、`oasdiff`、`cargo-semver-checks`（系统相关二进制文件，仅在 PATH 中存在时使用）
- **可选 — 仅审计**（只由 `audit.sh` 使用，会访问网络）：`pip-audit` / `npm` / `govulncheck` / `cargo-audit`

工具链不会安装其中任何工具。使用 `npx --no-install` 是为了避免在工具未安装时未经许可从网络下载。

在 Windows 上，请从 Git for Windows 附带的 Git Bash 运行现有 `*.sh` 文件。共用运行器会解析 Python 可执行文件名，因此不需要 PowerShell 专用脚本。如果 Python 的名称或路径与 `python3` / `python` 不同，请通过 `HARNESS_PYTHON` 显式指定。

## 安装到其他项目

> 本节介绍在**工具链分发源仓库**中执行的操作。由于 `scripts/init.sh` 本身和 `docs/` 不会复制到目标项目，重新安装或更新时必须从分发源运行。

`scripts/init.sh` 会将 `scripts/`（包括本文件的三种语言版本）复制到目标项目。目标项目中也可以查阅 `scripts/README.md`、`scripts/README.ja.md` 和 `scripts/README.zh-CN.md`。

只会带入**工具链机制**，不会带入本仓库特有的内容：

- `.feedback/rules.md` 从仅含标题的 `.feedback/rules.template.md` 初始化。分发源中已整理的规则和目标项目不存在的来源 ID 不会混入
- CLAUDE.md / AGENTS.md 中添加的是 `docs/pointer_claude.md` / `docs/pointer_agents.md` 的片段。再次运行时，只替换 `feedback-harness:pointer` 管理标记内的内容，保留标记外的用户文本。对于引入管理标记之前的旧说明，仅在能够可靠识别已知标题和结束位置时才迁移到管理区域

```bash
bash scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # 验证技术栈检测
```
