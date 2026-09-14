# Conduit online installer for Windows
# SPDX-License-Identifier: AGPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryArchive = 'https://github.com/blueberi99/conduit/archive/refs/heads/master.zip'
$archiveOverride = [Environment]::GetEnvironmentVariable('CONDUIT_ARCHIVE_URL')
if (-not [string]::IsNullOrWhiteSpace($archiveOverride)) {
    $repositoryArchive = $archiveOverride
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Conduit installer requires an Administrator PowerShell. Right-click PowerShell and choose Run as administrator.'
}

[Uri]$archiveUri = $null
if (-not [Uri]::TryCreate($repositoryArchive, [UriKind]::Absolute, [ref]$archiveUri) -or
    $archiveUri.Scheme -ne 'https') {
    throw 'CONDUIT_ARCHIVE_URL must be an absolute HTTPS URL'
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$installerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-install-' + [Guid]::NewGuid().ToString('N'))
$installerRootFull = [System.IO.Path]::GetFullPath($installerRoot)
if (-not $installerRootFull.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to use a temporary installer directory outside the Windows temp directory'
}

$previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Path $installerRoot -Force | Out-Null
    $archivePath = Join-Path $installerRoot 'conduit.zip'
    $extractPath = Join-Path $installerRoot 'source'

    Write-Output 'Downloading Conduit...'
    Invoke-WebRequest -UseBasicParsing -Uri $repositoryArchive -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

    $sourceDirectory = Get-ChildItem -LiteralPath $extractPath -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') -PathType Leaf } |
        Select-Object -First 1
    if ($null -eq $sourceDirectory) {
        throw 'The downloaded Conduit archive does not contain install.ps1'
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $sourceDirectory.FullName 'install.ps1') `
        -InstallWireSock -BootstrapIfEmpty
    if ($LASTEXITCODE -ne 0) {
        throw "Conduit installation failed with exit code $LASTEXITCODE"
    }
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    if (Test-Path -LiteralPath $installerRootFull -PathType Container) {
        Remove-Item -LiteralPath $installerRootFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ''
Write-Output 'Conduit installation completed.'
Write-Output 'Open a new PowerShell window and run: conduit discord'
