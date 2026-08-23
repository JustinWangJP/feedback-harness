# Native Windows regression tests for the PowerShell distribution path.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Passed++
}

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments = @(), [string]$WorkingDirectory = $repository)
    Push-Location $WorkingDirectory
    try {
        $previousPreference = $ErrorActionPreference
        $previousProjectDirectory = $env:CLAUDE_PROJECT_DIR
        $env:CLAUDE_PROJECT_DIR = $WorkingDirectory
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $ErrorActionPreference = $previousPreference
        $env:CLAUDE_PROJECT_DIR = $previousProjectDirectory
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally { Pop-Location }
}

$check = Join-Path $repository 'scripts\check.ps1'
$checkFile = Join-Path $repository 'scripts\check_file.ps1'
$audit = Join-Path $repository 'scripts\audit.ps1'
$init = Join-Path $repository 'scripts\init.ps1'

foreach ($entry in @($check, $checkFile, $audit, $init)) {
    $result = Invoke-Script $entry @('-Help')
    Assert-True ($result.ExitCode -eq 0) "$entry -Help exits 0"
    Assert-True (($result.Output -join "`n") -match '使い方') "$entry -Help prints usage"
}

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("feedback-harness-ps-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary > $null
try {
    $python = (Get-Command python -ErrorAction Stop).Source
    $feedbackLog = Join-Path $repository 'scripts\feedback_log.py'
    $previousProjectDirectory = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $temporary
    & $python $feedbackLog add --category testing --summary windows-lock --detail windows-lock --source human > $null
    $env:CLAUDE_PROJECT_DIR = $previousProjectDirectory
    Assert-True ($LASTEXITCODE -eq 0) 'feedback_store.py acquires the Windows repository lock'
    Assert-True (Test-Path -LiteralPath (Join-Path $temporary '.feedback\.state.lock') -PathType Leaf) 'feedback_store.py keeps the Windows lock file'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $temporary '.feedback\log') -Filter '*.md').Count -eq 1) 'feedback_log.py writes feedback on Windows'

    $eventJson = '{"hook":"windows-test","result":"pass"}'
    $eventPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($eventJson))
    & $python (Join-Path $repository 'scripts\feedback_store.py') append-event $temporary $eventPayload --base64 --lock-timeout 2
    Assert-True ($LASTEXITCODE -eq 0) 'feedback_store.py accepts PowerShell-safe base64 events'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $temporary '.feedback\events.jsonl')) -match 'windows-test') 'feedback_store.py preserves PowerShell hook events'

    & $python $feedbackLog --help > $null
    Assert-True ($LASTEXITCODE -eq 0) 'feedback_log.py starts on Windows without fcntl'

    $valid = Join-Path $temporary 'valid.ps1'
    $invalid = Join-Path $temporary 'invalid.ps1'
    Set-Content -LiteralPath $valid -Value "param([string]`$Name)`nWrite-Output `$Name" -Encoding utf8
    Set-Content -LiteralPath $invalid -Value "function Broken {`n" -Encoding utf8

    $result = Invoke-Script $checkFile @($valid) $temporary
    Assert-True ($result.ExitCode -eq 0) 'check_file.ps1 accepts valid PowerShell'

    $postEditHook = Join-Path $repository 'scripts\hooks\post_edit.ps1'
    $postEditPayload = @{ tool_input = @{ file_path = $valid } } | ConvertTo-Json -Compress
    $previousProjectDirectory = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $temporary
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $hookOutput = @($postEditPayload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $postEditHook 2>&1)
    $hookExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    $env:CLAUDE_PROJECT_DIR = $previousProjectDirectory
    Assert-True ($hookExitCode -eq 0) 'post_edit.ps1 accepts payloads with omitted optional properties'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $temporary '.feedback\events.jsonl')) -match 'post_edit') 'post_edit.ps1 records a Windows hook event'

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $node) {
        $eventPath = Join-Path $temporary '.feedback\events.jsonl'
        $eventCountBefore = @(Get-Content -LiteralPath $eventPath).Count
        $previousProjectDirectory = $env:CLAUDE_PROJECT_DIR
        $env:CLAUDE_PROJECT_DIR = $temporary
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $dispatcherOutput = @($postEditPayload | & $node.Source (Join-Path $repository 'scripts\hooks\dispatch.cjs') post_edit 2>&1)
        $dispatcherExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        $env:CLAUDE_PROJECT_DIR = $previousProjectDirectory
        $eventCountAfter = @(Get-Content -LiteralPath $eventPath).Count
        Assert-True ($dispatcherExitCode -eq 0) 'dispatch.cjs routes a Windows PostToolUse hook'
        Assert-True ($eventCountAfter -gt $eventCountBefore) 'dispatch.cjs preserves hook stdin on Windows'

        $unicodeFile = Join-Path $temporary '日本語.ps1'
        Set-Content -LiteralPath $unicodeFile -Value 'Write-Output 1' -Encoding utf8
        $unicodeProbe = @'
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const dispatcher = process.argv[1];
const file = process.argv[2];
const root = process.argv[3];
const result = childProcess.spawnSync(process.execPath, [dispatcher, 'post_edit'], {
  input: Buffer.from(JSON.stringify({ tool_input: { file_path: file } }), 'utf8'),
  env: { ...process.env, CLAUDE_PROJECT_DIR: root },
  encoding: 'utf8'
});
const events = fs.readFileSync(path.join(root, '.feedback', 'events.jsonl'), 'utf8');
if (result.status !== 0 || !events.includes(path.basename(file))) {
  process.stderr.write(result.stderr || 'Unicode path was not preserved in events.jsonl');
  process.exit(1);
}
'@
        & $node.Source -e $unicodeProbe (Join-Path $repository 'scripts\hooks\dispatch.cjs') $unicodeFile $temporary
        Assert-True ($LASTEXITCODE -eq 0) 'dispatch.cjs preserves UTF-8 file paths for PowerShell hooks'
    }

    $result = Invoke-Script $checkFile @($invalid) $temporary
    Assert-True ($result.ExitCode -eq 1) 'check_file.ps1 rejects invalid PowerShell'
    Assert-True (($result.Output -join "`n") -match 'line') 'PowerShell parser reports a line number'

    New-Item -ItemType Directory -Path (Join-Path $temporary '.feedback') -Force > $null
    Set-Content -LiteralPath (Join-Path $temporary '.feedback\config.yaml') -Value @(
        'checks:',
        '  powershell-syntax:',
        '    severity: skip'
    ) -Encoding utf8
    $result = Invoke-Script $checkFile @($invalid) $temporary
    Assert-True ($result.ExitCode -eq 0) 'check_file.ps1 honors powershell-syntax severity: skip'

    $target = Join-Path $temporary 'installed-project'
    New-Item -ItemType Directory -Path $target > $null
    Set-Content -LiteralPath (Join-Path $target 'README.md') -Value '# test' -Encoding utf8
    $result = Invoke-Script $init @($target)
    Assert-True ($result.ExitCode -eq 0) 'init.ps1 installs successfully'
    foreach ($file in @('check.ps1', 'check_file.ps1', 'audit.ps1', 'lib.ps1', 'harness_validation.py')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $target "scripts\$file") -PathType Leaf) "init.ps1 copies $file"
    }
    $result = Invoke-Script $init @($target)
    Assert-True ($result.ExitCode -eq 0) 'init.ps1 is idempotent'
    $agents = Get-Content -Raw -LiteralPath (Join-Path $target 'AGENTS.md')
    Assert-True (([regex]::Matches($agents, '<!-- feedback-harness:pointer:start -->')).Count -eq 1) 'init.ps1 keeps one managed pointer block'

    $list = Invoke-Script $check @('-ListChecks', '-Json') $target
    Assert-True ($list.ExitCode -eq 0) 'check.ps1 -ListChecks -Json exits 0'
    $parsed = ($list.Output -join "`n") | ConvertFrom-Json
    Assert-True ($null -ne $parsed) 'check.ps1 emits valid JSON'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "PowerShell tests: ALL PASS ($script:Passed assertions)"
exit 0
