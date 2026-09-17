#!/usr/bin/env bash
# conduit - per-app VPN split tunneling via network namespaces
# Copyright (C) 2026 berry
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail


# =============================================================================
# Global configuration
# =============================================================================

VERSION="3.2.2"

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

PROFILE_DIR="${CONDUIT_DIR:-$HOME/vpns}"

RUN_BASE="/run/conduit"
STATE_BASE="/var/lib/conduit"

LOCAL_UID="$(id -u)"

USER_RUN_DIR="$RUN_BASE/$LOCAL_UID"
USER_STATE_DIR="$STATE_BASE/$LOCAL_UID"
LAST_STATE="$USER_STATE_DIR/last-profile"


# -----------------------------------------------------------------------------
# Cloudflare WARP bootstrap
# -----------------------------------------------------------------------------

WARP_API_URL="${CONDUIT_WARP_API_URL:-https://api.cloudflareclient.com/v0a1922/reg}"

WARP_DNS="${CONDUIT_WARP_DNS:-1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001}"

WARP_MTU="${CONDUIT_WARP_MTU:-1280}"

WARP_ALLOWED_IPS="${CONDUIT_WARP_ALLOWED_IPS:-0.0.0.0/0, ::/0}"

WARP_DEVICE_TYPE="${CONDUIT_WARP_DEVICE_TYPE:-Android}"
WARP_LOCALE="${CONDUIT_WARP_LOCALE:-en_US}"
WARP_PERSISTENT_KEEPALIVE="${CONDUIT_WARP_PERSISTENT_KEEPALIVE:-0}"

# =============================================================================
# Generic helpers
# =============================================================================

die() {
    echo "conduit: $*" >&2
    exit 1
}


usage() {
    cat <<'EOF'
Conduit - isolated per-application VPN sessions

usage:
  conduit [options] <command> [args...]

options:
  --vpn <profile>        use a specific WireGuard profile
  --provider <name>      choose a profile from ~/vpns/<name>/
  -d, --detach           force detached mode
  -f, --foreground       force foreground mode
  -h, --help             show help
  -V, --version          show version

management:
  conduit show-vpn
  conduit status
  conduit doctor
  conduit bootstrap

  conduit attach
  conduit attach <session>
  conduit attach <session> <command> [args...]

  conduit logs [session]

  conduit kill <session>
  conduit kill --all

examples:
  conduit discord
  conduit firefox

  conduit --vpn PDE-778 discord
  conduit --provider proton discord
  conduit --provider cloudflare firefox
  conduit --provider windscribe discord

  conduit -f --provider cloudflare curl https://ifconfig.me

  conduit status

  conduit attach
  conduit attach 23af
  conduit attach discord
  conduit attach 23af curl https://ifconfig.me

  conduit logs discord

  conduit kill discord
  conduit kill 23af
  conduit kill --all

profile layout:
  ~/vpns/*.conf
  ~/vpns/<provider>/*.conf

examples:
  ~/vpns/proton/PDE-778-DE-778.conf
  ~/vpns/mullvad/de-ber-wg-102.conf
  ~/vpns/cloudflare/warp.conf

override profile directory:
  CONDUIT_DIR=/path/to/profiles conduit discord

If no WireGuard profiles exist, Conduit automatically bootstraps
a Cloudflare WARP profile under:

  ~/vpns/cloudflare/warp.conf

Each normal launch gets its own isolated network namespace.

GUI/non-shell commands are detached by default.
Interactive shells stay in the foreground by default.
EOF
}


is_ns_up() {
    local ns="$1"

    ip netns list 2>/dev/null |
        awk -v wanted="$ns" '
            $1 == wanted {
                found=1
            }

            END {
                exit !found
            }
        '
}


namespace_pids() {
    local ns="$1"

    ip netns pids "$ns" 2>/dev/null || true
}


namespace_pid_count() {
    local ns="$1"

    local count=0
    local pid

    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        count=$((count + 1))
    done < <(
        namespace_pids "$ns"
    )

    printf '%s\n' "$count"
}


# =============================================================================
# Profile discovery
# =============================================================================

profile_id() {
    local file="$1"

    if [[ "$file" == "$PROFILE_DIR/"* ]]; then
        printf '%s\n' "${file#"$PROFILE_DIR/"}"
    else
        printf '%s\n' "${file##*/}"
    fi
}


load_all_profiles() {
    ALL_PROFILES=()

    [[ -d "$PROFILE_DIR" ]] || return 0

    while IFS= read -r -d '' file; do
        ALL_PROFILES+=("$file")
    done < <(
        find "$PROFILE_DIR" \
            -type f \
            -name '*.conf' \
            -print0 \
            2>/dev/null
    )

    return 0
}


# =============================================================================
# Cloudflare WARP bootstrap
# =============================================================================

bootstrap_warp_config() {
    local warp_dir="$PROFILE_DIR/cloudflare"
    local target="$warp_dir/warp.conf"

    local command

    local private_key=""
    local public_key=""

    local tos_date
    local payload
    local response

    local peer_public_key
    local interface_ipv4
    local interface_ipv6
    local peer_endpoint

    local ipv4_address
    local ipv6_address=""
    local address

    local keepalive_line=""

    local tmp=""

    local -a missing=()


    if [[ -e "$target" ]]; then
        echo ">> WARP profile already exists: $target" >&2
        return 0
    fi


    # -------------------------------------------------------------------------
    # Dependencies
    # -------------------------------------------------------------------------

    for command in wg curl jq date mktemp; do
        if ! command -v "$command" >/dev/null 2>&1; then
            missing+=("$command")
        fi
    done


    if ((${#missing[@]} > 0)); then
        die \
            "cannot bootstrap Cloudflare WARP; missing: ${missing[*]}"
    fi


    # -------------------------------------------------------------------------
    # Validate options
    # -------------------------------------------------------------------------

    [[ "$WARP_MTU" =~ ^[0-9]+$ ]] ||
        die "invalid WARP MTU: $WARP_MTU"


    ((WARP_MTU >= 576 && WARP_MTU <= 65535)) ||
        die "WARP MTU out of range: $WARP_MTU"


    [[ "$WARP_PERSISTENT_KEEPALIVE" =~ ^[0-9]+$ ]] ||
        die \
            "invalid WARP persistent keepalive: $WARP_PERSISTENT_KEEPALIVE"


    ((WARP_PERSISTENT_KEEPALIVE >= 0 &&
      WARP_PERSISTENT_KEEPALIVE <= 65535)) ||
        die \
            "WARP persistent keepalive out of range"


    # -------------------------------------------------------------------------
    # Directory
    # -------------------------------------------------------------------------

    if [[ ! -d "$PROFILE_DIR" ]]; then
        mkdir -p "$PROFILE_DIR"
        chmod 700 "$PROFILE_DIR"
    fi


    mkdir -p "$warp_dir"
    chmod 700 "$warp_dir"

    umask 077


    echo ">> bootstrapping Cloudflare WARP..." >&2


    # -------------------------------------------------------------------------
    # Generate keypair locally
    # -------------------------------------------------------------------------

    private_key="$(
        wg genkey
    )" || die "failed to generate WireGuard private key"


    [[ -n "$private_key" ]] ||
        die "WireGuard generated an empty private key"


    public_key="$(
        printf '%s\n' "$private_key" |
            wg pubkey
    )" || die "failed to derive WireGuard public key"


    [[ -n "$public_key" ]] ||
        die "WireGuard generated an empty public key"


    # -------------------------------------------------------------------------
    # Registration payload
    # -------------------------------------------------------------------------

    tos_date="$(
        date -u '+%Y-%m-%dT%H:%M:%S.000+00:00'
    )"


    payload="$(
        jq -nc \
            --arg key "$public_key" \
            --arg tos "$tos_date" \
            --arg type "$WARP_DEVICE_TYPE" \
            --arg locale "$WARP_LOCALE" \
            '{
                key: $key,
                install_id: "",
                fcm_token: "",
                tos: $tos,
                type: $type,
                model: "PC",
                locale: $locale
            }'
    )"


    # -------------------------------------------------------------------------
    # Register public key
    # -------------------------------------------------------------------------

    if ! response="$(
        curl \
            --silent \
            --show-error \
            --fail \
            --connect-timeout 10 \
            --max-time 30 \
            -X POST \
            -H 'User-Agent: okhttp/3.12.1' \
            -H 'CF-Client-Version: a-6.3-1922' \
            -H 'Content-Type: application/json' \
            --data "$payload" \
            "$WARP_API_URL"
    )"; then
        private_key=""
        public_key=""

        die "Cloudflare WARP registration failed"
    fi


    # Validate JSON before extracting fields.
    if ! jq -e \
        '.config.peers[0].public_key and .config.interface.addresses' \
        >/dev/null \
        <<< "$response"
    then
        private_key=""
        public_key=""

        die "invalid response from Cloudflare WARP API"
    fi


    # -------------------------------------------------------------------------
    # Parse response
    # -------------------------------------------------------------------------

    peer_public_key="$(
        jq -r \
            '.config.peers[0].public_key // empty' \
            <<< "$response"
    )"


    interface_ipv4="$(
        jq -r \
            '.config.interface.addresses.v4 // empty' \
            <<< "$response"
    )"


    interface_ipv6="$(
        jq -r \
            '.config.interface.addresses.v6 // empty' \
            <<< "$response"
    )"


    peer_endpoint="$(
        jq -r \
            '.config.peers[0].endpoint.host // empty' \
            <<< "$response"
    )"


    [[ -n "$peer_public_key" ]] ||
        die "invalid WARP response: peer public key missing"


    [[ -n "$interface_ipv4" ]] ||
        die "invalid WARP response: IPv4 address missing"


    [[ -n "$peer_endpoint" ]] ||
        die "invalid WARP response: endpoint missing"


    # -------------------------------------------------------------------------
    # Address prefixes
    # -------------------------------------------------------------------------

    if [[ "$interface_ipv4" == */* ]]; then
        ipv4_address="$interface_ipv4"
    else
        ipv4_address="$interface_ipv4/32"
    fi


    if [[ -n "$interface_ipv6" ]]; then
        if [[ "$interface_ipv6" == */* ]]; then
            ipv6_address="$interface_ipv6"
        else
            ipv6_address="$interface_ipv6/128"
        fi
    fi


    address="$ipv4_address"


    if [[ -n "$ipv6_address" ]]; then
        address="$address, $ipv6_address"
    fi


    # -------------------------------------------------------------------------
    # Optional keepalive
    # -------------------------------------------------------------------------

    if [[ "$WARP_PERSISTENT_KEEPALIVE" != "0" ]]; then
        keepalive_line="PersistentKeepalive = $WARP_PERSISTENT_KEEPALIVE"
    fi


    # -------------------------------------------------------------------------
    # Write config atomically
    # -------------------------------------------------------------------------

    tmp="$(
        mktemp "$warp_dir/.warp.conf.XXXXXX"
    )"


    if ! {
        {
            echo "[Interface]"
            echo "PrivateKey = $private_key"
            echo "Address = $address"
            echo "DNS = $WARP_DNS"
            echo "MTU = $WARP_MTU"
            echo
            echo "[Peer]"
            echo "PublicKey = $peer_public_key"
            echo "AllowedIPs = $WARP_ALLOWED_IPS"
            echo "Endpoint = $peer_endpoint"

            if [[ -n "$keepalive_line" ]]; then
                echo "$keepalive_line"
            fi
        } > "$tmp"

        chmod 600 "$tmp"

        mv "$tmp" "$target"
    }; then
        rm -f "$tmp"

        private_key=""
        public_key=""

        die "failed to write WARP profile"
    fi


    private_key=""
    public_key=""
    response=""
    payload=""


    echo ">> generated: $target" >&2
    echo ">> permissions: 600" >&2

    return 0
}


ensure_profiles() {
    load_all_profiles


    if ((${#ALL_PROFILES[@]} == 0)); then
        echo ">> no VPN profiles found" >&2

        bootstrap_warp_config

        load_all_profiles
    fi


    ((${#ALL_PROFILES[@]} > 0)) ||
        die "no VPN profiles available"
}


# =============================================================================
# Provider filtering
# =============================================================================

filter_provider() {
    local provider="$1"
    local provider_dir="$PROFILE_DIR/$provider"

    local file
    local id
    local base

    CANDIDATES=()


    # Preferred provider-agnostic structure:
    #
    # ~/vpns/proton/*.conf
    # ~/vpns/mullvad/*.conf
    # ~/vpns/cloudflare/*.conf
    # ~/vpns/anything/*.conf
    #
    if [[ -d "$provider_dir" ]]; then
        for file in "${ALL_PROFILES[@]}"; do
            if [[ "$file" == "$provider_dir/"* ]]; then
                CANDIDATES+=("$file")
            fi
        done

        return 0
    fi


    # Legacy flat-layout compatibility.
    #
    # PDE* = Proton
    # Windscribe-* = Windscribe
    # other top-level configs = Mullvad
    #
    case "$provider" in
        proton)
            for file in "${ALL_PROFILES[@]}"; do
                id="$(profile_id "$file")"
                base="${file##*/}"

                if [[ "$id" != */* && "$base" == PDE* ]]; then
                    CANDIDATES+=("$file")
                fi
            done
            ;;


        windscribe)
            for file in "${ALL_PROFILES[@]}"; do
                id="$(profile_id "$file")"
                base="${file##*/}"

                if [[ "$id" != */* && "${base,,}" == windscribe-* ]]; then
                    CANDIDATES+=("$file")
                fi
            done
            ;;


        mullvad)
            for file in "${ALL_PROFILES[@]}"; do
                id="$(profile_id "$file")"
                base="${file##*/}"

                if [[ "$id" != */* && "$base" != PDE* &&
                    "${base,,}" != windscribe-* ]]; then
                    CANDIDATES+=("$file")
                fi
            done
            ;;


        *)
            die \
                "provider '$provider' not found; expected directory: $provider_dir"
            ;;
    esac


    return 0
}


# =============================================================================
# Profile selection
# =============================================================================

select_profile() {
    local vpn_arg="$1"
    local provider_arg="$2"

    local file
    local id
    local base
    local wanted
    local last=""

    local -a exact=()
    local -a matches=()
    local -a pool=()
    local -a without_last=()


    ensure_profiles


    if [[ -n "$provider_arg" ]]; then
        [[ "$provider_arg" =~ ^[A-Za-z0-9._-]+$ ]] ||
            die "invalid provider name: $provider_arg"


        filter_provider "$provider_arg"


        ((${#CANDIDATES[@]} > 0)) ||
            die "no profiles for provider: $provider_arg"


        pool=("${CANDIDATES[@]}")
    else
        pool=("${ALL_PROFILES[@]}")
    fi


    # -------------------------------------------------------------------------
    # Explicit profile selection
    # -------------------------------------------------------------------------

    if [[ -n "$vpn_arg" ]]; then
        wanted="$vpn_arg"


        for file in "${pool[@]}"; do
            id="$(profile_id "$file")"
            base="${file##*/}"


            if [[ "$id" == "$wanted" ||
                  "$id" == "$wanted.conf" ||
                  "$base" == "$wanted" ||
                  "$base" == "$wanted.conf" ]]; then

                exact+=("$file")
            fi
        done


        if ((${#exact[@]} == 1)); then
            CONF="${exact[0]}"
            PROFILE_ID="$(profile_id "$CONF")"

            return 0
        fi


        if ((${#exact[@]} > 1)); then
            echo "conduit: ambiguous profile '$vpn_arg':" >&2

            for file in "${exact[@]}"; do
                printf '  %s\n' "$(profile_id "$file")" >&2
            done

            exit 1
        fi


        # Substring matching.
        for file in "${pool[@]}"; do
            id="$(profile_id "$file")"
            base="${file##*/}"


            if [[ "$id" == *"$vpn_arg"* ||
                  "$base" == *"$vpn_arg"* ]]; then

                matches+=("$file")
            fi
        done


        if ((${#matches[@]} == 1)); then
            CONF="${matches[0]}"
            PROFILE_ID="$(profile_id "$CONF")"

            return 0
        fi


        if ((${#matches[@]} > 1)); then
            echo "conduit: ambiguous profile '$vpn_arg':" >&2

            for file in "${matches[@]}"; do
                printf '  %s\n' "$(profile_id "$file")" >&2
            done

            exit 1
        fi


        die "profile not found: $vpn_arg"
    fi


    # -------------------------------------------------------------------------
    # Random selection
    # -------------------------------------------------------------------------

    if [[ -r "$LAST_STATE" ]]; then
        last="$(<"$LAST_STATE")"
    fi


    for file in "${pool[@]}"; do
        if [[ "$(profile_id "$file")" != "$last" ]]; then
            without_last+=("$file")
        fi
    done


    if ((${#without_last[@]} > 0)); then
        pool=("${without_last[@]}")
    fi


    CONF="${pool[RANDOM % ${#pool[@]}]}"
    PROFILE_ID="$(profile_id "$CONF")"


    return 0
}


# =============================================================================
# Session IDs
# =============================================================================

new_session_id() {
    local uuid
    local id
    local try
    local ns


    for try in {1..32}; do
        if [[ -r /proc/sys/kernel/random/uuid ]]; then
            uuid="$(</proc/sys/kernel/random/uuid)"
            id="${uuid%%-*}"
        else
            id="$(
                printf '%08x' \
                    "$(( (RANDOM << 16) | RANDOM ))"
            )"
        fi


        ns="conduit-$LOCAL_UID-$id"


        [[ ! -e "$USER_RUN_DIR/$id" ]] ||
            continue


        if is_ns_up "$ns"; then
            continue
        fi


        printf '%s\n' "$id"

        return 0
    done


    die "could not allocate a unique session ID"
}


# =============================================================================
# Session environment capture
# =============================================================================

write_session_file() {
    local temp_base
    local key
    local value

    local -a keys=(
        PATH

        DISPLAY
        WAYLAND_DISPLAY
        XAUTHORITY

        XDG_RUNTIME_DIR
        XDG_SESSION_TYPE
        XDG_SESSION_ID
        XDG_SESSION_CLASS
        XDG_SESSION_DESKTOP
        XDG_CURRENT_DESKTOP

        XDG_DATA_HOME
        XDG_CONFIG_HOME
        XDG_CACHE_HOME
        XDG_STATE_HOME

        XDG_DATA_DIRS
        XDG_CONFIG_DIRS

        DBUS_SESSION_BUS_ADDRESS

        PULSE_SERVER
        PIPEWIRE_REMOTE

        QT_QPA_PLATFORM
        QT_IM_MODULE

        GDK_BACKEND
        GTK_IM_MODULE

        SDL_VIDEODRIVER

        GTK_USE_PORTAL

        ELECTRON_OZONE_PLATFORM_HINT
        MOZ_ENABLE_WAYLAND
        NIXOS_OZONE_WL

        XMODIFIERS

        DESKTOP_SESSION

        SSH_AUTH_SOCK

        TERM
        COLORTERM

        LANG
        LANGUAGE
        LC_ALL
        LC_CTYPE
    )


    if [[ -n "${XDG_RUNTIME_DIR:-}" &&
          -d "${XDG_RUNTIME_DIR:-}" &&
          -w "${XDG_RUNTIME_DIR:-}" ]]; then

        temp_base="$XDG_RUNTIME_DIR"
    else
        temp_base="${TMPDIR:-/tmp}"
    fi


    umask 077


    SESSION_FILE="$(
        mktemp "$temp_base/conduit-env.XXXXXX"
    )"


    chmod 0600 "$SESSION_FILE"


    for key in "${keys[@]}"; do
        if [[ -v "$key" ]]; then
            value="${!key}"


            # Never serialize multiline values.
            [[ "$value" == *$'\n'* ]] &&
                continue


            printf '%s=%s\n' \
                "$key" \
                "$value" \
                >> "$SESSION_FILE"
        fi
    done
}


# =============================================================================
# Privilege escalation
# =============================================================================

run_elevated() {
    local elevator="${CONDUIT_ELEVATOR:-auto}"


    case "$elevator" in
        auto)
            if command -v sudo >/dev/null 2>&1; then
                sudo -n -- "$SELF" "$@"

            elif command -v doas >/dev/null 2>&1; then
                doas -n "$SELF" "$@"

            else
                die "need sudo or doas for privilege escalation"
            fi
            ;;


        sudo)
            command -v sudo >/dev/null 2>&1 ||
                die "sudo not found"


            sudo -n -- "$SELF" "$@"
            ;;


        doas)
            command -v doas >/dev/null 2>&1 ||
                die "doas not found"


            doas -n "$SELF" "$@"
            ;;


        *)
            die "unknown CONDUIT_ELEVATOR: $elevator"
            ;;
    esac
}


# =============================================================================
# Resolve original user after elevation
# =============================================================================

resolve_invoking_user() {
    local passwd_line=""


    if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ &&
          "${SUDO_UID:-0}" -ne 0 ]]; then

        USER_UID="$SUDO_UID"


    elif [[ -n "${DOAS_USER:-}" &&
            "$DOAS_USER" != "root" ]]; then

        USER_UID="$(id -u "$DOAS_USER")"


    else
        die \
            "cannot identify invoking user; run conduit as your regular user"
    fi


    if command -v getent >/dev/null 2>&1; then
        passwd_line="$(
            getent passwd "$USER_UID" |
                head -n1 ||
                true
        )"
    fi


    # Minimal fallback for systems without getent.
    if [[ -z "$passwd_line" ]]; then
        passwd_line="$(
            awk -F: \
                -v uid="$USER_UID" \
                '$3 == uid { print; exit }' \
                /etc/passwd
        )"
    fi


    [[ -n "$passwd_line" ]] ||
        die "cannot resolve passwd entry for uid $USER_UID"


    IFS=: read -r \
        USER_NAME \
        _ \
        _ \
        USER_GID \
        _ \
        USER_HOME \
        USER_SHELL \
        <<< "$passwd_line"


    [[ -n "$USER_NAME" ]] ||
        die "cannot resolve invoking username"


    [[ -n "$USER_HOME" ]] ||
        die "cannot resolve invoking home"


    [[ -n "$USER_SHELL" ]] ||
        USER_SHELL="/bin/sh"


    ROOT_RUN_USER_DIR="$RUN_BASE/$USER_UID"
    ROOT_STATE_USER_DIR="$STATE_BASE/$USER_UID"
    ROOT_LAST_STATE="$ROOT_STATE_USER_DIR/last-profile"
}


# =============================================================================
# Read captured desktop environment
# =============================================================================

read_session_file() {
    local file="$1"

    local line
    local key
    local value
    local owner


    SESSION_ENV=()

    USER_PATH="/usr/local/bin:/usr/bin:/bin"


    [[ -f "$file" && ! -L "$file" ]] ||
        die "invalid session environment file"


    owner="$(
        stat -Lc '%u' "$file" 2>/dev/null ||
            true
    )"


    [[ "$owner" == "$USER_UID" ]] ||
        die "session environment file has wrong owner"


    while IFS= read -r line; do
        [[ "$line" == *=* ]] ||
            continue


        key="${line%%=*}"
        value="${line#*=}"


        case "$key" in
            PATH)
                USER_PATH="$value"
                ;;


            DISPLAY|\
            WAYLAND_DISPLAY|\
            XAUTHORITY|\
            XDG_RUNTIME_DIR|\
            XDG_SESSION_TYPE|\
            XDG_SESSION_ID|\
            XDG_SESSION_CLASS|\
            XDG_SESSION_DESKTOP|\
            XDG_CURRENT_DESKTOP|\
            XDG_DATA_HOME|\
            XDG_CONFIG_HOME|\
            XDG_CACHE_HOME|\
            XDG_STATE_HOME|\
            XDG_DATA_DIRS|\
            XDG_CONFIG_DIRS|\
            DBUS_SESSION_BUS_ADDRESS|\
            PULSE_SERVER|\
            PIPEWIRE_REMOTE|\
            QT_QPA_PLATFORM|\
            QT_IM_MODULE|\
            GDK_BACKEND|\
            GTK_IM_MODULE|\
            SDL_VIDEODRIVER|\
            GTK_USE_PORTAL|\
            ELECTRON_OZONE_PLATFORM_HINT|\
            MOZ_ENABLE_WAYLAND|\
            NIXOS_OZONE_WL|\
            XMODIFIERS|\
            DESKTOP_SESSION|\
            SSH_AUTH_SOCK|\
            TERM|\
            COLORTERM|\
            LANG|\
            LANGUAGE|\
            LC_ALL|\
            LC_CTYPE)

                SESSION_ENV+=("$key=$value")
                ;;
        esac

    done < "$file"
}


# =============================================================================
# WireGuard config parser
# =============================================================================

config_values() {
    local wanted_key="$1"
    local wanted_section="$2"
    local file="$3"


    awk \
        -v wanted_key="$wanted_key" \
        -v wanted_section="$wanted_section" '
        BEGIN {
            section=""
        }

        /^[[:space:]]*[#;]/ {
            next
        }

        /^[[:space:]]*$/ {
            next
        }

        /^[[:space:]]*\[/ {
            section=$0

            gsub(/^[[:space:]]*\[/, "", section)
            gsub(/\][[:space:]]*$/, "", section)

            next
        }

        {
            p=index($0, "=")

            if (!p)
                next

            key=substr($0, 1, p - 1)
            value=substr($0, p + 1)

            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

            if (key == wanted_key &&
                (wanted_section == "" || section == wanted_section))
                print value
        }
    ' "$file"
}


split_config_csv() {
    local key="$1"
    local section="$2"
    local file="$3"

    local -n destination="$4"

    local line
    local item

    local -a parts=()


    destination=()


    while IFS= read -r line; do
        IFS=',' read -r -a parts <<< "$line"


        for item in "${parts[@]}"; do
            # Trim left.
            item="${item#"${item%%[![:space:]]*}"}"

            # Trim right.
            item="${item%"${item##*[![:space:]]}"}"


            [[ -n "$item" ]] &&
                destination+=("$item")
        done

    done < <(
        config_values \
            "$key" \
            "$section" \
            "$file"
    )
}


parse_profile() {
    split_config_csv \
        "Address" \
        "Interface" \
        "$CONF" \
        ADDRS


    split_config_csv \
        "DNS" \
        "Interface" \
        "$CONF" \
        DNS_VALUES


    split_config_csv \
        "AllowedIPs" \
        "Peer" \
        "$CONF" \
        ALLOWED_IPS


    CONFIG_MTU=""


    while IFS= read -r CONFIG_MTU; do
        break
    done < <(
        config_values \
            "MTU" \
            "Interface" \
            "$CONF"
    )


    ((${#ADDRS[@]} > 0)) ||
        die "profile has no Address"


    ((${#ALLOWED_IPS[@]} > 0)) ||
        die "profile has no AllowedIPs"


    HAS_V4=0
    HAS_V6=0

    FULL_V4=0
    FULL_V6=0


    local value


    for value in "${ADDRS[@]}"; do
        if [[ "$value" == *:* ]]; then
            HAS_V6=1
        else
            HAS_V4=1
        fi
    done


    for value in "${ALLOWED_IPS[@]}"; do
        if [[ "$value" == "0.0.0.0/0" ]]; then
            FULL_V4=1
        fi


        if [[ "$value" == "::/0" ]]; then
            FULL_V6=1
        fi
    done


    ((FULL_V4 || FULL_V6)) ||
        die \
            "profile is not full-tunnel; AllowedIPs needs 0.0.0.0/0 and/or ::/0"


    ((FULL_V4 == 0 || HAS_V4 == 1)) ||
        die \
            "profile routes IPv4 but has no IPv4 Address"


    ((FULL_V6 == 0 || HAS_V6 == 1)) ||
        die \
            "profile routes IPv6 but has no IPv6 Address"
}


# =============================================================================
# MTU
# =============================================================================

choose_mtu() {
    local dev=""
    local host_mtu=""


    # Respect provider/config MTU first.
    if [[ -n "$CONFIG_MTU" ]]; then
        [[ "$CONFIG_MTU" =~ ^[0-9]+$ ]] ||
            die "invalid MTU: $CONFIG_MTU"


        ((CONFIG_MTU >= 576 && CONFIG_MTU <= 65535)) ||
            die "MTU out of range: $CONFIG_MTU"


        MTU="$CONFIG_MTU"

        return 0
    fi


    # Generic fallback:
    # host/default-route interface MTU minus WireGuard overhead.
    dev="$(
        ip -4 route show default 2>/dev/null |
            awk '
                NR == 1 {
                    for (i=1; i<=NF; i++) {
                        if ($i == "dev") {
                            print $(i+1)
                            exit
                        }
                    }
                }
            '
    )"


    if [[ -z "$dev" ]]; then
        dev="$(
            ip -6 route show default 2>/dev/null |
                awk '
                    NR == 1 {
                        for (i=1; i<=NF; i++) {
                            if ($i == "dev") {
                                print $(i+1)
                                exit
                            }
                        }
                    }
                '
        )"
    fi


    if [[ -n "$dev" &&
          -r "/sys/class/net/$dev/mtu" ]]; then

        host_mtu="$(<"/sys/class/net/$dev/mtu")"
    fi


    if [[ "$host_mtu" =~ ^[0-9]+$ &&
          "$host_mtu" -gt 80 ]]; then

        MTU=$((host_mtu - 80))
    else
        MTU=1420
    fi
}


# =============================================================================
# Namespace-specific /etc
# =============================================================================

write_namespace_etc() {
    mkdir -p "$NETNS_ETC"


    : > "$NETNS_ETC/resolv.conf"


    local dns
    local count=0

    local -a searches=()


    for dns in "${DNS_VALUES[@]}"; do
        # IPv6 nameserver.
        if [[ "$dns" == *:* ]]; then
            printf 'nameserver %s\n' \
                "$dns" \
                >> "$NETNS_ETC/resolv.conf"

            count=$((count + 1))


        # IPv4 nameserver.
        elif [[ "$dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf 'nameserver %s\n' \
                "$dns" \
                >> "$NETNS_ETC/resolv.conf"

            count=$((count + 1))


        # wg-quick also allows DNS search domains.
        else
            searches+=("$dns")
        fi
    done


    # Safe fallback if provider supplied no DNS.
    if ((count == 0)); then
        if ((FULL_V4)); then
            echo "nameserver 1.1.1.1" \
                >> "$NETNS_ETC/resolv.conf"
        else
            echo "nameserver 2606:4700:4700::1111" \
                >> "$NETNS_ETC/resolv.conf"
        fi
    fi


    if ((${#searches[@]} > 0)); then
        {
            printf 'search'
            printf ' %s' "${searches[@]}"
            printf '\n'
        } >> "$NETNS_ETC/resolv.conf"
    fi


    # Avoid host-local resolver services inside the VPN namespace.
    if [[ -r /etc/nsswitch.conf ]]; then
        awk '
            BEGIN {
                found=0
            }

            /^[[:space:]]*hosts:/ {
                print "hosts: files dns"
                found=1
                next
            }

            {
                print
            }

            END {
                if (!found)
                    print "hosts: files dns"
            }
        ' /etc/nsswitch.conf \
            > "$NETNS_ETC/nsswitch.conf"

    else
        echo "hosts: files dns" \
            > "$NETNS_ETC/nsswitch.conf"
    fi


    chmod 0644 \
        "$NETNS_ETC/resolv.conf" \
        "$NETNS_ETC/nsswitch.conf"
}


# =============================================================================
# Root dependency checks
# =============================================================================

check_root_dependencies() {
    local executable

    local -a commands=(
        ip
        wg
        wg-quick
        awk
        stat
        env
        setsid
    )


    for executable in "${commands[@]}"; do
        command -v "$executable" >/dev/null 2>&1 ||
            die "required command not found: $executable"
    done


    if ! command -v setpriv >/dev/null 2>&1 &&
       ! command -v runuser >/dev/null 2>&1; then

        die "need setpriv or runuser to drop privileges"
    fi
}


# =============================================================================
# Profile validation
# =============================================================================

validate_profile() {
    local owner
    local mode
    local mode_octal


    CONF="$(readlink -f "$CONF")"


    [[ -f "$CONF" ]] ||
        die "profile not found: $CONF"


    owner="$(
        stat -Lc '%u' "$CONF" 2>/dev/null ||
            true
    )"


    [[ "$owner" == "$USER_UID" ]] ||
        die \
            "profile must be owned by $USER_NAME: $CONF"


    mode="$(
        stat -Lc '%a' "$CONF" 2>/dev/null ||
            true
    )"


    [[ "$mode" =~ ^[0-7]{3,4}$ ]] ||
        die "cannot determine profile permissions: $CONF"


    mode_octal=$((8#$mode))


    if ((mode_octal & 077)); then
        die \
            "profile permissions are too open: $CONF (run: chmod 600 '$CONF')"
    fi
}


# =============================================================================
# Session state
# =============================================================================

prepare_session_state() {
    mkdir -p \
        "$ROOT_RUN_USER_DIR" \
        "$ROOT_STATE_USER_DIR"


    chmod 0755 \
        "$RUN_BASE" \
        "$STATE_BASE" \
        "$ROOT_RUN_USER_DIR" \
        "$ROOT_STATE_USER_DIR" \
        2>/dev/null ||
        true


    mkdir "$SESSION_DIR"

    chmod 0755 "$SESSION_DIR"


    printf '%s\n' "$NS" \
        > "$SESSION_DIR/namespace"

    printf '%s\n' "$PROFILE_ID" \
        > "$SESSION_DIR/profile"

    printf '%s\n' "$APP_LABEL" \
        > "$SESSION_DIR/app"

    printf '%s\n' "$MTU" \
        > "$SESSION_DIR/mtu"

    printf '%s\n' "$DETACH" \
        > "$SESSION_DIR/detached"

    printf '%s\n' "$(date +%s)" \
        > "$SESSION_DIR/started"

    printf '%s\n' "$PROFILE_ID" \
        > "$ROOT_LAST_STATE"


    chmod 0644 \
        "$SESSION_DIR/namespace" \
        "$SESSION_DIR/profile" \
        "$SESSION_DIR/app" \
        "$SESSION_DIR/mtu" \
        "$SESSION_DIR/detached" \
        "$SESSION_DIR/started" \
        "$ROOT_LAST_STATE"


    # Keep a sanitized environment copy for attach/supervisor.
    SESSION_ENV_FILE="$SESSION_DIR/session.env"


    cat "$SESSION_FILE" > "$SESSION_ENV_FILE"


    chown "$USER_UID:$USER_GID" "$SESSION_ENV_FILE"
    chmod 0600 "$SESSION_ENV_FILE"
}


# =============================================================================
# Session cleanup
# =============================================================================

kill_namespace_processes() {
    local ns="$1"

    local pid
    local attempt

    local -a pids=()


    mapfile -t pids < <(
        namespace_pids "$ns"
    )


    for pid in "${pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] ||
            continue


        kill -TERM "$pid" 2>/dev/null ||
            true
    done


    # Allow graceful application shutdown.
    for attempt in 1 2 3; do
        sleep 1


        pids=()


        mapfile -t pids < <(
            namespace_pids "$ns"
        )


        ((${#pids[@]} == 0)) &&
            return 0
    done


    for pid in "${pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] ||
            continue


        kill -KILL "$pid" 2>/dev/null ||
            true
    done
}


cleanup_current_session() {
    ip netns del "$NS" \
        2>/dev/null ||
        true


    # Setup may fail before the temporary interface moves.
    if [[ -n "${WG_HOST:-}" ]]; then
        ip link del "$WG_HOST" \
            2>/dev/null ||
            true
    fi


    rm -rf \
        "$NETNS_ETC" \
        "$SESSION_DIR"
}


terminate_current_session() {
    if is_ns_up "$NS"; then
        kill_namespace_processes "$NS"
    fi


    cleanup_current_session
}


wait_for_session_empty() {
    local -a pids=()


    while is_ns_up "$NS"; do
        pids=()


        mapfile -t pids < <(
            namespace_pids "$NS"
        )


        ((${#pids[@]} == 0)) &&
            return 0


        sleep 1
    done


    return 0
}


# =============================================================================
# Run application as original user
# =============================================================================

run_as_user_in_ns() {
    local env_bin


    env_bin="$(command -v env)"


    local -a base_env=(
        "HOME=$USER_HOME"

        "USER=$USER_NAME"
        "LOGNAME=$USER_NAME"

        "SHELL=$USER_SHELL"

        "PATH=$USER_PATH"

        "CONDUIT_ACTIVE=1"
        "CONDUIT_SESSION=$SESSION_ID"
        "CONDUIT_NAMESPACE=$NS"
        "CONDUIT_PROFILE=$PROFILE_ID"
    )


    case "${1:-}" in
        bash|*/bash|\
        sh|*/sh|\
        zsh|*/zsh|\
        fish|*/fish)

            echo \
                ">> attached to Conduit session $SESSION_ID (type 'exit' to leave)" \
                >&2
            ;;
    esac


    if command -v setpriv >/dev/null 2>&1; then
        ip netns exec "$NS" \
            setpriv \
                --reuid "$USER_UID" \
                --regid "$USER_GID" \
                --init-groups \
                -- \
            "$env_bin" \
                -i \
                "${base_env[@]}" \
                "${SESSION_ENV[@]}" \
                "$@"


        return $?
    fi


    ip netns exec "$NS" \
        runuser \
            -u "$USER_NAME" \
            -- \
        "$env_bin" \
            -i \
            "${base_env[@]}" \
            "${SESSION_ENV[@]}" \
            "$@"
}


# =============================================================================
# Root: create isolated VPN session
# =============================================================================

root_run() {
    SESSION_ID="$1"
    CONF="$2"
    PROFILE_ID="$3"
    SESSION_FILE="$4"
    APP_LABEL="$5"
    DETACH="$6"


    shift 6


    [[ "$DETACH" == "0" || "$DETACH" == "1" ]] ||
        die "invalid internal detach mode"


    [[ "${1:-}" == "--" ]] ||
        die "internal argument error"


    shift


    (($# > 0)) ||
        die "missing command"


    [[ "$SESSION_ID" =~ ^[0-9a-f]{8}$ ]] ||
        die "invalid internal session ID"


    APP_LABEL="${APP_LABEL//[^A-Za-z0-9._+-]/_}"


    [[ -n "$APP_LABEL" ]] ||
        APP_LABEL="app"


    resolve_invoking_user
    check_root_dependencies
    read_session_file "$SESSION_FILE"
    validate_profile

    parse_profile
    choose_mtu


    ROOT_RUN_USER_DIR="$RUN_BASE/$USER_UID"
    ROOT_STATE_USER_DIR="$STATE_BASE/$USER_UID"
    ROOT_LAST_STATE="$ROOT_STATE_USER_DIR/last-profile"


    NS="conduit-$USER_UID-$SESSION_ID"

    SESSION_DIR="$ROOT_RUN_USER_DIR/$SESSION_ID"

    NETNS_ETC="/etc/netns/$NS"

    # Short unique host-side interface name.
    WG_HOST="cw$SESSION_ID"


    [[ ! -e "$SESSION_DIR" ]] ||
        die "session already exists: $SESSION_ID"


    if is_ns_up "$NS"; then
        die "network namespace already exists: $NS"
    fi


    trap cleanup_current_session EXIT


    trap '
        terminate_current_session
        trap - EXIT
        exit 130
    ' INT TERM HUP


    # -------------------------------------------------------------------------
    # Namespace + WireGuard
    # -------------------------------------------------------------------------

    ip netns add "$NS"


    # Create WireGuard in host namespace first.
    ip link add \
        "$WG_HOST" \
        type wireguard


    # wg-quick strip removes Address/DNS/MTU/hooks.
    # Endpoint hostname resolution therefore happens from host context.
    wg setconf \
        "$WG_HOST" \
        <(wg-quick strip "$CONF")


    ip link set \
        "$WG_HOST" \
        netns "$NS"


    # Every isolated namespace can independently use wg0.
    ip -n "$NS" \
        link set \
        "$WG_HOST" \
        name wg0


    ip -n "$NS" \
        link set \
        dev wg0 \
        mtu "$MTU"


    local address


    for address in "${ADDRS[@]}"; do
        ip -n "$NS" \
            addr add \
            "$address" \
            dev wg0
    done


    ip -n "$NS" \
        link set \
        lo up


    ip -n "$NS" \
        link set \
        wg0 up


    if ((FULL_V4)); then
        ip -n "$NS" \
            route add \
            default \
            dev wg0
    fi


    if ((FULL_V6)); then
        ip -n "$NS" \
            -6 route add \
            default \
            dev wg0
    fi


    write_namespace_etc
    prepare_session_state


    echo ">> session:   $SESSION_ID" >&2
    echo ">> app:       $APP_LABEL" >&2
    echo ">> profile:   $PROFILE_ID" >&2
    echo ">> namespace: $NS" >&2
    echo ">> mtu:       $MTU" >&2


    # -------------------------------------------------------------------------
    # Detached mode
    # -------------------------------------------------------------------------

    if ((DETACH)); then
        local log_file="$SESSION_DIR/log"


        : > "$log_file"


        chown "$USER_UID:$USER_GID" "$log_file"
        chmod 0600 "$log_file"


        setsid \
            "$SELF" \
            --_root-supervise \
            "$SESSION_ID" \
            -- \
            "$@" \
            </dev/null \
            >>"$log_file" \
            2>&1 &


        local supervisor_pid=$!


        printf '%s\n' \
            "$supervisor_pid" \
            > "$SESSION_DIR/supervisor"


        chmod 0644 \
            "$SESSION_DIR/supervisor"


        # Supervisor now owns session lifecycle.
        trap - EXIT INT TERM HUP


        echo ">> detached" >&2
        echo ">> log: $log_file" >&2


        return 0
    fi


    # -------------------------------------------------------------------------
    # Foreground mode
    # -------------------------------------------------------------------------

    local rc=0


    if run_as_user_in_ns "$@"; then
        rc=0
    else
        rc=$?
    fi


    # GUI launchers may fork and exit while children remain.
    wait_for_session_empty


    cleanup_current_session


    trap - EXIT INT TERM HUP


    return "$rc"
}


# =============================================================================
# Root: detached lifecycle supervisor
# =============================================================================

root_supervise() {
    SESSION_ID="$1"


    shift


    [[ "${1:-}" == "--" ]] ||
        die "internal supervisor argument error"


    shift


    (($# > 0)) ||
        die "missing supervisor command"


    [[ "$SESSION_ID" =~ ^[0-9a-f]{8}$ ]] ||
        die "invalid supervisor session ID"


    resolve_invoking_user
    check_root_dependencies


    ROOT_RUN_USER_DIR="$RUN_BASE/$USER_UID"

    SESSION_DIR="$ROOT_RUN_USER_DIR/$SESSION_ID"


    [[ -d "$SESSION_DIR" ]] ||
        die "session state disappeared: $SESSION_ID"


    NS="$(<"$SESSION_DIR/namespace")"
    PROFILE_ID="$(<"$SESSION_DIR/profile")"
    APP_LABEL="$(<"$SESSION_DIR/app")"

    SESSION_ENV_FILE="$SESSION_DIR/session.env"

    NETNS_ETC="/etc/netns/$NS"

    WG_HOST=""


    [[ "$NS" == "conduit-$USER_UID-$SESSION_ID" ]] ||
        die "invalid supervisor namespace state"


    is_ns_up "$NS" ||
        die "network namespace disappeared: $NS"


    read_session_file "$SESSION_ENV_FILE"


    trap '
        terminate_current_session
        trap - EXIT
        exit 130
    ' INT TERM HUP


    local rc=0


    if run_as_user_in_ns "$@"; then
        rc=0
    else
        rc=$?
    fi


    wait_for_session_empty


    cleanup_current_session


    trap - EXIT INT TERM HUP


    return "$rc"
}


# =============================================================================
# Root: attach to existing session
# =============================================================================

root_attach() {
    SESSION_ID="$1"


    shift


    [[ "${1:-}" == "--" ]] ||
        die "internal attach argument error"


    shift


    (($# > 0)) ||
        die "missing attach command"


    [[ "$SESSION_ID" =~ ^[0-9a-f]{8}$ ]] ||
        die "invalid session ID: $SESSION_ID"


    resolve_invoking_user
    check_root_dependencies


    ROOT_RUN_USER_DIR="$RUN_BASE/$USER_UID"

    SESSION_DIR="$ROOT_RUN_USER_DIR/$SESSION_ID"


    [[ -d "$SESSION_DIR" ]] ||
        die "session not found: $SESSION_ID"


    NS="$(<"$SESSION_DIR/namespace")"
    PROFILE_ID="$(<"$SESSION_DIR/profile")"
    APP_LABEL="$(<"$SESSION_DIR/app")"

    SESSION_ENV_FILE="$SESSION_DIR/session.env"

    NETNS_ETC="/etc/netns/$NS"

    WG_HOST=""


    [[ "$NS" == "conduit-$USER_UID-$SESSION_ID" ]] ||
        die "invalid session state"


    is_ns_up "$NS" ||
        die "session is no longer active: $SESSION_ID"


    read_session_file "$SESSION_ENV_FILE"


    echo ">> session: $SESSION_ID" >&2
    echo ">> profile: $PROFILE_ID" >&2


    run_as_user_in_ns "$@"
}


# =============================================================================
# Root: kill one session
# =============================================================================

root_kill_session() {
    local id="$1"


    resolve_invoking_user


    [[ "$id" =~ ^[0-9a-f]{8}$ ]] ||
        die "invalid session ID: $id"


    local user_run_dir="$RUN_BASE/$USER_UID"
    local session_dir="$user_run_dir/$id"


    [[ -d "$session_dir" ]] ||
        die "session not found: $id"


    local ns


    ns="$(<"$session_dir/namespace")"


    [[ "$ns" == "conduit-$USER_UID-$id" ]] ||
        die "invalid session state"


    if is_ns_up "$ns"; then
        kill_namespace_processes "$ns"


        ip netns del "$ns" \
            2>/dev/null ||
            true
    fi


    rm -rf \
        "/etc/netns/$ns" \
        "$session_dir"


    echo "session $id stopped"
}


# =============================================================================
# Root: kill all invoking-user sessions
# =============================================================================

root_kill_all() {
    resolve_invoking_user


    local user_run_dir="$RUN_BASE/$USER_UID"


    [[ -d "$user_run_dir" ]] || {
        echo "no sessions"
        return 0
    }


    local directory
    local id
    local ns

    local found=0


    shopt -s nullglob


    for directory in "$user_run_dir"/*; do
        [[ -d "$directory" ]] ||
            continue


        id="${directory##*/}"


        [[ "$id" =~ ^[0-9a-f]{8}$ ]] ||
            continue


        ns=""


        [[ -r "$directory/namespace" ]] &&
            ns="$(<"$directory/namespace")"


        [[ "$ns" == "conduit-$USER_UID-$id" ]] ||
            continue


        found=1


        if is_ns_up "$ns"; then
            kill_namespace_processes "$ns"


            ip netns del "$ns" \
                2>/dev/null ||
                true
        fi


        rm -rf \
            "/etc/netns/$ns" \
            "$directory"


        echo "session $id stopped"
    done


    shopt -u nullglob


    if ((found == 0)); then
        echo "no sessions"
    fi
}


# =============================================================================
# Doctor helpers
# =============================================================================

doctor_ok() {
    printf '[OK]   %s\n' "$1"
}


doctor_warn() {
    printf '[WARN] %s\n' "$1"
}


doctor_fail() {
    printf '[FAIL] %s\n' "$1"
}


# =============================================================================
# Root: doctor self-test
# =============================================================================

root_doctor() {
    resolve_invoking_user
    check_root_dependencies


    local id
    local ns
    local wgdev


    id="$(
        printf '%08x' \
            "$(( (RANDOM << 16) | RANDOM ))"
    )"


    ns="conduit-doctor-$USER_UID-$id"
    wgdev="cwd${id:0:8}"


    trap '
        ip link del "$wgdev" 2>/dev/null || true
        ip netns del "$ns" 2>/dev/null || true
    ' EXIT INT TERM HUP


    if ! ip netns add "$ns"; then
        doctor_fail "network namespace creation"
        return 1
    fi


    doctor_ok "network namespace creation"


    if ! ip link add "$wgdev" type wireguard; then
        doctor_fail "WireGuard kernel interface"
        return 1
    fi


    doctor_ok "WireGuard kernel interface"


    ip link del "$wgdev"
    ip netns del "$ns"


    trap - EXIT INT TERM HUP


    doctor_ok "privilege escalation"


    return 0
}


# =============================================================================
# User-side doctor
# =============================================================================

doctor() {
    local failures=0
    local command

    local owner
    local mode
    local mode_octal

    local profiles=0
    local insecure=0

    local file


    echo "Conduit $VERSION"
    echo "Doctor"
    echo


    # -------------------------------------------------------------------------
    # Core commands
    # -------------------------------------------------------------------------

    local -a required=(
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
    )


    for command in "${required[@]}"; do
        if command -v "$command" >/dev/null 2>&1; then
            doctor_ok "$command"
        else
            doctor_fail "$command"
            failures=$((failures + 1))
        fi
    done


    # -------------------------------------------------------------------------
    # Privilege drop
    # -------------------------------------------------------------------------

    if command -v setpriv >/dev/null 2>&1; then
        doctor_ok "setpriv"

    elif command -v runuser >/dev/null 2>&1; then
        doctor_ok "runuser"

    else
        doctor_fail "setpriv/runuser"
        failures=$((failures + 1))
    fi


    # -------------------------------------------------------------------------
    # Privilege elevation
    # -------------------------------------------------------------------------

    if command -v sudo >/dev/null 2>&1; then
        doctor_ok "sudo"

    elif command -v doas >/dev/null 2>&1; then
        doctor_ok "doas"

    else
        doctor_fail "sudo/doas"
        failures=$((failures + 1))
    fi


    # -------------------------------------------------------------------------
    # WARP bootstrap dependencies
    # -------------------------------------------------------------------------

    if command -v curl >/dev/null 2>&1; then
        doctor_ok "curl (WARP bootstrap)"
    else
        doctor_fail "curl (WARP bootstrap)"
        failures=$((failures + 1))
    fi


    if command -v jq >/dev/null 2>&1; then
        doctor_ok "jq (WARP bootstrap)"
    else
        doctor_fail "jq (WARP bootstrap)"
        failures=$((failures + 1))
    fi


    # -------------------------------------------------------------------------
    # Desktop session
    # -------------------------------------------------------------------------

    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        doctor_ok "Wayland session"

    elif [[ -n "${DISPLAY:-}" ]]; then
        doctor_ok "X11 session"

    else
        doctor_warn \
            "no graphical session detected; CLI use is still available"
    fi


    # -------------------------------------------------------------------------
    # Profile validation
    # -------------------------------------------------------------------------

    load_all_profiles


    for file in "${ALL_PROFILES[@]}"; do
        profiles=$((profiles + 1))


        owner="$(
            stat -Lc '%u' "$file" 2>/dev/null ||
                true
        )"


        mode="$(
            stat -Lc '%a' "$file" 2>/dev/null ||
                true
        )"


        if [[ "$owner" != "$LOCAL_UID" ]]; then
            doctor_fail \
                "wrong profile owner: $(profile_id "$file")"

            insecure=$((insecure + 1))

            continue
        fi


        if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
            mode_octal=$((8#$mode))


            if ((mode_octal & 077)); then
                doctor_fail \
                    "insecure profile permissions: $(profile_id "$file") ($mode)"

                insecure=$((insecure + 1))
            fi

        else
            doctor_fail \
                "cannot inspect profile: $(profile_id "$file")"

            insecure=$((insecure + 1))
        fi
    done


    if ((profiles > 0)); then
        doctor_ok "$profiles VPN profile(s)"
    else
        doctor_warn \
            "no VPN profiles; first launch will bootstrap Cloudflare WARP"
    fi


    if ((insecure > 0)); then
        failures=$((failures + insecure))
    fi


    # -------------------------------------------------------------------------
    # Privileged kernel/network test
    # -------------------------------------------------------------------------

    echo


    if run_elevated --_root-doctor; then
        :
    else
        doctor_fail "privileged Conduit self-test"
        failures=$((failures + 1))
    fi


    echo


    if ((failures == 0)); then
        echo "Conduit is ready."
        return 0
    fi


    echo "Conduit found $failures problem(s)."


    return 1
}


# =============================================================================
# User-side session discovery
# =============================================================================

load_session_ids() {
    SESSION_IDS=()

    local directory


    [[ -d "$USER_RUN_DIR" ]] ||
        return 0


    shopt -s nullglob


    for directory in "$USER_RUN_DIR"/*; do
        [[ -d "$directory" ]] ||
            continue


        SESSION_IDS+=("${directory##*/}")
    done


    shopt -u nullglob


    return 0
}


# =============================================================================
# User-side status
# =============================================================================

show_status() {
    load_session_ids


    if ((${#SESSION_IDS[@]} == 0)); then
        echo "Conduit: no sessions"
        return 0
    fi


    printf '%-10s %-8s %-16s %-31s %-6s %-5s %s\n' \
        "SESSION" \
        "STATE" \
        "APP" \
        "PROFILE" \
        "MTU" \
        "PIDS" \
        "NAMESPACE"


    printf '%-10s %-8s %-16s %-31s %-6s %-5s %s\n' \
        "--------" \
        "------" \
        "--------------" \
        "-----------------------------" \
        "----" \
        "----" \
        "----------------------------"


    local id
    local dir

    local app
    local profile
    local mtu
    local ns

    local state
    local pids


    for id in "${SESSION_IDS[@]}"; do
        dir="$USER_RUN_DIR/$id"


        app="?"
        profile="?"
        mtu="?"
        ns="?"


        [[ -r "$dir/app" ]] &&
            app="$(<"$dir/app")"


        [[ -r "$dir/profile" ]] &&
            profile="$(<"$dir/profile")"


        [[ -r "$dir/mtu" ]] &&
            mtu="$(<"$dir/mtu")"


        [[ -r "$dir/namespace" ]] &&
            ns="$(<"$dir/namespace")"


        if [[ "$ns" != "?" ]] &&
           is_ns_up "$ns"; then

            state="active"
            pids="$(namespace_pid_count "$ns")"

        else
            state="stale"
            pids="0"
        fi


        printf '%-10s %-8s %-16s %-31s %-6s %-5s %s\n' \
            "$id" \
            "$state" \
            "$app" \
            "$profile" \
            "$mtu" \
            "$pids" \
            "$ns"
    done
}


# =============================================================================
# User-side profile listing
# =============================================================================

show_profiles() {
    ensure_profiles


    local last=""


    [[ -r "$LAST_STATE" ]] &&
        last="$(<"$LAST_STATE")"


    declare -A active_count=()


    local state
    local profile
    local file
    local id
    local marks


    shopt -s nullglob


    for state in "$USER_RUN_DIR"/*/profile; do
        [[ -r "$state" ]] ||
            continue


        profile="$(<"$state")"


        active_count["$profile"]="$(
            ((${active_count["$profile"]:-0} + 1))
        )"
    done


    shopt -u nullglob


    for file in "${ALL_PROFILES[@]}"; do
        id="$(profile_id "$file")"

        marks=""


        [[ "$id" == "$last" ]] &&
            marks+=" [last]"


        if [[ "${active_count["$id"]:-0}" -gt 0 ]]; then
            marks+=" [active:${active_count["$id"]}]"
        fi


        printf '  %s%s\n' \
            "$id" \
            "$marks"
    done
}


# =============================================================================
# User-side session selector
# =============================================================================

resolve_session_selector() {
    local selector="${1:-}"


    load_session_ids


    if ((${#SESSION_IDS[@]} == 0)); then
        die "no Conduit sessions"
    fi


    # No selector is allowed if exactly one session exists.
    if [[ -z "$selector" ]]; then
        if ((${#SESSION_IDS[@]} == 1)); then
            printf '%s\n' "${SESSION_IDS[0]}"
            return 0
        fi


        echo \
            "conduit: multiple sessions are active; choose one:" \
            >&2


        show_status >&2


        exit 1
    fi


    local id
    local dir

    local app
    local profile
    local profile_base

    local -a matches=()

    declare -A seen=()


    for id in "${SESSION_IDS[@]}"; do
        dir="$USER_RUN_DIR/$id"


        app=""
        profile=""


        [[ -r "$dir/app" ]] &&
            app="$(<"$dir/app")"


        [[ -r "$dir/profile" ]] &&
            profile="$(<"$dir/profile")"


        profile_base="${profile##*/}"


        if [[ "$id" == "$selector" ||
              "$id" == "$selector"* ||
              "$app" == "$selector" ||
              "$profile" == "$selector" ||
              "$profile_base" == "$selector" ]]; then


            if [[ -z "${seen["$id"]:-}" ]]; then
                matches+=("$id")
                seen["$id"]=1
            fi
        fi
    done


    if ((${#matches[@]} == 1)); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi


    if ((${#matches[@]} == 0)); then
        die "session not found: $selector"
    fi


    echo "conduit: ambiguous session '$selector':" >&2


    for id in "${matches[@]}"; do
        printf '  %s\n' "$id" >&2
    done


    exit 1
}


# =============================================================================
# User-side launch mode
# =============================================================================

resolve_detach_mode() {
    local requested="$1"
    local executable="${2##*/}"


    case "$requested" in
        foreground)
            printf '0\n'
            ;;


        detach)
            printf '1\n'
            ;;


        auto)
            case "$executable" in
                bash|sh|zsh|fish)
                    printf '0\n'
                    ;;

                *)
                    printf '1\n'
                    ;;
            esac
            ;;


        *)
            die "invalid detach mode"
            ;;
    esac
}


# =============================================================================
# User frontend
# =============================================================================

frontend_main() {
    case "${1:-}" in
        -h|--help)
            usage
            return 0
            ;;


        -V|--version|version)
            echo "conduit $VERSION"
            return 0
            ;;


        bootstrap)
            shift


            (($# == 0)) ||
                die "usage: conduit bootstrap"


            bootstrap_warp_config

            return 0
            ;;


        doctor)
            shift


            (($# == 0)) ||
                die "usage: conduit doctor"


            doctor

            return $?
            ;;


        show-vpn)
            shift


            (($# == 0)) ||
                die "usage: conduit show-vpn"


            show_profiles

            return 0
            ;;


        status)
            shift


            (($# == 0)) ||
                die "usage: conduit status"


            show_status

            return 0
            ;;


        attach)
            shift


            local attach_selector=""
            local attach_target=""


            # First arg is target unless omitted.
            if (($# > 0)); then
                attach_selector="$1"
                shift
            fi


            attach_target="$(
                resolve_session_selector "$attach_selector"
            )"


            # No command => attach user's normal shell.
            if (($# == 0)); then
                set -- "${SHELL:-/bin/sh}"
            fi


            run_elevated \
                --_root-attach \
                "$attach_target" \
                -- \
                "$@"


            return $?
            ;;


        logs)
            shift


            local log_target


            if (($# > 1)); then
                die "usage: conduit logs [session]"
            fi


            log_target="$(
                resolve_session_selector "${1:-}"
            )"


            local log_file="$USER_RUN_DIR/$log_target/log"


            [[ -f "$log_file" ]] ||
                die "no detached log for session: $log_target"


            if command -v tail >/dev/null 2>&1; then
                tail -f "$log_file"
            else
                cat "$log_file"
            fi


            return $?
            ;;


        kill)
            shift


            if [[ "${1:-}" == "--all" ]]; then
                (($# == 1)) ||
                    die "usage: conduit kill --all"


                run_elevated \
                    --_root-kill-all


                return $?
            fi


            (($# <= 1)) ||
                die "usage: conduit kill <session>"


            local kill_target


            kill_target="$(
                resolve_session_selector "${1:-}"
            )"


            run_elevated \
                --_root-kill \
                "$kill_target"


            return $?
            ;;
    esac


    # -------------------------------------------------------------------------
    # Normal launch
    # -------------------------------------------------------------------------

    local vpn_arg=""
    local provider_arg=""
    local requested_mode="auto"


    while (($# > 0)); do
        case "$1" in
            --vpn)
                (($# >= 2)) ||
                    die "--vpn requires a value"


                vpn_arg="$2"


                shift 2
                ;;


            --vpn=*)
                vpn_arg="${1#*=}"

                shift
                ;;


            --provider)
                (($# >= 2)) ||
                    die "--provider requires a value"


                provider_arg="$2"


                shift 2
                ;;


            --provider=*)
                provider_arg="${1#*=}"

                shift
                ;;


            -d|--detach)
                requested_mode="detach"

                shift
                ;;


            -f|--foreground)
                requested_mode="foreground"

                shift
                ;;


            -V|--version)
                echo "conduit $VERSION"

                return 0
                ;;


            -h|--help)
                usage

                return 0
                ;;


            --)
                shift

                break
                ;;


            -*)
                die "unknown option: $1"
                ;;


            *)
                break
                ;;
        esac
    done


    (($# > 0)) || {
        usage >&2
        exit 1
    }


    select_profile \
        "$vpn_arg" \
        "$provider_arg"


    local session_id
    local app_label
    local detach


    session_id="$(new_session_id)"


    app_label="${1##*/}"
    app_label="${app_label//[^A-Za-z0-9._+-]/_}"


    detach="$(
        resolve_detach_mode \
            "$requested_mode" \
            "$1"
    )"


    write_session_file


    local rc=0


    if run_elevated \
        --_root-run \
        "$session_id" \
        "$CONF" \
        "$PROFILE_ID" \
        "$SESSION_FILE" \
        "$app_label" \
        "$detach" \
        -- \
        "$@"
    then
        rc=0
    else
        rc=$?
    fi


    rm -f "$SESSION_FILE"


    return "$rc"
}


# =============================================================================
# Root internal API
# =============================================================================

root_main() {
    case "${1:-}" in
        --_root-run)
            shift


            (($# >= 8)) ||
                die "internal root-run argument error"


            root_run "$@"
            ;;


        --_root-supervise)
            shift


            (($# >= 3)) ||
                die "internal supervisor argument error"


            root_supervise "$@"
            ;;


        --_root-attach)
            shift


            (($# >= 3)) ||
                die "internal attach argument error"


            root_attach "$@"
            ;;


        --_root-kill)
            shift


            (($# == 1)) ||
                die "internal kill argument error"


            root_kill_session "$1"
            ;;


        --_root-kill-all)
            shift


            (($# == 0)) ||
                die "internal kill-all argument error"


            root_kill_all
            ;;


        --_root-doctor)
            shift


            (($# == 0)) ||
                die "internal doctor argument error"


            root_doctor
            ;;


        *)
            die \
                "do not run conduit directly as root"
            ;;
    esac
}


# =============================================================================
# Main
# =============================================================================

if ((EUID == 0)); then
    root_main "$@"
else
    frontend_main "$@"
fi
