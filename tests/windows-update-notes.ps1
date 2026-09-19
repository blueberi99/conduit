# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-upgrade-' + [Guid]::NewGuid().ToString('N'))
# Construct Unicode paths independently of Windows PowerShell's script encoding.
$testRoot = Join-Path $testRoot ('user ' + [char]0x130 + [char]0x15F)
$installDirectory = Join-Path $testRoot 'install'
$stateDirectory = Join-Path $testRoot 'state'
$scriptPath = Join-Path $installDirectory 'conduit-main.ps1'
$pendingPath = Join-Path $stateDirectory 'pending-upgrade.json'
$notesPath = Join-Path $installDirectory 'changelog'
$currentVersion = [Version]([System.IO.File]::ReadAllText((Join-Path $repository 'VERSION')).Trim())

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Import-TestFunctions {
    param([string] $Path, [string[]] $Names)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Parse errors in $Path"
    foreach ($name in $Names) {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $false)
        Assert-True ($null -ne $function) "Missing function $name"
        Set-Item -Path "Function:script:$name" -Value ([ScriptBlock]::Create($function.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
}

function Invoke-TestCommand {
    param([AllowEmptyCollection()][string[]] $Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output -join "`n" }
}

function Save-TestUpgrade {
    param([AllowNull()][Version] $Previous, [Version] $Current = $currentVersion)
    Save-ConduitPendingUpgrade -PreviousVersion $Previous -CurrentVersion $Current -StateDirectory $stateDirectory
}

try {
    New-Item -ItemType Directory -Path $installDirectory, $stateDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository 'conduit.ps1') -Destination $scriptPath
    Copy-Item -LiteralPath (Join-Path $repository 'changelog') -Destination $notesPath
    $env:CONDUIT_STATE_DIR = $stateDirectory
    $env:CONDUIT_DIR = Join-Path $repository 'tests\fixtures'
    $env:CONDUIT_NO_UPDATE_CHECK = '1'
    Import-TestFunctions -Path (Join-Path $repository 'install.ps1') -Names @(
        'Get-ConduitScriptVersion', 'Save-ConduitPendingUpgrade'
    )
    Import-TestFunctions -Path (Join-Path $repository 'conduit.ps1') -Names @('Get-ConduitUpgradeNotes')

    Assert-True ((Get-ConduitScriptVersion -Path $scriptPath) -eq $currentVersion) 'Installed version not detected'
    Assert-True ($null -eq (Get-ConduitScriptVersion -Path (Join-Path $testRoot 'missing.ps1'))) 'Missing installation has a version'
    $legacyScript = Join-Path $installDirectory 'conduit.ps1'
    [System.IO.File]::WriteAllText($legacyScript, "`$script:Version = '3.1.1'`r`nthrow 'Must not execute'", [System.Text.Encoding]::UTF8)
    Assert-True ((Get-ConduitScriptVersion -Path $legacyScript) -eq [Version]'3.1.1') 'Old script was not safely inspected'

    Save-TestUpgrade -Previous $null
    $fresh = Invoke-TestCommand @('--help')
    Assert-True ($fresh.ExitCode -eq 0 -and $fresh.Output -notmatch 'Conduit updated:') 'Fresh install announced an upgrade'
    Save-TestUpgrade -Previous $currentVersion
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Same-version reinstall scheduled notes'

    # Upgrade from a release predating this feature, with no last-seen state.
    Save-TestUpgrade -Previous '3.2.5'
    Save-TestUpgrade -Previous $currentVersion
    foreach ($command in @('--version', '-V', 'version')) {
        $versionResult = Invoke-TestCommand @($command)
        Assert-True ($versionResult.ExitCode -eq 0 -and $versionResult.Output -eq "conduit $currentVersion") "Version query $command was polluted: $($versionResult.Output)"
        Assert-True (Test-Path -LiteralPath $pendingPath) 'Version query consumed notes'
    }
    $supervisor = Invoke-TestCommand @('__supervise', 'invalid')
    Assert-True ($supervisor.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Supervisor consumed notes'
    $bootstrap = Invoke-TestCommand @('bootstrap', 'invalid')
    Assert-True ($bootstrap.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Bootstrap consumed notes'
    $update = Invoke-TestCommand @('update', 'invalid')
    Assert-True ($update.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Updater consumed notes'

    $first = Invoke-TestCommand @('--help')
    Assert-True ($first.ExitCode -eq 0 -and $first.Output.Contains("Conduit updated: 3.2.5 -> $currentVersion")) 'Upgrade header missing'
    foreach ($version in @('3.2.6', '3.2.7', '3.2.8', $currentVersion.ToString())) {
        Assert-True ($first.Output.Contains("# Conduit v$version")) "Skipped release $version missing"
    }
    Assert-True ($first.Output -notmatch '# Conduit v3\.2\.[0-5]\b') 'Old release notes leaked into upgrade range'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Notes not marked as shown'
    $second = Invoke-TestCommand @('--help')
    Assert-True ($second.ExitCode -eq 0 -and $second.Output -notmatch 'Conduit updated:') 'Notes displayed twice across processes'
    Save-TestUpgrade -Previous $currentVersion
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Reinstall replayed consumed notes'

    Save-TestUpgrade -Previous '3.2.5' -Current '3.2.7'
    Save-TestUpgrade -Previous '3.2.7'
    $accumulated = [System.IO.File]::ReadAllText($pendingPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ($accumulated.PreviousVersion -eq '3.2.5') 'Consecutive updates dropped unseen notes'
    $empty = Invoke-TestCommand @()
    Assert-True ($empty.ExitCode -eq 1 -and $empty.Output -match 'Conduit updated:' -and $empty.Output -match 'Conduit - isolated') 'Bare command did not show notes and help'

    # Version comparison must be numeric, not lexical; also exclude future notes.
    $numericNotes = "# Conduit v3.2.11`nFuture`n# Conduit v3.2.10`nTen`n# Conduit v3.2.9`nNine`n# Conduit v3.2.8`nEight`n"
    $numericRange = @(Get-ConduitUpgradeNotes -Text $numericNotes -PreviousVersion '3.2.8' -CurrentVersion '3.2.10') -join "`n"
    Assert-True ($numericRange -match 'Ten' -and $numericRange -match 'Nine' -and $numericRange -notmatch 'Future|Eight') 'Version range is not numeric/exclusive/inclusive'

    Save-TestUpgrade -Previous '3.2.5'
    $savedNotes = [System.IO.File]::ReadAllText($notesPath, [System.Text.Encoding]::UTF8)
    Remove-Item -LiteralPath $notesPath
    $missing = Invoke-TestCommand @('--help')
    Assert-True ($missing.ExitCode -eq 0 -and $missing.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Missing notes broke CLI or consumed pending notes'
    [System.IO.File]::WriteAllText($notesPath, 'Malformed changelog', [System.Text.Encoding]::UTF8)
    $malformed = Invoke-TestCommand @('--help')
    Assert-True ($malformed.ExitCode -eq 0 -and $malformed.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Malformed notes broke CLI or consumed pending notes'
    [System.IO.File]::WriteAllText($notesPath, $savedNotes, [System.Text.Encoding]::UTF8)

    $lock = [System.IO.File]::Open((Join-Path $stateDirectory 'upgrade-notes.lock'),
        [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $locked = Invoke-TestCommand @('--help')
        Assert-True ($locked.ExitCode -eq 0 -and $locked.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Busy state lock blocked the command or consumed notes'
    }
    finally { $lock.Dispose() }
    $recovered = Invoke-TestCommand @('--help')
    Assert-True ($recovered.Output -match 'Conduit updated:') 'Pending notes did not recover'

    [System.IO.File]::WriteAllText($pendingPath, '{invalid JSON', [System.Text.Encoding]::UTF8)
    $corrupt = Invoke-TestCommand @('--help')
    Assert-True ($corrupt.ExitCode -eq 0 -and $corrupt.Output -notmatch 'Conduit updated:') 'Corrupt state broke CLI'
    Save-TestUpgrade -Previous '3.2.5'
    Assert-True (([System.IO.File]::ReadAllText($pendingPath) | ConvertFrom-Json).PreviousVersion -eq '3.2.5') 'Installer did not replace corrupt state'
    Save-TestUpgrade -Previous $currentVersion -Current '3.2.5'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Downgrade retained an upgrade announcement'
    Save-TestUpgrade -Previous '3.2.5'
    Save-TestUpgrade -Previous $null
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Fresh install retained stale notes'

    # An older checkout sharing state must not consume the installed version's notes.
    Save-TestUpgrade -Previous $currentVersion -Current ([Version]'99.0.0')
    $mismatch = Invoke-TestCommand @('--help')
    Assert-True ($mismatch.ExitCode -eq 0 -and $mismatch.Output -notmatch 'Conduit updated:' -and (Test-Path -LiteralPath $pendingPath)) 'Different executable version consumed notes'
    Save-TestUpgrade -Previous ([Version]'99.0.0')
    Save-TestUpgrade -Previous '3.2.8'
    $launch = Invoke-TestCommand @('missing.exe')
    Assert-True ($launch.ExitCode -eq 1 -and $launch.Output -match 'Conduit updated:') 'Application invocation did not show notes'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) 'Application invocation did not consume notes'

    Write-Output 'Windows upgrade notes tests passed.'
}
finally {
    # Only remove this test's unique temporary directory, never real user state.
    $cleanupRoot = Split-Path -Parent $testRoot
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([System.IO.Path]::GetFullPath($cleanupRoot).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $cleanupRoot) -match '^conduit-upgrade-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $cleanupRoot)) {
        Remove-Item -LiteralPath $cleanupRoot -Recurse -Force
    }
}
