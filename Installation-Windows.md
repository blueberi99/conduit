# Installing Conduit on Windows

The Windows port supports Windows 10 and Windows 11. It keeps Conduit's core
behavior—only the selected application uses the WireGuard tunnel—by using
[WireSock Secure Connect](https://www.wiresock.net/) as the Windows packet
filtering backend.

Windows does not expose Linux-style network namespaces for ordinary desktop
applications. For that reason, the Windows implementation has a different
backend and intentionally supports one active Conduit tunnel at a time.

## 1. Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- Windows Package Manager (`winget`)

The online installer adds WireSock Secure Connect automatically. If it cannot
find a WireGuard `.conf` profile, it also installs WireGuard for Windows and
creates a Cloudflare WARP profile.

WireSock Secure Connect is free for personal, educational, and non-profit use.
Commercial use requires an appropriate WireSock license. Review its current
license before distributing or using Conduit in a business environment.

## 2. Install

Open PowerShell **as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/blueberi99/conduit/master/bootstrap.ps1 | iex
```

This follows the same download-and-run model used by WinUtil: the command reads
the bootstrap script from the official Conduit GitHub repository, downloads the
current `master` archive, and runs the installer. Review `bootstrap.ps1` before
executing it if you do not want to trust a mutable branch as Administrator.

Dependencies use the official Windows Package Manager package identifiers:

```powershell
winget install --id NTKERNEL.WireSockVPNClient --exact
winget install --id WireGuard.WireGuard --exact
```

For development from a cloned repository, use Administrator PowerShell:

```powershell
.\install.ps1 -InstallWireSock -BootstrapIfEmpty
```

The installer copies Conduit to:

```text
%LOCALAPPDATA%\Programs\Conduit
```

It also adds that directory to your user `PATH`. Open a new terminal after the
installer finishes.

## 3. Add VPN profiles

Profiles use the same layout as Linux:

```text
%USERPROFILE%\vpns\
├── proton\
│   └── PDE-778-DE-778.conf
├── mullvad\
│   └── de-sto-wg-001.conf
└── cloudflare\
    └── warp.conf
```

You can select another directory for the current terminal:

```powershell
$env:CONDUIT_DIR = 'D:\VPN profiles'
```

Conduit never edits the source profile. It creates an ACL-protected temporary
copy, injects a WireSock `AllowedApps` rule for the selected application, and
sets both IPv4 and IPv6 default routes in that copy. WireSock evaluates
`AllowedApps` and `AllowedIPs` together; covering both address families prevents
an incomplete provider profile from letting application traffic bypass the
tunnel. Windows profiles must therefore contain exactly one `[Peer]` section.

The online installer does this automatically when the profile directory is
empty. To generate it manually later, run:

```powershell
conduit bootstrap
```

## 4. Verify the installation

```powershell
conduit --version
conduit doctor
conduit show-vpn
```

`doctor` reports a missing WireSock installation, invalid profiles, and stale
or conflicting sessions.

## 5. Launch applications

```powershell
conduit discord
conduit firefox.exe
conduit --provider proton discord
conduit --vpn de-sto-wg-001 firefox.exe
conduit -f curl.exe https://ifconfig.me
```

Graphical applications detach by default. `-f` keeps a command in the
foreground and returns its exit code.

### Discord updates

Discord installs its executable below a versioned path such as:

```text
%LOCALAPPDATA%\Discord\app-1.0.9208\Discord.exe
```

Conduit deliberately does not persist that changing path. On every launch it
finds the newest installed Discord executable, while the tunnel filter targets
the stable `%LOCALAPPDATA%\Discord` directory. This also covers Discord helper
processes and continues to work after a Squirrel update creates a new `app-*`
directory. The same handling exists for Discord PTB and Discord Canary:

```powershell
conduit discordptb
conduit discordcanary
```

Close an already-running Discord instance before starting it through Conduit.
This gives Conduit an unambiguous application lifecycle and prevents the
existing process from escaping session management.

## 6. Manage a session

```powershell
conduit status
conduit logs
conduit kill
conduit kill --all
```

Unlike Linux, `attach` is unavailable because Windows applications cannot be
moved into a Linux-style network namespace after launch.

## 7. Kill switch and recovery

Conduit enables WireSock's network lock by default. To disable it for a single
terminal (not recommended):

```powershell
$env:CONDUIT_NETWORK_LOCK = '0'
```

If Windows or WireSock crashes while the lock is active and connectivity does
not return, open an Administrator terminal and run:

```powershell
& 'C:\Program Files\WireSock Secure Connect\command-line\wiresock-connect-cli.exe' reset-network-lock
```

## Updating

Run this from a normal terminal:

```powershell
conduit update
```

Conduit refuses to update while a managed application session is active. It
then asks for Administrator permission through UAC and runs the same official
GitHub bootstrap used for first installation. VPN profiles remain separate and
are preserved.

## Uninstall

From an Administrator PowerShell in the repository:

```powershell
.\uninstall.ps1
```

The uninstaller removes Conduit and its generated session state. It preserves
the VPN profiles under `%USERPROFILE%\vpns` and does not uninstall WireSock.

## WireSock trust boundary

WireSock is a third-party, mostly proprietary networking component, not part of
Conduit or Microsoft. Its application binaries are Authenticode-signed and its
installed packet-filter drivers are Microsoft Windows Hardware Compatibility
Publisher-signed. The winget manifest pins the installer SHA-256 and Microsoft
applies automated malware/PUA validation to community packages.

Those checks establish publisher and package integrity; they are not an
independent security audit. WireSock installs automatic services running as
`LocalSystem` plus a kernel networking driver, so it is a high-trust dependency.
The free edition is non-commercial and includes telemetry according to the
vendor's current licensing pages. Do not deploy it in a commercial or
high-assurance environment without reviewing the license and accepting that
closed-source trust boundary.
