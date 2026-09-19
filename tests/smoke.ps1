# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repository 'conduit.ps1'
$versionPath = Join-Path $repository 'VERSION'
$fixtureDirectory = Join-Path $repository 'tests\fixtures'
$stateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-smoke-' + [Guid]::NewGuid().ToString('N'))
$desktopDirectory = Join-Path $stateDirectory 'Desktop'
$startMenuDirectory = Join-Path $stateDirectory 'Start Menu\Programs'
$startupDirectory = Join-Path $stateDirectory 'Startup'

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
    $env:CONDUIT_NO_UPDATE_CHECK = '1'
    $env:CONDUIT_DESKTOP_DIR = $desktopDirectory
    $env:CONDUIT_START_MENU_DIR = $startMenuDirectory
    $env:CONDUIT_STARTUP_DIR = $startupDirectory

    $version = Invoke-TestCommand @('--version')
    Assert-True ($version.ExitCode -eq 0) 'version command failed'
    Assert-True ($version.Output -match '^conduit 3\.2\.8$') 'unexpected version output'
    Assert-True ((Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim() -eq '3.2.8') `
        'VERSION does not match conduit.ps1'

    $noArguments = Invoke-TestCommand @()
    Assert-True ($noArguments.ExitCode -eq 1) 'empty command should show usage and fail'
    Assert-True ($noArguments.Output -match '^Conduit - isolated') 'empty command did not show usage'
    Assert-True ($noArguments.Output -notmatch 'Cannot bind argument') 'empty command reached application resolution'

    $help = Invoke-TestCommand @('--help')
    Assert-True ($help.ExitCode -eq 0) 'help command failed'
    Assert-True ($help.Output -match 'isolated per-application VPN sessions for Windows') 'help text is incomplete'
    Assert-True ($help.Output -match 'conduit update') 'help does not list the update command'
    Assert-True ($help.Output -match 'conduit add shortcut <application>') `
        'help does not list managed shortcuts'
    Assert-True ($help.Output -match 'both Desktop and Start Menu') 'help does not explain Start Menu shortcuts'

    # Simulate the Windows folder API returning an empty result for a missing
    # redirected directory. Substitute only this external API in the actual
    # function; never change the current user's Known Folder registry values.
    Add-Type -TypeDefinition @'
using System;
public static class ConduitFolderTestEnvironment {
    public static string Folder;
    public static string GetEnvironmentVariable(string name) { return null; }
    public static string GetFolderPath(string name) { return ""; }
    public static string GetFolderPath(string name, Environment.SpecialFolderOption option) {
        return option == Environment.SpecialFolderOption.DoNotVerify ? Folder : "";
    }
    public static string ExpandEnvironmentVariables(string value) {
        return Environment.ExpandEnvironmentVariables(value);
    }
}
'@
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    $folderFunction = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-ConduitShortcutDirectory'
    }, $true)
    $desktopDirectory = Join-Path $stateDirectory ('Redirected ' + [char]0x130 + 'sim\Desktop')
    & {
        . ([ScriptBlock]::Create($folderFunction.Extent.Text.Replace('[Environment]', '[ConduitFolderTestEnvironment]')))
        [ConduitFolderTestEnvironment]::Folder = $desktopDirectory
        Assert-True ((Get-ConduitShortcutDirectory -Kind shortcut) -ceq $desktopDirectory) `
            'missing redirected desktop path was lost'
        Assert-True (-not (Test-Path -LiteralPath $desktopDirectory)) `
            'looking up a missing directory unexpectedly created it'
        [ConduitFolderTestEnvironment]::Folder = $startupDirectory
        Assert-True ((Get-ConduitShortcutDirectory -Kind startup) -ceq $startupDirectory) `
            'missing startup path was lost'
        [ConduitFolderTestEnvironment]::Folder = $startMenuDirectory
        Assert-True ((Get-ConduitShortcutDirectory -Kind start-menu) -ceq $startMenuDirectory) `
            'missing Start Menu path was lost'
        # Exercise the fallback when the Windows folder API cannot return a path.
        function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction)
            return [pscustomobject]@{ Desktop = $desktopDirectory; Programs = $startMenuDirectory; Startup = $startupDirectory }
        }
        [ConduitFolderTestEnvironment]::Folder = ''
        Assert-True ((Get-ConduitShortcutDirectory -Kind shortcut) -ceq $desktopDirectory) `
            'configured registry desktop fallback was lost'
        Assert-True ((Get-ConduitShortcutDirectory -Kind start-menu) -ceq $startMenuDirectory) `
            'configured registry Start Menu fallback was lost'
    }
    $desktopDirectory = Join-Path $stateDirectory 'Redirected Desktop\Desktop'
    $env:CONDUIT_DESKTOP_DIR = $desktopDirectory
    $addMissingDesktop = Invoke-TestCommand @('add', 'shortcut', 'powershell.exe')
    Assert-True ($addMissingDesktop.ExitCode -eq 0) "missing desktop creation failed: $($addMissingDesktop.Output)"
    Assert-True (Test-Path -LiteralPath $desktopDirectory -PathType Container) `
        'adding a shortcut did not create the missing desktop directory'
    Assert-True (Test-Path -LiteralPath $startMenuDirectory -PathType Container) `
        'adding a shortcut did not create the missing Start Menu directory'
    $realDiscordShortcut = Join-Path $desktopDirectory 'Discord.lnk'
    [System.IO.File]::WriteAllText($realDiscordShortcut, 'unrelated Discord shortcut', [System.Text.Encoding]::UTF8)
    $originalStartMenuLink = Join-Path $startMenuDirectory 'Discord.lnk'
    [System.IO.File]::WriteAllText($originalStartMenuLink, 'original Start Menu shortcut', [System.Text.Encoding]::UTF8)

    $addShortcut = Invoke-TestCommand @('add', 'shortcut', 'powershell.exe')
    Assert-True ($addShortcut.ExitCode -eq 0) "desktop shortcut creation failed: $($addShortcut.Output)"
    $managedDesktopShortcut = Join-Path $desktopDirectory 'Conduit - Powershell.lnk'
    $managedStartMenuShortcut = Join-Path $startMenuDirectory 'Conduit - Powershell.lnk'
    Assert-True (Test-Path -LiteralPath $managedDesktopShortcut -PathType Leaf) `
        'managed desktop shortcut was not created'
    Assert-True (Test-Path -LiteralPath $managedStartMenuShortcut -PathType Leaf) `
        'managed Start Menu shortcut was not created'
    Assert-True ((Get-Content -LiteralPath $realDiscordShortcut -Raw -Encoding UTF8) -eq 'unrelated Discord shortcut') `
        'unrelated Discord shortcut was modified'

    $shortcutShell = New-Object -ComObject WScript.Shell
    $desktopLink = $null
    try {
        foreach ($linkPath in @($managedDesktopShortcut, $managedStartMenuShortcut)) {
            $desktopLink = $shortcutShell.CreateShortcut($linkPath)
            Assert-True ([System.IO.Path]::GetFileName($desktopLink.TargetPath) -ieq 'powershell.exe') `
                'shortcut does not target a native executable recognized by Start'
            Assert-True ($desktopLink.Arguments -match '^-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' -and
                $desktopLink.Arguments.Contains($scriptPath) -and $desktopLink.Arguments.EndsWith(' powershell.exe')) `
                'shortcut does not launch Conduit with the requested application'
            Assert-True ($desktopLink.IconLocation -ieq ((Get-Command powershell.exe).Source + ',0')) `
                'shortcut does not use the application executable icon'
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($desktopLink)
            $desktopLink = $null
        }
    }
    finally {
        if ($null -ne $desktopLink -and [Runtime.InteropServices.Marshal]::IsComObject($desktopLink)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($desktopLink)
        }
        if ([Runtime.InteropServices.Marshal]::IsComObject($shortcutShell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcutShell)
        }
    }

    $replaceShortcut = Invoke-TestCommand @('add', 'shortcut', 'powershell.exe')
    Assert-True ($replaceShortcut.ExitCode -eq 0) 'existing desktop shortcut replacement failed'
    Assert-True ($replaceShortcut.Output -match '^Replaced Conduit shortcut') `
        'existing desktop shortcut was not reported as replaced'
    Assert-True (@(Get-ChildItem -LiteralPath $startMenuDirectory -Filter 'Conduit - *.lnk').Count -eq 1) `
        're-adding duplicated the Start Menu entry'

    $addStartup = Invoke-TestCommand @('add', 'startup', 'powershell.exe')
    Assert-True ($addStartup.ExitCode -eq 0) "startup shortcut creation failed: $($addStartup.Output)"
    $managedStartupShortcut = Join-Path $startupDirectory 'Conduit - Powershell.lnk'
    Assert-True (Test-Path -LiteralPath $managedStartupShortcut -PathType Leaf) `
        'managed startup shortcut was not created'

    $removeStartup = Invoke-TestCommand @('remove', 'startup', 'powershell.exe')
    Assert-True ($removeStartup.ExitCode -eq 0) 'startup shortcut removal failed'
    Assert-True (-not (Test-Path -LiteralPath $managedStartupShortcut)) `
        'managed startup shortcut was not removed'
    Assert-True ((Test-Path -LiteralPath $managedStartMenuShortcut) -and (Test-Path -LiteralPath $managedDesktopShortcut)) `
        'removing startup removed the desktop or Start Menu shortcut'
    $removeMissingStartup = Invoke-TestCommand @('remove', 'startup', 'powershell.exe')
    Assert-True ($removeMissingStartup.ExitCode -eq 0) 'removing an absent startup shortcut should be harmless'

    $removeShortcut = Invoke-TestCommand @('remove', 'shortcut', 'powershell.exe')
    Assert-True ($removeShortcut.ExitCode -eq 0) 'desktop shortcut removal failed'
    Assert-True (-not (Test-Path -LiteralPath $managedDesktopShortcut)) `
        'managed desktop shortcut was not removed'
    Assert-True (-not (Test-Path -LiteralPath $managedStartMenuShortcut)) `
        'managed Start Menu shortcut was not removed'
    Assert-True (Test-Path -LiteralPath $realDiscordShortcut -PathType Leaf) `
        'removing a Conduit shortcut removed the unrelated Discord shortcut'
    Assert-True ((Get-Content -LiteralPath $originalStartMenuLink -Raw -Encoding UTF8) -eq 'original Start Menu shortcut') `
        'original Start Menu shortcut was changed'

    $startupOnly = Invoke-TestCommand @('add', 'startup', 'powershell.exe')
    Assert-True ($startupOnly.ExitCode -eq 0) 'startup-only setup failed'
    Assert-True (-not (Test-Path -LiteralPath $managedDesktopShortcut) -and -not (Test-Path -LiteralPath $managedStartMenuShortcut)) `
        'adding startup unexpectedly created desktop or Start Menu shortcuts'
    $readded = Invoke-TestCommand @('add', 'shortcut', 'powershell.exe')
    Assert-True ($readded.ExitCode -eq 0) 'shortcut recreation failed'
    Remove-Item -LiteralPath $managedDesktopShortcut -Force
    $removePartial = Invoke-TestCommand @('remove', 'shortcut', 'powershell.exe')
    Assert-True ($removePartial.ExitCode -eq 0) 'removal failed when desktop link was already missing'
    Assert-True (-not (Test-Path -LiteralPath $managedStartMenuShortcut)) `
        'missing desktop link prevented Start Menu removal'
    Assert-True (Test-Path -LiteralPath $managedStartupShortcut) `
        'removing shortcuts also removed the independent startup link'

    # Test only the uninstaller's link-cleanup function in temporary folders.
    # The full uninstaller must never run against the developer's installation.
    $uninstallTokens = $null
    $uninstallErrors = $null
    $uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository 'uninstall.ps1'), [ref]$uninstallTokens, [ref]$uninstallErrors
    )
    $cleanupFunction = $uninstallAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Remove-ConduitManagedShortcuts'
    }, $true)
    Add-Type -TypeDefinition @'
using System;
public static class ConduitCleanupTestEnvironment {
    public static string Desktop, Programs, Startup;
    public static string GetFolderPath(string name) {
        if (name == "DesktopDirectory") return Desktop;
        if (name == "Programs") return Programs;
        if (name == "Startup") return Startup;
        return Environment.GetFolderPath(Environment.SpecialFolder.System);
    }
}
'@
    [ConduitCleanupTestEnvironment]::Desktop = $desktopDirectory
    [ConduitCleanupTestEnvironment]::Programs = $startMenuDirectory
    [ConduitCleanupTestEnvironment]::Startup = $startupDirectory
    $cleanupAdd = Invoke-TestCommand @('add', 'shortcut', 'powershell.exe')
    Assert-True ($cleanupAdd.ExitCode -eq 0) 'uninstaller test setup failed'
    $cleanupShell = New-Object -ComObject WScript.Shell
    $unrelatedLinkPath = Join-Path $startMenuDirectory 'Conduit - Unrelated.lnk'
    $legacyLinkPath = Join-Path $startMenuDirectory 'Conduit - Legacy.lnk'
    try {
        $otherLink = $cleanupShell.CreateShortcut($unrelatedLinkPath)
        $otherLink.TargetPath = (Get-Command powershell.exe).Source
        $otherLink.Arguments = '-NoProfile -File "C:\some-other-app.ps1"'
        $otherLink.Save()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($otherLink)
        $legacyLink = $cleanupShell.CreateShortcut($legacyLinkPath)
        $legacyLink.TargetPath = Join-Path $repository 'conduit.cmd'
        $legacyLink.Arguments = 'powershell.exe'
        $legacyLink.Save()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($legacyLink)
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($cleanupShell) }
    & {
        $installDirectory = $repository
        $installedScript = $scriptPath
        . ([ScriptBlock]::Create($cleanupFunction.Extent.Text.Replace('[Environment]', '[ConduitCleanupTestEnvironment]')))
        Remove-ConduitManagedShortcuts
    }
    foreach ($managedPath in @($managedDesktopShortcut, $managedStartMenuShortcut, $managedStartupShortcut, $legacyLinkPath)) {
        Assert-True (-not (Test-Path -LiteralPath $managedPath)) "uninstaller left a managed link: $managedPath"
    }
    Assert-True (Test-Path -LiteralPath $unrelatedLinkPath) 'uninstaller removed a shortcut for another script'
    Assert-True ((Get-Content -LiteralPath $originalStartMenuLink -Raw -Encoding UTF8) -eq 'original Start Menu shortcut') `
        'uninstaller changed the original application shortcut'

    $unsafeShortcut = Invoke-TestCommand @('add', 'shortcut', 'discord&calc')
    Assert-True ($unsafeShortcut.ExitCode -eq 1) 'unsafe shortcut application name should fail'
    Assert-True ($unsafeShortcut.Output -match 'must be a command name') `
        'unsafe shortcut application error is unclear'

    $latestVersionPath = Join-Path $stateDirectory 'latest-version'
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText($latestVersionPath, '99.0.0', [System.Text.Encoding]::UTF8)
    $env:CONDUIT_VERSION_URL = ([Uri]$latestVersionPath).AbsoluteUri
    Remove-Item Env:CONDUIT_NO_UPDATE_CHECK
    $updateNotice = Invoke-TestCommand @('missing.exe')
    Assert-True ($updateNotice.ExitCode -eq 1) 'notice test should still reach application resolution'
    Assert-True ($updateNotice.Output -match "Conduit 99\.0\.0 is available.*conduit update") `
        'newer published version did not produce an update notice'

    $env:CONDUIT_NO_UPDATE_CHECK = '1'
    $disabledNotice = Invoke-TestCommand @('missing.exe')
    Assert-True ($disabledNotice.Output -notmatch 'is available') 'disabled update check still produced a notice'

    Remove-Item Env:CONDUIT_NO_UPDATE_CHECK
    [System.IO.File]::WriteAllText($latestVersionPath, '3.2.8', [System.Text.Encoding]::UTF8)
    $currentNotice = Invoke-TestCommand @('missing.exe')
    Assert-True ($currentNotice.Output -notmatch 'is available') 'current version produced an update notice'

    $env:CONDUIT_VERSION_URL = ([Uri](Join-Path $stateDirectory 'unreachable-version')).AbsoluteUri
    $unreachableNotice = Invoke-TestCommand @('missing.exe')
    Assert-True ($unreachableNotice.ExitCode -eq 1) 'unreachable version source changed the normal exit path'
    Assert-True ($unreachableNotice.Output -match 'application not found') `
        'unreachable version source blocked application handling'
    $env:CONDUIT_NO_UPDATE_CHECK = '1'
    Remove-Item Env:CONDUIT_VERSION_URL

    $profiles = Invoke-TestCommand @('show-vpn')
    Assert-True ($profiles.ExitCode -eq 0) 'show-vpn command failed'
    Assert-True ($profiles.Output -match 'cloudflare\\example\.conf') 'nested profile was not discovered'
    Assert-True ($profiles.Output -match 'proton\\invalid\.conf \[invalid\]') 'invalid profile was not marked'
    Assert-True ($profiles.Output -match 'Windscribe-Athens-Odeon-WG\.conf') `
        'flat Windscribe profile was not discovered'

    $windscribe = Invoke-TestCommand @('--provider', 'windscribe', 'missing.exe')
    Assert-True ($windscribe.ExitCode -eq 1) 'Windscribe selection should reach application resolution'
    Assert-True ($windscribe.Output -match 'application not found') `
        'flat Windscribe provider selection did not choose the Windscribe profile'

    $mullvad = Invoke-TestCommand @('--provider', 'mullvad', 'missing.exe')
    Assert-True ($mullvad.ExitCode -eq 1) 'empty Mullvad selection should fail'
    Assert-True ($mullvad.Output -match 'no profiles for provider: mullvad') `
        'flat Windscribe profile leaked into legacy Mullvad selection'

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
    Remove-Item Env:CONDUIT_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_VERSION_URL -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_DESKTOP_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_START_MENU_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CONDUIT_STARTUP_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $stateDirectory -PathType Container) {
        Remove-Item -LiteralPath $stateDirectory -Recurse -Force
    }
}
