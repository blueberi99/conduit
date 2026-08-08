#!/usr/bin/env bash
# conduit - per-app VPN split tunneling via network namespaces
# Copyright (C) 2026 berry
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

NS=conduit
STATE=/etc/wireguard/.conduit-last

# Resolve the invoking user's home — works both as a regular user
# and after sudo elevation. Override with CONDUIT_DIR if needed.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi
PROFILE_DIR="${CONDUIT_DIR:-$USER_HOME/vpns}"

usage() {
    cat >&2 <<'EOF'
usage:
  conduit [--provider <proton|mullvad>] [--vpn <profile>] <command> [args...]
  conduit show-vpn        list profiles
  conduit kill            tear down the tunnel

If no profile is given, a random one is picked (excluding the last used).
--vpn accepts substrings: "PDE-421" matches "PDE-421-DE-421.conf".
Profile dir: ~/vpns (override with CONDUIT_DIR).
examples:
  conduit discord
  conduit --provider proton discord
  conduit --vpn fra-403 discord
EOF
    exit 1
}

if [[ "${1:-}" == "show-vpn" ]]; then
    [[ -d "$PROFILE_DIR" ]] || { echo "profile dir missing: $PROFILE_DIR" >&2; exit 1; }
    last=$(cat "$STATE" 2>/dev/null || true)
    active=""
    # only trust the marker if the namespace actually exists
    if ip netns list 2>/dev/null | grep -qw "$NS"; then
        [[ -f "/etc/netns/$NS/profile" ]] && active=$(cat "/etc/netns/$NS/profile")
    fi
    shopt -s nullglob
    confs=("$PROFILE_DIR"/*.conf)
    shopt -u nullglob
    [[ ${#confs[@]} -gt 0 ]] || { echo "no profiles: $PROFILE_DIR/*.conf" >&2; exit 1; }
    for f in "${confs[@]}"; do
        name=$(basename "$f")
        marks=""
        [[ "$name" == "$last" ]] && marks="$marks [last]"
        [[ -n "$active" && "$name" == "$active" ]] && marks="$marks [active]"
        printf '  %s%s\n' "$name" "$marks"
    done
    exit 0
fi

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

if [[ $EUID -ne 0 ]]; then
    exec sudo CONDUIT_DIR="$PROFILE_DIR" "$0" "$@"
fi

PROFILE_ARG=""
PROVIDER_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn)         [[ $# -ge 2 ]] || usage; PROFILE_ARG="$2"; shift 2 ;;
        --vpn=*)       PROFILE_ARG="${1#*=}"; shift ;;
        --provider)    [[ $# -ge 2 ]] || usage; PROVIDER_ARG="$2"; shift 2 ;;
        --provider=*)  PROVIDER_ARG="${1#*=}"; shift ;;
        kill)          ip netns del "$NS" 2>/dev/null && echo "tunnel down" || echo "no namespace"
                       rm -f "/etc/netns/$NS/profile"; exit 0 ;;
        -h|--help)     usage ;;
        *) break ;;
    esac
done
[[ $# -ge 1 ]] || usage

shopt -s nullglob
all=("$PROFILE_DIR"/*.conf)
shopt -u nullglob
[[ ${#all[@]} -gt 0 ]] || { echo "no profiles: $PROFILE_DIR/*.conf" >&2; exit 1; }

if [[ -n "$PROFILE_ARG" ]]; then
    p="$PROFILE_ARG"
    [[ "$p" != *.conf ]] && p="$p.conf"
    CONF="$PROFILE_DIR/$p"
    if [[ ! -f "$CONF" ]]; then
        # no exact match — try substring
        matches=()
        for f in "${all[@]}"; do
            [[ $(basename "$f") == *"$PROFILE_ARG"* ]] && matches+=("$f")
        done
        if [[ ${#matches[@]} -eq 1 ]]; then
            CONF="${matches[0]}"
        elif [[ ${#matches[@]} -gt 1 ]]; then
            echo "ambiguous: '$PROFILE_ARG' matches multiple profiles:" >&2
            printf '  %s\n' "${matches[@]##*/}" >&2
            exit 1
        else
            echo "profile not found: $p (list: conduit show-vpn)" >&2
            exit 1
        fi
    fi
else
    candidates=("${all[@]}")
    # provider filter — by filename prefix: PDE* = proton, rest = mullvad
    # (adjust the patterns to your own naming scheme)
    if [[ -n "$PROVIDER_ARG" ]]; then
        filtered=()
        for f in "${candidates[@]}"; do
            case "$PROVIDER_ARG" in
                proton)  [[ $(basename "$f") == PDE* ]] && filtered+=("$f") ;;
                mullvad) [[ $(basename "$f") != PDE* ]] && filtered+=("$f") ;;
                *) echo "unknown provider: $PROVIDER_ARG (proton|mullvad)" >&2; exit 1 ;;
            esac
        done
        candidates=("${filtered[@]}")
        [[ ${#candidates[@]} -gt 0 ]] || { echo "no profiles for provider: $PROVIDER_ARG" >&2; exit 1; }
    fi
    last=$(cat "$STATE" 2>/dev/null || true)
    without_last=()
    for f in "${candidates[@]}"; do
        [[ $(basename "$f") == "$last" ]] && continue
        without_last+=("$f")
    done
    [[ ${#without_last[@]} -gt 0 ]] && candidates=("${without_last[@]}")
    CONF=$(printf '%s\n' "${candidates[@]}" | shuf -n1)
fi

PROFILE_NAME=$(basename "$CONF")

USER_UID=$(id -u "$SUDO_USER")
export VPN_NS="$NS" VPN_UID="$USER_UID" VPN_USER="$SUDO_USER"

run_in_ns() {
    # Per-app mount namespace:
    # resolv.conf -> VPN DNS, nsswitch.conf -> hosts line without systemd-resolved.
    # The app can never reach the host's resolved (and its poisoned ISP DNS cache).
    ip netns exec "$NS" unshare --mount --propagation private bash -c '
        mount --bind /etc/netns/"$VPN_NS"/resolv.conf /etc/resolv.conf
        mount --bind /etc/netns/"$VPN_NS"/nsswitch.conf /etc/nsswitch.conf

        # Import the real session environment from plasmashell.
        # Missing vars (XAUTHORITY, XDG_SESSION_TYPE, ...) make Electron
        # pick the wrong platform and break screen sharing.
        SESSENV=()
        SPID=$(pgrep -u "$VPN_USER" -x plasmashell | head -n1 || true)
        if [[ -n "$SPID" ]]; then
            while IFS= read -r kv; do SESSENV+=("$kv"); done < <(
                tr "\0" "\n" < "/proc/$SPID/environ" | grep -E "^(DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|XDG_SESSION_DESKTOP|XDG_CURRENT_DESKTOP|WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|QT_QPA_PLATFORM|KDE_SESSION_VERSION|PULSE_SERVER|PIPEWIRE_REMOTE)="
            )
        fi
        if [[ ${#SESSENV[@]} -eq 0 ]]; then
            SESSENV=(
                "XDG_RUNTIME_DIR=/run/user/$VPN_UID"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$VPN_UID/bus"
                "WAYLAND_DISPLAY=wayland-0"
                "DISPLAY=:0"
            )
        fi

        exec runuser -u "$VPN_USER" -- env \
            HOME="/home/$VPN_USER" \
            "${SESSENV[@]}" \
            "$@"
    ' _ "$@"
}

# Namespace already up: verify profile match, then run inside
if ip netns list | grep -qw "$NS"; then
    active=$(cat "/etc/netns/$NS/profile" 2>/dev/null || echo "?")
    if [[ -n "$PROFILE_ARG" && "$active" != "$PROFILE_NAME" ]]; then
        echo "namespace is running with '$active'." >&2
        echo "to switch to '$PROFILE_NAME': conduit kill, then retry" >&2
        exit 1
    fi
    run_in_ns "$@"
    exit 0
fi

cleanup() { ip netns del "$NS" 2>/dev/null || true; rm -f "/etc/netns/$NS/profile"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

ip netns del "$NS" 2>/dev/null || true

# Address may hold multiple comma-separated entries (Mullvad: v4 + v6)
mapfile -t ADDRS < <(awk -F' *= *' '/^Address/{print $2}' "$CONF" | tr ',' '\n' | tr -d ' ')
DNS=$(awk -F' *= *' '/^DNS/{print $2}' "$CONF" | cut -d, -f1 | tr -d '[:space:]')
ENDPOINT=$(awk -F' *= *' '/^Endpoint/{print $2}' "$CONF" | cut -d: -f1)

ip netns add "$NS"
ip link add wg0 type wireguard
wg setconf wg0 <(wg-quick strip "$CONF")
ip link set wg0 netns "$NS"

# MTU: same heuristic as wg-quick — physical interface MTU - 80
PHY_DEV=$(ip route get "$ENDPOINT" | grep -oP '(?<= dev )\S+' | head -n1 || true)
if [[ -n "${PHY_DEV:-}" && -r "/sys/class/net/$PHY_DEV/mtu" ]]; then
    ip -n "$NS" link set dev wg0 mtu $(( $(cat "/sys/class/net/$PHY_DEV/mtu") - 80 ))
fi

HAS_V6=0
for a in "${ADDRS[@]}"; do
    ip -n "$NS" addr add "$a" dev wg0
    [[ "$a" == *:* ]] && HAS_V6=1
done

ip -n "$NS" link set lo up
ip -n "$NS" link set wg0 up
ip -n "$NS" route add default dev wg0

if [[ "$HAS_V6" -eq 1 ]] && grep -q '::/0' "$CONF"; then
    ip -n "$NS" -6 route add default dev wg0
fi

mkdir -p "/etc/netns/$NS"
echo "nameserver ${DNS:-9.9.9.9}" > "/etc/netns/$NS/resolv.conf"
sed 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf > "/etc/netns/$NS/nsswitch.conf"
echo "$PROFILE_NAME" > "/etc/netns/$NS/profile"
echo "$PROFILE_NAME" > "$STATE"

echo ">> profile: $PROFILE_NAME" >&2
run_in_ns "$@"
