# audit.ps1 — On-demand vulnerability audit for native Windows/PowerShell.
# Unlike check.ps1 this command may access the network and is never called by Stop hooks.

[CmdletBinding(PositionalBinding = $true)]
param(
    [Parameter(Position = 0)][string]$ProjectRoot,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'lib.ps1')

function Show-Usage {
    Write-Output '使い方: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/audit.ps1 [プロジェクトルート]'
    Write-Output ''
    Write-Output 'ネットワークを使うため Stop フックからは呼ばれない。'
    Write-Output 'exit 0 = 脆弱性なし(または全SKIP) / 1 = 脆弱性あり / 2 = 引数・環境の誤り'
}
if ($Help) { Show-Usage; exit 0 }

$root = Get-HarnessProjectRoot $ProjectRoot
if (-not $root) { [Console]::Error.WriteLine("ERROR: ディレクトリが見つかりません: $ProjectRoot"); exit 2 }
Set-Location -LiteralPath $root
$config = Import-HarnessConfig -Root $root -ScriptDirectory $scriptDirectory

$results = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]
$failed = $false
$passed = 0

function Invoke-Audit {
    param([string]$Tool, [string]$Label, [string]$Command, [string[]]$Arguments = @())
    if (-not (Test-HarnessCommand $Tool)) { $results.Add("SKIP  $Label ($Tool 未インストール)"); return }
    $result = Invoke-HarnessNative $Command $Arguments
    if ($result.ExitCode -eq 0) { $script:passed++; $results.Add("PASS  $Label"); return }
    $script:failed = $true
    $results.Add("FAIL  $Label")
    $tail = @($result.Output | Select-Object -Last 20) -join [Environment]::NewLine
    $failures.Add("----- FAIL: $Label ($Command $($Arguments -join ' ')) -----`n$tail")
}

if ((Test-Path 'pyproject.toml' -PathType Leaf) -or (Test-Path 'requirements.txt' -PathType Leaf) -or
    (Test-Path 'requirements-dev.txt' -PathType Leaf) -or (Test-Path 'poetry.lock' -PathType Leaf) -or
    (Test-Path 'uv.lock' -PathType Leaf)) {
    Invoke-Audit 'pip-audit' 'python: pip-audit' 'pip-audit'
}

if (Test-Path 'package.json' -PathType Leaf) {
    $pm = Get-HarnessNodePackageManager
    if ($pm -eq 'npm') {
        if (Test-Path 'package-lock.json' -PathType Leaf) {
            $level = [string](Get-HarnessConfigValue 'audit.npm_audit_level' 'high')
            Invoke-Audit npm 'node: npm audit' npm @('audit', "--audit-level=$level")
        }
    } else {
        $direct = if ($pm -eq 'pnpm') { 'pnpm audit' } else { 'yarn npm audit' }
        $results.Add("SKIP  node: npm audit ($pm の lockfile — $direct を直接実行してください)")
    }
}
if (Test-Path 'go.sum' -PathType Leaf) { Invoke-Audit govulncheck 'go: govulncheck' govulncheck @('./...') }
if (Test-Path 'Cargo.lock' -PathType Leaf) { Invoke-Audit cargo-audit 'rust: cargo audit' cargo @('audit') }

Write-Output '=== feedback-harness audit ==='
$results | Write-Output
$failures | Write-Output
if ($failed) {
    Write-Output '脆弱性が検出されました。修正してから再実行すること。'
    Write-Output "HINT: 修正後、Python 3 `"$scriptDirectory\feedback_log.py`" add --source hook --category security での記録を検討すること"
    exit 1
}
if ($passed -eq 0) {
    Write-Output '監査対象が見つかりません(依存マニフェスト/lockfile が無い、またはツール未導入)'
    exit 0
}
$state = Join-Path $root '.feedback'
New-Item -ItemType Directory -Path $state -Force > $null
[DateTime]::Now.ToString('yyyy-MM-dd') | Set-Content -LiteralPath (Join-Path $state '.last-audit') -Encoding utf8
Write-Output 'ALL PASS (監査OK — .feedback/.last-audit を更新)'
exit 0
