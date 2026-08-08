# Installation

## 1. Dependencies

```bash
# Arch / CachyOS
sudo pacman -S wireguard-tools iproute2 util-linux

# Debian / Ubuntu
sudo apt install wireguard-tools iproute2 util-linux
```

## 2. Get the repo

```bash
git clone https://github.com/berry/conduit-vpn.git
cd conduit-vpn
```

Or grab just the script:

```bash
curl -O https://raw.githubusercontent.com/berry/conduit-vpn/main/conduit.sh
```

## 3. Install

```bash
sudo install -m 755 conduit.sh /usr/local/bin/conduit
```

The script auto-detects your home directory (also through sudo), so no
configuration is needed. Profiles are read from `~/vpns` by default;
set `CONDUIT_DIR` to use a different location.

## 4. Passwordless sudo

```bash
echo "\$USER ALL=(root) NOPASSWD: /usr/local/bin/conduit" | sudo tee /etc/sudoers.d/conduit
```

## 5. WireGuard profiles

Download WireGuard configs from your provider:

- **Proton:** account.protonvpn.com → Downloads → WireGuard configuration (paid plan required)
- **Mullvad:** mullvad.net → Account → WireGuard configuration

Drop them into the profile directory:

```bash
mkdir -p ~/vpns
mv ~/Downloads/*.conf ~/vpns/
chmod 600 ~/vpns/*.conf
```

## 6. Verify

```bash
bash -n /usr/local/bin/conduit && echo "SYNTAX OK"
conduit show-vpn
```

Your profiles should be listed.

## 7. First run

```bash
conduit bash
```

Inside the namespace:

```bash
curl -s ifconfig.me        # should return the VPN IP
getent hosts discord.com   # should return real IPs (not poisoned ones)
exit
```

On the host:

```bash
curl -s ifconfig.me        # your own IP — must differ
```

## 8. KDE menu entries (optional)

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

```bash
cd conduit-vpn
git pull
sudo install -m 755 conduit.sh /usr/local/bin/conduit
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `profile dir missing` | No configs in `~/vpns` — or set `CONDUIT_DIR` to your actual location |
| `any valid prefix is expected` | Outdated script — update; comma-separated addresses are supported |
| DNS not resolving inside | `conduit bash` → `cat /etc/resolv.conf` should show the VPN DNS |
| TLS handshake EOF | Exit IP is blocked by the service → `conduit kill` and retry (new random profile) |
| Screen sharing broken | `xlsclients \| grep -i discord` — if listed, the app is in X11 mode; session env import failed |
| `mount: ... does not exist` | `/etc/netns/conduit/` missing — the script creates it on first run; retry |

## Uninstall

```bash
sudo rm /usr/local/bin/conduit /etc/sudoers.d/conduit
sudo rm -rf /etc/netns/conduit /etc/wireguard/.conduit-last
rm ~/.local/share/applications/*-vpn.desktop
```