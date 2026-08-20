[English](README.md) | [日本語](README.ja.md) | 简体中文

# feedback-harness

这是一个可同时用于 Claude Code 和 Codex 的反馈工具链，提供以下两种机制：

1. **自动反馈循环** — 自动将 lint、类型检查、测试和构建结果返回给代理，使其能够自行修复问题
2. **积累人工反馈** — 记录评审意见和有效的工作方式，将其整理为共享规则，并应用到后续工作中

## 环境要求

- **必需：** `bash`、`python3`
- **可选：** 项目使用的 lint、类型检查、测试、构建等工具

只会使用已经安装的可选工具。找不到的工具会在说明原因后标记为 `SKIP`，工具链不会自动安装任何工具。

## 工作原理

| 环境 | 自动检查 | 应用规则 |
|------|-------------|-----------|
| Claude Code（已安装插件） | 插件通过 `hooks/hooks.json` 提供 Hooks。编辑文件后立即运行 `check_file.sh`，结束响应前运行 `check.sh`（仅当上次成功检查后存在变更时才运行 `check.sh`）。检查失败时以退出码 2 将结果返回给代理。还会检查配置文件（JSON/YAML）语法、密钥、内部链接、依赖项和 CI 配置。项目未明确配置的检查所产生的问题会作为 WARN（不阻塞流程的警告）记录到 `events.jsonl`。缺少工具时标记为 SKIP，工具链不会自动安装工具。 | `apply-feedback` skill 读取 `.feedback/rules.md` 和尚未整理的反馈。 |
| Claude Code（仅使用 `init.sh`） | 代理按照 CLAUDE.md 中的规则，在每次变更后运行 `check_file.sh`，并在完成前运行 `check.sh`。 | CLAUDE.md 要求在开始工作前读取 `.feedback/rules.md` 和尚未整理的反馈。 |
| Codex（已安装插件） | Codex 将同一个 `hooks/hooks.json` 作为 Codex Hooks 加载。它从 `apply_patch` 的补丁中识别目标文件并立即检查，然后在 Stop 前执行完整检查。 | `apply-feedback` skill 读取 `.feedback/rules.md` 和尚未整理的反馈。 |
| Codex IDE 扩展或通用代理（使用 `scripts/init.sh` 安装） | 代理按照 AGENTS.md 中的规则，在每次变更后运行 `check_file.sh`，并在完成前运行 `check.sh`。 | AGENTS.md 要求在开始工作前读取 `.feedback/rules.md`。 |

在所有环境中，反馈都保存在各项目的 `.feedback/` 目录中。在 Claude Code、ChatGPT 桌面应用中的 Codex 以及 Codex CLI 中，插件 Hooks 会自动执行检查。仅使用 `init.sh` 安装时，Claude Code 中的代理按照 CLAUDE.md，Codex IDE 扩展和其他通用代理则按照 AGENTS.md，自行执行检查。在 Codex 中，首次使用时需要打开 `/hooks`，检查其内容并将其设为受信任后启用。本仓库中的 `.claude/settings.json` 是使用 Claude Code 开发本工具链时的配置，不会分发到目标项目。

## 功能列表

检查会**自动检测项目的技术栈**，无需预先配置。如果某项检查所需的工具不存在，该检查会在说明原因后标记为 `SKIP`，并且不会自动安装工具。

| 阶段 | 检查内容 | 工具 / 目标 |
|---|---|---|
| `lint` | 静态分析 | ruff / eslint / go vet / clippy / shellcheck 和 bash -n |
| `typecheck` | 类型检查 | mypy（声明 `[tool.mypy]` 时）/ tsc |
| `test` | 测试（在现有测试执行中**加入覆盖率测量**） | pytest（`--cov`）/ go test `-cover` / npm `test:coverage` / cargo test / mvn verify |
| `build` | 构建 | go build / npm run build / cargo check |
| `format` | 格式偏差 | ruff format / prettier / gofmt / cargo fmt |
| `security` | 混入的密钥 | secretlint（声明 `.secretlintrc.*` 时）/ gitleaks |
| `docs` | Markdown 内部链接失效 | 内置实现（只需要 python3） |
| `contract` | API 破坏性变更 | oasdiff（OpenAPI）/ cargo semver-checks（`[lib]` crate） |
| — | 配置文件语法 | `*.json` / `*.yaml`（避免将 JSONC 和多文档 YAML 误判为错误） |
| — | 依赖项的存在性和一致性 | npm ls / go mod verify / cargo metadata / deptry |
| — | CI 配置和 Dockerfile | actionlint / dockerfilelint 或 hadolint |
| — | 未使用代码和架构约束 | vulture / knip / import-linter（仅在声明时） |

用于积累反馈的功能如下：

| 功能 | 命令 | 用途 |
|---|---|---|
| 记录反馈 | `feedback_log.py add` | 立即记录人工反馈或有效的工作方式，并保存 signal |
| 转化为规则 | `promote` / `merge` / `close` / `retire` | 向 `rules.md` 添加或合并规则、关闭已处理的反馈，或停用过时规则 |
| 测量 | `stats` | 显示首次通过率、平均重新检查次数、常见 WARN 和**复发候选** |
| 报告 | `report` | 生成用于晨会或复盘的周期摘要，并与上一周期进行比较 |
| 漏洞审计 | `audit.sh` | 仅在需要时执行（唯一使用网络的处理） |

## 可以做什么 / 不会做什么

本工具链有意不执行某些操作。以下内容是设计决策，并非尚未实现的功能。

| 可以做什么 | 不会做什么（以及原因） |
|---|---|
| 自动将检查失败返回给代理，使其能够自行修复问题 | **不会强制完成** — WARN（项目未明确配置的检查所产生的问题）保持退出码 0；只有 FAIL 会阻塞完成 |
| 使用已有工具；工具不存在时说明原因并标记为 SKIP | **不会自动安装工具。** 是否更改环境由用户决定 |
| 每轮运行可完全离线完成的检查 | **`check.sh` 不使用网络。** 漏洞审计被独立到 `audit.sh`，Stop hook 不会调用它 |
| 测量覆盖率 | **不会运行两次测试。** 只在现有 test 命令中加入覆盖率测量，或切换到 `test:coverage` |
| 通过与 Git 基线比较来检测破坏性变更 | **不会访问远程仓库。** 比较基线为 `git merge-base HEAD <默认分支>`；无法解析时使用 `HEAD` |
| `apply-feedback` skill 读取已记录的反馈并应用到下一项工作 | **不会擅自修改共享文件。** 对 `rules.md` 以外的变更（如追加 CLAUDE.md 或引入 lint）只提出建议，经人工批准后才应用 |
| 通过 `stats` / `report` 输出数值 | **不会创建仪表盘。** 不运行持续驻留的后台进程，不生成图表，也不向外部发送数据；只在请求时输出文本 |
| 检测密钥 | **不会输出密钥值本身。** secretlint 默认会屏蔽值，gitleaks 必须使用 `--redact`，因为失败日志会传递给代理 |

## 目录结构

```text
.claude-plugin/
  plugin.json       # Claude Code 插件定义
  marketplace.json  # Claude Code marketplace 和兼容 Codex 的目录
.codex-plugin/
  plugin.json       # Codex 插件定义
skills/             # feedback-loop（编排器）/ capture-feedback / apply-feedback
agents/             # feedback-curator（规则整理）/ harness-qa（一致性验证）
commands/
  init.md           # /feedback-harness:init — 为不支持 Hooks 的环境部署资源
hooks/
  hooks.json        # 用于分发的 Claude Code / Codex 共用 Hooks 定义
scripts/
  check.sh          # 自动检测技术栈（Python/Node/Go/Rust/Java/Shell/Make）→ 8 个阶段 + 横向检查
  check_file.sh     # 根据扩展名执行快速单文件检查
  audit.sh          # 按需漏洞审计（唯一使用网络的检查；不属于 Stop hook）
  lib.sh            # 共用工具函数（has / harness_project_root / harness_tree_changed /
                    #   harness_validate_json|yaml / harness_check_md_links / harness_log_event|warn）
  harness_config.py # 读取 .feedback/config.yaml 并解析检查设置
  feedback_log.py   # 反馈记录 CLI（add / list / search / promote / merge / close /
                    #   retire / rules / stats / report）
  init.sh           # 安装脚本（为不支持 Hooks 的环境部署资源）
  README.md         # 脚本的详细规范和所需工具（英文）
  README.ja.md      # 脚本文档的日文版
  README.zh-CN.md   # 脚本文档的简体中文版
  hooks/            # Claude Code / Codex Hooks 包装脚本（SessionStart / PostToolUse / Stop）
.feedback/
  rules.md          # 通用永久规则（代理必读；分为失败来源/成功来源两部分）
  rules.template.md # 初始化或重新生成 rules.md 时使用的模板
  config.yaml       # 可选项目配置（提交到 Git 以共享；从 config.example.yaml 开始）
  config.example.yaml # 带完整注释的配置模板
  log/              # 带元数据 frontmatter 的 Markdown 反馈记录
  .last-check       # Stop hook 的本地检查标记，使用修改时间（不由 Git 跟踪）
  .last-retro       # 复盘统计周期的起点（由 report --mark 更新；不跟踪）
  .last-audit       # 最近一次成功漏洞审计的日期（不跟踪）
  events.jsonl      # 用于 stats/report 的 Hook 结果和 WARN 日志（本地状态；不跟踪）
package.json        # 仅用于让 npx --no-install 解析 secretlint 等检查工具
tests/              # Bash 测试（check.sh 会检测并自动运行 make check）
docs/
  pointer_claude.md # 写入目标项目 CLAUDE.md 的说明
  pointer_agents.md # 写入目标项目 AGENTS.md 的说明
  superpowers/      # 设计规范（specs/）和实现计划（plans/）
.claude/
  settings.json     # 在本仓库中启用插件的开发配置（不分发）
```

工具链自身也属于 `check.sh` 的检查目标（会检测其 `*.sh` 和 `*.py` 文件）。

### 文档的权威顺序

有关当前用法，请参阅本 README、[配置指南](docs/configuration.md)和[脚本参考](scripts/README.zh-CN.md)。带日期的 `docs/proposals/` 和 `docs/superpowers/` 文件保留提案或设计编写时的决策。如果这些资料与当前规范不同，请以刚才列出的三份文档和实际实现为准。完整文档列表请参阅[文档导航](docs/README.zh-CN.md)。

有关 Codex 当前规范，请参阅 OpenAI 官方的[插件使用指南](https://learn.chatgpt.com/docs/plugins)、[插件包规范](https://developers.openai.com/plugins/build/plugins)和 [Hooks 规范](https://developers.openai.com/codex/hooks)。有关 Claude Code，请参阅 Anthropic 官方的[插件安装指南](https://code.claude.com/docs/en/discover-plugins)。

## 安装到其他项目

### 仅使用 Claude Code

```text
/plugin marketplace add JustinWangJP/feedback-harness
/plugin install feedback-harness@feedback-harness
```

目标项目中只会创建用于保存积累数据的 `.feedback/`。脚本、skills、agents 和 Hooks 都保留在插件中。Anthropic 官方 marketplace 以外的第三方 marketplace 默认禁用自动更新。只有用户启用自动更新后，插件才会在启动时更新到最新版本。

要向整个团队分发插件，请在目标项目的 `.claude/settings.json` 中添加以下设置。用户信任该文件夹后，系统会提示安装插件。

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

### 在 ChatGPT 桌面应用的 Codex 或 Codex CLI 中使用

```bash
codex plugin marketplace add JustinWangJP/feedback-harness
```

注册 marketplace 后，通过以下任一方式安装插件：

- 在 ChatGPT 桌面应用中打开“Plugins”，安装 `feedback-harness`
- 在 Codex CLI 中打开 `/plugins`，安装并启用 `feedback-harness`

安装后请开始一个新会话。在 Codex 中打开 `/hooks`，检查 `SessionStart`、`PostToolUse` 和 `Stop` 各 Hook 的内容，并将其设为受信任后启用。Codex IDE 扩展不支持插件，因此请使用下一节介绍的 `init.sh`。

### 使用 `init.sh` 手动运行（Claude Code / Codex IDE 扩展 / 通用代理）

将 `init.sh` 与 Claude Code 插件结合使用时：

```text
/feedback-harness:init
```

不使用插件，或从 Claude Code 以外的环境安装时，请直接执行：

```bash
git clone https://github.com/JustinWangJP/feedback-harness
bash feedback-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project && bash scripts/check.sh   # 验证技术栈检测
```

安装程序会将 `scripts/` 和 AGENTS.md 复制到目标项目。它会在 CLAUDE.md / AGENTS.md 中加入带有管理标记的说明，用于标识 feedback-harness 管理的范围。再次运行 `init.sh` 时，只替换管理标记内的内容，并保留标记外的用户文本。`.feedback/rules.md` 从空模板开始。

### 不同安装方式分发的资源

| 资源 | 插件 | `init.sh` |
|---|---|---|
| `scripts/check.sh` `check_file.sh` `audit.sh` `lib.sh` `harness_config.py` `feedback_log.py` `README.md` `README.ja.md` `README.zh-CN.md` | 保存在插件中。Codex 通过 `PLUGIN_ROOT` 运行（Hooks 还会设置兼容变量 `CLAUDE_PLUGIN_ROOT`）；Claude Code 使用 `CLAUDE_PLUGIN_ROOT` | 复制到目标项目的 `scripts/` 目录 |
| Hooks（`hooks.json`） | 是（启用后自动运行） | 否（由 CLAUDE.md / AGENTS.md 规则作为替代） |
| skills | 是（Claude Code / Codex） | 否（由 CLAUDE.md / AGENTS.md 规则作为替代） |
| agents / commands | 仅 Claude Code | 否 |
| `scripts/hooks/*` 和 `init.sh` 本身 | 是 | 否 |
| `.feedback/`（积累数据） | SessionStart hook 首次使用时创建 | `init.sh` 首次使用时创建 |
| 写入 `CLAUDE.md` / `AGENTS.md` 的说明 | 否（需要时与 `init.sh` 结合使用） | 两者都会写入（再次运行时仅替换管理区域，并保留区域外的内容） |

### 更新

| 安装方式 | 更新方法 |
|---------|---------|
| Claude Code 插件 | 第三方 marketplace 默认禁用自动更新。可在 `/plugin` → `Marketplaces` 中选择 `Enable auto-update`，或运行 `/plugin marketplace update feedback-harness` 和 `/plugin update feedback-harness@feedback-harness` |
| Codex 插件 | 运行 `codex plugin marketplace upgrade feedback-harness` 更新 marketplace，在 `/plugins` 中检查插件，并在更新后开始新会话 |
| 由 `init.sh` 复制的 `scripts/` | 更新作为分发源的 feedback-harness 仓库，然后重新运行该仓库中的 `init.sh`。它会替换脚本和 CLAUDE.md / AGENTS.md 的管理区域，同时保留管理标记外的用户内容 |

## Skills / Agents / Commands 的使用方法（插件安装）

从 marketplace 安装后，可以在 Claude Code 和 Codex 中使用 **3 个 Skill**。**2 个 Agent 和 1 个 Command 仅可用于 Claude Code。** 在 Codex 中，`feedback-loop` skill 使用 Codex 的子代理功能。通过 `init.sh` 安装时不包含这些组件，而是通过写入 CLAUDE.md / AGENTS.md 的规则和复制的脚本实现相同流程。

### 各组件的启动方式

| 类型 | 如何启动 | 由谁启动 |
|---|---|---|
| **Skill** | 根据请求内容**自动启动**。如需明确调用，请在请求中指定 skill 名称（例如：“请使用 apply-feedback skill 应用规则。”） | Claude / Codex |
| **Agent** | `feedback-loop` skill 通过环境的子代理功能启动（在 Claude Code 中也使用随插件分发的 Agent 定义） | Skill（**无需直接调用**） |
| **Command** | 输入 `/feedback-harness:init` | 用户 |

**使用插件时，通常不需要执行任何特殊操作。** 每个 Skill 会根据请求内容自动启动。由于 `init.sh` 不会复制 Skills，其工作流改为遵循 CLAUDE.md / AGENTS.md 中添加的规则，并直接执行相应脚本。以下说明仅用于需要明确启动插件 Skill 的情况。

### Skill 1：`apply-feedback` — 工作前应用过去的反馈

**何时启动：** 开始实现、编辑、评审或设计之前；当你要求“应用过去的反馈”“参考上次的反馈”“遵循规则”时，以及要求返工或修正时。

**执行内容：**

1. 读取 `.feedback/rules.md`（两个部分：**失败来源** = 必须遵守的约束；**成功来源** = 应重复采用的有效方式）
2. 通过 `list --status open` 读取尚未转化为规则的 open 条目，避免其在等待整理期间被忽略
3. 找出与当前工作类别相关的规则，并在实现前纳入工作方针
4. 如果规则与当前请求冲突，优先遵循**当前请求**，并告知该冲突，以便重新审视规则

```text
你：重构认证相关代码。
  → apply-feedback 自动启动，并在开始工作前读取 rules.md。
```

### Skill 2：`capture-feedback` — 记录修正和成功模式

**何时启动：** 当你修正或指出成果物的问题、说“请这样做”或“以后这样做”，或修改工作方针时。希望保留有效工作方式时也会启动。

**执行内容：**

1. 用一句话概括反馈
2. 如果反馈涉及失败，则用一行对根因进行分类（`文脈欠落` / `指示欠陥` / `実行誤り` / `モデル限界` / `未判定`）
3. 确定 signal（发生了什么）。对错误输出或行为的修正，无论根因是什么，都属于 `failure`；省略时由 CLI 推断
4. 选择类别，并通过 `feedback_log.py add` 记录条目
5. 当 open 条目达到 3 个或更多时，建议通过 `feedback-loop` 进行整理

```text
你：错误消息请使用日语。以后也这样做。
  → capture-feedback 自动启动，并连同根因一起记录该修正。
```

根因按以下标准判断：

| 根因 | 判断标准 |
|---|---|
| `文脈欠落`（缺少上下文） | 做出判断所需的事实、规则或版本信息不在已加载的上下文中。不包括忽略原本可查阅的信息 |
| `指示欠陥`（指示缺陷） | 预期结果、约束、验收标准或步骤缺失、含糊或相互矛盾，仅靠通常的质量标准无法得出唯一结论。普通缺陷不能仅因为没有明确禁止规则就归入此类 |
| `実行誤り`（执行错误） | 已具备必要上下文和足够明确的指示，但仍发生遗漏、违反指示、推理错误或实现错误。对于单次失败，应优先考虑此分类 |
| `モデル限界`（模型限制） | 即使提供充分上下文、明确指示、可用工具和合理重试，仍无法稳定避免同类失败。不能仅凭一次疏忽作此判断 |
| `未判定`（未判定） | 证据不足，或无法区分多个原因。不要勉强分类，应等待更多信息 |

只记录一行 `根因:`。如果使用未定义的分类，CLI 会拒绝并提示从上述五种分类中重新选择。

### Skill 3：`feedback-loop` — 分派整体流程

**何时启动：** 收到“整理反馈”“转化为规则”“检查工具链”“将其安装到某项目”“盘点规则”“运行情况如何？”或“进行审计”等请求时。

它会根据请求内容自动选择 **Phase**。

| 请求示例 | Phase | 执行内容 |
|---|---|---|
| “整理反馈” / “转化为规则” | 1 | 启动 **feedback-curator agent**，由其决定使用 promote、merge 还是 close |
| “检查工具链” / “进行验证” | 2 | 启动 **harness-qa agent**，在 `_workspace/` 下生成一致性报告 |
| “将此工具链安装到项目 X” | 3 | 运行 `init.sh`，然后在目标项目中运行一次 `check.sh` |
| “盘点规则” / “定期审查” | 4 | 根据 `stats` 将每条规则分类为保留、强化措辞或候选停用 |
| “运行情况如何？” / “首次通过率是多少？” / “复盘议题” | — | 运行 `stats` 或 `report --last`（复盘后使用 `--mark` 推进统计周期） |
| “进行审计” / “检查漏洞” | — | 运行 `audit.sh`（使用网络，因此 Hooks 不会自动运行） |

```text
你：整理积累的反馈并转化为规则。
  → feedback-loop 选择 Phase 1，并启动 feedback-curator。
  → 它会展示规则修改结果和 rules.md 差异，由你决定是否采用。
```

### Agents（通过 Skills 启动）

无需直接调用这些 agents，但了解其职责有助于理解结果。在 Codex 中，会将同名 Markdown 文件作为工作规则读取，并传递给 Codex 子代理。

| Agent | 启动方 | 职责 | 输出 |
|---|---|---|---|
| `feedback-curator` | `feedback-loop` Phase 1（Phase 4 不启动，只使用其判断框架） | 将反馈整理为共享规则。先按 signal 选择反映位置，再按根因进一步处理失败反馈 | `promote`、`merge` 或 `close` 的结果和判断摘要。对 `rules.md` 以外的变更（如追加 CLAUDE.md 或引入 lint）**只提出建议** |
| `harness-qa` | `feedback-loop` Phase 2 | 检查脚本能否运行、Hooks 配置是否正确，以及 CLAUDE.md、AGENTS.md 和 rules.md 是否一致 | 在 `_workspace/qa_report_{日期}.md` 生成 PASS/FAIL/SKIP 报告 |

两个 agent 都**不会自动修改共享文件**。对 `rules.md` 以外的变更只提出建议，由用户决定是否实际应用。

### Command：`/feedback-harness:init`

当 Codex 或其他通用代理与 Claude Code **结合使用**时，此命令会将 `scripts/` 和 AGENTS.md 复制到当前项目。仅使用 Claude Code 时无需执行，因为脚本保留在插件中。

```text
/feedback-harness:init
```

### 验证安装

```text
/plugin                      # Claude Code：确认 feedback-harness 已启用
/plugins                     # Codex：确认 feedback-harness 已安装并启用
/hooks                       # Codex：确认 3 个 Hook 均已受信任
```

响应中显示相应 Skill 的使用标记时，即可确认该 Skill 正在工作。要确认 Hooks 是否运行，请编辑一个文件并检查 `.feedback/events.jsonl` 是否增加了新行。

## 使用方法

### 日常开发（Claude Code / Codex 插件）

检查会自动执行，因此通常**无需手动运行任何内容**。编辑文件时会触发 `check_file.sh`；响应结束前会运行 `check.sh`。检查失败时，结果会自动返回给代理。

以下命令用于在本仓库中工作，或在通过 `init.sh` 复制了 `scripts/` 的项目中手动执行。仅安装插件的目标项目不会复制 `scripts/`，通常应交由 Hooks 处理。

```bash
bash scripts/check.sh                    # 完成前的完整检查（CI 也使用同一命令）
bash scripts/check.sh /path/to/project   # 检查其他项目
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 排除耗时阶段
bash scripts/audit.sh                    # 漏洞审计（使用网络，因此手动执行）
```

### 记录反馈

```bash
# 收到人工反馈时（失败反馈应包含一行根因）
python3 scripts/feedback_log.py add --category style --source human \
  --summary "错误消息使用日语" \
  --detail "指示中没有统一使用日语的要求。根因: 指示欠陥"

# 保留有效工作方式或指示措辞时（省略 signal 时自动判断）
python3 scripts/feedback_log.py add --category workflow --source agent \
  --summary "先确定设计再实现可以避免返工"
```

使用 Claude Code / Codex 插件时，`capture-feedback` skill 会执行相同处理，因此无需直接运行命令。

### 整理积累的反馈

```bash
python3 scripts/feedback_log.py list                    # 列出 open 条目
python3 scripts/feedback_log.py list --signal failure   # 仅显示失败类 signal
python3 scripts/feedback_log.py promote <id> --rule "<一条通用规则>"
python3 scripts/feedback_log.py merge <id> --into <现有规则的来源id>   # 用于复发
python3 scripts/feedback_log.py retire <来源id> --reason "<停用原因>"  # 规则盘点
```

### 测量并共享效果

```bash
python3 scripts/feedback_log.py stats                      # 首次通过率、复发候选、最近审计日期
python3 scripts/feedback_log.py report --since yesterday  # 一项晨会议题
python3 scripts/feedback_log.py report --last --mark       # 复盘后推进下一个统计周期的起点
```

### 环境变量

环境变量是**优先于配置的临时覆盖项**。可用于 CI 或调查期间的一次性调整。应提交到 Git 并由团队共享的设置请写入配置文件。

| 变量 | 默认值 | 效果 |
|---|---|---|
| `FEEDBACK_CHECK_SKIP` | （空） | 以空格分隔要排除的阶段（`lint typecheck test build format security docs contract`） |
| `FEEDBACK_SHELLCHECK_SEVERITY` | `warning` | shellcheck 严重程度阈值；使用 `style` 可执行更严格的检查 |
| `FEEDBACK_CONTRACT_BASE` | `main` | API 契约差异的基线分支 |
| `CLAUDE_PROJECT_DIR` | （自动） | Claude Code 设置的检查目标根目录。Codex 根据 Hook 执行时的当前目录解析 |

### 配置文件

可以提交 `.feedback/config.yaml` 来共享项目设置。它可以配置阶段 skip、FAIL/WARN 行为、排除路径（`exclude`）、日志行数、工具阈值、审计间隔等，而无需使用环境变量。未填写的项目使用默认值。

```bash
cp .feedback/config.example.yaml .feedback/config.yaml   # 从模板开始
bash scripts/check.sh --list-checks           # 不执行检查，仅列出检查 ID、实际判定和来源
bash scripts/check.sh --list-checks --json    # 以机器可读 JSON 输出相同信息
```

优先级为：环境变量 > 单项检查 > 技术栈 > 全局 > 默认值。语法和全部设置请参阅[配置指南](docs/configuration.md)。

## 反馈运作流程

```text
[记录] 人工修正 / 有效工作方式 / 重复出现的检查失败 / 完成前复盘
          → feedback_log.py add   （capture-feedback skill / AGENTS.md 规则）
             失败反馈在 --detail 中包含一行根因：
               文脈欠落 | 指示欠陥 | 実行誤り | モデル限界 | 未判定
             signal（--signal）描述发生的事件：
               错误输出或行为无论根因如何均为 failure；省略时由 CLI 自动判断
                ↓
[open]  ├─ 无需等待转化为规则，在开始下一项工作前读取（apply-feedback skill）
        └─ feedback-curator 根据根因选择反映位置（feedback-loop skill）
             promote → 向 .feedback/rules.md 添加新规则      （主要用于指示缺陷）
             merge   → 合并到现有规则；复发时强化措辞
             close   → 关闭无法通用化的一次性反馈
             建议    → 缺少上下文：向 CLAUDE.md 等添加前提信息
                       执行错误：添加 lint、测试或检查清单
                       模型限制：切换到人工确认或确定性工具（需要复现证据）
                       未判定：保持 open，等待更多信息
                       rules.md 以外的变更仅作为建议，获得人工批准后才应用
                ↓
[应用] .feedback/rules.md → 在下一会话开始工作前应用
                ↓
[盘点] 定期审查（feedback-loop Phase 4）→ 通过 retire 停用过时规则
[测量] feedback_log.py stats         — 首次通过率和复发候选（仅在请求时输出文本）
[报告] feedback_log.py report --last → 五分钟晨会/复盘议题
                                          （之后使用 --mark 推进统计周期）
[审计] bash scripts/audit.sh          — 手动执行的漏洞审计（使用网络）
                                          仅成功时更新 .last-audit，report 会检查其时间
```

记录的反馈无需等待 `promote`，从下一项工作开始就会被查阅。否则，在等待将条目转化为规则期间，同一问题可能再次发生。

测量对应 Feedback Flywheel 中的“测量变化”。本工具链不会创建仪表盘。`stats` 只在请求时输出文本，数值只出现在 `report` 的“数字”部分。`events.jsonl`（Hook 结果）和 `.last-retro`（统计周期标记）都是仅在本机使用的状态文件，不通过 Git 共享。

规则并非唯一的反映位置，因为合适的共享成果物取决于 signal 类型。缺少知识时，应补充 CLAUDE.md 等前提文档。对于能够机械检测的失败，将其加入 lint 或测试，比仅依赖文字规则更可靠。参阅 [Feedback Flywheel](docs/references/fowler-feedback-flywheel-translation.md)。
