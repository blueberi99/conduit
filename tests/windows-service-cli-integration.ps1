# SPDX-License-Identifier: AGPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repository 'conduit.ps1'
$fixture = Join-Path $repository 'tests\fixtures\cloudflare\example.conf'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('conduit-service-cli-' + [Guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profiles'
$stateRoot = Join-Path $testRoot 'state'
$appPath = Join-Path $testRoot 'test-app.exe'
$backendPath = Join-Path $testRoot 'wiresock-connect-cli.exe'
$capturePath = Join-Path $testRoot 'captured.conf'
$stopPath = Join-Path $testRoot 'disconnect.requested'
$deletedPath = Join-Path $testRoot 'deleted-profile.txt'

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

public static class FakeWireSockServiceCli
{
    public static int Main(string[] args)
    {
        try
        {
        if (args.Length == 0) return 1;
        string stop = Environment.GetEnvironmentVariable("FAKE_WIRESOCK_STOP");
        if (args[0] == "import")
        {
            if (Environment.GetEnvironmentVariable("FAKE_WIRESOCK_IMPORT_FAILURE") == "1")
            {
                Console.WriteLine("Failed to import profile: invalid test profile");
                return 0;
            }
            File.Copy(args[1], Environment.GetEnvironmentVariable("FAKE_WIRESOCK_CAPTURE"), true);
            return 0;
        }
        if (args[0] == "connect")
        {
            Console.WriteLine("Connection established");
            Console.Out.Flush();
            while (!File.Exists(stop)) Thread.Sleep(100);
            return 0;
        }
        if (args[0] == "disconnect")
        {
            File.WriteAllText(stop, "stop");
            return 0;
        }
        if (args[0] == "delete")
        {
            File.WriteAllText(Environment.GetEnvironmentVariable("FAKE_WIRESOCK_DELETED"), args[1]);
            return 0;
        }
        return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.ToString());
            return 2;
        }
    }
}
'@

$applicationSource = @'
public static class FakeApplication
{
    public static int Main(string[] args) { return 0; }
}
'@

try {
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $profileRoot 'example.conf')
    Add-Type -TypeDefinition $backendSource -Language CSharp -OutputAssembly $backendPath -OutputType ConsoleApplication
    Add-Type -TypeDefinition $applicationSource -Language CSharp -OutputAssembly $appPath -OutputType ConsoleApplication

    $env:CONDUIT_DIR = $profileRoot
    $env:CONDUIT_STATE_DIR = $stateRoot
    $env:CONDUIT_WIRESOCK = $backendPath
    $env:CONDUIT_STARTUP_DELAY_MS = '250'
    $env:CONDUIT_NO_TASKKILL = '1'
    $env:FAKE_WIRESOCK_CAPTURE = $capturePath
    $env:FAKE_WIRESOCK_STOP = $stopPath
    $env:FAKE_WIRESOCK_DELETED = $deletedPath

    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -f --vpn example $appPath 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    Assert-True ($exitCode -eq 0) "service CLI session failed: $($output -join ' ')"
    Assert-True (Test-Path -LiteralPath $capturePath -PathType Leaf) 'service CLI did not import the generated profile'
    Assert-True (Test-Path -LiteralPath $deletedPath -PathType Leaf) 'service CLI did not delete the imported profile'

    $sessionFile = Get-ChildItem -LiteralPath (Join-Path $stateRoot 'sessions') -Filter 'session.json' -Recurse |
        Select-Object -First 1
    $session = Get-Content -LiteralPath $sessionFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($session.State -eq 'stopped') 'service CLI session was not marked stopped'
    Assert-True ($session.BackendKind -eq 'service-cli') 'new WireSock CLI was not recognized'
    Assert-True ($session.ImportedProfile -match '^conduit-[0-9a-f]{8}$') 'temporary profile name was not session-unique'
    Assert-True ((Get-Content -LiteralPath $deletedPath -Raw) -eq $session.ImportedProfile) `
        'wrong WireSock profile was deleted'

    $env:FAKE_WIRESOCK_IMPORT_FAILURE = '1'
    $ErrorActionPreference = 'Continue'
    $failureOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -f --vpn example $appPath 2>&1)
    $failureExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Remove-Item Env:FAKE_WIRESOCK_IMPORT_FAILURE
    Assert-True ($failureExitCode -eq 1) 'reported WireSock import failure should fail the session'
    Assert-True (($failureOutput -join ' ') -match 'could not import the session profile') `
        'reported WireSock import failure was not surfaced clearly'
    Assert-True (($failureOutput -join ' ') -match 'Conduit session ([0-9a-f]{8})') `
        'failed session ID was not reported'
    $failureId = $Matches[1]

    $ErrorActionPreference = 'Continue'
    $logsOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        logs $failureId 2>&1)
    $logsExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-True ($logsExitCode -eq 0) 'failed-session logs command failed'
    Assert-True (($logsOutput -join ' ') -match '== import\.log ==') `
        'WireSock import log was omitted from conduit logs'

    Write-Output 'Conduit WireSock service CLI integration test passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    Remove-Item Env:FAKE_WIRESOCK_IMPORT_FAILURE -ErrorAction SilentlyContinue
}
