# Conduit

Per-application WireGuard split tunneling for Linux and Windows.

Run one application through a VPN while the rest of the computer keeps using
its normal connection. Conduit keeps ordinary WireGuard profiles
provider-agnostic and gives both platforms the same everyday command:

```text
conduit discord
```

## How it works

On Linux, Conduit creates a network namespace containing its own WireGuard
interface, routes, and DNS configuration. This gives every launch a genuinely
isolated network stack.

On Windows, Conduit uses WireSock Secure Connect and generates a protected,
session-only profile with an `AllowedApps` filter. The original WireGuard
profile is never modified.

| Capability | Linux | Windows |
| --- | --- | --- |
| Per-application tunnel | Network namespace | WireSock application filter |
| Kill switch | Namespace has no fallback route | WireSock network lock |
| Concurrent profiles | Yes | One active tunnel |
| Attach another command | Yes | No |
| Profile layout | `~/vpns` | `%USERPROFILE%\vpns` |

## Features

- Only the selected application uses the VPN
- A kill switch prevents fallback to the normal connection
- Random or explicit profile selection
- Provider folders for Proton, Mullvad, Windscribe, Cloudflare, or any WireGuard provider
- Automatic Cloudflare WARP profile bootstrap
- One-line Windows installation and Administrator-approved self-update
- Detached GUI sessions with status, logs, and explicit cleanup
- Update-safe Discord, Discord PTB, and Discord Canary discovery on Windows

## Usage

The common commands are:

```text
conduit discord
conduit --vpn mullvad-se firefox
conduit --provider proton discord
conduit --provider windscribe discord
conduit show-vpn
conduit status
conduit logs
conduit kill
conduit kill --all
```

Use `conduit --help` for platform-specific details.

## Install on Linux

Required packages are `wireguard-tools`, `iproute2`, `util-linux`, `curl`,
`jq`, and `sudo` or `doas`.

```bash
git clone https://github.com/blueberi99/conduit.git
cd conduit
chmod +x conduit.sh install.sh uninstall.sh
./install.sh
```

See [Installation.md](Installation.md) for the complete Linux guide.

## Install on Windows

The Windows backend depends on WireSock Secure Connect, a separately licensed,
mostly proprietary third-party product. WireSock is not part of Conduit and is
not covered by Conduit's AGPL license. Its free edition is limited to personal,
educational, and non-profit use and includes telemetry; commercial use requires
a separate WireSock license. See [Third-party notices](THIRD-PARTY-NOTICES.md).

Open PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/blueberi99/conduit/master/bootstrap.ps1 | iex
```

If WireSock is not already present, the installer displays these terms and
requires you to type `ACCEPT` before asking winget to install it under the
WireSock EULA. If no `.conf` profile exists, it also installs WireGuard for
Windows and creates a Cloudflare WARP profile.
Open a new terminal and verify the installation:

```powershell
conduit doctor
conduit show-vpn
conduit discord
```

Update later with an Administrator/UAC prompt:

```powershell
conduit update
```

WireSock Secure Connect is free for personal, educational, and non-profit use;
commercial use requires an appropriate WireSock license. See
[Installation-Windows.md](Installation-Windows.md) for setup, Discord update
handling, limitations, and recovery instructions.

## Profiles

Conduit recursively discovers ordinary `.conf` files:

```text
vpns/
├── proton/
│   └── PDE-778-DE-778.conf
├── mullvad/
│   └── de-sto-wg-001.conf
├── windscribe/
│   └── Athens-Odeon-WG.conf
└── cloudflare/
    └── warp.conf
```

Standard Windscribe WireGuard profiles are supported, including dual-stack
`Address` values, provider DNS, and `PresharedKey`. Legacy flat files named
`Windscribe-*.conf` can also be selected with `--provider windscribe`.

Without `--vpn`, Conduit chooses a random profile and avoids the last-used one
when another choice exists.

## Platform notes

Linux network namespaces can isolate several simultaneous applications and
profiles. Windows has no equivalent public desktop API, so the Windows backend
allows one active Conduit tunnel and does not implement `attach`.

Discord's Windows executable lives in a changing `app-<version>` directory.
Conduit resolves the newest executable at launch and filters the stable Discord
installation root, so Discord updates do not invalidate the VPN rule.

## License

AGPLv3. Derivatives must remain open source under the same license and preserve
the copyright notice. If a modified version is run as a network service, its
source must be offered to users. See [LICENSE](LICENSE).
