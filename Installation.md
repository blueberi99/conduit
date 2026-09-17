# Installation.md

# Installation

Conduit is designed to be distribution-agnostic. The installer checks for the tools it needs rather than detecting your Linux distribution.

## 1. Dependencies

### Fedora / Nobara

```bash
sudo dnf install wireguard-tools iproute util-linux curl jq sudo
```

### Arch / CachyOS

```bash
sudo pacman -S wireguard-tools iproute2 util-linux curl jq sudo
```

### Debian / Ubuntu

```bash
sudo apt install wireguard-tools iproute2 util-linux curl jq sudo
```

Conduit requires:

- `bash`
- `ip`
- `wg`
- `wg-quick`
- `setsid`
- `setpriv` or `runuser`
- `sudo`
- `curl` and `jq` for automatic Cloudflare WARP bootstrap

## 2. Get Conduit

```bash
git clone https://github.com/blueberi99/conduit.git
cd conduit
```

## 3. Install

```bash
chmod +x conduit.sh install.sh uninstall.sh
./install.sh
```

The installer:

- validates `conduit.sh`
- checks required dependencies
- installs Conduit to `/usr/local/bin/conduit`
- installs the minimal sudoers rule under `/etc/sudoers.d/conduit`
- creates `~/vpns` with secure permissions
- bootstraps a Cloudflare WARP profile if no VPN profiles exist
- runs `conduit doctor` after installation

The installed binary is owned by root and is not writable by the regular user.

## 4. Automatic Cloudflare WARP setup

If `~/vpns` contains no WireGuard profiles, Conduit automatically creates:

```text
~/vpns/cloudflare/warp.conf
```

The WireGuard private key is generated locally. The generated profile is stored with `0600` permissions.

You can also manually trigger WARP setup:

```bash
conduit bootstrap
```

Existing WARP profiles are never silently overwritten.

## 5. Using your own VPN profiles

Conduit supports normal WireGuard configurations from providers such as Proton VPN, Mullvad, Windscribe, Cloudflare WARP, and others.

Recommended layout:

```text
~/vpns/
├── proton/
│   └── PDE-778-DE-778.conf
├── mullvad/
│   └── de-ber-wg-102.conf
├── windscribe/
│   └── Athens-Odeon-WG.conf
└── cloudflare/
    └── warp.conf
```

Windscribe WireGuard exports are supported with their dual-stack `Address`,
provider `DNS`, `Endpoint`, and `PresharedKey` fields unchanged. Legacy flat
files named `Windscribe-*.conf` can be selected with
`--provider windscribe`.

Create provider directories as needed:

```bash
mkdir -p ~/vpns/proton ~/vpns/mullvad ~/vpns/windscribe
```

Copy profiles:

```bash
cp ~/Downloads/*.conf ~/vpns/proton/
```

Secure them:

```bash
chmod 600 ~/vpns/proton/*.conf
```

Legacy flat profiles directly under `~/vpns/*.conf` are also supported.

To use another profile directory:

```bash
CONDUIT_DIR=/path/to/profiles conduit bash
```

## 6. Verify installation

```bash
conduit --version
conduit doctor
conduit show-vpn
```

Expected output:

```text
conduit 3.2.2
```

`conduit doctor` checks dependencies, profile permissions, privilege escalation, network namespace creation, and WireGuard support.

## 7. First tunnel test

Start an interactive shell:

```bash
conduit --provider cloudflare bash
```

Inside the Conduit session:

```bash
curl -4 https://ifconfig.me
echo

curl -6 https://ifconfig.me
echo

cat /etc/resolv.conf
ip addr show wg0
```

Then:

```bash
exit
```

Run the same IP check on the host:

```bash
curl https://ifconfig.me
```

The host connection should remain outside the Conduit VPN session.

## 8. Launch applications

GUI applications detach from the terminal automatically:

```bash
conduit discord
```

Or choose a provider:

```bash
conduit --provider proton discord
conduit --provider cloudflare firefox
conduit --provider windscribe discord
```

Each launch receives its own network namespace and WireGuard interface.

Multiple Conduit sessions can therefore use different VPN profiles simultaneously.

## 9. Session management

List sessions:

```bash
conduit status
```

Attach a shell to a session:

```bash
conduit attach discord
```

Run one command inside an existing session:

```bash
conduit attach discord curl https://ifconfig.me
```

View detached application logs:

```bash
conduit logs discord
```

Stop a session:

```bash
conduit kill discord
```

Session ID prefixes also work:

```bash
conduit kill 23af
```

Stop all sessions:

```bash
conduit kill --all
```

## 10. Desktop menu entries (optional)

Conduit commands can be used directly in normal XDG desktop entries.

Example:

```bash
mkdir -p ~/.local/share/applications

cat > ~/.local/share/applications/discord-vpn.desktop <<'EOF'
[Desktop Entry]
Name=Discord (VPN)
Exec=/usr/local/bin/conduit discord
Icon=discord
Type=Application
Categories=Network;InstantMessaging;
EOF
```

Vesktop:

```bash
cat > ~/.local/share/applications/vesktop-vpn.desktop <<'EOF'
[Desktop Entry]
Name=Vesktop (VPN)
Exec=/usr/local/bin/conduit vesktop
Icon=vesktop
Type=Application
Categories=Network;InstantMessaging;
EOF
```

## Updating

From the repository:

```bash
cd ~/Github/conduit
git pull
./install.sh
```

The installer can safely replace the existing Conduit binary and configuration.

Your VPN profiles remain separate under `~/vpns`.

## Troubleshooting

Run this first:

```bash
conduit doctor
```

### Profile permissions are too open

```bash
chmod 600 ~/vpns/**/*.conf
```

Or fix the affected file individually:

```bash
chmod 600 ~/vpns/cloudflare/warp.conf
```

### No profiles exist

Run:

```bash
conduit bootstrap
```

Conduit also performs this automatically when no profiles exist.

### Application output is missing

Detached applications write their output to their session log:

```bash
conduit status
conduit logs <session>
```

### Check DNS inside a session

```bash
conduit attach <session> cat /etc/resolv.conf
```

### Check VPN IP

```bash
conduit attach <session> curl https://ifconfig.me
```

### Stop broken/stuck sessions

```bash
conduit kill <session>
```

Or:

```bash
conduit kill --all
```

## Uninstall

From the repository:

```bash
./uninstall.sh
```

The uninstaller removes:

- `/usr/local/bin/conduit`
- `/etc/sudoers.d/conduit`
- Conduit runtime session state
- Conduit-owned network namespaces

It deliberately preserves:

```text
~/vpns
```

VPN profiles and private keys are never deleted automatically.
