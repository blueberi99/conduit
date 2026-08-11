#!/usr/bin/env bash
# conduit - per-app VPN split tunneling via network namespaces
# Copyright (C) 2026 berry
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# -----------------------------------------------------------------------------
# Global configuration
# -----------------------------------------------------------------------------

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

PROFILE_DIR="${CONDUIT_DIR:-$HOME/vpns}"

RUN_BASE="/run/conduit"
STATE_BASE="/var/lib/conduit"

USER_RUN_DIR="$RUN_BASE/$(id -u)"
USER_STATE_DIR="$STATE_BASE/$(id -u)"
LAST_STATE="$USER_STATE_DIR/last-profile"


# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------

die() {
    echo "conduit: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage:
  conduit [options] <command> [args...]

options:
  --vpn <profile>        use a specific WireGuard profile
  --provider <name>      choose a random profile from ~/vpns/<name>/

commands:
  conduit show-vpn       list available profiles
  conduit status         list active Conduit sessions
  conduit kill [target]  stop one session
  conduit kill --all     stop all your sessions

examples:
  conduit discord
  conduit firefox

  conduit --vpn PDE-778 discord
  conduit --provider proton discord
  conduit --provider mullvad discord
  conduit --provider cloudflare firefox

profile layout:
  ~/vpns/*.conf
  ~/vpns/<provider>/*.conf

examples:
  ~/vpns/proton/PDE-778-DE-778.conf
  ~/vpns/mullvad/de-ber-wg-102.conf
  ~/vpns/cloudflare/warp.conf

override profile directory:
  CONDUIT_DIR=/path/to/profiles conduit discord

Each launch gets its own isolated network namespace.
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


# -----------------------------------------------------------------------------
# Profile discovery
# -----------------------------------------------------------------------------

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
}


filter_provider() {
    local provider="$1"
    local provider_dir="$PROFILE_DIR/$provider"

    local file
    local id
    local base

    CANDIDATES=()

    # Preferred provider-agnostic layout:
    #
    # ~/vpns/proton/*.conf
    # ~/vpns/mullvad/*.conf
    # ~/vpns/cloudflare/*.conf
    # ~/vpns/whatever/*.conf
    #
    if [[ -d "$provider_dir" ]]; then
        for file in "${ALL_PROFILES[@]}"; do
            if [[ "$file" == "$provider_dir/"* ]]; then
                CANDIDATES+=("$file")
            fi
        done

        return 0
    fi

    # Backward compatibility with the old flat layout.
    #
    # PDE* = Proton
    # non-PDE root profiles = Mullvad
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

        mullvad)
            for file in "${ALL_PROFILES[@]}"; do
                id="$(profile_id "$file")"
                base="${file##*/}"

                if [[ "$id" != */* && "$base" != PDE* ]]; then
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

    load_all_profiles

    ((${#ALL_PROFILES[@]} > 0)) ||
        die "no WireGuard profiles found under $PROFILE_DIR"

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


    # Explicit profile.
    if [[ -n "$vpn_arg" ]]; then
        wanted="$vpn_arg"

        # Exact match first.
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
            return
        fi

        if ((${#exact[@]} > 1)); then
            echo "conduit: ambiguous profile '$vpn_arg':" >&2

            for file in "${exact[@]}"; do
                printf '  %s\n' "$(profile_id "$file")" >&2
            done

            exit 1
        fi


        # Substring match.
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
            return
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


    # Random selection, avoiding the previous profile when possible.
    if [[ -r "$LAST_STATE" ]]; then
        last="$(<"$LAST_STATE")"
    fi

    for file in "${pool[@]}"; do
        [[ "$(profile_id "$file")" == "$last" ]] ||
            without_last+=("$file")
    done

    if ((${#without_last[@]} > 0)); then
        pool=("${without_last[@]}")
    fi

    CONF="${pool[RANDOM % ${#pool[@]}]}"
    PROFILE_ID="$(profile_id "$CONF")"
}


# -----------------------------------------------------------------------------
# Session IDs
# -----------------------------------------------------------------------------

new_session_id() {
    local uuid
    local id
    local try

    for try in {1..32}; do
        if [[ -r /proc/sys/kernel/random/uuid ]]; then
            uuid="$(</proc/sys/kernel/random/uuid)"
            id="${uuid%%-*}"
        else
            id="$(printf '%08x' "$((RANDOM << 16 | RANDOM))")"
        fi

        [[ ! -e "$USER_RUN_DIR/$id" ]] || continue

        printf '%s\n' "$id"
        return
    done

    die "could not allocate a unique session ID"
}


# -----------------------------------------------------------------------------
# Session environment capture
# -----------------------------------------------------------------------------

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
            [[ "$value" == *$'\n'* ]] && continue

            printf '%s=%s\n' \
                "$key" \
                "$value" \
                >> "$SESSION_FILE"
        fi
    done
}


# -----------------------------------------------------------------------------
# Privilege escalation
# -----------------------------------------------------------------------------

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


# -----------------------------------------------------------------------------
# Resolve invoking user after elevation
# -----------------------------------------------------------------------------

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

    # Minimal fallback for distributions without getent.
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


# -----------------------------------------------------------------------------
# Read captured desktop environment
# -----------------------------------------------------------------------------

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
        [[ "$line" == *=* ]] || continue

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


# -----------------------------------------------------------------------------
# WireGuard config parser
# -----------------------------------------------------------------------------

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

        /^[[:space:]]*#/ {
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
            # trim left
            item="${item#"${item%%[![:space:]]*}"}"

            # trim right
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
        [[ "$value" == "0.0.0.0/0" ]] &&
            FULL_V4=1

        [[ "$value" == "::/0" ]] &&
            FULL_V6=1
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


# -----------------------------------------------------------------------------
# MTU
# -----------------------------------------------------------------------------

choose_mtu() {
    local dev=""
    local host_mtu=""

    # Respect provider config first.
    if [[ -n "$CONFIG_MTU" ]]; then
        [[ "$CONFIG_MTU" =~ ^[0-9]+$ ]] ||
            die "invalid MTU: $CONFIG_MTU"

        ((CONFIG_MTU >= 576 && CONFIG_MTU <= 65535)) ||
            die "MTU out of range: $CONFIG_MTU"

        MTU="$CONFIG_MTU"
        return
    fi

    # Otherwise use the physical default route.
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


# -----------------------------------------------------------------------------
# Namespace-specific /etc
# -----------------------------------------------------------------------------

write_namespace_etc() {
    mkdir -p "$NETNS_ETC"

    : > "$NETNS_ETC/resolv.conf"

    local dns
    local count=0

    local -a searches=()

    for dns in "${DNS_VALUES[@]}"; do
        # IPv6 address
        if [[ "$dns" == *:* ]]; then
            printf 'nameserver %s\n' \
                "$dns" \
                >> "$NETNS_ETC/resolv.conf"

            count=$((count + 1))

        # IPv4 address
        elif [[ "$dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf 'nameserver %s\n' \
                "$dns" \
                >> "$NETNS_ETC/resolv.conf"

            count=$((count + 1))

        # DNS search domain
        else
            searches+=("$dns")
        fi
    done

    # Safe fallback when the VPN profile contains no DNS.
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

    # Use ordinary DNS inside the VPN namespace instead of a host-local
    # resolver service such as systemd-resolved.
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


# -----------------------------------------------------------------------------
# Root-side dependency check
# -----------------------------------------------------------------------------

check_root_dependencies() {
    local command

    local -a commands=(
        ip
        wg
        wg-quick
        awk
        stat
        env
    )

    for command in "${commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 ||
            die "required command not found: $command"
    done

    if ! command -v setpriv >/dev/null 2>&1 &&
       ! command -v runuser >/dev/null 2>&1; then
        die "need setpriv or runuser to drop privileges"
    fi
}


# -----------------------------------------------------------------------------
# Profile validation
# -----------------------------------------------------------------------------

validate_profile() {
    local owner

    CONF="$(readlink -f "$CONF")"

    [[ -f "$CONF" && ! -L "$CONF" ]] ||
        die "profile not found: $CONF"

    owner="$(
        stat -Lc '%u' "$CONF" 2>/dev/null ||
            true
    )"

    [[ "$owner" == "$USER_UID" ]] ||
        die \
            "profile must be owned by $USER_NAME: $CONF"
}


# -----------------------------------------------------------------------------
# Session state
# -----------------------------------------------------------------------------

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

    printf '%s\n' "$(date +%s)" \
        > "$SESSION_DIR/started"

    printf '%s\n' "$PROFILE_ID" \
        > "$ROOT_LAST_STATE"

    chmod 0644 \
        "$SESSION_DIR/namespace" \
        "$SESSION_DIR/profile" \
        "$SESSION_DIR/app" \
        "$SESSION_DIR/mtu" \
        "$SESSION_DIR/started" \
        "$ROOT_LAST_STATE"
}


# -----------------------------------------------------------------------------
# Session cleanup
# -----------------------------------------------------------------------------

namespace_pids() {
    local ns="$1"

    ip netns pids "$ns" \
        2>/dev/null ||
        true
}


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

        kill -TERM "$pid" \
            2>/dev/null ||
            true
    done

    # Give applications a few seconds to exit cleanly.
    for attempt in 1 2 3; do
        sleep 1

        pids=()

        mapfile -t pids < <(
            namespace_pids "$ns"
        )

        ((${#pids[@]} == 0)) &&
            return
    done

    for pid in "${pids[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] ||
            continue

        kill -KILL "$pid" \
            2>/dev/null ||
            true
    done
}


cleanup_current_session() {
    ip netns del "$NS" \
        2>/dev/null ||
        true

    # If setup failed before the interface was moved, remove it here.
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
            return

        sleep 1
    done
}


# -----------------------------------------------------------------------------
# Run application as original user
# -----------------------------------------------------------------------------

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
                ">> entered Conduit session $SESSION_ID (type 'exit' to leave)" \
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

        return
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


# -----------------------------------------------------------------------------
# Root: create and run one isolated session
# -----------------------------------------------------------------------------

root_run() {
    SESSION_ID="$1"
    CONF="$2"
    PROFILE_ID="$3"
    SESSION_FILE="$4"
    APP_LABEL="$5"

    shift 5

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

    # Linux interface names are limited, so keep the temporary host-side name
    # short and unique.
    WG_HOST="cw${SESSION_ID:0:10}"

    [[ ! -e "$SESSION_DIR" ]] ||
        die "session already exists: $SESSION_ID"

    ! is_ns_up "$NS" ||
        die "network namespace already exists: $NS"

    # This trap only knows about THIS invocation's namespace.
    trap cleanup_current_session EXIT

    trap '
        terminate_current_session
        trap - EXIT
        exit 130
    ' INT TERM HUP

    # Create an independent network namespace.
    ip netns add "$NS"

    # Create WireGuard in the host namespace first.
    ip link add \
        "$WG_HOST" \
        type wireguard

    # Strip wg-quick-only fields such as Address/DNS/MTU/hooks.
    # Endpoint hostname resolution happens while configuring from the host.
    wg setconf \
        "$WG_HOST" \
        <(wg-quick strip "$CONF")

    # Move the interface to the new namespace.
    ip link set \
        "$WG_HOST" \
        netns "$NS"

    # Every namespace can independently call its interface wg0.
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

    # The namespace has no physical interface, so these routes are also the
    # kill-switch: no wg0 means no network path.
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

    local rc=0

    if run_as_user_in_ns "$@"; then
        rc=0
    else
        rc=$?
    fi

    # Some GUI apps fork children and let their launcher process exit.
    # Keep the VPN alive while anything is still inside this namespace.
    wait_for_session_empty

    cleanup_current_session

    trap - EXIT INT TERM HUP

    return "$rc"
}


# -----------------------------------------------------------------------------
# Root: kill sessions
# -----------------------------------------------------------------------------

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


root_kill_all() {
    resolve_invoking_user

    local user_run_dir="$RUN_BASE/$USER_UID"

    [[ -d "$user_run_dir" ]] || {
        echo "no sessions"
        return
    }

    local directory
    local id
    local ns

    local found=0

    shopt -s nullglob

    for directory in "$user_run_dir"/*; do
        [[ -d "$directory" ]] || continue

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

    ((found)) ||
        echo "no sessions"
}


# -----------------------------------------------------------------------------
# User-side status
# -----------------------------------------------------------------------------

load_session_ids() {
    SESSION_IDS=()

    local directory

    [[ -d "$USER_RUN_DIR" ]] ||
        return

    shopt -s nullglob

    for directory in "$USER_RUN_DIR"/*; do
        [[ -d "$directory" ]] || continue

        SESSION_IDS+=("${directory##*/}")
    done

    shopt -u nullglob
}


show_status() {
    load_session_ids

    if ((${#SESSION_IDS[@]} == 0)); then
        echo "Conduit: no active sessions"
        return
    fi

    printf '%-10s %-18s %-35s %-8s %s\n' \
        "SESSION" \
        "APP" \
        "PROFILE" \
        "MTU" \
        "NAMESPACE"

    printf '%-10s %-18s %-35s %-8s %s\n' \
        "--------" \
        "----------------" \
        "---------------------------------" \
        "------" \
        "------------------------------"

    local id
    local dir
    local app
    local profile
    local mtu
    local ns

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

        printf '%-10s %-18s %-35s %-8s %s\n' \
            "$id" \
            "$app" \
            "$profile" \
            "$mtu" \
            "$ns"
    done
}


# -----------------------------------------------------------------------------
# User-side profile listing
# -----------------------------------------------------------------------------

show_profiles() {
    load_all_profiles

    ((${#ALL_PROFILES[@]} > 0)) ||
        die "no profiles found under $PROFILE_DIR"

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
        [[ -r "$state" ]] || continue

        profile="$(<"$state")"

        active_count["$profile"]=$(
            ((${active_count["$profile"]:-0} + 1))
        )
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


# -----------------------------------------------------------------------------
# User-side kill selector
# -----------------------------------------------------------------------------

resolve_session_selector() {
    local selector="${1:-}"

    load_session_ids

    if ((${#SESSION_IDS[@]} == 0)); then
        die "no active sessions"
    fi

    # No selector: convenient when exactly one tunnel exists.
    if [[ -z "$selector" ]]; then
        if ((${#SESSION_IDS[@]} == 1)); then
            printf '%s\n' "${SESSION_IDS[0]}"
            return
        fi

        echo \
            "conduit: multiple sessions are active; specify one:" \
            >&2

        show_status >&2

        exit 1
    fi

    local id
    local dir
    local app

    local -a matches=()

    declare -A seen=()

    for id in "${SESSION_IDS[@]}"; do
        dir="$USER_RUN_DIR/$id"

        app=""

        [[ -r "$dir/app" ]] &&
            app="$(<"$dir/app")"

        if [[ "$id" == "$selector" ||
              "$id" == "$selector"* ||
              "$app" == "$selector" ]]; then

            if [[ -z "${seen["$id"]:-}" ]]; then
                matches+=("$id")
                seen["$id"]=1
            fi
        fi
    done

    if ((${#matches[@]} == 1)); then
        printf '%s\n' "${matches[0]}"
        return
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


# -----------------------------------------------------------------------------
# User frontend
# -----------------------------------------------------------------------------

frontend_main() {
    case "${1:-}" in
        -h|--help)
            usage
            return
            ;;

        show-vpn)
            show_profiles
            return
            ;;

        status)
            show_status
            return
            ;;

        kill)
            shift

            if [[ "${1:-}" == "--all" ]]; then
                run_elevated \
                    --_root-kill-all

                return
            fi

            local target

            target="$(
                resolve_session_selector "${1:-}"
            )"

            run_elevated \
                --_root-kill \
                "$target"

            return
            ;;
    esac

    local vpn_arg=""
    local provider_arg=""

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

            -h|--help)
                usage
                return
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

    session_id="$(new_session_id)"

    app_label="${1##*/}"
    app_label="${app_label//[^A-Za-z0-9._+-]/_}"

    write_session_file

    local rc=0

    if run_elevated \
        --_root-run \
        "$session_id" \
        "$CONF" \
        "$PROFILE_ID" \
        "$SESSION_FILE" \
        "$app_label" \
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


# -----------------------------------------------------------------------------
# Root internal entry point
# -----------------------------------------------------------------------------

root_main() {
    case "${1:-}" in
        --_root-run)
            shift

            (($# >= 7)) ||
                die "internal argument error"

            root_run "$@"
            ;;

        --_root-kill)
            shift

            (($# == 1)) ||
                die "internal argument error"

            root_kill_session "$1"
            ;;

        --_root-kill-all)
            root_kill_all
            ;;

        *)
            die \
                "do not run conduit directly as root"
            ;;
    esac
}


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

if ((EUID == 0)); then
    root_main "$@"
else
    frontend_main "$@"
fi