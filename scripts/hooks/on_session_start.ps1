# Native PowerShell SessionStart hook. Failures never block the session.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$hookDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDirectory = Split-Path -Parent $hookDirectory
. (Join-Path $scriptDirectory 'lib.ps1')

$null = Read-HarnessHookInput
$root = Get-HarnessProjectRoot
if (-not $root) { exit 0 }
$template = Join-Path (Split-Path -Parent $scriptDirectory) '.feedback\rules.template.md'
$feedback = Join-Path $root '.feedback'
New-Item -ItemType Directory -Path (Join-Path $feedback 'log') -Force > $null
$rules = Join-Path $feedback 'rules.md'
if (-not (Test-Path -LiteralPath $rules -PathType Leaf) -and (Test-Path -LiteralPath $template -PathType Leaf)) {
    Copy-Item -LiteralPath $template -Destination $rules -ErrorAction SilentlyContinue
}
exit 0
