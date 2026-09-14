# Conduit installer for Windows
# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch] $InstallWireSock,
    [switch] $InstallWireGuard,
    [switch] $BootstrapIfEmpty,
    [switch] $NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Conduit installation requires an Administrator PowerShell.'
}

$sourceDirectory = Split-Path -Parent $PSCommandPath
$installDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Conduit'
$profileDirectory = [Environment]::GetEnvironmentVariable('CONDUIT_DIR')
if ([string]::IsNullOrWhiteSpace($profileDirectory)) {
    $profileDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'vpns'
}

function Test-WireSockInstalled {
    foreach ($commandName in @('wiresock-connect-cli.exe', 'wiresock-client.exe')) {
        if ($null -ne (Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue)) {
            return $true
        }
    }

    foreach ($root in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($relative in @(
            'WireSock Secure Connect\command-line\wiresock-connect-cli.exe',
            'WireSock Secure Connect\wiresock-client.exe',
            'WireSock Secure Connect\bin\wiresock-client.exe',
            'WireSock VPN Client\wiresock-client.exe',
            'WireSock VPN Client\bin\wiresock-client.exe',
            'NT KERNEL\WireSock VPN Client\wiresock-client.exe'
        )) {
            if (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) {
                return $true
            }
        }
    }
    return $false
}

function Test-WireGuardInstalled {
    if ($null -ne (Get-Command 'wg.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        return $true
    }
    foreach ($root in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root 'WireGuard\wg.exe') -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "winget was not found; install $Label manually and retry"
    }
    Write-Output "Installing $Label..."
    & $winget.Source install --id $Id --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "$Label installation failed with exit code $LASTEXITCODE"
    }
}

Write-Output 'Conduit installer for Windows'
Write-Output ''

foreach ($requiredFile in @('conduit.ps1', 'conduit.cmd')) {
    $source = Join-Path $sourceDirectory $requiredFile
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required source file is missing: $source"
    }
}

if ($InstallWireSock -and -not (Test-WireSockInstalled)) {
    Install-WingetPackage -Id 'NTKERNEL.WireSockVPNClient' -Label 'WireSock Secure Connect'
}

$profilesBeforeInstall = @()
if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
    $profilesBeforeInstall = @(Get-ChildItem -LiteralPath $profileDirectory -Filter '*.conf' -File -Recurse -ErrorAction SilentlyContinue)
}
if ($BootstrapIfEmpty -and $profilesBeforeInstall.Count -eq 0) {
    $InstallWireGuard = $true
}
if ($InstallWireGuard -and -not (Test-WireGuardInstalled)) {
    Install-WingetPackage -Id 'WireGuard.WireGuard' -Label 'WireGuard for Windows'
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'conduit.ps1') `
    -Destination (Join-Path $installDirectory 'conduit-main.ps1') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'conduit.cmd') `
    -Destination (Join-Path $installDirectory 'conduit.cmd') -Force
# A public conduit.ps1 shadows conduit.cmd in PowerShell and bypasses the
# wrapper's process-scoped ExecutionPolicy override. Remove it when upgrading
# from Conduit 3.1.1 or older.
Remove-Item -LiteralPath (Join-Path $installDirectory 'conduit.ps1') -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $alreadyPresent = $false
    foreach ($part in $parts) {
        if ($part.TrimEnd('\') -ieq $installDirectory.TrimEnd('\')) {
            $alreadyPresent = $true
            break
        }
    }
    if (-not $alreadyPresent) {
        $newUserPath = (@($parts) + $installDirectory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    }
}

Write-Output "[OK] Installed to $installDirectory"
Write-Output "[OK] Profile directory: $profileDirectory"

if (Test-WireSockInstalled) {
    Write-Output '[OK] WireSock Secure Connect detected'
}
else {
    Write-Warning 'WireSock Secure Connect is not installed. Run this installer again with -InstallWireSock, or run: winget install NTKERNEL.WireSockVPNClient'
}

if ($BootstrapIfEmpty -and $profilesBeforeInstall.Count -eq 0) {
    Write-Output 'No VPN profile was found; creating a Cloudflare WARP profile...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $installDirectory 'conduit-main.ps1') bootstrap
    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare WARP bootstrap failed with exit code $LASTEXITCODE"
    }
}

Write-Output ''
Write-Output 'Open a new PowerShell or Command Prompt, then run:'
Write-Output '  conduit doctor'
Write-Output '  conduit show-vpn'
Write-Output '  conduit discord'
