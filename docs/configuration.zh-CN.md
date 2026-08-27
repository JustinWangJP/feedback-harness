[English](configuration.md) | [日本語](configuration.ja.md) | 简体中文

# 配置指南（config.yaml）

工具链的行为可以通过 `.feedback/config.yaml` 调整。这个文件**会提交进仓库**，因此团队所有人都会拿到同一份设置，不再需要拜托每个人「自己 export 一下」。没有写的项目一律使用默认值，不必全部写出来。

复制[模板](../.feedback/config.example.yaml)到 `.feedback/config.yaml` 即可开始：

```bash
cp .feedback/config.example.yaml .feedback/config.yaml
```

### 日常使用流程

```
[引入]   运行一次 check.sh          → 掌握当前失败的项目
   ↓
[调整]   --list-checks              → 查看检查 ID 和当前判定
   ↓     复制 config.example.yaml 到 .feedback/config.yaml
[确认]   --list-checks              → 确认「来源」一列是否变成了 config
   ↓
[共享]   提交 config.yaml           → 团队所有人拿到同一份设置
   ↓
[偿还]   修好之后删除对应行         → 恢复默认值
```

**config 的 diff 本身就是偿还技术债的记录。** 能够删掉 `warn_on: [format]`，就是偿还了那笔债的证据，而 diff 就是记录。正因如此，哪怕是临时的放宽也要写进 config，而不是写在 shell 历史或个人的环境变量里。

## 三分钟上手

先查看当前设置。这条命令不会运行检查本身，因此可以放心使用。

```bash
bash scripts/check.sh --list-checks
```

输出（以本仓库 feedback-harness 自身为例；具体有哪些行取决于项目的技术栈构成和工具安装情况）：

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

**最左边一列就是配置键。** 如果你在意 `ruff-format` 是 `warn`，只需在复制好的 config 里加一行：

```yaml
checks:
  ruff-format:
    severity: fail
```

再次运行 `--list-checks`，判定和**来源**都会改变：

```
ruff-format  python: ruff format  format    fail  checks.ruff-format
```

来源从 `既定`（默认）变成 `checks.ruff-format`，就确认了你写的设置确实生效。这个「写下来 → 用 `--list-checks` 确认来源」的往返，是 config 所有工作的基本形态。

## 按困扰查找

### 引入第一天，既有代码大面积 FAIL

**症状**：引入工具链后 format 或 lint 大量 FAIL，什么都完成不了。

**要写的 YAML**：

```yaml
check:
  warn_on: [format]   # 把 FAIL 降为 WARN。仍然检查，但不阻塞完成
```

**输出会怎样变化**：`--list-checks` 的判定列会从 `fail` 变成 `warn`。`check.sh` 的最后一行变为 `ALL PASS (N件WARN …)`，退出码为 0。WARN 会通过插件的 Hooks 记录到 `events.jsonl`，并出现在 `stats` 的「頻出WARN」中，因此忘记修的地方仍然可见（仅用 `init.sh` 引入、没有 Hooks 的环境不会记录）。

修完之后就把该阶段从 `warn_on` 里去掉。**只有想彻底去掉某项检查时才使用 `skip`** —— `skip` 不会执行检查，坏掉了也无法察觉。`warn_on` 是为了「现在修不了，但希望一直看得见」。

### 想停掉误报很多的检查

**症状**：某项检查（这里是 `vulture`）在这个项目里总是给出没有意义的提示。

**要写的 YAML**：

```yaml
checks:
  vulture:
    severity: skip
```

**输出会怎样变化**：`check.sh` 对应的行变成 `SKIP  python: vulture (config: checks.vulture)`。因为理由中带有 `config: …`，所以能区分是自己停掉的还是默认行为。

也可以按阶段停止（例如 `check.skip: [security]`；可用的值为 `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract`）。不过 `lint` 包含 18 项检查，若想保留语法错误检测（`bash-syntax` / `json-syntax`），请按检查 ID 单独指定。

### monorepo 中各语言情况不同

**症状**：同一个仓库里既有 Python 又有 Node，Python 的 test 太重，而 Node 的 lint 由于历史原因很脏。

**要写的 YAML**：

```yaml
check:
  python:
    skip: [test]
  node:
    warn_on: [lint]
```

**输出会怎样变化**：只有 Python 的 test 阶段被 SKIP，只有 Node 的 lint 组变成 WARN。**不会外溢到其他技术栈**（写了 `check.python.skip` 也不会去掉 Go 的 test）。技术栈共有 `python` / `node` / `go` / `rust` / `java` / `shell` 六种。

### 不想让生成物和 vendor 代码进入视野

**症状**：`vendor/` 下的 shell 脚本或已生成的 Markdown 被 `bash-syntax`、`md-links` 挑出问题。

**要写的 YAML**：

```yaml
check:
  exclude:
    - vendor/**
    - dist/**
```

**输出会怎样变化**：该 glob 会从工具链枚举的检查对象中移除，由这些文件引起的 PASS / FAIL / WARN 行随之消失。

**生效范围（重要）**：`exclude` 只对**工具链自己枚举文件的检查**生效 —— shell 的 `bash -n` / `shellcheck`、config 的 `json-syntax` / `yaml-syntax`、docs 的 `md-links` 等。**对 ruff、pytest、go test 这类自己遍历目录树的工具无效。** 它们各自遵循自身的忽略配置（ruff 的 `exclude` / `per-file-ignores`、pytest 的 `testpaths` / `--ignore` 等）。详见「[不生效时](#不生效时)」。

### 只想改变 CI 的行为

**症状**：日常使用的 config 保持原样，只在 CI 中去掉重的阶段，或把 shellcheck 调严。

**要写的东西**：环境变量。它优先于 config：

```bash
FEEDBACK_CHECK_SKIP="test build" bash scripts/check.sh   # 只在 CI 去掉重的阶段
FEEDBACK_SHELLCHECK_SEVERITY=style bash scripts/check.sh # 只在 CI 调严
```

**输出会怎样变化**：`--list-checks` 的来源会以 `env.` 开头，例如 `env.FEEDBACK_CHECK_SKIP`。**能用环境变量切换的只有这三项**（`FEEDBACK_CHECK_SKIP` / `FEEDBACK_SHELLCHECK_SEVERITY` / `FEEDBACK_CONTRACT_BASE`），没有用环境变量覆盖判定（`severity` / `fail_on` / `warn_on`）的入口。

### 只想让某一项检查绝对阻塞

**症状**：未声明的检查会变成 WARN，但唯独这一项必须 FAIL（例如依赖是否真实存在）。

**要写的 YAML**：

```yaml
checks:
  deptry:
    severity: fail
```

**输出会怎样变化**：`--list-checks` 中从 `warn` 变为 `fail`，来源为 `checks.deptry`。一旦有问题，`check.sh` 会以退出码 1 结束并阻塞完成。

## 优先级

**环境变量 > `checks.<检查>` > `check.<技术栈>` > `check`（全局） > 默认值**

最具体的指定获胜。选择的指导原则：**想提交的设置写进 config，一次性的临时覆盖用环境变量。** 写在 CI workflow 里的环境变量反而会被提交，但那表示的是「CI 这个环境的默认值」。

### 配置文件有两层

| 文件 | 是否追踪 | 用途 |
|---|---|---|
| `.feedback/config.yaml` | 提交并共享 | 团队的设置。让所有人得到相同判定 |
| `.feedback/local/config.yaml` | 已在 `.gitignore` 中 | 仅本机的设置。**优先于共享设置** |

两者能写的项目完全相同。个人设置用于在不修改共享设置的前提下反映本地情况 —— 关掉没在用的工具的检查、临时去掉重的检查等。若想改变团队的判定，请直接修改共享设置。

由个人设置决定的项目，其 `--list-checks` 来源以 `local.` 开头（例如 `local.checks.ruff`），SKIP 的理由显示也不是 `(config: …)` 而是 `(個人設定: …)`。个人设置对他人不可见，这一区分是为了避免「读了共享设置也找不到原因」的局面。

无论哪个文件损坏，都会给出带文件名的错误，检查则以默认值继续进行。

在同一层中，若同一个阶段被写在多个键里，按 `fail_on` > `warn_on` > `skip` 的顺序优先。这是为了不误将检查停用，优先采用更严格的判定。

## 项目参考

供查阅的一章，不必通读。检查 ID 请从 `--list-checks` 最左边一列复制。

**① 全局（`check`）**

| 键 | 类型 | 默认值 | 对应的环境变量 | 效果 |
|---|---|---|---|---|
| `skip` | 阶段列表 | `[]` | `FEEDBACK_CHECK_SKIP` | 跳过指定阶段。词汇为 `lint` / `typecheck` / `test` / `build` / `format` / `security` / `docs` / `contract` |
| `fail_on` | 阶段列表 | `[]` | — | 即便没有声明也判为 FAIL 而非 WARN |
| `warn_on` | 阶段列表 | `[]` | — | 把会 FAIL 的阶段降为 WARN |
| `exclude` | glob 列表 | `[]` | — | 从工具链枚举的文件中排除（生效范围见上文） |
| `log_tail_lines` | 整数 | `40` | — | FAIL / WARN 时输出的日志行数。直接影响 agent 的上下文量 |

**② 按技术栈（`check.<stack>`）**

只有 `skip` / `fail_on` / `warn_on` 三个键。含义与①相同，但只对该技术栈的检查生效。技术栈为 `python` / `node` / `go` / `rust` / `java` / `shell`。

**③ 按检查（`checks.<id>`）**

| 键 | 类型 | 默认值 | 效果 |
|---|---|---|---|
| `severity` | `fail` \| `warn` \| `skip` | 因检查而异（由是否声明决定的默认值） | 该检查的判定。`skip` 表示不执行 |
| 工具专有键 | — | — | 见下表 |

| 检查 ID | 专有键 | 类型 | 默认值 | 对应的环境变量 |
|---|---|---|---|---|
| `shellcheck` | `min_severity` | `style`\|`info`\|`warning`\|`error` | `warning` | `FEEDBACK_SHELLCHECK_SEVERITY` |
| `vulture` | `min_confidence` | 0～100 的整数（越大检出越少） | `80` | — |
| `oasdiff` | `base` | 字符串 | `main` | `FEEDBACK_CONTRACT_BASE` |

**其他小节**

| 键 | 类型 | 默认值 | 效果 |
|---|---|---|---|
| `audit.interval_days` | 整数 | `7` | `stats` / `report` 提示「建议执行审计」前的间隔天数 |
| `audit.npm_audit_level` | 字符串 | `high` | `npm audit --audit-level=<值>`（`low` / `moderate` / `high` / `critical`） |
| `feedback.open_threshold` | 整数 | `3` | `add` / `stats` / `report` 催促 promote 的 open 条目数 |
| `feedback.lock_timeout_seconds` | 整数 | `10` | 多个 agent/session 同时更新时，等待获取 repository lock 的秒数（1～300） |
| `feedback.stale_days` | 整数 | `7` | `stats` / `report` 在高频 WARN、失败排行上标注「已有这么久没有复发」前的天数 |
| `feedback.retro_interval_days` | 整数 | `90` | `stats` / `report` 提示「建议盘点规则」前的间隔天数（基准点为 `.feedback/.last-retro`） |

### 检查 ID 一览（41 项）

不要去背。需要时从 `--list-checks` 最左边一列复制。下表用于把握全貌。

| 技术栈／分组 | 检查 ID |
|---|---|
| python | `ruff` / `ruff-format` / `mypy` / `pytest` / `deptry` / `vulture` / `import-linter` |
| node | `node-lint` / `node-typecheck` / `tsc` / `node-test` / `node-test-coverage` / `node-build` / `npm-ls` / `prettier` / `knip` |
| go | `go-vet` / `go-build` / `go-test` / `go-mod-verify` / `gofmt` |
| rust | `clippy` / `cargo-check` / `cargo-test` / `cargo-metadata` / `cargo-fmt` / `cargo-semver-checks` |
| java | `mvn` / `gradle` |
| shell | `bash-syntax` / `shellcheck` |
| 横向 | `json-syntax` / `yaml-syntax` / `md-links` / `secretlint` / `gitleaks` / `actionlint` / `dockerfilelint` / `hadolint` / `oasdiff` / `make-check` |

`gradle` 同时指 `./gradlew check` 和 `gradle check`（只是启动方式不同，并非两项检查）。

**派生检查 ID（按模块）**

在没有根 `pom.xml` 的 Maven monorepo 中，检测到的每个 `pom.xml` 都拥有独立的检查 ID `mvn-<模块 slug>`（例如 `services/api/pom.xml` → `mvn-services-api`）。slug 只保留小写字母、数字和连字符；当不同模块得到相同 slug 时会追加序号（`mvn-services-api-2`）。实际的 ID 可以在 `--list-checks` 最左边一列确认。

判定按 **该派生 ID 的显式设置 → `mvn` 的设置** 的顺序解析。也就是说 `check.skip: [test]` 和 `checks.mvn.severity: skip` 会作用于所有模块，而 `checks.mvn-tools-cli.severity: skip` 只停止那一个模块。不必为了去掉一个重的模块而整个关闭 Maven 检查。

## 不生效时

### 首先用 `--list-checks` 查看来源

绝大多数「不生效」，都是**判定在与预想不同的层级被决定**的症状。

```bash
bash scripts/check.sh --list-checks
```

- 来源仍是 `既定`（默认）→ config 没有被读取。请查看下面的「损坏的 config」
- 来源是 config 的路径（例如 `check.python.warn_on`）但与期待的键不同（本想写 `check.python.warn_on`，实际生效的是 `check.warn_on`）→ 优先级用错了
- 来源是 `env.<变量名>` → 环境变量仍处于 export 状态。它优先于 config，在 `unset` 之前 config 不会生效

### 损坏的 config 会在表格之后输出到 stderr（设计如此）

当 config 中有拼写错误（未知的键、未知的检查 ID、类型不匹配）时，`--list-checks` 会**以默认值**输出表格，然后向 stderr 输出错误并以退出码 1 结束：

```
$ bash scripts/check.sh --list-checks
検査ID       ラベル               ステージ  判定  出所
（…表格以默认值输出…）

ERROR: .feedback/config.yaml を読めませんでした。以下はすべて既定値です。
.feedback/config.yaml: check.skip の 'lnit' は未知のステージです。使えるのは lint / typecheck / test / build / format / security / docs / contract
```

这比悄悄退回默认值更安全 —— 它会告诉你「设置不生效」的原因正是 config 本身有误。在 `check.sh` 的正常运行中也会出现 `FAIL  config: .feedback/config.yaml`。

### `exclude` 的生效范围

`exclude` 只对**工具链自己枚举文件的检查**（`bash-syntax` / `shellcheck` / `json-syntax` / `yaml-syntax` / `md-links` 等）生效。对 ruff、pytest、go test、vulture 这类**自己遍历目录树的工具无效** —— 它们遵循工具自身的忽略配置（ruff 的 `exclude` / `per-file-ignores`、pytest 的 `testpaths` 等）。工具链不会把配置翻译成各工具的排除语法（各工具语义不同，翻译必然产生偏差）。

### 有些检查不出现在 `--list-checks` 中

`--list-checks` 只显示根据目标项目的构成而成为适用对象的检查。若检查已成为适用对象但工具未安装，不会省略该行，而是显示为 `skip` 并给出理由。反之，若没有配置或没有目标文件，即检查本身的适用条件未满足，则不会显示。例如在没有 import-linter 配置的项目中不会显示 `import-linter`，但如果有配置而只缺工具，则会显示为 `skip`。

若需要通过机器处理获取所有行，可以使用下面的 JSON 输出。

```bash
bash scripts/check.sh --list-checks --json
```

### 仍然搞不清楚时

用 `bash -c '. scripts/lib.sh; harness_python scripts/harness_config.py --json'` 可以输出全部已解析的实际取值。同时请确认是否属于「[YAML 支持与不支持的写法](#yaml-支持与不支持的写法)」中的情况。

## YAML 支持与不支持的写法

config 的 YAML 不依赖 PyYAML，而是由自带的解析器读取（为了不增加可选依赖）。因此**支持的写法是 YAML 的一个子集**。

**支持的写法**：

- 注释（以 `#` 开头，以及值后面的注释）
- 嵌套映射（空格缩进，无深度限制）
- 标量：裸字符串 / `'...'` / `"..."` / 整数 / `true`、`false` / 空（= null）
- 列表：块形式（`- item`）与流形式（`[a, b]`），以及空列表 `[]`

**不支持的写法（会给出带行号和理由的错误）**：

- 锚点与别名（`&` / `*`）
- 多文档（`---` 分隔）
- 多行字符串（`|` / `>`）
- 列表元素的嵌套（元素为映射或列表的列表）
- 制表符缩进

此外，引号（`'` / `"`）或流形式列表（`[`）没有闭合时，同样会给出带行号的错误。这是为了防止损坏的值被当作普通字符串接受，导致后续检查在无意中失效。

如果悄悄忽略不支持的写法，就会造成「写了却不生效」这一最糟糕的状态，因此以上情况一律 FAIL。未知的键（例如 `shelcheck_severity` 这样的拼写错误）出于同样的理由也会报错。
