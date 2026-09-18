# Conduit uninstaller for Windows
# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Conduit removal requires an Administrator PowerShell.'
}

$installDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Conduit'
$stateDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Conduit'
$installedScript = Join-Path $installDirectory 'conduit-main.ps1'
if (-not (Test-Path -LiteralPath $installedScript -PathType Leaf)) {
    $installedScript = Join-Path $installDirectory 'conduit.ps1'
}
$profileDirectory = [Environment]::GetEnvironmentVariable('CONDUIT_DIR')
if ([string]::IsNullOrWhiteSpace($profileDirectory)) {
    $profileDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'vpns'
}

function Remove-ConduitManagedShortcuts {
    $launcher = Join-Path $installDirectory 'conduit.cmd'
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($folderName in @('DesktopDirectory', 'Startup')) {
            $folder = [Environment]::GetFolderPath($folderName)
            if ([string]::IsNullOrWhiteSpace($folder) -or
                -not (Test-Path -LiteralPath $folder -PathType Container)) {
                continue
            }

            foreach ($file in Get-ChildItem -LiteralPath $folder -Filter 'Conduit - *.lnk' -File -ErrorAction SilentlyContinue) {
                $shortcut = $null
                try {
                    $shortcut = $shell.CreateShortcut($file.FullName)
                    if ($shortcut.TargetPath -ieq $launcher) {
                        Remove-Item -LiteralPath $file.FullName -Force
                    }
                }
                catch {
                    Write-Warning "Could not inspect managed shortcut $($file.FullName): $($_.Exception.Message)"
                }
                finally {
                    if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
                        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
                    }
                }
            }
        }
    }
    finally {
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

Write-Output 'Conduit uninstaller for Windows'
Write-Output 'VPN profiles will NOT be deleted.'
Write-Output ''

if (Test-Path -LiteralPath $installedScript -PathType Leaf) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installedScript kill --all
    if ($LASTEXITCODE -ne 0) {
        throw "Could not stop every Conduit session. Run 'conduit kill --all' and retry the uninstaller."
    }
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @($userPath -split ';' | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
        $_.TrimEnd('\') -ine $installDirectory.TrimEnd('\')
})
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')

Remove-ConduitManagedShortcuts

foreach ($name in @('conduit-main.ps1', 'conduit.ps1', 'conduit.cmd')) {
    Remove-Item -LiteralPath (Join-Path $installDirectory $name) -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $installDirectory -PathType Container) {
    $remaining = @(Get-ChildItem -LiteralPath $installDirectory -Force)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $installDirectory -Force
    }
    else {
        Write-Warning "The install directory contains other files and was preserved: $installDirectory"
    }
}

# This directory contains only Conduit-generated runtime configs and logs.
# User WireGuard profiles live elsewhere and are deliberately preserved.
if (Test-Path -LiteralPath $stateDirectory -PathType Container) {
    Remove-Item -LiteralPath $stateDirectory -Recurse -Force
}

Write-Output '[OK] Conduit was removed.'
Write-Output "Preserved VPN profiles: $profileDirectory"
Write-Output 'WireSock Secure Connect was left installed because it may be used by other applications.'
