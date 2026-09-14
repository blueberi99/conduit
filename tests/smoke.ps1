# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repository 'conduit.ps1'
$fixtureDirectory = Join-Path $repository 'tests\fixtures'
$stateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-smoke-' + [Guid]::NewGuid().ToString('N'))

function Invoke-TestCommand {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output -join "`n"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )
    if (-not $Condition) { throw $Message }
}

try {
    $env:CONDUIT_DIR = $fixtureDirectory
    $env:CONDUIT_STATE_DIR = $stateDirectory

    $version = Invoke-TestCommand @('--version')
    Assert-True ($version.ExitCode -eq 0) 'version command failed'
    Assert-True ($version.Output -match '^conduit 3\.2\.1$') 'unexpected version output'

    $noArguments = Invoke-TestCommand @()
    Assert-True ($noArguments.ExitCode -eq 1) 'empty command should show usage and fail'
    Assert-True ($noArguments.Output -match '^Conduit - isolated') 'empty command did not show usage'
    Assert-True ($noArguments.Output -notmatch 'Cannot bind argument') 'empty command reached application resolution'

    $help = Invoke-TestCommand @('--help')
    Assert-True ($help.ExitCode -eq 0) 'help command failed'
    Assert-True ($help.Output -match 'isolated per-application VPN sessions for Windows') 'help text is incomplete'
    Assert-True ($help.Output -match 'conduit update') 'help does not list the update command'

    $profiles = Invoke-TestCommand @('show-vpn')
    Assert-True ($profiles.ExitCode -eq 0) 'show-vpn command failed'
    Assert-True ($profiles.Output -match 'cloudflare\\example\.conf') 'nested profile was not discovered'
    Assert-True ($profiles.Output -match 'proton\\invalid\.conf \[invalid\]') 'invalid profile was not marked'

    $invalidProfile = Invoke-TestCommand @('--vpn', 'invalid', 'missing.exe')
    Assert-True ($invalidProfile.ExitCode -eq 1) 'invalid profile should be rejected before launch'
    Assert-True ($invalidProfile.Output -match 'PrivateKey is not valid Base64') 'invalid key error is unclear'

    $randomSelection = Invoke-TestCommand @('missing.exe')
    Assert-True ($randomSelection.ExitCode -eq 1) 'missing test application should fail'
    Assert-True ($randomSelection.Output -match 'Ignoring 1 invalid VPN profile') `
        'random selection did not report the ignored invalid profile'
    Assert-True ($randomSelection.Output -match 'application not found') `
        'random selection did not continue with the remaining valid profile'

    $status = Invoke-TestCommand @('status')
    Assert-True ($status.ExitCode -eq 0) 'status command failed'
    Assert-True ($status.Output -match 'no sessions') 'empty status was not reported'

    $env:CONDUIT_INSTALL_URL = 'http://example.invalid/bootstrap.ps1'
    $unsafeUpdate = Invoke-TestCommand @('update')
    Remove-Item Env:CONDUIT_INSTALL_URL
    Assert-True ($unsafeUpdate.ExitCode -eq 1) 'non-HTTPS update URL should fail'
    Assert-True ($unsafeUpdate.Output -match 'absolute HTTPS URL') 'unsafe update URL error is unclear'

    $invalid = Invoke-TestCommand @('--not-an-option')
    Assert-True ($invalid.ExitCode -eq 1) 'invalid option should fail'
    Assert-True ($invalid.Output -match 'unknown option') 'invalid option error is unclear'

    Write-Output 'Conduit Windows smoke tests passed.'
}
finally {
    if (Test-Path -LiteralPath $stateDirectory -PathType Container) {
        Remove-Item -LiteralPath $stateDirectory -Recurse -Force
    }
}
