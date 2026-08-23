# init.ps1 — Install feedback-harness into another project without requiring Bash.

[CmdletBinding(PositionalBinding = $true)]
param(
    [Parameter(Position = 0)][string]$Destination,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path

function Show-Usage {
    Write-Output '使い方: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/init.ps1 <対象プロジェクトパス>'
    Write-Output ''
    Write-Output '  <対象プロジェクトパス>  ハーネスを導入するプロジェクトのディレクトリ'
    Write-Output '  -Help                     この使い方を表示する'
    Write-Output ''
    Write-Output 'Codex IDE 拡張や他の汎用エージェントを併用する場合に実行する。'
    Write-Output 'exit 0 = 導入成功 / 2 = 引数・環境の誤り'
}

if ($Help) { Show-Usage; exit 0 }
if (-not $Destination) { Show-Usage; exit 2 }
if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    [Console]::Error.WriteLine("ERROR: 対象が存在しません: $Destination")
    exit 2
}
$destinationRoot = (Resolve-Path -LiteralPath $Destination).Path
if ($destinationRoot.TrimEnd('\', '/') -eq $sourceRoot.TrimEnd('\', '/')) {
    [Console]::Error.WriteLine('ERROR: 自分自身には導入できません')
    exit 2
}

Write-Output "導入先: $destinationRoot"
$destinationScripts = Join-Path $destinationRoot 'scripts'
$destinationChecks = Join-Path $destinationScripts 'checks'
New-Item -ItemType Directory -Path $destinationChecks -Force > $null

$distributed = @(
    'check.sh', 'check_file.sh', 'lib.sh', 'audit.sh',
    'check.ps1', 'check_file.ps1', 'lib.ps1', 'audit.ps1',
    'harness_config.py', 'harness_validation.py', 'feedback_store.py', 'feedback_log.py',
    'README.md', 'README.ja.md', 'README.zh-CN.md'
)
foreach ($name in $distributed) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\$name") -Destination (Join-Path $destinationScripts $name) -Force
}
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'scripts\checks') -Filter '*.sh' -File |
    Copy-Item -Destination $destinationChecks -Force

# Distributed Python files are maintained and linted in this repository.  Keep a target
# project's ruff configuration from treating vendored copies as application sources.
foreach ($name in @('harness_config.py', 'harness_validation.py', 'feedback_store.py', 'feedback_log.py')) {
    $path = Join-Path $destinationScripts $name
    $lines = @(Get-Content -LiteralPath $path)
    $updated = @($lines[0], '# ruff: noqa -- ハーネス配布ファイル(導入元で管理・検査済み)', '# fmt: off') + $lines[1..($lines.Count - 1)] + '# fmt: on'
    Set-Content -LiteralPath $path -Value $updated -Encoding utf8
}
Write-Output '  scripts/ ... OK (Bash + PowerShell)'
Write-Output '  .claude/ ... スキップ(Claude Code ではプラグインを使ってください)'

$feedback = Join-Path $destinationRoot '.feedback'
New-Item -ItemType Directory -Path (Join-Path $feedback 'log') -Force > $null
Copy-Item -LiteralPath (Join-Path $sourceRoot '.feedback\rules.template.md') -Destination (Join-Path $feedback 'rules.template.md') -Force
if (-not (Test-Path -LiteralPath (Join-Path $feedback 'rules.md') -PathType Leaf)) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.feedback\rules.template.md') -Destination (Join-Path $feedback 'rules.md')
}
Copy-Item -LiteralPath (Join-Path $sourceRoot '.feedback\config.example.yaml') -Destination (Join-Path $feedback 'config.example.yaml') -Force
Write-Output '  .feedback/ ... OK'

function Update-Pointer {
    param([string]$FileName, [string]$Heading, [string]$Fragment, [string]$LegacyEnd)
    $path = Join-Path $destinationRoot $FileName
    $installDate = [DateTime]::Now.ToString('yyyy-MM-dd')
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = Get-Content -Raw -LiteralPath $path
        $dateMatch = [regex]::Match($existing, '(?m)^\| ([0-9]{4}-[0-9]{2}-[0-9]{2}) \| フィードバックハーネス導入')
        if ($dateMatch.Success) { $installDate = $dateMatch.Groups[1].Value }
    }
    $fragmentText = (Get-Content -Raw -LiteralPath (Join-Path $sourceRoot $Fragment)).Replace('{{INSTALL_DATE}}', $installDate).TrimEnd()
    $startMarker = '<!-- feedback-harness:pointer:start -->'
    $endMarker = '<!-- feedback-harness:pointer:end -->'
    $block = "$startMarker`n$fragmentText`n$endMarker`n"

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $projectName = Split-Path -Leaf $destinationRoot
        Set-Content -LiteralPath $path -Value "# $projectName`n`n$block" -Encoding utf8
        Write-Output "  $FileName ... 管理ブロック付きで新規作成"
        return
    }

    $content = Get-Content -Raw -LiteralPath $path
    $startCount = ([regex]::Matches($content, [regex]::Escape($startMarker))).Count
    $endCount = ([regex]::Matches($content, [regex]::Escape($endMarker))).Count
    if ($startCount -gt 0 -or $endCount -gt 0) {
        if ($startCount -ne 1 -or $endCount -ne 1) { throw "${FileName}: 管理マーカーが不整合です" }
        $start = $content.IndexOf($startMarker, [StringComparison]::Ordinal)
        $end = $content.IndexOf($endMarker, $start, [StringComparison]::Ordinal) + $endMarker.Length
        if ($end -lt $content.Length -and $content[$end] -eq "`r") { $end++ }
        if ($end -lt $content.Length -and $content[$end] -eq "`n") { $end++ }
        $content = $content.Substring(0, $start) + $block + $content.Substring($end)
        $action = '管理ブロックを更新'
    } elseif ($content.Contains($Heading)) {
        $headingIndex = $content.IndexOf($Heading, [StringComparison]::Ordinal)
        $start = $content.LastIndexOf("`n", [Math]::Max(0, $headingIndex - 1)) + 1
        $match = [regex]::Match($content.Substring($start), $LegacyEnd, [Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $match.Success) { throw "${FileName}: 旧ポインタの末尾を特定できません" }
        $end = $start + $match.Index + $match.Length
        if ($end -lt $content.Length -and $content[$end] -eq "`r") { $end++ }
        if ($end -lt $content.Length -and $content[$end] -eq "`n") { $end++ }
        $content = $content.Substring(0, $start) + $block + $content.Substring($end)
        $action = '旧ポインタを管理ブロックへ移行'
    } else {
        $separator = if ($content.EndsWith("`n`n")) { '' } elseif ($content.EndsWith("`n")) { "`n" } else { "`n`n" }
        $content += "$separator---`n`n$block"
        $action = '既存ファイルに管理ブロックを追記'
    }
    Set-Content -LiteralPath $path -Value $content -NoNewline -Encoding utf8
    Write-Output "  $FileName ... $action"
}

try {
    Update-Pointer 'CLAUDE.md' '## ハーネス: フィードバックループ' 'docs\pointer_claude.md' '^\*\*ハーネス本体の更新:\*\*.*$'
    Update-Pointer 'AGENTS.md' '## フィードバックハーネス — エージェント作業規約（Codex / 汎用エージェント向け）' 'docs\pointer_agents.md' '^今回の明示的な指示を優先し、矛盾があったことをユーザーに一言伝える。$'
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 2
}

$ignoreEntries = [ordered]@{
    '_workspace/' = 'Harness working area (QAレポート等の中間生成物)'
    '.feedback/.last-check' = 'Stop フックの検査スタンプ(ローカル状態)'
    '.feedback/events.jsonl' = 'フック合否のイベントログ(マシン固有のノイズを共有しない)'
    '.feedback/.last-retro' = '棚卸しの基点(個人の運用リズム)'
    '.feedback/.last-audit' = '脆弱性監査の最終実行日(マシンローカル)'
    '.feedback/.state.lock' = 'feedback CLI のrepository-wide lock(ローカル状態)'
    '.feedback/.transaction.json' = '中断されたfeedback更新の回復journal(ローカル状態)'
    '.feedback/local/' = '個人設定レイヤ(この端末だけの設定。共有設定に勝つ)'
}
$gitignore = Join-Path $destinationRoot '.gitignore'
$existingLines = if (Test-Path -LiteralPath $gitignore) { @(Get-Content -LiteralPath $gitignore) } else { @() }
$added = New-Object System.Collections.Generic.List[string]
foreach ($entry in $ignoreEntries.GetEnumerator()) {
    if ($existingLines -contains $entry.Key) { continue }
    Add-Content -LiteralPath $gitignore -Value @('', "# $($entry.Value)", $entry.Key) -Encoding utf8
    $added.Add($entry.Key)
}
if ($added.Count -eq 0) { Write-Output '  .gitignore ... 記載済みのためスキップ' }
else { Write-Output "  .gitignore ... $($added -join ' ') を追記" }

Write-Output ''
Write-Output "導入完了。動作確認: Set-Location `"$destinationRoot`"; powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1"
Write-Output 'Claude Code を使う場合は、あわせてプラグインを導入してください。'
exit 0
