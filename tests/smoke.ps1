# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repository 'conduit.ps1'
$fixtureDirectory = Join-Path $repository 'tests\fixtures'
$stateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-smoke-' + [Guid]::NewGuid().ToString('N'))

function Invoke-TestCommand {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

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
    Assert-True ($version.Output -match '^conduit 3\.2\.0$') 'unexpected version output'

    $help = Invoke-TestCommand @('--help')
    Assert-True ($help.ExitCode -eq 0) 'help command failed'
    Assert-True ($help.Output -match 'isolated per-application VPN sessions for Windows') 'help text is incomplete'
    Assert-True ($help.Output -match 'conduit update') 'help does not list the update command'

    $profiles = Invoke-TestCommand @('show-vpn')
    Assert-True ($profiles.ExitCode -eq 0) 'show-vpn command failed'
    Assert-True ($profiles.Output -match 'cloudflare\\example\.conf') 'nested profile was not discovered'

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
