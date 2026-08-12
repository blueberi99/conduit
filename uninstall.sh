#!/usr/bin/env bash
# Conduit uninstaller
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail


# =============================================================================
# Configuration
# =============================================================================

DEST="/usr/local/bin/conduit"
SUDOERS_FILE="/etc/sudoers.d/conduit"

LOCAL_UID="$(id -u)"

RUN_USER_DIR="/run/conduit/$LOCAL_UID"
STATE_USER_DIR="/var/lib/conduit/$LOCAL_UID"

PROFILE_DIR="${CONDUIT_DIR:-$HOME/vpns}"


# =============================================================================
# Helpers
# =============================================================================

die() {
    echo "uninstall: $*" >&2
    exit 1
}


ok() {
    printf '[OK] %s\n' "$1"
}


warn() {
    printf '[WARN] %s\n' "$1"
}


# =============================================================================
# Safety
# =============================================================================

if ((EUID == 0)); then
    die "run ./uninstall.sh as your normal user, not as root"
fi


command -v sudo >/dev/null 2>&1 ||
    die "sudo is required to uninstall Conduit"


echo "Conduit uninstaller"
echo
echo "VPN profiles will NOT be deleted."
echo


sudo -v


# =============================================================================
# Stop running sessions
# =============================================================================

if [[ -x "$DEST" ]]; then
    echo "Stopping active Conduit sessions..."


    if "$DEST" kill --all >/dev/null 2>&1; then
        ok "sessions stopped"
    else
        warn "normal session cleanup failed; attempting fallback cleanup"
    fi
fi


# =============================================================================
# Clean leftover namespaces
# =============================================================================

if command -v ip >/dev/null 2>&1; then
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue


        case "$ns" in
            "conduit-$LOCAL_UID-"*|\
            "conduit-doctor-$LOCAL_UID-"*)

                # Kill any remaining processes still holding the namespace.
                while IFS= read -r pid; do
                    [[ "$pid" =~ ^[0-9]+$ ]] || continue

                    sudo kill -TERM "$pid" 2>/dev/null ||
                        true
                done < <(
                    sudo ip netns pids "$ns" 2>/dev/null ||
                        true
                )


                sleep 1


                while IFS= read -r pid; do
                    [[ "$pid" =~ ^[0-9]+$ ]] || continue

                    sudo kill -KILL "$pid" 2>/dev/null ||
                        true
                done < <(
                    sudo ip netns pids "$ns" 2>/dev/null ||
                        true
                )


                sudo ip netns del "$ns" \
                    2>/dev/null ||
                    true

                sudo rm -rf \
                    "/etc/netns/$ns" \
                    2>/dev/null ||
                    true
                ;;
        esac

    done < <(
        sudo ip netns list 2>/dev/null |
            awk '{print $1}'
    )
fi


# =============================================================================
# Remove runtime/state
# =============================================================================

sudo rm -rf "$RUN_USER_DIR"
sudo rm -rf "$STATE_USER_DIR"


sudo rmdir /run/conduit \
    2>/dev/null ||
    true


sudo rmdir /var/lib/conduit \
    2>/dev/null ||
    true


ok "runtime state removed"


# =============================================================================
# Remove installed binary
# =============================================================================

if sudo test -e "$DEST"; then
    sudo rm -f "$DEST"
    ok "$DEST removed"
else
    warn "$DEST was not installed"
fi


# =============================================================================
# Remove privilege rule
# =============================================================================

if sudo test -e "$SUDOERS_FILE"; then
    sudo rm -f "$SUDOERS_FILE"
    ok "$SUDOERS_FILE removed"
else
    warn "$SUDOERS_FILE was not present"
fi


# =============================================================================
# Finish
# =============================================================================

echo
echo "Conduit has been uninstalled."
echo
echo "Preserved VPN profiles:"
echo "  $PROFILE_DIR"
echo
echo "To remove profiles manually:"
echo "  rm -rf '$PROFILE_DIR'"