# Native PowerShell PostToolUse hook for Edit, Write, MultiEdit and apply_patch.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hookDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDirectory = Split-Path -Parent $hookDirectory
. (Join-Path $scriptDirectory 'lib.ps1')

$inputJson = Read-HarnessHookInput
$files = New-Object System.Collections.Generic.List[string]
try {
    $payload = $inputJson | ConvertFrom-Json
    $toolInputProperty = $payload.PSObject.Properties['tool_input']
    $toolInput = if ($null -ne $toolInputProperty) { $toolInputProperty.Value } else { $null }
    if ($null -ne $toolInput) {
        $filePathProperty = $toolInput.PSObject.Properties['file_path']
        if ($null -ne $filePathProperty -and $filePathProperty.Value) {
            $files.Add([string]$filePathProperty.Value)
        }
    }
    $command = ''
    if ($null -ne $toolInput) {
        $commandProperty = $toolInput.PSObject.Properties['command']
        $patchProperty = $toolInput.PSObject.Properties['patch']
        if ($null -ne $commandProperty -and $commandProperty.Value) {
            $command = [string]$commandProperty.Value
        } elseif ($null -ne $patchProperty -and $patchProperty.Value) {
            $command = [string]$patchProperty.Value
        }
    }
    foreach ($line in ($command -split "`r?`n")) {
        if ($line -match '^\*\*\* (?:Add|Update) File: (.+)$') { $files.Add($Matches[1]); continue }
        if ($line -match '^\*\*\* Move to: (.+)$') {
            if ($files.Count -gt 0) { $files[$files.Count - 1] = $Matches[1] }
            else { $files.Add($Matches[1]) }
        }
    }
} catch { exit 0 }

$files = @($files | Where-Object { $_ } | Select-Object -Unique)
if ($files.Count -eq 0) { exit 0 }
$root = Get-HarnessProjectRoot
$failed = $false
$failureOutput = New-Object System.Collections.Generic.List[string]
foreach ($file in $files) {
    $checkPath = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $root $file }
    $result = Invoke-HarnessNative (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDirectory 'check_file.ps1'), $checkPath
    )
    if ($result.ExitCode -eq 0) {
        Write-HarnessEvent -Root $root -Hook post_edit -Result pass -File $checkPath -ScriptDirectory $scriptDirectory
        continue
    }
    Write-HarnessEvent -Root $root -Hook post_edit -Result fail -File $checkPath -ScriptDirectory $scriptDirectory
    $failed = $true
    $failureOutput.Add("[$file]`n$($result.Output -join [Environment]::NewLine)")
}
if ($failed) {
    [Console]::Error.WriteLine($failureOutput -join [Environment]::NewLine)
    [Console]::Error.WriteLine('上記の問題を修正してから作業を続けること。')
    exit 2
}
exit 0
