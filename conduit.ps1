# conduit - per-application WireGuard split tunneling for Windows
# Copyright (C) 2026 berry
#
# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]] $ConduitArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '3.2.5'
$script:SelfPath = $PSCommandPath
$script:ExitCode = 0
$script:InstallerUrl = 'https://raw.githubusercontent.com/blueberi99/conduit/master/bootstrap.ps1'
$script:VersionUrl = 'https://raw.githubusercontent.com/blueberi99/conduit/master/VERSION'

$profileOverride = [Environment]::GetEnvironmentVariable('CONDUIT_DIR')
if ([string]::IsNullOrWhiteSpace($profileOverride)) {
    $script:ProfileDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'vpns'
}
else {
    $script:ProfileDir = [System.IO.Path]::GetFullPath($profileOverride)
}

$stateOverride = [Environment]::GetEnvironmentVariable('CONDUIT_STATE_DIR')
if ([string]::IsNullOrWhiteSpace($stateOverride)) {
    $script:StateBase = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Conduit'
}
else {
    $script:StateBase = [System.IO.Path]::GetFullPath($stateOverride)
}

$script:SessionRoot = Join-Path $script:StateBase 'sessions'
$script:LastProfilePath = Join-Path $script:StateBase 'last-profile'


function Throw-ConduitError {
    param([Parameter(Mandatory = $true)][string] $Message)

    throw $Message
}


function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}


function Read-Utf8File {
    param([Parameter(Mandatory = $true)][string] $Path)

    # Windows PowerShell 5.1 treats BOM-less text as the active ANSI code page.
    # Conduit writes UTF-8 without a BOM, so always decode its own files
    # explicitly to preserve non-ASCII user, application, and profile paths.
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}


function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $temporaryPath = '{0}.{1}.tmp' -f $Path, $PID
    $json = $Value | ConvertTo-Json -Depth 8
    Write-Utf8File -Path $temporaryPath -Content $json
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}


function Protect-ConduitDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    # Limit generated copies of profiles to the current user and LocalSystem.
    # Build the full ACL in memory first: if Set-Acl is unavailable (for
    # example, on a non-NTFS volume), the existing usable ACL remains intact.
    try {
        # PowerShell 7 terminals can pass their PSModulePath to the Windows
        # PowerShell process started by conduit.cmd. Import the matching inbox
        # security module by absolute path instead of relying on auto-loading.
        $securityModule = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
        if ($null -eq (Get-Module -Name 'Microsoft.PowerShell.Security')) {
            Import-Module -Name $securityModule -ErrorAction Stop
        }
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow

        $acl = Get-Acl -LiteralPath $Path
        $allowedSids = @($userSid.Value, $systemSid.Value)
        $hasUserFullControl = $false
        $hasSystemFullControl = $false
        $aclIsRestricted = $true
        foreach ($rule in $acl.Access) {
            try {
                $ruleSid = $rule.IdentityReference.Translate(
                    [System.Security.Principal.SecurityIdentifier]
                ).Value
            }
            catch {
                $aclIsRestricted = $false
                break
            }
            if ($ruleSid -notin $allowedSids) {
                $aclIsRestricted = $false
                break
            }
            if ($rule.AccessControlType -eq $allow -and
                ($rule.FileSystemRights -band $rights) -eq $rights) {
                if ($ruleSid -eq $userSid.Value) { $hasUserFullControl = $true }
                if ($ruleSid -eq $systemSid.Value) { $hasSystemFullControl = $true }
            }
        }

        # A child directory that inherits only the already-restricted parent
        # ACL is just as private. Avoid rewriting that ACL on every launch;
        # some non-elevated Windows environments reject the redundant write.
        if ($aclIsRestricted -and $hasUserFullControl -and $hasSystemFullControl) {
            return
        }

        $acl.SetAccessRuleProtection($true, $false)
        $userRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $userSid, $rights, $inheritance, $propagation, $allow
        )
        $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $systemSid, $rights, $inheritance, $propagation, $allow
        )
        $acl.SetAccessRule($userRule)
        $acl.AddAccessRule($systemRule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    catch {
        $details = ''
        if ([Environment]::GetEnvironmentVariable('CONDUIT_DEBUG') -eq '1') {
            $details = ": $($_.Exception.Message)"
        }
        Write-Warning "Could not harden ACLs on $Path$details"
    }
}


function Initialize-ConduitState {
    Protect-ConduitDirectory -Path $script:StateBase
    Protect-ConduitDirectory -Path $script:SessionRoot
}


function Show-ConduitUsage {
    @'
Conduit - isolated per-application VPN sessions for Windows

usage:
  conduit [options] <application.exe> [args...]

options:
  --vpn <profile>        use a specific WireGuard profile
  --provider <name>      choose a profile from %USERPROFILE%\vpns\<name>\
  -d, --detach           return after the application starts (default)
  -f, --foreground       wait for the application and return its exit code
  -h, --help             show help
  -V, --version          show version

management:
  conduit show-vpn
  conduit status
  conduit doctor
  conduit bootstrap
  conduit update
  conduit add shortcut <application>
  conduit remove shortcut <application>
  conduit add startup <application>
  conduit remove startup <application>
  conduit logs [session]
  conduit kill [session]
  conduit kill --all

examples:
  conduit discord.exe
  conduit firefox.exe
  conduit --vpn PDE-778 discord.exe
  conduit --provider mullvad firefox.exe
  conduit --provider windscribe discord.exe
  conduit -f curl.exe https://ifconfig.me
  conduit add shortcut discord
  conduit add startup discord

profile layout:
  %USERPROFILE%\vpns\*.conf
  %USERPROFILE%\vpns\<provider>\*.conf

Set CONDUIT_DIR to override the profile directory.

Windows uses WireSock Secure Connect as its per-application WireGuard
backend. One Conduit VPN session may be active at a time on Windows.
'@ | Write-Output
}


function Show-ConduitUpdateNotice {
    if ([Environment]::GetEnvironmentVariable('CONDUIT_NO_UPDATE_CHECK') -eq '1') {
        return
    }

    $versionUrl = [Environment]::GetEnvironmentVariable('CONDUIT_VERSION_URL')
    if ([string]::IsNullOrWhiteSpace($versionUrl)) {
        $versionUrl = $script:VersionUrl
    }

    try {
        [Uri]$uri = $null
        if (-not [Uri]::TryCreate($versionUrl, [UriKind]::Absolute, [ref]$uri)) {
            return
        }

        $latestText = ''
        if ($uri.Scheme -eq 'file') {
            $latestText = [System.IO.File]::ReadAllText($uri.LocalPath, [System.Text.Encoding]::UTF8)
        }
        elseif ($uri.Scheme -eq 'https') {
            $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol = `
                    $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 2
                $latestText = [string]$response.Content
            }
            finally {
                [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
            }
        }
        else {
            return
        }

        $latestText = $latestText.Trim()
        if ($latestText -notmatch '^\d+\.\d+\.\d+$') {
            return
        }

        $latestVersion = [Version]$latestText
        $currentVersion = [Version]$script:Version
        if ($latestVersion -gt $currentVersion) {
            Write-Warning "Conduit $latestVersion is available (current $currentVersion). Run 'conduit update' when no session is active."
        }
    }
    catch {
        # Version checks must never delay or prevent a VPN session. The launch
        # continues silently when the endpoint is offline or returns bad data.
    }
}


function Get-ConduitProfiles {
    if (-not (Test-Path -LiteralPath $script:ProfileDir -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.conf' -File -Recurse |
            Sort-Object FullName
    )
}


function Get-ProfileId {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo] $Profile)

    $root = $script:ProfileDir.TrimEnd('\') + '\'
    if ($Profile.FullName.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Profile.FullName.Substring($root.Length)
    }

    return $Profile.Name
}


function Get-ProviderProfiles {
    param(
        [Parameter(Mandatory = $true)][object[]] $Profiles,
        [Parameter(Mandatory = $true)][string] $Provider
    )

    if ($Provider -notmatch '^[A-Za-z0-9._-]+$') {
        Throw-ConduitError "invalid provider name: $Provider"
    }

    $providerDirectory = Join-Path $script:ProfileDir $Provider
    if (Test-Path -LiteralPath $providerDirectory -PathType Container) {
        $prefix = ([System.IO.Path]::GetFullPath($providerDirectory)).TrimEnd('\') + '\'
        return @($Profiles | Where-Object {
            $_.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
    }

    # Compatibility with the original flat Linux layout.
    if ($Provider -ieq 'proton') {
        return @($Profiles | Where-Object {
            (Get-ProfileId $_) -notlike '*\*' -and $_.Name -like 'PDE*'
        })
    }
    if ($Provider -ieq 'windscribe') {
        return @($Profiles | Where-Object {
            (Get-ProfileId $_) -notlike '*\*' -and $_.Name -like 'Windscribe-*'
        })
    }
    if ($Provider -ieq 'mullvad') {
        return @($Profiles | Where-Object {
            (Get-ProfileId $_) -notlike '*\*' -and
                $_.Name -notlike 'PDE*' -and $_.Name -notlike 'Windscribe-*'
        })
    }

    Throw-ConduitError "provider '$Provider' not found; expected directory: $providerDirectory"
}


function Select-ConduitProfile {
    param(
        [AllowEmptyString()][string] $Vpn,
        [AllowEmptyString()][string] $Provider
    )

    $profiles = @(Get-ConduitProfiles)
    if ($profiles.Count -eq 0) {
        Throw-ConduitError "no VPN profiles found under $script:ProfileDir; run 'conduit bootstrap' or add a .conf file"
    }

    $pool = $profiles
    if (-not [string]::IsNullOrWhiteSpace($Provider)) {
        $pool = @(Get-ProviderProfiles -Profiles $profiles -Provider $Provider)
        if ($pool.Count -eq 0) {
            Throw-ConduitError "no profiles for provider: $Provider"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Vpn)) {
        $exact = @($pool | Where-Object {
            $id = Get-ProfileId $_
            $id -ieq $Vpn -or $id -ieq "$Vpn.conf" -or
                $_.Name -ieq $Vpn -or $_.Name -ieq "$Vpn.conf"
        })

        if ($exact.Count -eq 1) {
            Test-WireGuardProfile -Path $exact[0].FullName
            return $exact[0]
        }
        if ($exact.Count -gt 1) {
            $names = ($exact | ForEach-Object { Get-ProfileId $_ }) -join ', '
            Throw-ConduitError "ambiguous profile '$Vpn': $names"
        }

        $partial = @($pool | Where-Object {
            (Get-ProfileId $_).IndexOf($Vpn, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.Name.IndexOf($Vpn, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($partial.Count -eq 1) {
            Test-WireGuardProfile -Path $partial[0].FullName
            return $partial[0]
        }
        if ($partial.Count -gt 1) {
            $names = ($partial | ForEach-Object { Get-ProfileId $_ }) -join ', '
            Throw-ConduitError "ambiguous profile '$Vpn': $names"
        }

        Throw-ConduitError "profile not found: $Vpn"
    }

    $validPool = @()
    $invalidCount = 0
    foreach ($profile in $pool) {
        try {
            Test-WireGuardProfile -Path $profile.FullName
            $validPool += $profile
        }
        catch {
            $invalidCount++
        }
    }
    if ($invalidCount -gt 0) {
        Write-Warning "Ignoring $invalidCount invalid VPN profile(s); run 'conduit doctor' for details"
    }
    if ($validPool.Count -eq 0) {
        $scope = if ([string]::IsNullOrWhiteSpace($Provider)) { '' } else { " for provider '$Provider'" }
        Throw-ConduitError "no valid VPN profiles$scope; run 'conduit doctor' for details"
    }
    $pool = $validPool

    $last = ''
    if (Test-Path -LiteralPath $script:LastProfilePath -PathType Leaf) {
        $last = (Read-Utf8File -Path $script:LastProfilePath).Trim()
    }

    $withoutLast = @($pool | Where-Object { (Get-ProfileId $_) -ine $last })
    if ($withoutLast.Count -gt 0) {
        $pool = $withoutLast
    }

    return $pool | Get-Random
}


function Find-WireSockClient {
    $override = [Environment]::GetEnvironmentVariable('CONDUIT_WIRESOCK')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override -PathType Leaf) {
            return (Resolve-Path -LiteralPath $override).Path
        }
        Throw-ConduitError "CONDUIT_WIRESOCK does not exist: $override"
    }

    foreach ($commandName in @('wiresock-connect-cli.exe', 'wiresock-client.exe')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            return $command.Source
        }
    }

    $candidates = @()
    foreach ($programRoot in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programRoot)) {
            continue
        }
        $candidates += @(
            (Join-Path $programRoot 'WireSock Secure Connect\command-line\wiresock-connect-cli.exe'),
            (Join-Path $programRoot 'WireSock Secure Connect\wiresock-client.exe'),
            (Join-Path $programRoot 'WireSock Secure Connect\bin\wiresock-client.exe'),
            (Join-Path $programRoot 'WireSock VPN Client\wiresock-client.exe'),
            (Join-Path $programRoot 'WireSock VPN Client\bin\wiresock-client.exe'),
            (Join-Path $programRoot 'NT KERNEL\WireSock VPN Client\wiresock-client.exe')
        )
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}


function Get-WireSockBackendKind {
    param([Parameter(Mandatory = $true)][string] $Backend)

    if ([System.IO.Path]::GetFileName($Backend) -ieq 'wiresock-connect-cli.exe') {
        return 'service-cli'
    }
    return 'legacy-client'
}


function Find-WireGuardTool {
    $command = Get-Command 'wg.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    $candidate = Join-Path ${env:ProgramFiles} 'WireGuard\wg.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    return $null
}


function Find-SquirrelApplication {
    param([Parameter(Mandatory = $true)][string] $Command)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Command).ToLowerInvariant()
    $knownApplications = @{
        'discord'       = @('Discord', 'Discord.exe')
        'discordcanary' = @('DiscordCanary', 'DiscordCanary.exe')
        'discordptb'    = @('DiscordPTB', 'DiscordPTB.exe')
    }
    if (-not $knownApplications.ContainsKey($name)) {
        return $null
    }

    $definition = $knownApplications[$name]
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }
    $root = Join-Path $localAppData $definition[0]
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue) {
        $executable = Join-Path $directory.FullName $definition[1]
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            continue
        }

        $version = [Version]'0.0'
        [void][Version]::TryParse($directory.Name.Substring(4), [ref]$version)
        $candidates.Add([pscustomobject]@{
            Path          = $executable
            Version       = $version
            LastWriteTime = $directory.LastWriteTimeUtc
        })
    }

    $selected = $candidates |
        Sort-Object -Property @{ Expression = 'Version'; Descending = $true },
            @{ Expression = 'LastWriteTime'; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $selected) {
        return $null
    }

    return [pscustomobject]@{
        Path = $selected.Path
        Root = $root
    }
}


function Resolve-ConduitApplication {
    param([Parameter(Mandatory = $true)][string] $Command)

    $resolved = $null
    $stableApplicationRoot = $null
    $hasDirectory = $Command -match '[\\/]'
    if (-not $hasDirectory) {
        $squirrelApplication = Find-SquirrelApplication -Command $Command
        if ($null -ne $squirrelApplication) {
            $resolved = $squirrelApplication.Path
            $stableApplicationRoot = $squirrelApplication.Root
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolved) -and (Test-Path -LiteralPath $Command -PathType Leaf)) {
        $resolved = (Resolve-Path -LiteralPath $Command).Path
    }
    elseif ([string]::IsNullOrWhiteSpace($resolved)) {
        $found = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $found -and [System.IO.Path]::GetExtension($Command) -eq '') {
            $found = Get-Command "$Command.exe" -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        if ($null -ne $found) {
            $resolved = $found.Source
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        Throw-ConduitError "application not found: $Command (use an .exe name or full path)"
    }

    $extension = [System.IO.Path]::GetExtension($resolved)
    if ($extension -ine '.exe' -and $extension -ine '.com') {
        Throw-ConduitError "Windows sessions require a native .exe or .com application: $resolved"
    }

    # Squirrel-based applications (notably Discord) live under a versioned
    # app-* directory. WireSock accepts an application directory and includes
    # executables below it, so use the stable install root across updates.
    if ([string]::IsNullOrWhiteSpace($stableApplicationRoot)) {
        $parent = [System.IO.DirectoryInfo]([System.IO.Path]::GetDirectoryName($resolved))
        if ($null -ne $parent -and $parent.Name -like 'app-*' -and $null -ne $parent.Parent) {
            $updater = Join-Path $parent.Parent.FullName 'Update.exe'
            if (Test-Path -LiteralPath $updater -PathType Leaf) {
                $stableApplicationRoot = $parent.Parent.FullName
            }
        }
    }

    $allowedApp = $resolved
    if (-not [string]::IsNullOrWhiteSpace($stableApplicationRoot)) {
        if ($stableApplicationRoot.Contains(',')) {
            $allowedApp = [System.IO.Path]::GetFileName($resolved)
        }
        else {
            $allowedApp = $stableApplicationRoot
        }
    }

    $processNames = @([System.IO.Path]::GetFileNameWithoutExtension($resolved))
    if (Test-Path -LiteralPath $allowedApp -PathType Container) {
        $executableFiles = @(
            Get-ChildItem -LiteralPath $allowedApp -Filter '*.exe' -File -ErrorAction SilentlyContinue
        )
        foreach ($appDirectory in Get-ChildItem -LiteralPath $allowedApp -Directory -Filter 'app-*' -ErrorAction SilentlyContinue) {
            $executableFiles += @(
                Get-ChildItem -LiteralPath $appDirectory.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue
            )
        }
        $processNames += @($executableFiles | ForEach-Object { $_.BaseName })
        $processNames = @($processNames | Sort-Object -Unique)
    }

    return [pscustomobject]@{
        Path        = $resolved
        Label       = [System.IO.Path]::GetFileName($resolved)
        ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
        ProcessNames = @($processNames)
        AllowedApp  = $allowedApp
    }
}


function Resolve-ConduitDnsIPv4 {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [AllowEmptyString()][string] $Server = ''
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Server)) {
            $records = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop)
        }
        else {
            $records = @(
                Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            )
        }
        return @(
            $records |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) } |
                ForEach-Object { [string]$_.IPAddress } |
                Sort-Object -Unique
        )
    }
    catch {
        return @()
    }
}


function Get-DiscordDnsHealth {
    if ($null -eq (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            State   = 'unverified'
            Message = 'Resolve-DnsName is unavailable on this Windows installation'
        }
    }

    $domains = @('discord.com', 'updates.discord.com')
    $mismatches = 0
    $verified = 0

    foreach ($domain in $domains) {
        $systemAddresses = @(Resolve-ConduitDnsIPv4 -Name $domain)
        if ($systemAddresses.Count -eq 0) {
            return [pscustomobject]@{
                State   = 'unavailable'
                Message = "Windows DNS could not resolve $domain"
            }
        }

        $trustedAddresses = @(Resolve-ConduitDnsIPv4 -Name $domain -Server '1.1.1.1')
        if ($trustedAddresses.Count -eq 0) {
            $trustedAddresses = @(Resolve-ConduitDnsIPv4 -Name $domain -Server '8.8.8.8')
        }
        if ($trustedAddresses.Count -eq 0) {
            continue
        }

        $verified++
        $overlap = @($systemAddresses | Where-Object { $trustedAddresses -contains $_ })
        if ($overlap.Count -eq 0) {
            $mismatches++
        }
    }

    if ($verified -eq $domains.Count -and $mismatches -eq $domains.Count) {
        return [pscustomobject]@{
            State   = 'rewritten'
            Message = 'Windows DNS answers for Discord differ from trusted public resolvers'
        }
    }

    if ($verified -eq 0) {
        return [pscustomobject]@{
            State   = 'unverified'
            Message = 'trusted DNS resolvers could not be reached for comparison'
        }
    }

    return [pscustomobject]@{
        State   = 'ok'
        Message = 'Discord DNS answers match a trusted public resolver'
    }
}


function Get-AllowedApplicationProcesses {
    param(
        [Parameter(Mandatory = $true)][object[]] $ProcessNames,
        [Parameter(Mandatory = $true)][string] $AllowedApp
    )

    $allowedIsDirectory = Test-Path -LiteralPath $AllowedApp -PathType Container
    $allowedIsPath = $allowedIsDirectory -or [System.IO.Path]::IsPathRooted($AllowedApp)
    $allowedPrefix = if ($allowedIsDirectory) { $AllowedApp.TrimEnd('\') + '\' } else { '' }

    $matches = @()
    foreach ($name in @($ProcessNames | Sort-Object -Unique)) {
        foreach ($process in Get-Process -Name ([string]$name) -ErrorAction SilentlyContinue) {
            if (-not $allowedIsPath) {
                $matches += $process
                continue
            }
            try {
                if (($allowedIsDirectory -and $process.Path.StartsWith(
                    $allowedPrefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) -or (-not $allowedIsDirectory -and $process.Path -ieq $AllowedApp)) {
                    $matches += $process
                }
            }
            catch {}
        }
    }
    return $matches
}


function Stop-AllowedApplicationProcesses {
    param(
        [Parameter(Mandatory = $true)][object[]] $ProcessNames,
        [Parameter(Mandatory = $true)][string] $AllowedApp,
        [Parameter(Mandatory = $true)][string] $SessionStartedAt
    )

    $minimumStart = [DateTime]::Parse(
        $SessionStartedAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime().AddSeconds(-2)

    foreach ($process in Get-AllowedApplicationProcesses -ProcessNames $ProcessNames -AllowedApp $AllowedApp) {
        try {
            if ($process.StartTime.ToUniversalTime() -ge $minimumStart) {
                Stop-ProcessTree -ProcessId $process.Id
            }
        }
        catch {}
    }
}


function Test-WireGuardProfile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $content = Read-Utf8File -Path $Path
    foreach ($required in @(
        '(?im)^\s*\[Interface\]\s*$',
        '(?im)^\s*\[Peer\]\s*$',
        '(?im)^\s*AllowedIPs\s*=',
        '(?im)^\s*Endpoint\s*='
    )) {
        if ($content -notmatch $required) {
            Throw-ConduitError "invalid WireGuard profile '$Path'; missing required field"
        }
    }

    $interfaceCount = [regex]::Matches($content, '(?im)^\s*\[Interface\]\s*$').Count
    $peerCount = [regex]::Matches($content, '(?im)^\s*\[Peer\]\s*$').Count
    if ($interfaceCount -ne 1 -or $peerCount -ne 1) {
        Throw-ConduitError "invalid WireGuard profile '$Path'; Windows requires exactly one [Interface] and one [Peer]"
    }

    foreach ($field in @('PrivateKey', 'PublicKey')) {
        $keyMatches = [regex]::Matches(
            $content,
            "(?im)^\s*$field\s*=\s*([^\r\n]+?)\s*$"
        )
        if ($keyMatches.Count -ne 1) {
            Throw-ConduitError "invalid WireGuard profile '$Path'; expected exactly one $field"
        }
        $key = $keyMatches[0].Groups[1].Value.Trim()
        try {
            $keyBytes = [Convert]::FromBase64String($key)
        }
        catch {
            Throw-ConduitError "invalid WireGuard profile '$Path'; $field is not valid Base64"
        }
        if ($keyBytes.Length -ne 32) {
            Throw-ConduitError "invalid WireGuard profile '$Path'; $field must contain a 32-byte WireGuard key"
        }
    }
}


function New-WireSockProfile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $AllowedApp
    )

    Test-WireGuardProfile -Path $Source
    if ($AllowedApp -match '[\r\n]') {
        Throw-ConduitError 'application path contains an invalid newline'
    }

    $inputLines = [System.IO.File]::ReadAllLines($Source)
    $output = New-Object System.Collections.Generic.List[string]
    $peerCount = @($inputLines | Where-Object { $_ -match '(?i)^\s*\[Peer\]\s*$' }).Count
    $hasJunkPacketSetting = @($inputLines | Where-Object { $_ -match '(?i)^\s*Jc\s*=' }).Count -gt 0
    if ($peerCount -ne 1) {
        Throw-ConduitError "Windows sessions require exactly one [Peer] section; found $peerCount in '$Source'"
    }

    $output.Add('# Generated by Conduit for a single Windows session. Do not edit.')
    foreach ($line in $inputLines) {
        # The session owns application filtering. Provider hook commands are
        # intentionally ignored because Unix hooks are not portable to Windows.
        if ($line -match '(?i)^\s*(?:#@ws:\s*)?(?:AllowedApps|DisallowedApps)\s*=') {
            continue
        }
        if ($line -match '(?i)^\s*(?:PreUp|PostUp|PreDown|PostDown)\s*=') {
            continue
        }
        if ($line -match '(?i)^\s*AllowedIPs\s*=') {
            continue
        }

        $output.Add($line)
        if (-not $hasJunkPacketSetting -and $line -match '(?i)^\s*\[Interface\]\s*$') {
            # WireSock 3.6 enables global junk packets by default. Pin standard
            # WireGuard profiles to standard handshake framing unless the
            # provider explicitly supplied its own Jc value.
            $output.Add('Jc = 0')
        }
        if ($line -match '(?i)^\s*\[Peer\]\s*$') {
            $output.Add("#@ws:AllowedApps = $AllowedApp")
            # WireSock combines AllowedApps and AllowedIPs with AND semantics.
            # Force both address families into the selected application's
            # tunnel so an incomplete provider profile cannot leak traffic.
            $output.Add('AllowedIPs = 0.0.0.0/0, ::/0')
        }
    }

    Write-Utf8File -Path $Destination -Content (($output -join "`r`n") + "`r`n")
}


function New-ConduitSessionId {
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        if (-not (Test-Path -LiteralPath (Join-Path $script:SessionRoot $id))) {
            return $id
        }
    }

    Throw-ConduitError 'could not allocate a unique session ID'
}


function Get-SessionDirectory {
    param([Parameter(Mandatory = $true)][string] $Id)
    return Join-Path $script:SessionRoot $Id
}


function Read-SessionState {
    param([Parameter(Mandatory = $true)][string] $Id)

    $path = Join-Path (Get-SessionDirectory $Id) 'session.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-Utf8File -Path $path) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}


function Write-SessionState {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)] $State
    )

    $path = Join-Path (Get-SessionDirectory $Id) 'session.json'
    Write-JsonAtomic -Value $State -Path $path
}


function Test-ProcessId {
    param([int] $ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}


function Get-StateProperty {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($State -is [System.Collections.IDictionary] -and $State.Contains($Name)) {
        return $State[$Name]
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}


function Test-SessionRoleProcess {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][ValidateSet('Supervisor', 'Tunnel', 'App')][string] $Role
    )

    $processId = [int](Get-StateProperty -State $State -Name ($Role + 'Pid'))
    if ($processId -le 0) {
        return $false
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }

    $expectedPath = [string](Get-StateProperty -State $State -Name ($Role + 'Path'))
    $expectedStartedAt = [string](Get-StateProperty -State $State -Name ($Role + 'StartedAt'))
    if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($expectedStartedAt)) {
        return $false
    }

    try {
        if ($process.Path -ine $expectedPath) {
            return $false
        }
        $expectedStart = [DateTime]::Parse(
            $expectedStartedAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $actualStart = $process.StartTime.ToUniversalTime()
        return [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -lt 2
    }
    catch {
        return $false
    }
}


function Test-SessionActive {
    param([Parameter(Mandatory = $true)] $State)

    if ($State.State -notin @('starting', 'active', 'stopping')) {
        return $false
    }
    return (Test-SessionRoleProcess -State $State -Role Supervisor) -or
        (Test-SessionRoleProcess -State $State -Role Tunnel)
}


function Get-ConduitSessions {
    if (-not (Test-Path -LiteralPath $script:SessionRoot -PathType Container)) {
        return @()
    }

    $sessions = @()
    foreach ($directory in Get-ChildItem -LiteralPath $script:SessionRoot -Directory -ErrorAction SilentlyContinue) {
        $state = Read-SessionState -Id $directory.Name
        if ($null -ne $state) {
            $sessions += $state
        }
    }
    return $sessions
}


function Get-ActiveSessions {
    return @(Get-ConduitSessions | Where-Object { Test-SessionActive $_ })
}


function Resolve-SessionSelector {
    param(
        [AllowEmptyString()][string] $Selector,
        [switch] $IncludeInactive
    )

    $sessions = @(
        if ($IncludeInactive) { Get-ConduitSessions } else { Get-ActiveSessions }
    )
    if ($sessions.Count -eq 0) {
        Throw-ConduitError 'no Conduit sessions'
    }

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        if ($sessions.Count -eq 1) {
            return $sessions[0]
        }
        Throw-ConduitError 'multiple sessions exist; choose one by ID or application name'
    }

    $matches = @($sessions | Where-Object {
        $_.Id -ieq $Selector -or $_.Id.StartsWith($Selector, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.App -ieq $Selector -or $_.Profile -ieq $Selector -or
            [System.IO.Path]::GetFileName($_.Profile) -ieq $Selector
    })

    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -eq 0) {
        Throw-ConduitError "session not found: $Selector"
    }

    Throw-ConduitError "ambiguous session '$Selector': $(($matches.Id) -join ', ')"
}


function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string] $Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}


function Join-NativeArguments {
    param([object[]] $Values)
    return (($Values | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
}


function Get-ConduitLauncherPath {
    $override = [Environment]::GetEnvironmentVariable('CONDUIT_LAUNCHER')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override -PathType Leaf) {
            return (Resolve-Path -LiteralPath $override).Path
        }
        Throw-ConduitError "CONDUIT_LAUNCHER does not exist: $override"
    }

    $launcher = Join-Path (Split-Path -Parent $script:SelfPath) 'conduit.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Throw-ConduitError "Conduit launcher not found beside $script:SelfPath; reinstall Conduit and retry"
    }
    return (Resolve-Path -LiteralPath $launcher).Path
}


function Get-ConduitShortcutIdentity {
    param([Parameter(Mandatory = $true)][string] $Application)

    if ($Application -notmatch '^[A-Za-z0-9._-]+$') {
        Throw-ConduitError 'shortcut application must be a command name such as discord or firefox.exe'
    }

    $key = [System.IO.Path]::GetFileNameWithoutExtension($Application).ToLowerInvariant()
    $label = switch ($key) {
        'discord' { 'Discord'; break }
        'discordptb' { 'Discord PTB'; break }
        'discordcanary' { 'Discord Canary'; break }
        default {
            if ($key.Length -eq 0) {
                Throw-ConduitError 'shortcut application name is empty'
            }
            $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        }
    }

    return [pscustomobject]@{
        Application = $Application
        Label       = $label
        FileName    = "Conduit - $label.lnk"
    }
}


function Get-ConduitShortcutDirectory {
    param([Parameter(Mandatory = $true)][ValidateSet('shortcut', 'startup')][string] $Kind)

    $environmentName = if ($Kind -eq 'shortcut') { 'CONDUIT_DESKTOP_DIR' } else { 'CONDUIT_STARTUP_DIR' }
    $override = [Environment]::GetEnvironmentVariable($environmentName)
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath($override)
    }

    $specialFolder = if ($Kind -eq 'shortcut') { 'DesktopDirectory' } else { 'Startup' }
    $directory = [Environment]::GetFolderPath($specialFolder)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        Throw-ConduitError "Windows could not locate the $Kind folder"
    }
    return $directory
}


function Add-ConduitShortcut {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('shortcut', 'startup')][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Application
    )

    $identity = Get-ConduitShortcutIdentity -Application $Application
    $launcher = Get-ConduitLauncherPath
    $resolvedApplication = Resolve-ConduitApplication -Command $Application
    $directory = Get-ConduitShortcutDirectory -Kind $Kind
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $path = Join-Path $directory $identity.FileName
    $temporaryPath = Join-Path $directory ('.conduit-{0}.lnk' -f [Guid]::NewGuid().ToString('N'))
    $wasExisting = Test-Path -LiteralPath $path -PathType Leaf
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($temporaryPath)
        $shortcut.TargetPath = $launcher
        $shortcut.Arguments = Join-NativeArguments @($identity.Application)
        $shortcut.WorkingDirectory = Split-Path -Parent $launcher
        $shortcut.IconLocation = "$($resolvedApplication.Path),0"
        $shortcut.Description = "Launch $($identity.Label) through Conduit VPN"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            Throw-ConduitError "Windows did not create the shortcut: $temporaryPath"
        }
        Copy-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    catch {
        Throw-ConduitError "could not create the Conduit $Kind for $($identity.Label): $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }

    $verb = if ($wasExisting) { 'Replaced' } else { 'Created' }
    Write-Output "$verb Conduit $kind for $($identity.Label): $path"
}


function Remove-ConduitShortcut {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('shortcut', 'startup')][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Application
    )

    $identity = Get-ConduitShortcutIdentity -Application $Application
    $directory = Get-ConduitShortcutDirectory -Kind $Kind
    $path = Join-Path $directory $identity.FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Output "No Conduit $kind exists for $($identity.Label): $path"
        return
    }

    Remove-Item -LiteralPath $path -Force
    Write-Output "Removed Conduit $kind for $($identity.Label): $path"
}


function Start-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [object[]] $ArgumentValues = @(),
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [switch] $Hidden,
        [string] $OutputPath,
        [string] $ErrorPath
    )

    $parameters = @{
        FilePath         = $FilePath
        WorkingDirectory = $WorkingDirectory
        PassThru         = $true
    }
    if ($ArgumentValues.Count -gt 0) {
        $parameters.ArgumentList = Join-NativeArguments $ArgumentValues
    }
    if ($Hidden) {
        $parameters.WindowStyle = 'Hidden'
    }
    else {
        $parameters.NoNewWindow = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $parameters.RedirectStandardOutput = $OutputPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorPath)) {
        $parameters.RedirectStandardError = $ErrorPath
    }

    return Start-Process @parameters
}


function Start-DetachedSupervisor {
    param(
        [Parameter(Mandatory = $true)][string] $HostExecutable,
        [Parameter(Mandatory = $true)][string] $SessionId,
        [Parameter(Mandatory = $true)][string] $SessionDirectory
    )

    foreach ($value in @($HostExecutable, $script:SelfPath, $SessionDirectory)) {
        if ($value -match '[\r\n]') {
            Throw-ConduitError 'a supervisor path contains an invalid newline'
        }
    }

    $supervisorOut = Join-Path $SessionDirectory 'supervisor.log'
    $supervisorError = Join-Path $SessionDirectory 'supervisor-error.log'
    $launcherPath = Join-Path $SessionDirectory 'launch-supervisor.cmd'

    # A short-lived cmd launcher gives the supervisor independent standard
    # handles and a separate console. This lets Conduit survive the terminal
    # that launched it without leaving a visible PowerShell window behind.
    # Keep the batch file ASCII-only. Unicode user/profile paths travel through
    # the Windows process environment, which cmd.exe expands without recoding.
    $launchEnvironment = [ordered]@{
        CONDUIT_LAUNCH_HOST   = $HostExecutable
        CONDUIT_LAUNCH_SCRIPT = $script:SelfPath
        CONDUIT_LAUNCH_ID     = $SessionId
        CONDUIT_LAUNCH_OUT    = $supervisorOut
        CONDUIT_LAUNCH_ERROR  = $supervisorError
    }
    $previousEnvironment = @{}
    foreach ($name in $launchEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $launchEnvironment[$name], 'Process')
    }

    $batch = @'
@echo off
start "" /min "%CONDUIT_LAUNCH_HOST%" "-NoLogo" "-NoProfile" "-ExecutionPolicy" "Bypass" "-WindowStyle" "Hidden" "-File" "%CONDUIT_LAUNCH_SCRIPT%" "__supervise" "%CONDUIT_LAUNCH_ID%" 1>"%CONDUIT_LAUNCH_OUT%" 2>"%CONDUIT_LAUNCH_ERROR%"
'@
    $batch = ($batch -replace "`r?`n", "`r`n") + "`r`n"
    Write-Utf8File -Path $launcherPath -Content $batch

    try {
        # cmd.exe receives an ASCII-only relative batch name. The Unicode
        # session directory is supplied through CreateProcess' working
        # directory instead of being re-decoded by cmd's active code page.
        $launcherName = [System.IO.Path]::GetFileName($launcherPath)
        $launcher = Start-ManagedProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -ArgumentValues @('/d', '/s', '/c', $launcherName) `
            -WorkingDirectory $SessionDirectory -Hidden
        $launcher.WaitForExit()
        if ($launcher.ExitCode -ne 0) {
            Throw-ConduitError "could not start the detached session supervisor (exit $($launcher.ExitCode))"
        }
    }
    finally {
        foreach ($name in $launchEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
        Remove-Item -LiteralPath $launcherPath -Force -ErrorAction SilentlyContinue
    }
}


function Stop-ProcessTree {
    param([int] $ProcessId)

    if (-not (Test-ProcessId $ProcessId)) {
        return
    }

    if ([Environment]::GetEnvironmentVariable('CONDUIT_NO_TASKKILL') -ne '1') {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
        }
        catch {}
        finally {
            $ErrorActionPreference = $previousPreference
        }
    }

    # Some restricted environments deny taskkill's process-tree query even
    # though the current user owns the process. Always retain a direct fallback.
    if (Test-ProcessId $ProcessId) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}


function Stop-WireSockProcess {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $Backend,
        [string] $BackendKind,
        [string] $ImportedProfile,
        [string] $WorkingDirectory = $script:StateBase
    )

    if (-not [string]::IsNullOrWhiteSpace($Backend) -and $BackendKind -eq 'service-cli') {
        try {
            $disconnect = Start-ManagedProcess -FilePath $Backend -ArgumentValues @('disconnect') `
                -WorkingDirectory $WorkingDirectory -Hidden
            [void]$disconnect.WaitForExit(10000)
        }
        catch {}
    }

    if ($null -ne $Process -and -not $Process.HasExited) {
        try {
            if ($Process.CloseMainWindow()) {
                [void]$Process.WaitForExit(2000)
            }
        }
        catch {}

        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            try { [void]$Process.WaitForExit(2000) } catch {}
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Backend) -and $BackendKind -eq 'service-cli' -and
        -not [string]::IsNullOrWhiteSpace($ImportedProfile)) {
        try {
            $delete = Start-ManagedProcess -FilePath $Backend -ArgumentValues @('delete', $ImportedProfile) `
                -WorkingDirectory $WorkingDirectory -Hidden
            [void]$delete.WaitForExit(10000)
        }
        catch {}
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Backend)) {
        try {
            $reset = Start-ManagedProcess -FilePath $Backend -ArgumentValues @('reset-network-lock') `
                -WorkingDirectory $script:StateBase -Hidden
            [void]$reset.WaitForExit(3000)
        }
        catch {}
    }
}


function Invoke-ConduitSupervisor {
    param([Parameter(Mandatory = $true)][string] $Id)

    $directory = Get-SessionDirectory $Id
    $requestPath = Join-Path $directory 'request.json'
    $state = Read-SessionState -Id $Id
    if ($null -eq $state -or -not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        Throw-ConduitError "session startup data is missing: $Id"
    }

    $request = (Read-Utf8File -Path $requestPath) | ConvertFrom-Json
    $backend = $null
    $backendKind = $null
    $importedProfile = $null
    $tunnel = $null
    $application = $null
    $exitCode = 1
    $normalExit = $false

    try {
        $state.SupervisorPid = $PID
        $supervisorProcess = Get-Process -Id $PID
        $state.SupervisorPath = $supervisorProcess.Path
        $state.SupervisorStartedAt = $supervisorProcess.StartTime.ToUniversalTime().ToString('o')
        $state.State = 'starting'
        Write-SessionState -Id $Id -State $state

        $backend = Find-WireSockClient
        if ([string]::IsNullOrWhiteSpace($backend)) {
            Throw-ConduitError "WireSock Secure Connect was not found; install it with 'winget install NTKERNEL.WireSockVPNClient'"
        }
        $backendKind = Get-WireSockBackendKind -Backend $backend

        $existing = @(Get-AllowedApplicationProcesses `
            -ProcessNames @($request.ProcessNames) -AllowedApp $request.AllowedApp)
        if ($existing.Count -gt 0) {
            Throw-ConduitError "close existing $($request.App) and updater instances before starting a Conduit session"
        }

        $networkLock = [Environment]::GetEnvironmentVariable('CONDUIT_NETWORK_LOCK')
        $lockMode = if ($networkLock -eq '0' -or $networkLock -ieq 'false') { 'disabled' } else { 'enabled' }
        $tunnelOut = Join-Path $directory 'tunnel.log'
        $tunnelErr = Join-Path $directory 'tunnel-error.log'
        if ($backendKind -eq 'service-cli') {
            $importedProfile = [System.IO.Path]::GetFileNameWithoutExtension([string]$request.GeneratedProfile)
            $importOut = Join-Path $directory 'import.log'
            $importErr = Join-Path $directory 'import-error.log'
            $import = Start-ManagedProcess -FilePath $backend `
                -ArgumentValues @('import', $request.GeneratedProfile) -WorkingDirectory $directory `
                -Hidden -OutputPath $importOut -ErrorPath $importErr
            if (-not $import.WaitForExit(15000)) {
                Stop-Process -Id $import.Id -Force -ErrorAction SilentlyContinue
                Throw-ConduitError 'WireSock profile import timed out'
            }
            $import.WaitForExit()
            $import.Refresh()
            $importExitCode = $import.ExitCode
            if ($null -eq $importExitCode) { $importExitCode = 0 }
            $importDetails = @()
            if (Test-Path -LiteralPath $importOut) { $importDetails += Get-Content -LiteralPath $importOut -Tail 8 }
            if (Test-Path -LiteralPath $importErr) { $importDetails += Get-Content -LiteralPath $importErr -Tail 8 }
            $importMessage = ($importDetails -join ' ').Trim()
            if ($importExitCode -ne 0 -or $importMessage -match '(?i)\bfailed\s+to\s+import\b') {
                Throw-ConduitError "WireSock could not import the session profile (exit $importExitCode). $importMessage"
            }

            $tunnel = Start-ManagedProcess -FilePath $backend `
                -ArgumentValues @('connect', $importedProfile, '-log-level', 'info', '-network-lock', $lockMode) `
                -WorkingDirectory $directory -Hidden -OutputPath $tunnelOut -ErrorPath $tunnelErr
        }
        else {
            $tunnel = Start-ManagedProcess -FilePath $backend `
                -ArgumentValues @('run', '-config', $request.GeneratedProfile, '-log-level', 'info', '-network-lock', $lockMode) `
                -WorkingDirectory $directory -Hidden -OutputPath $tunnelOut -ErrorPath $tunnelErr
        }

        $state.TunnelPid = $tunnel.Id
        $state.TunnelPath = $backend
        $state.TunnelStartedAt = $tunnel.StartTime.ToUniversalTime().ToString('o')
        $state.BackendKind = $backendKind
        $state.ImportedProfile = $importedProfile
        Write-SessionState -Id $Id -State $state

        $delayText = [Environment]::GetEnvironmentVariable('CONDUIT_STARTUP_DELAY_MS')
        $delay = 1800
        if (-not [string]::IsNullOrWhiteSpace($delayText)) {
            $parsedDelay = 0
            if ([int]::TryParse($delayText, [ref]$parsedDelay) -and $parsedDelay -ge 250 -and $parsedDelay -le 30000) {
                $delay = $parsedDelay
            }
        }

        $startupLimit = if ($backendKind -eq 'service-cli') { [Math]::Max($delay, 30000) } else { $delay }
        $elapsed = 0
        $connected = $false
        while ($elapsed -lt $startupLimit) {
            Start-Sleep -Milliseconds 200
            $elapsed += 200
            if ($tunnel.HasExited) {
                $details = @()
                if (Test-Path -LiteralPath $tunnelOut) {
                    $details += Get-Content -LiteralPath $tunnelOut -Tail 8
                }
                if (Test-Path -LiteralPath $tunnelErr) {
                    $details += Get-Content -LiteralPath $tunnelErr -Tail 8
                }
                Throw-ConduitError "WireSock exited during tunnel startup. $(($details -join ' ').Trim())"
            }
            if ($backendKind -eq 'service-cli' -and (Test-Path -LiteralPath $tunnelOut -PathType Leaf)) {
                $recentTunnelOutput = (Get-Content -LiteralPath $tunnelOut -Tail 30) -join [Environment]::NewLine
                if ($recentTunnelOutput -match '(?im)((^|\W)Connected(\W|$)|Connection\s+established|Handshake\s+response\s+received)') {
                    $connected = $true
                    break
                }
            }
        }
        if ($backendKind -eq 'service-cli' -and -not $connected) {
            Throw-ConduitError 'WireSock did not report a connected tunnel within 30 seconds'
        }

        $appOut = Join-Path $directory 'app.log'
        $appErr = Join-Path $directory 'app-error.log'
        if ([bool]$request.Detach) {
            $application = Start-ManagedProcess -FilePath $request.Command `
                -ArgumentValues @($request.Arguments) -WorkingDirectory $request.WorkingDirectory `
                -Hidden -OutputPath $appOut -ErrorPath $appErr
        }
        else {
            $application = Start-ManagedProcess -FilePath $request.Command `
                -ArgumentValues @($request.Arguments) -WorkingDirectory $request.WorkingDirectory
        }

        $state.AppPid = $application.Id
        $state.AppPath = $request.Command
        $state.AppStartedAt = $application.StartTime.ToUniversalTime().ToString('o')
        $state.State = 'active'
        Write-SessionState -Id $Id -State $state

        if (-not [bool]$request.Detach) {
            $application.WaitForExit()
            $exitCode = $application.ExitCode
            $normalExit = $true
        }
        else {
            $emptyChecks = 0
            while ($true) {
                if (Test-Path -LiteralPath (Join-Path $directory 'stop.requested')) {
                    break
                }
                if ($tunnel.HasExited) {
                    Throw-ConduitError 'WireSock stopped unexpectedly; the application session was terminated'
                }

                $running = @(Get-AllowedApplicationProcesses `
                    -ProcessNames @($request.ProcessNames) -AllowedApp $request.AllowedApp)
                if ($running.Count -eq 0) {
                    $emptyChecks++
                    if ($emptyChecks -ge 8) {
                        $normalExit = $true
                        $exitCode = 0
                        break
                    }
                }
                else {
                    $emptyChecks = 0
                }
                Start-Sleep -Milliseconds 250
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        try {
            [System.IO.File]::AppendAllText((Join-Path $directory 'conduit-error.log'), $message + [Environment]::NewLine)
            $state.State = 'failed'
            $state.Error = $message
            Write-SessionState -Id $Id -State $state
        }
        catch {}
        [Console]::Error.WriteLine("conduit: $message")
        $exitCode = 1
    }
    finally {
        $stopRequested = Test-Path -LiteralPath (Join-Path $directory 'stop.requested')
        if (($stopRequested -or -not $normalExit) -and $null -ne $application -and -not $application.HasExited) {
            Stop-ProcessTree -ProcessId $application.Id
        }
        if ($stopRequested -or -not $normalExit) {
            try {
                Stop-AllowedApplicationProcesses -ProcessNames @($request.ProcessNames) `
                    -AllowedApp $request.AllowedApp -SessionStartedAt $state.StartedAt
            }
            catch {}
        }
        Stop-WireSockProcess -Process $tunnel -Backend $backend -BackendKind $backendKind `
            -ImportedProfile $importedProfile -WorkingDirectory $directory

        if ($normalExit -or $stopRequested) {
            try {
                $state.State = 'stopped'
                $state.StoppedAt = [DateTime]::UtcNow.ToString('o')
                Write-SessionState -Id $Id -State $state
            }
            catch {}
        }

        Remove-Item -LiteralPath $request.GeneratedProfile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }

    $script:ExitCode = $exitCode
}


function Start-ConduitSession {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo] $Profile,
        [Parameter(Mandatory = $true)] $Application,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $ApplicationArguments,
        [Parameter(Mandatory = $true)][bool] $Detach
    )

    if ($Application.ProcessName -match '^(?i:Discord(?:PTB|Canary)?)$') {
        $dnsHealth = Get-DiscordDnsHealth
        if ($dnsHealth.State -eq 'rewritten') {
            Throw-ConduitError ('Windows DNS appears to rewrite Discord addresses before WireSock can apply ' +
                "per-application filtering. Configure a trusted system DNS resolver such as " +
                "1.1.1.1/1.0.0.1, flush the DNS cache, and retry. Run 'conduit doctor' for details")
        }
        if ($dnsHealth.State -eq 'unavailable') {
            Throw-ConduitError "$($dnsHealth.Message); fix Windows DNS and retry"
        }
    }

    Initialize-ConduitState
    $launchLock = $null
    try {
        try {
            $launchLock = [System.IO.File]::Open(
                (Join-Path $script:StateBase 'launch.lock'),
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch {
            Throw-ConduitError 'another Conduit launch is already in progress'
        }

    $active = @(Get-ActiveSessions)
    if ($active.Count -gt 0) {
        Throw-ConduitError "a Windows Conduit session is already active ($($active[0].Id)); stop it with 'conduit kill $($active[0].Id)'"
    }

    $id = New-ConduitSessionId
    $directory = Get-SessionDirectory $id
    Protect-ConduitDirectory -Path $directory

    $generatedProfile = Join-Path $directory ("conduit-$id.conf")
    New-WireSockProfile -Source $Profile.FullName -Destination $generatedProfile -AllowedApp $Application.AllowedApp

    $profileId = Get-ProfileId $Profile
    $state = [ordered]@{
        Id            = $id
        State         = 'starting'
        App           = $Application.Label
        ProcessName   = $Application.ProcessName
        ProcessNames  = @($Application.ProcessNames)
        AllowedApp    = $Application.AllowedApp
        Profile       = $profileId
        StartedAt     = [DateTime]::UtcNow.ToString('o')
        StoppedAt     = $null
        SupervisorPid = 0
        SupervisorPath = $null
        SupervisorStartedAt = $null
        TunnelPid     = 0
        TunnelPath    = $null
        TunnelStartedAt = $null
        BackendKind      = $null
        ImportedProfile  = $null
        AppPid        = 0
        AppPath       = $Application.Path
        AppStartedAt  = $null
        Error          = $null
    }
    Write-SessionState -Id $id -State $state

    $request = [ordered]@{
        Command          = $Application.Path
        Arguments        = @($ApplicationArguments)
        WorkingDirectory = (Get-Location).Path
        GeneratedProfile = $generatedProfile
        ProcessName      = $Application.ProcessName
        ProcessNames     = @($Application.ProcessNames)
        AllowedApp       = $Application.AllowedApp
        App              = $Application.Label
        Detach           = $Detach
    }
    Write-JsonAtomic -Value $request -Path (Join-Path $directory 'request.json')
    Write-Utf8File -Path $script:LastProfilePath -Content ($profileId + [Environment]::NewLine)

    if (-not $Detach) {
        Write-Output "Conduit session $id ($($Application.Label), $profileId)"
        Invoke-ConduitSupervisor -Id $id
        return
    }

    $hostExecutable = (Get-Process -Id $PID).Path
    Start-DetachedSupervisor -HostExecutable $hostExecutable -SessionId $id -SessionDirectory $directory

    for ($attempt = 0; $attempt -lt 450; $attempt++) {
        Start-Sleep -Milliseconds 100
        $current = Read-SessionState -Id $id
        if ($null -ne $current -and $current.State -eq 'active') {
            Write-Output "Conduit session $id started: $($Application.Label) via $profileId"
            return
        }
        if ($null -ne $current -and $current.State -eq 'failed') {
            Throw-ConduitError "session failed: $($current.Error)"
        }
        if ($null -ne $current -and [int]$current.SupervisorPid -gt 0 -and
            -not (Test-SessionRoleProcess -State $current -Role Supervisor)) {
            Throw-ConduitError "session supervisor exited during startup; see 'conduit logs $id'"
        }
    }

    Throw-ConduitError "session startup timed out; see 'conduit logs $id'"
    }
    finally {
        if ($null -ne $launchLock) {
            $launchLock.Dispose()
        }
    }
}


function Show-ConduitStatus {
    $sessions = @(Get-ConduitSessions)
    if ($sessions.Count -eq 0) {
        Write-Output 'Conduit: no sessions'
        return
    }

    $rows = foreach ($state in $sessions) {
        $displayState = $state.State
        if (-not (Test-SessionActive $state) -and $state.State -in @('starting', 'active', 'stopping')) {
            $displayState = 'stale'
        }
        [pscustomobject]@{
            SESSION = $state.Id
            STATE   = $displayState
            APP     = $state.App
            PROFILE = $state.Profile
            PID     = $state.AppPid
        }
    }
    $rows | Sort-Object SESSION | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
}


function Show-ConduitProfiles {
    $profiles = @(Get-ConduitProfiles)
    if ($profiles.Count -eq 0) {
        Throw-ConduitError "no VPN profiles found under $script:ProfileDir"
    }

    $last = ''
    if (Test-Path -LiteralPath $script:LastProfilePath -PathType Leaf) {
        $last = (Read-Utf8File -Path $script:LastProfilePath).Trim()
    }

    $activeProfiles = @{}
    foreach ($session in Get-ActiveSessions) {
        if (-not $activeProfiles.ContainsKey($session.Profile)) {
            $activeProfiles[$session.Profile] = 0
        }
        $activeProfiles[$session.Profile]++
    }

    foreach ($profile in $profiles) {
        $id = Get-ProfileId $profile
        $marks = ''
        try { Test-WireGuardProfile -Path $profile.FullName }
        catch { $marks += ' [invalid]' }
        if ($id -ieq $last) { $marks += ' [last]' }
        if ($activeProfiles.ContainsKey($id)) { $marks += " [active:$($activeProfiles[$id])]" }
        Write-Output "  $id$marks"
    }
}


function Show-ConduitLogs {
    param([AllowEmptyString()][string] $Selector)

    $session = Resolve-SessionSelector -Selector $Selector -IncludeInactive
    $directory = Get-SessionDirectory $session.Id
    $files = @(
        (Join-Path $directory 'conduit-error.log'),
        (Join-Path $directory 'supervisor.log'),
        (Join-Path $directory 'supervisor-error.log'),
        (Join-Path $directory 'import.log'),
        (Join-Path $directory 'import-error.log'),
        (Join-Path $directory 'tunnel.log'),
        (Join-Path $directory 'tunnel-error.log'),
        (Join-Path $directory 'app.log'),
        (Join-Path $directory 'app-error.log')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

    if ($files.Count -eq 0) {
        Write-Output "Conduit: no logs for session $($session.Id)"
        return
    }

    foreach ($file in $files) {
        Write-Output "== $([System.IO.Path]::GetFileName($file)) =="
        Get-Content -LiteralPath $file -Tail 200
    }
}


function Stop-ConduitSession {
    param([Parameter(Mandatory = $true)] $Session)

    $sessionId = [string]$Session.Id
    $directory = Get-SessionDirectory $sessionId
    $knownAppPid = [int]$Session.AppPid
    $knownTunnelPid = [int]$Session.TunnelPid
    $knownSupervisorPid = [int]$Session.SupervisorPid
    $manageProcesses = Test-SessionActive $Session
    if (-not $manageProcesses) {
        $knownAppPid = 0
        $knownTunnelPid = 0
        $knownSupervisorPid = 0
    }
    Write-Utf8File -Path (Join-Path $directory 'stop.requested') -Content ([DateTime]::UtcNow.ToString('o'))

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (-not $manageProcesses) { break }
        $current = Read-SessionState -Id $sessionId
        if ($null -ne $current) {
            $Session = $current
            $knownAppPid = [int]$Session.AppPid
            $knownTunnelPid = [int]$Session.TunnelPid
            $knownSupervisorPid = [int]$Session.SupervisorPid
        }

        if (-not (Test-SessionRoleProcess -State $Session -Role Supervisor) -and
            -not (Test-SessionRoleProcess -State $Session -Role Tunnel) -and
            -not (Test-SessionRoleProcess -State $Session -Role App)) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ($manageProcesses -and ((Test-SessionRoleProcess -State $Session -Role Supervisor) -or
        (Test-SessionRoleProcess -State $Session -Role Tunnel) -or
        (Test-SessionRoleProcess -State $Session -Role App))) {
        $allowedApp = [string](Get-StateProperty -State $Session -Name 'AllowedApp')
        $processNames = @(Get-StateProperty -State $Session -Name 'ProcessNames')
        if (-not [string]::IsNullOrWhiteSpace($allowedApp) -and $processNames.Count -gt 0) {
            try {
                Stop-AllowedApplicationProcesses -ProcessNames $processNames `
                    -AllowedApp $allowedApp -SessionStartedAt $Session.StartedAt
            }
            catch {}
        }
        if (Test-SessionRoleProcess -State $Session -Role App) {
            Stop-ProcessTree -ProcessId $knownAppPid
        }
        if (Test-SessionRoleProcess -State $Session -Role Tunnel) {
            Stop-ProcessTree -ProcessId $knownTunnelPid
        }
        if (Test-SessionRoleProcess -State $Session -Role Supervisor) {
            Stop-ProcessTree -ProcessId $knownSupervisorPid
        }

        $backend = Find-WireSockClient
        if ($null -ne $backend) {
            $backendKind = [string](Get-StateProperty -State $Session -Name 'BackendKind')
            if ([string]::IsNullOrWhiteSpace($backendKind)) {
                $backendKind = Get-WireSockBackendKind -Backend $backend
            }
            $importedProfile = [string](Get-StateProperty -State $Session -Name 'ImportedProfile')
            Stop-WireSockProcess -Process $null -Backend $backend -BackendKind $backendKind `
                -ImportedProfile $importedProfile -WorkingDirectory $directory
        }
    }

    Start-Sleep -Milliseconds 250
    if ($manageProcesses -and ((Test-SessionRoleProcess -State $Session -Role Supervisor) -or
        (Test-SessionRoleProcess -State $Session -Role Tunnel) -or
        (Test-SessionRoleProcess -State $Session -Role App))) {
        Throw-ConduitError "session $sessionId could not be stopped; its state was preserved for recovery"
    }

    if (Test-Path -LiteralPath $directory -PathType Container) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    Write-Output "session $sessionId stopped"
}


function Stop-AllConduitSessions {
    $sessions = @(Get-ConduitSessions)
    if ($sessions.Count -eq 0) {
        Write-Output 'no sessions'
        return
    }
    foreach ($session in $sessions) {
        Stop-ConduitSession -Session $session
    }
}


function Invoke-ConduitDoctor {
    $failures = 0
    Write-Output "Conduit $script:Version"
    Write-Output 'Doctor (Windows)'
    Write-Output ''

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Write-Output '[OK]   Windows'
    }
    else {
        Write-Output '[FAIL] Windows is required for conduit.ps1'
        $failures++
    }

    if ($PSVersionTable.PSVersion -ge [Version]'5.1') {
        Write-Output "[OK]   PowerShell $($PSVersionTable.PSVersion)"
    }
    else {
        Write-Output '[FAIL] PowerShell 5.1 or newer is required'
        $failures++
    }

    $backend = Find-WireSockClient
    if ($null -ne $backend) {
        $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($backend).FileVersion
        Write-Output "[OK]   WireSock Secure Connect $version"
    }
    else {
        Write-Output '[FAIL] WireSock Secure Connect (winget install NTKERNEL.WireSockVPNClient)'
        $failures++
    }

    $profiles = @(Get-ConduitProfiles)
    if ($profiles.Count -gt 0) {
        $invalidProfiles = 0
        foreach ($profile in $profiles) {
            try { Test-WireGuardProfile -Path $profile.FullName }
            catch {
                Write-Output "[FAIL] $(Get-ProfileId $profile): $($_.Exception.Message)"
                $invalidProfiles++
            }
        }
        if ($invalidProfiles -eq 0) {
            Write-Output "[OK]   $($profiles.Count) VPN profile(s)"
        }
        $failures += $invalidProfiles
    }
    else {
        Write-Output "[WARN] no VPN profiles under $script:ProfileDir"
        if ($null -ne (Find-WireGuardTool)) {
            Write-Output '[OK]   wg.exe is available for WARP bootstrap'
        }
        else {
            Write-Output '[WARN] wg.exe is required only for WARP bootstrap (install WireGuard for Windows)'
        }
    }

    if ($null -ne (Find-SquirrelApplication -Command 'discord')) {
        $dnsHealth = Get-DiscordDnsHealth
        if ($dnsHealth.State -eq 'ok') {
            Write-Output '[OK]   Discord DNS answers match a trusted public resolver'
        }
        elseif ($dnsHealth.State -eq 'rewritten') {
            Write-Output '[FAIL] Windows DNS appears to rewrite Discord addresses; configure a trusted system resolver such as 1.1.1.1/1.0.0.1'
            $failures++
        }
        else {
            Write-Output "[WARN] Discord DNS check: $($dnsHealth.Message)"
        }
    }

    $active = @(Get-ActiveSessions)
    if ($active.Count -eq 0) {
        Write-Output '[OK]   no conflicting Conduit session'
    }
    elseif ($active.Count -eq 1) {
        Write-Output "[OK]   active session $($active[0].Id)"
    }
    else {
        Write-Output '[FAIL] multiple Windows sessions detected; stop them with conduit kill --all'
        $failures++
    }

    Write-Output ''
    if ($failures -eq 0) {
        Write-Output 'Conduit is ready.'
        $script:ExitCode = 0
        return
    }
    Write-Output "Conduit found $failures problem(s)."
    $script:ExitCode = 1
}


function Test-ConduitAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}


function Invoke-ConduitUpdate {
    $active = @(Get-ActiveSessions)
    if ($active.Count -gt 0) {
        Throw-ConduitError "stop the active session first with 'conduit kill $($active[0].Id)'"
    }

    $installerUrl = [Environment]::GetEnvironmentVariable('CONDUIT_INSTALL_URL')
    if ([string]::IsNullOrWhiteSpace($installerUrl)) {
        $installerUrl = $script:InstallerUrl
    }

    [Uri]$uri = $null
    if (-not [Uri]::TryCreate($installerUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https') {
        Throw-ConduitError 'CONDUIT_INSTALL_URL must be an absolute HTTPS URL'
    }

    $quotedUrl = $installerUrl.Replace("'", "''")
    $updateCommand = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    `$source = Invoke-RestMethod -UseBasicParsing -Uri '$quotedUrl'
    & ([ScriptBlock]::Create([string]`$source))
    exit 0
}
catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($updateCommand))
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)

    Write-Output "Updating Conduit from $installerUrl"
    try {
        if (Test-ConduitAdministrator) {
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-NativeArguments $arguments) `
                -Wait -PassThru
        }
        else {
            Write-Output 'Requesting Administrator permission...'
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-NativeArguments $arguments) `
                -Verb RunAs -Wait -PassThru
        }
    }
    catch {
        Throw-ConduitError "update was cancelled or could not start: $($_.Exception.Message)"
    }

    if ($process.ExitCode -ne 0) {
        Throw-ConduitError "update failed with exit code $($process.ExitCode)"
    }
    Write-Output 'Conduit update completed.'
}


function Invoke-WarpBootstrap {
    $targetDirectory = Join-Path $script:ProfileDir 'cloudflare'
    $target = Join-Path $targetDirectory 'warp.conf'
    if (Test-Path -LiteralPath $target) {
        Write-Output "WARP profile already exists: $target"
        return
    }

    $wg = Find-WireGuardTool
    if ($null -eq $wg) {
        Throw-ConduitError 'wg.exe was not found; install WireGuard for Windows before running bootstrap'
    }

    Protect-ConduitDirectory -Path $script:ProfileDir
    Protect-ConduitDirectory -Path $targetDirectory

    $privateKey = (& $wg genkey | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($privateKey)) {
        Throw-ConduitError 'WireGuard generated an empty private key'
    }
    $publicKey = ($privateKey | & $wg pubkey | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($publicKey)) {
        Throw-ConduitError 'WireGuard generated an empty public key'
    }

    $apiUrl = [Environment]::GetEnvironmentVariable('CONDUIT_WARP_API_URL')
    if ([string]::IsNullOrWhiteSpace($apiUrl)) { $apiUrl = 'https://api.cloudflareclient.com/v0a1922/reg' }
    $payload = @{
        key          = $publicKey
        install_id   = ''
        fcm_token     = ''
        tos          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.000+00:00')
        type         = 'Android'
        model        = 'PC'
        locale       = 'en_US'
    } | ConvertTo-Json
    $headers = @{
        'User-Agent'        = 'okhttp/3.12.1'
        'CF-Client-Version' = 'a-6.3-1922'
    }

    Write-Output 'Bootstrapping Cloudflare WARP...'
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        # Windows PowerShell 5.1 can default to TLS 1.0 on otherwise modern
        # systems. Cloudflare's registration endpoint requires TLS 1.2+.
        [Net.ServicePointManager]::SecurityProtocol = `
            $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' `
            -Headers $headers -Body $payload -TimeoutSec 30
    }
    catch {
        Throw-ConduitError "Cloudflare WARP registration failed: $($_.Exception.Message)"
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    }

    $peer = $response.config.peers | Select-Object -First 1
    $ipv4 = [string]$response.config.interface.addresses.v4
    $ipv6 = [string]$response.config.interface.addresses.v6
    if ($null -eq $peer -or [string]::IsNullOrWhiteSpace([string]$peer.public_key) -or
        [string]::IsNullOrWhiteSpace($ipv4) -or [string]::IsNullOrWhiteSpace([string]$peer.endpoint.host)) {
        Throw-ConduitError 'invalid response from Cloudflare WARP API'
    }

    if ($ipv4 -notlike '*/*') { $ipv4 += '/32' }
    $addresses = $ipv4
    if (-not [string]::IsNullOrWhiteSpace($ipv6)) {
        if ($ipv6 -notlike '*/*') { $ipv6 += '/128' }
        $addresses += ", $ipv6"
    }

    $dns = [Environment]::GetEnvironmentVariable('CONDUIT_WARP_DNS')
    if ([string]::IsNullOrWhiteSpace($dns)) { $dns = '1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001' }
    $mtu = [Environment]::GetEnvironmentVariable('CONDUIT_WARP_MTU')
    if ([string]::IsNullOrWhiteSpace($mtu)) { $mtu = '1280' }
    $allowedIps = [Environment]::GetEnvironmentVariable('CONDUIT_WARP_ALLOWED_IPS')
    if ([string]::IsNullOrWhiteSpace($allowedIps)) { $allowedIps = '0.0.0.0/0, ::/0' }

    $configuration = @"
[Interface]
PrivateKey = $privateKey
Address = $addresses
DNS = $dns
MTU = $mtu

[Peer]
PublicKey = $($peer.public_key)
AllowedIPs = $allowedIps
Endpoint = $($peer.endpoint.host)
"@

    $temporary = Join-Path $targetDirectory ('.warp.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File -Path $temporary -Content ($configuration.Trim() + "`r`n")
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        $privateKey = $null
        $publicKey = $null
        $payload = $null
    }

    Write-Output "Generated: $target"
}


function Invoke-Conduit {
    param([object[]] $CommandLine)

    $values = @($CommandLine | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if ($values.Count -eq 0) {
        Show-ConduitUsage
        $script:ExitCode = 1
        return
    }

    switch ($values[0]) {
        { $_ -in @('-h', '--help') } {
            Show-ConduitUsage
            return
        }
        { $_ -in @('-V', '--version', 'version') } {
            Write-Output "conduit $script:Version"
            return
        }
        'show-vpn' {
            if ($values.Count -ne 1) { Throw-ConduitError 'usage: conduit show-vpn' }
            Show-ConduitProfiles
            return
        }
        'status' {
            if ($values.Count -ne 1) { Throw-ConduitError 'usage: conduit status' }
            Show-ConduitStatus
            return
        }
        'doctor' {
            if ($values.Count -ne 1) { Throw-ConduitError 'usage: conduit doctor' }
            Invoke-ConduitDoctor
            return
        }
        'bootstrap' {
            if ($values.Count -ne 1) { Throw-ConduitError 'usage: conduit bootstrap' }
            Invoke-WarpBootstrap
            return
        }
        'update' {
            if ($values.Count -ne 1) { Throw-ConduitError 'usage: conduit update' }
            Invoke-ConduitUpdate
            return
        }
        'add' {
            if ($values.Count -ne 3 -or $values[1] -notin @('shortcut', 'startup')) {
                Throw-ConduitError 'usage: conduit add <shortcut|startup> <application>'
            }
            Add-ConduitShortcut -Kind $values[1] -Application $values[2]
            return
        }
        'remove' {
            if ($values.Count -ne 3 -or $values[1] -notin @('shortcut', 'startup')) {
                Throw-ConduitError 'usage: conduit remove <shortcut|startup> <application>'
            }
            Remove-ConduitShortcut -Kind $values[1] -Application $values[2]
            return
        }
        'logs' {
            if ($values.Count -gt 2) { Throw-ConduitError 'usage: conduit logs [session]' }
            $selector = if ($values.Count -eq 2) { $values[1] } else { '' }
            Show-ConduitLogs -Selector $selector
            return
        }
        'kill' {
            if ($values.Count -eq 2 -and $values[1] -eq '--all') {
                Stop-AllConduitSessions
                return
            }
            if ($values.Count -gt 2) { Throw-ConduitError 'usage: conduit kill [session]' }
            $selector = if ($values.Count -eq 2) { $values[1] } else { '' }
            $session = Resolve-SessionSelector -Selector $selector -IncludeInactive
            Stop-ConduitSession -Session $session
            return
        }
        'attach' {
            Throw-ConduitError "'attach' is not available on Windows because Windows has no Linux-style network namespaces; launch the target app as a new Conduit session"
        }
        '__supervise' {
            if ($values.Count -ne 2 -or $values[1] -notmatch '^[0-9a-f]{8}$') {
                Throw-ConduitError 'invalid supervisor invocation'
            }
            Invoke-ConduitSupervisor -Id $values[1]
            return
        }
    }

    $vpn = ''
    $provider = ''
    $detach = $true
    $index = 0
    while ($index -lt $values.Count) {
        $value = $values[$index]
        if ($value -eq '--vpn') {
            if ($index + 1 -ge $values.Count) { Throw-ConduitError '--vpn requires a value' }
            $vpn = $values[$index + 1]
            $index += 2
            continue
        }
        if ($value.StartsWith('--vpn=')) {
            $vpn = $value.Substring(6)
            $index++
            continue
        }
        if ($value -eq '--provider') {
            if ($index + 1 -ge $values.Count) { Throw-ConduitError '--provider requires a value' }
            $provider = $values[$index + 1]
            $index += 2
            continue
        }
        if ($value.StartsWith('--provider=')) {
            $provider = $value.Substring(11)
            $index++
            continue
        }
        if ($value -in @('-d', '--detach')) {
            $detach = $true
            $index++
            continue
        }
        if ($value -in @('-f', '--foreground')) {
            $detach = $false
            $index++
            continue
        }
        if ($value -eq '--') {
            $index++
            break
        }
        if ($value.StartsWith('-')) {
            Throw-ConduitError "unknown option: $value"
        }
        break
    }

    if ($index -ge $values.Count) {
        Throw-ConduitError 'an application command is required'
    }

    Show-ConduitUpdateNotice
    $profile = Select-ConduitProfile -Vpn $vpn -Provider $provider
    $application = Resolve-ConduitApplication -Command $values[$index]
    $applicationArguments = @()
    if ($index + 1 -lt $values.Count) {
        $applicationArguments = @($values[($index + 1)..($values.Count - 1)])
    }

    Start-ConduitSession -Profile $profile -Application $application `
        -ApplicationArguments $applicationArguments -Detach $detach
}


try {
    Invoke-Conduit -CommandLine @($ConduitArguments)
}
catch {
    [Console]::Error.WriteLine("conduit: $($_.Exception.Message)")
    if ([Environment]::GetEnvironmentVariable('CONDUIT_DEBUG') -eq '1') {
        [Console]::Error.WriteLine($_.ScriptStackTrace)
    }
    $script:ExitCode = 1
}
exit $script:ExitCode
