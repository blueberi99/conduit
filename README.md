# conduit

Per-app VPN split tunneling for Linux, using network namespaces + WireGuard.

Run any application inside its own VPN tunnel while the rest of your system
uses the normal connection. No daemon, no keyring, no VPN client — just
`iproute2` and `wireguard-tools`.

```
conduit discord
  └── network namespace "conduit" is created
        ├── wg0 (WireGuard, configured from the chosen profile)
        ├── default route → wg0 only (kill switch comes for free)
        ├── resolv.conf → VPN DNS (bind mount)
        ├── nsswitch.conf → systemd-resolved bypass (bind mount)
        └── the app runs inside, as your own user
```

Launch a second app (`conduit vesktop`) and it shares the existing tunnel —
no second connection is created.

## Features

- **True split tunneling** — traffic outside the app never touches the VPN
- **Kill switch** — if the tunnel drops, the app loses connectivity entirely; leaks are impossible
- **Multi-profile** — keep any number of `.conf` files in a directory, pick randomly or explicitly
- **Provider-agnostic** — Proton, Mullvad, or any plain WireGuard config works
- **DNS poisoning resistant** — bind-mounted `nsswitch.conf` bypasses systemd-resolved,
  so hijacked ISP DNS records never reach the app
- **Wayland/X11 friendly** — the real session environment is imported from the running
  desktop, so screen sharing and portals keep working

## Usage

```bash
conduit discord                      # random profile (excluding the last used)
conduit --vpn mullvad-se discord     # explicit profile
conduit firefox                      # any application works
conduit show-vpn                     # list profiles ([last] and [active] markers)
conduit kill                         # tear down the tunnel
conduit bash                         # debug shell inside the namespace
```

## Profile management

Profiles live in `~/vpns/*.conf`. Adding a profile = dropping a file into the directory.

```bash
conduit show-vpn
#   de-ber-wg-001.conf
#   de-fra-wg-203.conf [last]
#   PDE-421-DE-421.conf [active]
```

- Without `--vpn`, a random profile is chosen, excluding the last used one
- The last used profile is tracked in `/etc/wireguard/.conduit-last`
- To switch profiles while the tunnel is up: `conduit kill`, then relaunch

## Why the nsswitch.conf bind mount?

On some distributions (e.g. CachyOS) systemd-resolved is active and the `resolve`
module precedes `dns` in `nsswitch.conf`. Every `getaddrinfo()` call then goes to
the host's resolved over D-Bus **without ever reading resolv.conf** — and resolved
happily serves poisoned/hijacked ISP DNS records from its cache, killing TLS
handshakes for blocked domains.

The bind-mounted nsswitch.conf drops the `resolve` module, so the app falls back
to plain `dns` and uses the VPN's DNS through the tunnel. The host system is never
modified.

## Requirements

- `wireguard-tools` (wg, wg-quick)
- `iproute2`
- `util-linux` (unshare)
- sudo (a NOPASSWD rule is recommended)

## Installation

See [INSTALL.md](INSTALL.md). Short version:

```bash
git clone https://github.com/blueberi99/conduit.git
cd conduit-vpn
sudo install -m 755 conduit.sh /usr/local/bin/conduit

## Known limitations

- The first app owns the tunnel — closing it kills connectivity for the others
- Proton free plans cannot download WireGuard configs; a paid plan is required
- Some VPN exit IPs are blocked by services like Discord → `conduit kill` and retry
- WireGuard configs expire (~1 year); re-download when they do

## License

AGPLv3 — use it, fork it, ship it in your own projects. Derivatives must stay
open source under the same license and keep the copyright notice. If you run
a modified version as a network service, you must offer the source to users.
See [LICENSE](LICENSE).