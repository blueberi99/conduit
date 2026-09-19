# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repository 'conduit.ps1'
$fixture = Join-Path $repository 'tests\fixtures\Windscribe-Athens-Odeon-WG.conf'
$testContainer = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-integration-' + [Guid]::NewGuid().ToString('N'))
$testRoot = Join-Path $testContainer 'Unicode İsim'
$profileRoot = Join-Path $testRoot 'profiles'
$stateRoot = Join-Path $testRoot 'state'
$squirrelRoot = Join-Path $testRoot 'DiscordCanary'
$appDirectory = Join-Path $squirrelRoot 'app-2.0.1'
$appPath = Join-Path $appDirectory 'TestCanary.exe'
$discordCanaryPath = Join-Path $appDirectory 'DiscordCanary.exe'
$shortcutDirectory = Join-Path $testRoot 'Desktop'
$startMenuDirectory = Join-Path $testRoot 'Start Menu\Programs'
$startupDirectory = Join-Path $testRoot 'Startup'
$stableIconPath = Join-Path $squirrelRoot 'app.ico'
$backendPath = Join-Path $testRoot 'fake-wiresock.exe'
$capturePath = Join-Path $testRoot 'captured.conf'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )
    if (-not $Condition) { throw $Message }
}

$backendSource = @'
using System;
using System.IO;
using System.Threading;

public static class FakeWireSock
{
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "reset-network-lock") return 0;
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "-config")
            {
                string capture = Environment.GetEnvironmentVariable("FAKE_WIRESOCK_CAPTURE");
                if (!String.IsNullOrEmpty(capture)) File.Copy(args[i + 1], capture, true);
            }
        }
        Console.WriteLine("fake tunnel ready");
        while (true) Thread.Sleep(250);
    }
}
'@

$applicationSource = @'
using System.Threading;

public static class FakeApplication
{
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "sleep") Thread.Sleep(30000);
        return 0;
    }
}
'@

try {
    New-Item -ItemType Directory -Path $profileRoot, $appDirectory -Force | Out-Null
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $profileRoot 'Windscribe-Athens-Odeon-WG.conf')
    Add-Type -TypeDefinition $backendSource -Language CSharp -OutputAssembly $backendPath -OutputType ConsoleApplication
    Add-Type -TypeDefinition $applicationSource -Language CSharp -OutputAssembly $appPath -OutputType ConsoleApplication
    Copy-Item -LiteralPath $appPath -Destination $discordCanaryPath
    Copy-Item -LiteralPath $appPath -Destination (Join-Path $squirrelRoot 'Update.exe')
    Add-Type -AssemblyName System.Drawing
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Command powershell.exe).Source)
    $iconStream = [System.IO.File]::Create($stableIconPath)
    try { $icon.Save($iconStream) }
    finally { $iconStream.Dispose(); $icon.Dispose() }

    $env:CONDUIT_DIR = $profileRoot
    $env:CONDUIT_STATE_DIR = $stateRoot
    $env:CONDUIT_WIRESOCK = $backendPath
    $env:CONDUIT_STARTUP_DELAY_MS = '250'
    $env:CONDUIT_NO_TASKKILL = '1'
    $env:CONDUIT_NO_UPDATE_CHECK = '1'
    $env:CONDUIT_DESKTOP_DIR = $shortcutDirectory
    $env:CONDUIT_START_MENU_DIR = $startMenuDirectory
    $env:CONDUIT_STARTUP_DIR = $startupDirectory
    $env:FAKE_WIRESOCK_CAPTURE = $capturePath
    $env:LOCALAPPDATA = $testRoot

    Write-Output 'integration: Discord Canary discovery'
    $shortcutOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        add shortcut discordcanary 2>&1)
    $shortcutExitCode = $LASTEXITCODE
    Assert-True ($shortcutExitCode -eq 0) "Discord Canary discovery failed: $($shortcutOutput -join ' ')"
    Assert-True (Test-Path -LiteralPath (Join-Path $shortcutDirectory 'Conduit - Discord Canary.lnk') -PathType Leaf) `
        'Discord Canary discovery did not create the managed shortcut'

    $startupOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        add startup discordcanary 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "Startup icon setup failed: $($startupOutput -join ' ')"
    # An app update removes the old Discord executable; all shortcut icons
    # must still point at a valid file outside that versioned directory.
    Remove-Item -LiteralPath $discordCanaryPath -Force
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($folder in @($shortcutDirectory, $startMenuDirectory, $startupDirectory)) {
            $link = $shell.CreateShortcut((Join-Path $folder 'Conduit - Discord Canary.lnk'))
            try {
                Assert-True ($link.IconLocation -ceq ($stableIconPath + ',0')) `
                    'shortcut icon still depends on the removed application version'
                Assert-True ($link.Arguments.Contains($scriptPath) -and $link.Arguments.EndsWith(' discordcanary')) `
                    'shortcut lost the Conduit script or dynamic application command'
                $savedIcon = New-Object System.Drawing.Icon($stableIconPath)
                $savedIcon.Dispose()
            }
            finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        }
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }

    Write-Output 'integration: foreground session'
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -f --provider windscribe $appPath 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($exitCode -eq 0) "foreground session failed: $($output -join ' ')"
    Assert-True (Test-Path -LiteralPath $capturePath -PathType Leaf) 'backend did not receive the generated profile'

    $captured = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8
    Assert-True ($captured.Contains("#@ws:AllowedApps = $squirrelRoot")) 'Squirrel app did not use its stable install root'
    Assert-True (-not $captured.Contains("#@ws:AllowedApps = $appPath")) 'versioned executable leaked into AllowedApps'
    Assert-True ($captured.Contains('AllowedIPs = 0.0.0.0/0, ::/0')) 'generated profile does not prevent IPv6 bypass'
    Assert-True ($captured.Contains('Jc = 0')) 'standard WireGuard handshake mode was not pinned'
    Assert-True ($captured.Contains('Address = 100.122.85.109/32, fd54:4::f920:f547:6137:553e/128')) `
        'Windscribe dual-stack interface address was not preserved'
    Assert-True ($captured.Contains('DNS = 10.255.255.2')) 'Windscribe DNS was not preserved'
    Assert-True ($captured.Contains('Endpoint = otp-105-wg.whiskergalaxy.com:443')) `
        'Windscribe endpoint was not preserved'
    Assert-True ($captured.Contains('PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=')) `
        'Windscribe preshared key was not preserved'

    $sourceProfile = Get-Content -LiteralPath (Join-Path $profileRoot 'Windscribe-Athens-Odeon-WG.conf') `
        -Raw -Encoding UTF8
    Assert-True ($sourceProfile -notmatch 'AllowedApps') 'source VPN profile was modified'

    $sessionFile = Get-ChildItem -LiteralPath (Join-Path $stateRoot 'sessions') -Filter 'session.json' -Recurse |
        Select-Object -First 1
    Assert-True ($null -ne $sessionFile) 'session state was not recorded'
    $session = Get-Content -LiteralPath $sessionFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($session.State -eq 'stopped') 'completed foreground session was not marked stopped'
    Assert-True (@($session.ProcessNames) -contains 'Update') 'Squirrel updater process is not tracked'

    Write-Output 'integration: detached session'
    $ErrorActionPreference = 'Continue'
    $detachedOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        --provider windscribe $appPath sleep 2>&1)
    $detachedExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($detachedExitCode -eq 0) "detached session failed: $($detachedOutput -join ' ')"
    Assert-True (($detachedOutput -join ' ') -match 'session ([0-9a-f]{8}) started') 'detached session ID was not reported'
    $detachedId = $Matches[1]

    Write-Output "integration: stopping $detachedId"
    $ErrorActionPreference = 'Continue'
    $killOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        kill $detachedId 2>&1)
    $killExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($killExitCode -eq 0) "kill command failed: $($killOutput -join ' ')"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $stateRoot 'sessions') $detachedId))) `
        'killed session directory was not removed'

    Write-Output 'Conduit Windows integration test passed.'
}
finally {
    Remove-Item Env:CONDUIT_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_DESKTOP_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_START_MENU_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_STARTUP_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testContainer -PathType Container) {
        Remove-Item -LiteralPath $testContainer -Recurse -Force
    }
}
