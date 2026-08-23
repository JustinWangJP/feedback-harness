# check_file.ps1 — Fast native PowerShell check for one edited file.

[CmdletBinding(PositionalBinding = $true)]
param(
    [Parameter(Position = 0)][string]$FilePath,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'lib.ps1')

function Show-Usage {
    Write-Output '使い方: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_file.ps1 <ファイルパス>'
    Write-Output ''
    Write-Output '  <ファイルパス>  検査する単一ファイル(PostToolUse フックが編集直後に渡す)'
    Write-Output '  -Help             この使い方を表示する'
    Write-Output ''
    Write-Output 'exit 0 = 問題なし / 1 = 問題あり。存在しないファイルは削除直後を考慮して exit 0。'
}

if ($Help) { Show-Usage; exit 0 }
if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { exit 0 }

$root = Get-HarnessProjectRoot
$config = Import-HarnessConfig -Root $root -ScriptDirectory $scriptDirectory
if ($config.Error) {
    Write-Output 'check_file: .feedback/config.yaml の設定エラーです:'
    Write-Output $config.Error
    exit 1
}
if (Test-HarnessExcluded (Get-HarnessRelativePath $FilePath $root)) { exit 0 }

$blocking = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Finding {
    param([string]$Severity, [string[]]$Text)
    if (-not $Text -or $Text.Count -eq 0) { return }
    $value = $Text -join [Environment]::NewLine
    if (-not $value.Trim()) { return }
    if ($Severity -eq 'warn') { $warnings.Add($value) }
    else { $blocking.Add($value) }
}

function Invoke-FileCommand {
    param([string]$Id, [string]$Command, [string[]]$Arguments)
    $severity = Get-HarnessCheckSeverity $Id 'fail'
    if ($severity -eq 'skip') { return }
    $result = Invoke-HarnessNative $Command $Arguments
    if ($result.ExitCode -ne 0) { Add-Finding $severity $result.Output }
}

$extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
switch ($extension) {
    '.py' {
        $severity = Get-HarnessCheckSeverity ruff fail
        if ($severity -ne 'skip') {
            if (Test-HarnessCommand ruff) { Invoke-FileCommand ruff ruff @('check', '--output-format=concise', $FilePath) }
            else {
                $python = Get-HarnessPython
                if ($python) {
                    $result = Invoke-HarnessNative $python.Command (@($python.Prefix) + @('-m', 'py_compile', $FilePath))
                    if ($result.ExitCode -ne 0) { Add-Finding $severity $result.Output }
                }
            }
        }
    }
    { $_ -in @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs') } {
        $severity = Get-HarnessCheckSeverity 'node-lint' fail
        if ($severity -ne 'skip') {
            $eslintConfig = (Test-Path '.eslintrc.json' -PathType Leaf) -or
                (Test-Path '.eslintrc.js' -PathType Leaf) -or
                (Test-Path 'eslint.config.js' -PathType Leaf) -or
                (Test-Path 'eslint.config.mjs' -PathType Leaf)
            if ($eslintConfig -and (Test-HarnessCommand npx)) {
                $probe = Invoke-HarnessNative npx @('--no-install', 'eslint', '--version')
                if ($probe.ExitCode -eq 0) { Invoke-FileCommand 'node-lint' npx @('--no-install', 'eslint', '--format', 'unix', $FilePath) }
            } elseif ($_ -in @('.js', '.mjs', '.cjs') -and (Test-HarnessCommand node)) {
                Invoke-FileCommand 'node-lint' node @('--check', $FilePath)
            }
        }
    }
    '.go' {
        $severity = Get-HarnessCheckSeverity gofmt fail
        if ($severity -ne 'skip' -and (Test-HarnessCommand gofmt)) {
            $result = Invoke-HarnessNative gofmt @('-l', $FilePath)
            if ($result.Output.Count -gt 0) { Add-Finding $severity @("gofmt: 未フォーマット: $FilePath (gofmt -w を実行せよ)") }
        }
    }
    '.rs' {
        if (Test-HarnessCommand rustfmt) { Invoke-FileCommand 'cargo-fmt' rustfmt @('--check', $FilePath) }
    }
    { $_ -in @('.ps1', '.psm1', '.psd1') } {
        $severity = Get-HarnessCheckSeverity 'powershell-syntax' fail
        if ($severity -ne 'skip') { Add-Finding $severity @(Test-HarnessPowerShellFile $FilePath) }
        $analyzerSeverity = Get-HarnessCheckSeverity psscriptanalyzer fail
        if ($analyzerSeverity -ne 'skip' -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            $findings = @(Invoke-ScriptAnalyzer -Path $FilePath -Severity Error, Warning 2>&1 | ForEach-Object { $_.ToString() })
            Add-Finding $analyzerSeverity $findings
        }
    }
    '.sh' {
        if (Test-HarnessCommand bash) { Invoke-FileCommand 'bash-syntax' bash @('-n', $FilePath) }
        $severity = Get-HarnessCheckSeverity shellcheck fail
        if ($severity -ne 'skip' -and (Test-HarnessCommand shellcheck)) {
            Invoke-FileCommand shellcheck shellcheck @('-x', '-S', [string](Get-HarnessConfigValue 'checks.shellcheck.min_severity' 'warning'), '-f', 'gcc', $FilePath)
        }
    }
    '.json' {
        $severity = Get-HarnessCheckSeverity 'json-syntax' fail
        if ($severity -ne 'skip' -and -not (Test-HarnessJsonc $FilePath)) {
            $python = Get-HarnessPython
            if ($python) {
                $validator = Join-Path $scriptDirectory 'harness_validation.py'
                $result = Invoke-HarnessNative $python.Command (@($python.Prefix) + @($validator, 'json', $FilePath))
                if ($result.ExitCode -ne 0) { Add-Finding $severity $result.Output }
            }
        }
    }
    { $_ -in @('.yaml', '.yml') } {
        $severity = Get-HarnessCheckSeverity 'yaml-syntax' fail
        if ($severity -ne 'skip') {
            $python = Get-HarnessPython
            if ($python) {
                $validator = Join-Path $scriptDirectory 'harness_validation.py'
                $result = Invoke-HarnessNative $python.Command (@($python.Prefix) + @($validator, 'yaml', $FilePath))
                if ($result.ExitCode -eq 1) { Add-Finding $severity $result.Output }
            }
        }
    }
}

if ($blocking.Count -gt 0) {
    Write-Output "check_file: $FilePath に問題があります:"
    $blocking | Write-Output
    if ($warnings.Count -gt 0) {
        Write-Output ''
        Write-Output '--- 以下は非ブロッキング(WARN) ---'
        $warnings | Write-Output
    }
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Output "check_file: $FilePath に注意点があります(非ブロッキング):"
    $warnings | Write-Output
}
exit 0
