#!/usr/bin/env bash
# Conduit installer
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail


# =============================================================================
# Configuration
# =============================================================================

DEST="/usr/local/bin/conduit"
SUDOERS_FILE="/etc/sudoers.d/conduit"

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

SOURCE="$SCRIPT_DIR/conduit.sh"

INSTALL_USER="$(id -un)"
INSTALL_UID="$(id -u)"

PROFILE_DIR="${CONDUIT_DIR:-$HOME/vpns}"


# =============================================================================
# Helpers
# =============================================================================

die() {
    echo "install: $*" >&2
    exit 1
}


ok() {
    printf '[OK]   %s\n' "$1"
}


warn() {
    printf '[WARN] %s\n' "$1"
}


fail() {
    printf '[FAIL] %s\n' "$1"
}


find_visudo() {
    if command -v visudo >/dev/null 2>&1; then
        command -v visudo
        return 0
    fi

    if [[ -x /usr/sbin/visudo ]]; then
        printf '%s\n' /usr/sbin/visudo
        return 0
    fi

    return 1
}


# =============================================================================
# Safety
# =============================================================================

if ((EUID == 0)); then
    die "run ./install.sh as your normal user, not as root"
fi


[[ -f "$SOURCE" ]] ||
    die "conduit.sh not found: $SOURCE"


command -v sudo >/dev/null 2>&1 ||
    die "sudo is required by the automatic installer"


VISUDO="$(
    find_visudo
)" || die "visudo not found"


# =============================================================================
# Dependency checks
# =============================================================================

echo "Conduit installer"
echo
echo "Checking dependencies..."
echo


missing=()


required=(
    bash
    ip
    wg
    wg-quick
    awk
    stat
    env
    setsid
    find
    date
    mktemp
    readlink
    curl
    jq
    install
)


for command in "${required[@]}"; do
    if command -v "$command" >/dev/null 2>&1; then
        ok "$command"
    else
        fail "$command"
        missing+=("$command")
    fi
done


if command -v setpriv >/dev/null 2>&1; then
    ok "setpriv"

elif command -v runuser >/dev/null 2>&1; then
    ok "runuser"

else
    fail "setpriv or runuser"
    missing+=("setpriv/runuser")
fi


ok "sudo"
ok "visudo"


if ((${#missing[@]} > 0)); then
    echo
    echo "Missing dependencies:"
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Common package names:"
    echo "  ip                -> iproute2 / iproute"
    echo "  wg, wg-quick      -> wireguard-tools"
    echo "  setsid/setpriv    -> util-linux"
    echo "  curl              -> curl"
    echo "  jq                -> jq"
    echo
    echo "Install the missing tools with your distribution's package manager"
    echo "and run ./install.sh again."

    exit 1
fi


# =============================================================================
# Source validation
# =============================================================================

echo
echo "Validating source..."
echo


if bash -n "$SOURCE"; then
    ok "bash syntax"
else
    die "conduit.sh failed syntax validation"
fi


SOURCE_VERSION="$(
    bash "$SOURCE" --version 2>/dev/null ||
        true
)"


if [[ -n "$SOURCE_VERSION" ]]; then
    ok "$SOURCE_VERSION"
else
    warn "could not determine Conduit version"
fi


# =============================================================================
# Privilege acquisition
# =============================================================================

echo
echo "Administrator privileges are required for installation."


sudo -v


# =============================================================================
# Transaction preparation
# =============================================================================

BACKUP_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/conduit-install.XXXXXX"
)"

HAD_BINARY=0
HAD_SUDOERS=0
INSTALL_COMPLETE=0


cleanup() {
    local rc=$?

    if ((INSTALL_COMPLETE == 0)); then
        echo
        warn "installation did not complete; rolling back"


        if ((HAD_BINARY)); then
            sudo install \
                -o root \
                -g root \
                -m 0755 \
                "$BACKUP_DIR/conduit" \
                "$DEST" \
                2>/dev/null ||
                true
        else
            sudo rm -f "$DEST" 2>/dev/null ||
                true
        fi


        if ((HAD_SUDOERS)); then
            sudo install \
                -o root \
                -g root \
                -m 0440 \
                "$BACKUP_DIR/sudoers" \
                "$SUDOERS_FILE" \
                2>/dev/null ||
                true
        else
            sudo rm -f "$SUDOERS_FILE" 2>/dev/null ||
                true
        fi
    fi


    rm -rf "$BACKUP_DIR"

    exit "$rc"
}


trap cleanup EXIT INT TERM HUP


if sudo test -f "$DEST"; then
    sudo cat "$DEST" > "$BACKUP_DIR/conduit"
    HAD_BINARY=1
fi


if sudo test -f "$SUDOERS_FILE"; then
    sudo cat "$SUDOERS_FILE" > "$BACKUP_DIR/sudoers"
    HAD_SUDOERS=1
fi


# =============================================================================
# Install binary
# =============================================================================

echo
echo "Installing Conduit..."
echo


sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$SOURCE" \
    "$DEST"


ok "$DEST"


# =============================================================================
# Install sudoers rule
# =============================================================================

SUDOERS_TEMP="$BACKUP_DIR/conduit.sudoers"


printf '%s\n' \
    "$INSTALL_USER ALL=(root) NOPASSWD: $DEST" \
    > "$SUDOERS_TEMP"


chmod 0600 "$SUDOERS_TEMP"


if ! sudo "$VISUDO" -cf "$SUDOERS_TEMP" >/dev/null; then
    die "generated sudoers rule failed validation"
fi


sudo install \
    -o root \
    -g root \
    -m 0440 \
    "$SUDOERS_TEMP" \
    "$SUDOERS_FILE"


if ! sudo "$VISUDO" -cf "$SUDOERS_FILE" >/dev/null; then
    die "installed sudoers file failed validation"
fi


ok "$SUDOERS_FILE"


# =============================================================================
# Profile directory
# =============================================================================

mkdir -p "$PROFILE_DIR"

chmod 0700 "$PROFILE_DIR"


ok "$PROFILE_DIR"


# =============================================================================
# First-run WARP bootstrap
# =============================================================================

PROFILE_FOUND=0


while IFS= read -r -d '' profile; do
    PROFILE_FOUND=1
    break
done < <(
    find "$PROFILE_DIR" \
        -type f \
        -name '*.conf' \
        -print0 \
        2>/dev/null
)


if ((PROFILE_FOUND == 0)); then
    echo
    echo "No VPN profiles were found."
    echo "Bootstrapping Cloudflare WARP..."
    echo


    "$DEST" bootstrap


    ok "Cloudflare WARP profile"
else
    echo
    ok "existing VPN profiles detected"
fi


# =============================================================================
# Final self-test
# =============================================================================

echo
echo "Running Conduit doctor..."
echo


"$DEST" doctor


# =============================================================================
# Complete
# =============================================================================

INSTALL_COMPLETE=1


echo
echo "Conduit installed successfully."
echo
echo "Version:"
echo "  $("$DEST" --version)"
echo
echo "Try:"
echo "  conduit --provider cloudflare bash"
echo "  conduit discord"
echo "  conduit status"
echo
echo "Profiles:"
echo "  $PROFILE_DIR"