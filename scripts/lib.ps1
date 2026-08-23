# lib.ps1 — PowerShell entry points shared by check.ps1, check_file.ps1, audit.ps1 and hooks.
# Windows PowerShell 5.1 and PowerShell 7+ are supported.  No Bash dependency is required.

Set-StrictMode -Version Latest

$script:HarnessConfig = $null
$script:HarnessPython = $null

function Read-HarnessHookInput {
    # Node sends hook payloads as UTF-8 bytes. Reading through Console.In on
    # Windows PowerShell 5.1 applies the active OEM code page and corrupts paths
    # containing non-ASCII characters, so decode the standard-input bytes here.
    $stream = [Console]::OpenStandardInput()
    $memory = New-Object System.IO.MemoryStream
    try {
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
    if ($bytes.Length -eq 0) { return '' }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $utf8.GetString($bytes)
    } catch {
        return [Console]::InputEncoding.GetString($bytes)
    }
}

function Get-HarnessPython {
    if ($null -ne $script:HarnessPython) { return $script:HarnessPython }

    foreach ($candidate in @(
        @{ Command = 'py'; Prefix = @('-3') },
        @{ Command = 'python'; Prefix = @() },
        @{ Command = 'python3'; Prefix = @() }
    )) {
        if ($null -eq (Get-Command $candidate.Command -ErrorAction SilentlyContinue)) { continue }
        try {
            & $candidate.Command @($candidate.Prefix) -c 'import sys' 2>$null
            if ($LASTEXITCODE -eq 0) {
                $script:HarnessPython = $candidate
                return $candidate
            }
        } catch { }
    }
    return $null
}

function Invoke-HarnessPython {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $python = Get-HarnessPython
    if ($null -eq $python) { throw 'Python 3 が見つかりません' }
    & $python.Command @($python.Prefix) @Arguments
}

function Test-HarnessCommand {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) { return $false }
    try {
        & $Name --version *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-HarnessProjectRoot {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Container)) { return $null }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    if ($env:CLAUDE_PROJECT_DIR -and (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR -PathType Container)) {
        return (Resolve-Path -LiteralPath $env:CLAUDE_PROJECT_DIR).Path
    }
    if (Test-HarnessCommand 'git') {
        $gitRoot = Invoke-HarnessNative git @('rev-parse', '--show-toplevel')
        if ($gitRoot.ExitCode -eq 0 -and $gitRoot.Output.Count -gt 0) {
            return (Resolve-Path -LiteralPath ($gitRoot.Output | Select-Object -First 1)).Path
        }
    }
    return (Get-Location).Path
}

function Import-HarnessConfig {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )
    $fallback = [pscustomobject]@{
        Error = $null
        Values = @{
            'check.exclude' = @(@(), '既定')
            'check.log_tail_lines' = @(40, '既定')
            'checks.shellcheck.min_severity' = @('warning', '既定')
            'checks.vulture.min_confidence' = @(80, '既定')
            'checks.oasdiff.base' = @('main', '既定')
            'audit.interval_days' = @(7, '既定')
            'audit.npm_audit_level' = @('high', '既定')
            'feedback.lock_timeout_seconds' = @(10, '既定')
        }
        Severity = @{}
    }

    $loader = Join-Path $ScriptDirectory 'harness_config.py'
    try {
        if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'harness_config.py がありません' }
        $json = Invoke-HarnessPython $loader --json $Root 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $json.Trim()) { throw '設定ローダーが失敗しました' }
        $raw = $json | ConvertFrom-Json
        $values = @{}
        foreach ($property in $raw.values.PSObject.Properties) {
            $values[$property.Name] = @($property.Value)
        }
        $severity = @{}
        foreach ($property in $raw.severity.PSObject.Properties) {
            $severity[$property.Name] = @($property.Value)
        }
        $script:HarnessConfig = [pscustomobject]@{
            Error = $raw.error
            Values = $values
            Severity = $severity
        }
    } catch {
        $fallback.Error = "設定ローダー(harness_config.py)を起動できませんでした(Python 3 を確認してください)。既定値で続行します: $($_.Exception.Message)"
        $script:HarnessConfig = $fallback
    }
    return $script:HarnessConfig
}

function Get-HarnessConfigValue {
    param([Parameter(Mandatory)][string]$Key, $Default)
    if ($null -ne $script:HarnessConfig -and $script:HarnessConfig.Values.ContainsKey($Key)) {
        return $script:HarnessConfig.Values[$Key][0]
    }
    return $Default
}

function Get-HarnessCheckSeverity {
    param([Parameter(Mandatory)][string]$Id, [string]$Default = 'fail')
    if ($null -ne $script:HarnessConfig -and $script:HarnessConfig.Severity.ContainsKey($Id)) {
        return [string]$script:HarnessConfig.Severity[$Id][0]
    }
    return $Default
}

function Get-HarnessCheckSource {
    param([Parameter(Mandatory)][string]$Id)
    if ($null -ne $script:HarnessConfig -and $script:HarnessConfig.Severity.ContainsKey($Id)) {
        return [string]$script:HarnessConfig.Severity[$Id][1]
    }
    return '既定'
}

function Get-HarnessRelativePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    try {
        $absolute = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
        if ([System.IO.Path]::IsPathRooted($Path)) { $absolute = [System.IO.Path]::GetFullPath($Path) }
        $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($absolute.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $absolute.Substring($rootPath.Length).Replace('\', '/')
        }
    } catch { }
    return $Path.TrimStart('.', '\', '/').Replace('\', '/')
}

function Test-HarnessExcluded {
    param([Parameter(Mandatory)][string]$Path)
    $patterns = @(Get-HarnessConfigValue 'check.exclude' @())
    $normalized = $Path.Replace('\', '/')
    foreach ($pattern in $patterns) {
        if ($normalized -like ([string]$pattern).Replace('\', '/')) { return $true }
    }
    return $false
}

function Get-HarnessNodePackageManager {
    if (Test-Path -LiteralPath 'yarn.lock') { return 'yarn' }
    if (Test-Path -LiteralPath 'pnpm-lock.yaml') { return 'pnpm' }
    return 'npm'
}

function Get-HarnessFiles {
    param([Parameter(Mandatory)][string]$Pattern)
    $paths = @()
    if (Test-HarnessCommand 'git') {
        $inside = Invoke-HarnessNative git @('rev-parse', '--is-inside-work-tree')
        if ($inside.ExitCode -eq 0) {
            $listed = Invoke-HarnessNative git @('-c', 'core.quotePath=false', 'ls-files', '--cached', '--others', '--exclude-standard', $Pattern)
            if ($listed.ExitCode -eq 0) { $paths = @($listed.Output) }
        }
    }
    if ($paths.Count -eq 0) {
        $paths = @(Get-ChildItem -Path . -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|\.venv|venv)[\\/]' } |
            ForEach-Object { Get-HarnessRelativePath $_.FullName (Get-Location).Path })
    }
    return @($paths | Where-Object {
        $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) -and -not (Test-HarnessExcluded $_)
    } | Sort-Object -Unique)
}

function Test-HarnessJsonc {
    param([Parameter(Mandatory)][string]$Path)
    $base = [System.IO.Path]::GetFileName($Path)
    return $base -like 'tsconfig*.json' -or $base -like 'jsconfig*.json' -or
        $base -eq 'devcontainer.json' -or $Path.Replace('\', '/') -match '(^|/)\.vscode/'
}

function Test-HarnessJson {
    param([Parameter(Mandatory)][string[]]$Path)
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($file in $Path) {
        if (Test-HarnessJsonc $file) { continue }
        try { Get-Content -Raw -LiteralPath $file -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop > $null }
        catch { $bad.Add("${file}: $($_.Exception.Message)") }
    }
    return $bad
}

function Test-HarnessPowerShellFile {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return @($errors | ForEach-Object { "${Path}: $($_.Message) (line $($_.Extent.StartLineNumber))" })
}

function Invoke-HarnessNative {
    param([Parameter(Mandatory)][string]$Command, [string[]]$Arguments = @())
    $output = @()
    $exitCode = 0
    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 127
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Write-HarnessEvent {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Hook,
        [Parameter(Mandatory)][string]$Result,
        [string]$File,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )
    try {
        $event = [ordered]@{
            ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            hook = $Hook
            result = $Result
        }
        if ($File) { $event.file = Get-HarnessRelativePath $File $Root }
        $json = $event | ConvertTo-Json -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $timeout = Get-HarnessConfigValue 'feedback.lock_timeout_seconds' 10
        Invoke-HarnessPython (Join-Path $ScriptDirectory 'feedback_store.py') append-event $Root $payload --base64 --lock-timeout $timeout *> $null
    } catch { }
}

function Write-HarnessWarnEvent {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )
    try {
        $event = [ordered]@{
            ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            hook = 'stop'
            result = 'warn'
            check = $Label
        }
        $json = $event | ConvertTo-Json -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $timeout = Get-HarnessConfigValue 'feedback.lock_timeout_seconds' 10
        Invoke-HarnessPython (Join-Path $ScriptDirectory 'feedback_store.py') append-event $Root $payload --base64 --lock-timeout $timeout *> $null
    } catch { }
}

function Test-HarnessTreeChanged {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Stamp)
    if (-not (Test-Path -LiteralPath $Stamp -PathType Leaf)) { return $true }
    try {
        $stampTime = (Get-Item -LiteralPath $Stamp).LastWriteTimeUtc
        $excluded = '[\\/](\.git|\.feedback|_workspace|node_modules|\.venv|venv|__pycache__|\.[^\\/]*_cache)([\\/]|$)'
        $changed = Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.FullName -notmatch $excluded -and $_.LastWriteTimeUtc -gt $stampTime } |
            Select-Object -First 1
        return $null -ne $changed
    } catch {
        return $true
    }
}
