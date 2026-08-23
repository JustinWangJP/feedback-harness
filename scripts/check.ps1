# check.ps1 — Native Windows/PowerShell implementation of feedback-harness checks.
# It preserves check.sh's PASS/FAIL/WARN/SKIP contract without requiring Bash.

[CmdletBinding(PositionalBinding = $true)]
param(
    [Parameter(Position = 0)][string]$ProjectRoot,
    [switch]$ListChecks,
    [switch]$Json,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'lib.ps1')

function Show-Usage {
    Write-Output '使い方: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1 [プロジェクトルート] [-ListChecks [-Json]]'
    Write-Output ''
    Write-Output '  (引数なし)       プロジェクトを自動検出してフル検査を実行する'
    Write-Output '  -ListChecks       検査を実行せず、実効設定を一覧する'
    Write-Output '  -Json             -ListChecks の出力を JSON にする'
    Write-Output '  -Help             この使い方を表示する'
    Write-Output ''
    Write-Output 'exit 0 = 全PASS(SKIP含む) / 1 = FAILあり / 2 = 引数・環境の誤り'
}

if ($Help) { Show-Usage; exit 0 }
if ($Json -and -not $ListChecks) {
    [Console]::Error.WriteLine('ERROR: -Json は -ListChecks と組み合わせて使います')
    exit 2
}

$root = Get-HarnessProjectRoot $ProjectRoot
if (-not $root) {
    [Console]::Error.WriteLine("ERROR: ディレクトリが見つかりません: $ProjectRoot")
    exit 2
}
Set-Location -LiteralPath $root
$config = Import-HarnessConfig -Root $root -ScriptDirectory $scriptDirectory

$script:Results = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:CheckRows = New-Object System.Collections.Generic.List[object]
$script:Failed = $false
$script:Warned = $false
$script:StackFound = $false
$tailLines = [int](Get-HarnessConfigValue 'check.log_tail_lines' 40)

if ($config.Error) {
    $script:Failed = $true
    $script:Results.Add('FAIL  config: .feedback/config.yaml')
    $script:Failures.Add("----- FAIL: config: .feedback/config.yaml -----`n$($config.Error)")
}

function Add-CheckRow {
    param([string]$Id, [string]$Label, [string]$Stage, [string]$Severity, [string]$Source)
    $script:CheckRows.Add([pscustomobject]@{
        id = $Id; label = $Label; stage = $Stage; severity = $Severity; source = $Source
    })
}

function Add-Skip {
    param([string]$Id, [string]$Stage, [string]$Label, [string]$Reason)
    if ($ListChecks) { Add-CheckRow $Id $Label $Stage 'skip' $Reason }
    else { $script:Results.Add("SKIP  $Label$(if ($Reason) { " ($Reason)" })") }
}

function Add-StageResult {
    param(
        [string]$Stage, [string]$Id, [string]$Label, [string]$DefaultSeverity,
        [int]$ExitCode, [string[]]$Output, [string]$CommandDisplay
    )
    $severity = Get-HarnessCheckSeverity $Id $DefaultSeverity
    if ($ListChecks) {
        Add-CheckRow $Id $Label $Stage $severity (Get-HarnessCheckSource $Id)
        return
    }
    if ($severity -eq 'skip') {
        $source = Get-HarnessCheckSource $Id
        Add-Skip $Id $Stage $Label $(if ($source -eq '既定') { '' } else { $source })
        return
    }
    if ($ExitCode -eq 0) { $script:Results.Add("PASS  $Label"); return }
    if ($ExitCode -in @(126, 127)) { $script:Results.Add("SKIP  $Label (実行不可)"); return }

    $tail = @($Output | Select-Object -Last $tailLines) -join [Environment]::NewLine
    if ($severity -eq 'warn') {
        $script:Warned = $true
        $script:Results.Add("WARN  $Label")
        $script:Warnings.Add("----- WARN: $Label ($CommandDisplay) — 末尾${tailLines}行 -----`n$tail")
    } else {
        $script:Failed = $true
        $script:Results.Add("FAIL  $Label")
        $script:Failures.Add("----- FAIL: $Label ($CommandDisplay) — 末尾${tailLines}行 -----`n$tail")
    }
}

function Invoke-Stage {
    param(
        [string]$Stage, [string]$Id, [string]$Tool, [string]$Label,
        [string]$Command, [string[]]$Arguments = @(), [switch]$Soft
    )
    $defaultSeverity = if ($Soft) { 'warn' } else { 'fail' }
    $severity = Get-HarnessCheckSeverity $Id $defaultSeverity
    if ($ListChecks) {
        $source = Get-HarnessCheckSource $Id
        if ($Tool -ne '-' -and -not (Test-HarnessCommand $Tool)) {
            $severity = 'skip'; $source = "$Tool 未インストールまたは起動不可"
        }
        Add-CheckRow $Id $Label $Stage $severity $source
        return
    }
    if ($severity -eq 'skip') {
        Add-Skip $Id $Stage $Label (Get-HarnessCheckSource $Id)
        return
    }
    if ($Tool -ne '-' -and -not (Test-HarnessCommand $Tool)) {
        Add-Skip $Id $Stage $Label "$Tool 未インストールまたは起動不可"
        return
    }
    $result = Invoke-HarnessNative $Command $Arguments
    Add-StageResult $Stage $Id $Label $defaultSeverity $result.ExitCode $result.Output "$Command $($Arguments -join ' ')"
}

function Invoke-PythonStage {
    param(
        [string]$Stage, [string]$Id, [string]$Label, [string[]]$Arguments,
        [switch]$Soft, [int[]]$SkipExitCodes = @()
    )
    if ($ListChecks) {
        Add-CheckRow $Id $Label $Stage (Get-HarnessCheckSeverity $Id $(if ($Soft) { 'warn' } else { 'fail' })) (Get-HarnessCheckSource $Id)
        return
    }
    $python = Get-HarnessPython
    if ($null -eq $python) { Add-Skip $Id $Stage $Label 'Python 3 未インストール'; return }
    $allArgs = @($python.Prefix) + $Arguments
    $result = Invoke-HarnessNative $python.Command $allArgs
    if ($result.ExitCode -in $SkipExitCodes) { Add-Skip $Id $Stage $Label '検証用Pythonパッケージ未インストール'; return }
    Add-StageResult $Stage $Id $Label $(if ($Soft) { 'warn' } else { 'fail' }) $result.ExitCode $result.Output "$($python.Command) $($allArgs -join ' ')"
}

function Test-PackageScript {
    param([string]$Name)
    try {
        $package = Get-Content -Raw -LiteralPath 'package.json' | ConvertFrom-Json
        return $null -ne $package.scripts -and $null -ne $package.scripts.PSObject.Properties[$Name]
    } catch { return $false }
}

# Python
if ((Test-Path 'pyproject.toml' -PathType Leaf) -or (Test-Path 'setup.py' -PathType Leaf) -or (Test-Path 'requirements.txt' -PathType Leaf)) {
    $script:StackFound = $true
    Invoke-Stage lint ruff ruff 'python: ruff' ruff @('check', '.')
    $ruffConfigured = (Test-Path 'pyproject.toml' -PathType Leaf) -and (Select-String -Path 'pyproject.toml' -Pattern '^\[tool\.ruff' -Quiet)
    Invoke-Stage format 'ruff-format' ruff 'python: ruff format' ruff @('format', '--check', '.') -Soft:(-not $ruffConfigured)
    if ((Test-Path 'pyproject.toml' -PathType Leaf) -and (Select-String -Path 'pyproject.toml' -Pattern '\[tool\.mypy\]' -Quiet)) {
        Invoke-Stage typecheck mypy mypy 'python: mypy' mypy @('.')
    }
    if ((Test-Path 'tests' -PathType Container) -or @(Get-ChildItem -File -Filter 'test_*.py' -ErrorAction SilentlyContinue).Count -gt 0 -or @(Get-ChildItem -File -Filter '*_test.py' -ErrorAction SilentlyContinue).Count -gt 0) {
        $pytestArgs = @('-q', '-x')
        $python = Get-HarnessPython
        if ($python) {
            $probe = Invoke-HarnessNative $python.Command (@($python.Prefix) + @('-c', 'import pytest_cov'))
            if ($probe.ExitCode -eq 0) { $pytestArgs += @('--cov', '--cov-report=term-missing') }
        }
        Invoke-Stage test pytest pytest 'python: pytest' pytest $pytestArgs
    }
    if (Test-HarnessCommand deptry) {
        $configured = (Test-Path 'pyproject.toml' -PathType Leaf) -and (Select-String -Path 'pyproject.toml' -Pattern '^\[tool\.deptry' -Quiet)
        Invoke-Stage lint deptry deptry 'python: deptry' deptry @('.') -Soft:(-not $configured)
    }
    if (Test-HarnessCommand vulture) {
        $configured = (Test-Path '.vulture' -PathType Leaf) -or ((Test-Path 'pyproject.toml' -PathType Leaf) -and (Select-String -Path 'pyproject.toml' -Pattern '^\[tool\.vulture' -Quiet))
        $confidence = [string](Get-HarnessConfigValue 'checks.vulture.min_confidence' 80)
        Invoke-Stage lint vulture vulture 'python: vulture' vulture @('.', '--min-confidence', $confidence) -Soft:(-not $configured)
    }
} else {
    $pythonFiles = @(Get-HarnessFiles '*.py')
    if ($pythonFiles.Count -gt 0) {
        $script:StackFound = $true
        Invoke-Stage lint ruff ruff 'python: ruff' ruff (@('check') + $pythonFiles)
        Invoke-Stage format 'ruff-format' ruff 'python: ruff format' ruff (@('format', '--check') + $pythonFiles) -Soft
    }
}

# Node / TypeScript
if (Test-Path 'package.json' -PathType Leaf) {
    $script:StackFound = $true
    $pm = Get-HarnessNodePackageManager
    if (-not (Test-HarnessCommand node)) {
        Add-Skip 'node-all' test 'node: 全ステージ' 'node 未インストール'
    } else {
        if (Test-PackageScript lint) { Invoke-Stage lint 'node-lint' $pm "node: $pm run lint" $pm @('run', 'lint') }
        if (Test-PackageScript typecheck) { Invoke-Stage typecheck 'node-typecheck' $pm "node: $pm run typecheck" $pm @('run', 'typecheck') }
        elseif (Test-Path 'tsconfig.json' -PathType Leaf) {
            $probe = Invoke-HarnessNative npx @('--no-install', 'tsc', '--version')
            if ($probe.ExitCode -eq 0) { Invoke-Stage typecheck tsc '-' 'node: tsc --noEmit' npx @('--no-install', 'tsc', '--noEmit') }
            else { Add-Skip tsc typecheck 'node: tsc --noEmit' 'typescript 未インストール' }
        }
        if (Test-PackageScript 'test:coverage') { Invoke-Stage test 'node-test-coverage' $pm "node: $pm run test:coverage" $pm @('run', 'test:coverage') }
        elseif (Test-PackageScript test) { Invoke-Stage test 'node-test' $pm "node: $pm test" $pm @('test') }
        if (Test-PackageScript build) { Invoke-Stage build 'node-build' $pm "node: $pm run build" $pm @('run', 'build') }
        if (-not (Test-Path 'node_modules' -PathType Container)) { Add-Skip 'npm-ls' lint 'node: npm ls' 'node_modules 未インストール' }
        elseif ($pm -ne 'npm') { Add-Skip 'npm-ls' lint 'node: npm ls' "$pm は ls --all 非対応" }
        else { Invoke-Stage lint 'npm-ls' npm 'node: npm ls' npm @('ls', '--all') }

        $prettierConfigured = (Test-Path '.prettierrc' -PathType Leaf) -or @(Get-ChildItem -File -Filter '.prettierrc.*' -ErrorAction SilentlyContinue).Count -gt 0 -or @(Get-ChildItem -File -Filter 'prettier.config.*' -ErrorAction SilentlyContinue).Count -gt 0
        if ($prettierConfigured) {
            $probe = Invoke-HarnessNative npx @('--no-install', 'prettier', '--version')
            if ($probe.ExitCode -eq 0) { Invoke-Stage format prettier '-' 'node: prettier' npx @('--no-install', 'prettier', '--check', '.') }
            else { Add-Skip prettier format 'node: prettier' 'prettier 未インストール' }
        }
    }
}

# Go
if (Test-Path 'go.mod' -PathType Leaf) {
    $script:StackFound = $true
    Invoke-Stage lint 'go-vet' go 'go: vet' go @('vet', './...')
    Invoke-Stage build 'go-build' go 'go: build' go @('build', './...')
    Invoke-Stage test 'go-test' go 'go: test' go @('test', '-cover', './...')
    if (Test-Path 'go.sum' -PathType Leaf) { Invoke-Stage lint 'go-mod-verify' go 'go: mod verify' go @('mod', 'verify') }
    $goFiles = @(Get-HarnessFiles '*.go')
    if ($goFiles.Count -gt 0 -and (Test-HarnessCommand gofmt)) {
        if ($ListChecks) { Add-CheckRow gofmt 'go: gofmt' format (Get-HarnessCheckSeverity gofmt fail) (Get-HarnessCheckSource gofmt) }
        else {
            $format = Invoke-HarnessNative gofmt (@('-l') + $goFiles)
            $exit = if ($format.ExitCode -eq 0 -and $format.Output.Count -gt 0) { 1 } else { $format.ExitCode }
            Add-StageResult format gofmt 'go: gofmt' fail $exit $format.Output 'gofmt -l'
        }
    }
}

# Rust
if (Test-Path 'Cargo.toml' -PathType Leaf) {
    $script:StackFound = $true
    if (-not (Test-HarnessCommand cargo)) { Add-Skip 'cargo-all' test 'rust: 全ステージ' 'cargo 未インストール' }
    else {
        $clippy = Invoke-HarnessNative cargo @('clippy', '--version')
        if ($clippy.ExitCode -eq 0) { Invoke-Stage lint clippy '-' 'rust: clippy' cargo @('clippy', '--quiet', '--', '-D', 'warnings') }
        else { Invoke-Stage build 'cargo-check' '-' 'rust: check' cargo @('check', '--quiet') }
        Invoke-Stage test 'cargo-test' '-' 'rust: test' cargo @('test', '--quiet')
        if (Test-Path 'Cargo.lock' -PathType Leaf) { Invoke-Stage lint 'cargo-metadata' '-' 'rust: metadata' cargo @('metadata', '--offline', '--format-version', '1') }
        $configured = (Test-Path 'rustfmt.toml' -PathType Leaf) -or (Test-Path '.rustfmt.toml' -PathType Leaf)
        Invoke-Stage format 'cargo-fmt' '-' 'rust: cargo fmt' cargo @('fmt', '--check') -Soft:(-not $configured)
    }
}

# Java (Windows wrappers use mvnw.cmd / gradlew.bat)
if (Test-Path 'pom.xml' -PathType Leaf) {
    $script:StackFound = $true
    if (Test-Path 'mvnw.cmd' -PathType Leaf) { Invoke-Stage test mvn '-' 'java: mvnw verify' '.\mvnw.cmd' @('-q', 'verify') }
    elseif ((Test-Path 'mvnw' -PathType Leaf) -and (Test-HarnessCommand bash)) { Invoke-Stage test mvn '-' 'java: mvnw verify' bash @('./mvnw', '-q', 'verify') }
    else { Invoke-Stage test mvn mvn 'java: mvn verify' mvn @('-q', 'verify') }
}
if ((Test-Path 'build.gradle' -PathType Leaf) -or (Test-Path 'build.gradle.kts' -PathType Leaf)) {
    $script:StackFound = $true
    if (Test-Path 'gradlew.bat' -PathType Leaf) { Invoke-Stage test gradle '-' 'java: gradlew check' '.\gradlew.bat' @('-q', 'check') }
    else { Invoke-Stage test gradle gradle 'java: gradle check' gradle @('-q', 'check') }
}

# Native PowerShell sources: parser is built in; PSScriptAnalyzer is optional.
$powerShellFiles = @((@(Get-HarnessFiles '*.ps1') + @(Get-HarnessFiles '*.psm1') + @(Get-HarnessFiles '*.psd1')) | Sort-Object -Unique)
if ($powerShellFiles.Count -gt 0) {
    $script:StackFound = $true
    if ($ListChecks) { Add-CheckRow 'powershell-syntax' 'powershell: parser' lint (Get-HarnessCheckSeverity 'powershell-syntax' fail) (Get-HarnessCheckSource 'powershell-syntax') }
    else {
        $syntaxErrors = @($powerShellFiles | ForEach-Object { Test-HarnessPowerShellFile $_ })
        Add-StageResult lint 'powershell-syntax' 'powershell: parser' fail $(if ($syntaxErrors.Count) { 1 } else { 0 }) $syntaxErrors 'PowerShell parser'
    }
    if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
        if ($ListChecks) { Add-CheckRow psscriptanalyzer 'powershell: PSScriptAnalyzer' lint (Get-HarnessCheckSeverity psscriptanalyzer fail) (Get-HarnessCheckSource psscriptanalyzer) }
        else {
            $analysis = @($powerShellFiles | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Severity Error, Warning 2>&1 } | ForEach-Object { $_.ToString() })
            Add-StageResult lint 'psscriptanalyzer' 'powershell: PSScriptAnalyzer' fail $(if ($analysis.Count) { 1 } else { 0 }) $analysis 'Invoke-ScriptAnalyzer'
        }
    } else { Add-Skip psscriptanalyzer lint 'powershell: PSScriptAnalyzer' 'PSScriptAnalyzer 未インストール' }
}

# Shell sources remain checkable when Bash is available, but are never required on Windows.
$shellFiles = @(Get-HarnessFiles '*.sh')
if ($shellFiles.Count -gt 0) {
    $script:StackFound = $true
    if (Test-HarnessCommand bash) {
        foreach ($file in $shellFiles) {
            Invoke-Stage lint 'bash-syntax' '-' "shell: bash -n ($file)" bash @('-n', $file)
        }
    } else { Add-Skip 'bash-syntax' lint 'shell: bash -n' 'bash 未インストール' }
    if (Test-HarnessCommand shellcheck) { Invoke-Stage lint shellcheck shellcheck 'shell: shellcheck' shellcheck (@('-x', '-S', [string](Get-HarnessConfigValue 'checks.shellcheck.min_severity' 'warning')) + $shellFiles) }
    else { Add-Skip shellcheck lint 'shell: shellcheck' 'shellcheck 未インストール' }
}

# Cross-cutting syntax and documentation checks.
$validator = Join-Path $scriptDirectory 'harness_validation.py'
$jsonFiles = @(Get-HarnessFiles '*.json')
if ($jsonFiles.Count -gt 0) { Invoke-PythonStage lint 'json-syntax' 'config: json 構文' (@($validator, 'json') + $jsonFiles) }
$yamlFiles = @((@(Get-HarnessFiles '*.yaml') + @(Get-HarnessFiles '*.yml')) | Sort-Object -Unique)
if ($yamlFiles.Count -gt 0) { Invoke-PythonStage lint 'yaml-syntax' 'config: yaml 構文' (@($validator, 'yaml') + $yamlFiles) -SkipExitCodes @(2) }
$markdownFiles = @(Get-HarnessFiles '*.md')
if ($markdownFiles.Count -gt 0) { Invoke-PythonStage docs 'md-links' 'docs: 内部リンク' (@($validator, 'markdown') + $markdownFiles) }

if ((Test-Path 'Makefile' -PathType Leaf) -and (Select-String -Path 'Makefile' -Pattern '^check:' -Quiet)) {
    $script:StackFound = $true
    if ($env:FEEDBACK_CHECK_RECURSION_GUARD) { Add-Skip 'make-check' test 'make check' '再帰ガード' }
    elseif (Test-HarnessCommand make) {
        $previousGuard = $env:FEEDBACK_CHECK_RECURSION_GUARD
        $env:FEEDBACK_CHECK_RECURSION_GUARD = '1'
        try { Invoke-Stage test 'make-check' make 'make check' make @('check') }
        finally { $env:FEEDBACK_CHECK_RECURSION_GUARD = $previousGuard }
    } else { Add-Skip 'make-check' test 'make check' 'make 未インストール' }
}

if ($ListChecks) {
    if ($Json) { $script:CheckRows | ConvertTo-Json -Depth 4 }
    else { $script:CheckRows | Format-Table id, label, stage, severity, source -AutoSize | Out-String | Write-Output }
    if ($config.Error) {
        [Console]::Error.WriteLine('ERROR: .feedback/config.yaml を読めませんでした。以下はすべて既定値です。')
        [Console]::Error.WriteLine([string]$config.Error)
        exit 1
    }
    exit 0
}

Write-Output '=== feedback-harness check ==='
if (-not $script:StackFound -and $script:Results.Count -eq 0) {
    Write-Output '検出できたスタックがありません (pyproject.toml / package.json / go.mod / Cargo.toml / pom.xml / *.ps1 / *.sh / Makefile:check を確認)'
    exit 0
}
if ($script:Results.Count -eq 0) { Write-Output 'スタックは検出しましたが、実行できるステージがありません'; exit 0 }
$script:Results | Write-Output

if ($script:Warned) {
    Write-Output ''
    Write-Output '以下は完了をブロックしませんが、確認してください:'
    $script:Warnings | Write-Output
}
if ($script:Failed) {
    Write-Output ''
    Write-Output '以下の失敗を修正してから完了とすること:'
    $script:Failures | Write-Output
    exit 1
}

$passed = @($script:Results | Where-Object { $_ -like 'PASS*' }).Count
$skipped = @($script:Results | Where-Object { $_ -like 'SKIP*' }).Count
$warns = @($script:Results | Where-Object { $_ -like 'WARN*' }).Count
if (($passed + $warns) -eq 0) { Write-Output '実行できたステージがありません(すべてSKIP)'; exit 0 }
if ($warns -gt 0 -and $skipped -gt 0) { Write-Output "ALL PASS (${warns}件WARN・${skipped}件SKIP — 未検証/未対応の項目があります)" }
elseif ($warns -gt 0) { Write-Output "ALL PASS (${warns}件WARN — 未対応の指摘があります)" }
elseif ($skipped -gt 0) { Write-Output "ALL PASS (${skipped}件SKIP — 未検証の項目があります)" }
else { Write-Output 'ALL PASS' }
exit 0
