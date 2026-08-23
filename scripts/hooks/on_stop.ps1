# Native PowerShell Stop hook. Runs the full check only when the tree changed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hookDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDirectory = Split-Path -Parent $hookDirectory
. (Join-Path $scriptDirectory 'lib.ps1')

$inputJson = Read-HarnessHookInput
$active = $false
try { $active = [bool](($inputJson | ConvertFrom-Json).stop_hook_active) } catch { }
if ($active) { exit 0 }

$root = Get-HarnessProjectRoot
$null = Import-HarnessConfig -Root $root -ScriptDirectory $scriptDirectory
$stamp = Join-Path $root '.feedback\.last-check'
if (-not (Test-HarnessTreeChanged -Root $root -Stamp $stamp)) { exit 0 }

$hostCommand = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $hostCommand) { $hostCommand = (Get-Process -Id $PID).Path }
$result = Invoke-HarnessNative $hostCommand @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDirectory 'check.ps1'), $root
)
foreach ($line in $result.Output) {
    if ($line -like 'WARN  *') {
        Write-HarnessWarnEvent -Root $root -Label $line.Substring(6) -ScriptDirectory $scriptDirectory
    }
}
if ($result.ExitCode -eq 0) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $stamp) -Force > $null
    New-Item -ItemType File -Path $stamp -Force > $null
    Write-HarnessEvent -Root $root -Hook stop -Result pass -ScriptDirectory $scriptDirectory
    exit 0
}
Write-HarnessEvent -Root $root -Hook stop -Result fail -ScriptDirectory $scriptDirectory
[Console]::Error.WriteLine($result.Output -join [Environment]::NewLine)
[Console]::Error.WriteLine("HINT: 同種の失敗が繰り返される場合は、修正後に Python 3 `"$scriptDirectory\feedback_log.py`" add --source hook で記録を検討すること")
exit 2
