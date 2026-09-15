#!/bin/bash
# ==========================================================
#  DX-NEST — DX Nested Ephemeral Sandbox Terminal
#  A Free VPS Manager: runs a persistent Ubuntu QEMU VM
#  safely nested inside a Daytona Sandbox.
#
#  Created by: @COD-DEXTER
#  v2.0  — full architecture redesign of DAYTONA-VPS1
#  v2.1  — production hardening pass (see CHANGELOG.md):
#          secure config loading + validation, dedicated
#          known_hosts, KVM/TCG detection, disk-marker
#          reconciliation, real restart/enter verification
#          + recovery menu, network diagnostics, log
#          rotation, AUTH_MODE/VM_USER in config menu,
#          CLI mode, stronger PID identity checks.
#  v2.2  — real-world Daytona fixes + persistent `dx` command
#          (see CHANGELOG.md): fixed a confirmed crash in
#          Status (qemu-img/ps failures under set -e/pipefail),
#          Sandbox RAM/CPU now shows UNKNOWN instead of a
#          misleading "0G/0 vCPU", self-installs to
#          /usr/local/lib/dx-nest + /usr/local/bin/dx so `dx`
#          works from any directory with no internet needed,
#          plus a separate bootstrap.sh with multi-source +
#          bash -n validated download for blocked-GitHub networks.
#  v2.2.1 — final release audit (see CHANGELOG.md): self_install()
#          now writes the persistent manager via a validated
#          temp-file + atomic rename instead of an in-place `cp`,
#          so a disk-full/permission/interrupted failure mid-
#          install can never leave a truncated or invalid
#          /usr/local/lib/dx-nest/install.sh behind — the previous
#          working installation (if any) is always left intact.
# ==========================================================
#
# This replaces the old single-shot "create_vps / boot_qemu" script
# with a real Start/Stop/Restart/Status/Enter VM manager. See README.md
# in this repo for the full list of problems this fixes and why.
#
# Design notes that matter for anyone editing this file:
#  - QEMU is launched with -daemonize + -pidfile, NOT -nographic. This
#    means the menu terminal is never hijacked by the guest console,
#    and we get a real, race-free PID file for free from QEMU itself.
#  - The guest's serial console and QEMU monitor are exposed as UNIX
#    sockets (chardev/monitor), so "Console" and graceful shutdown work
#    without ever needing a broad `pkill`.
#  - The qcow2 disk and seed.img are created exactly once. Start/Stop/
#    Restart NEVER touch them. Resizing or rebuilding the VM requires
#    an explicit, separate menu action with a typed confirmation.
#  - Lifecycle mutation (start/stop/restart) is done via *_impl()
#    functions that do NOT take the lock themselves. Only the public
#    start_vm/stop_vm/restart_vm wrappers take the lock, exactly once
#    per call, so restart never nests flock() inside the same process.
#  - Almost every bare "fn_call" that can legitimately fail (start_vm,
#    stop_vm, restart_vm, enter_vps) is invoked either inside an
#    if/while condition or with a trailing `|| true` at call sites
#    that shouldn't abort the whole script under `set -e`. A bare
#    failing command in a case branch DOES trigger the ERR trap and
#    kill the whole menu under `set -Eeuo pipefail` — that is a real
#    footgun this revision fixes at every call site.

set -Eeuo pipefail

# ==========================================================
# Section 0: Paths & Globals
# ==========================================================
BASE_DIR="${DXNEST_HOME:-/home/daytona/dxnest}"
IMAGE_PATH="$BASE_DIR/ubuntu-22.04-base.qcow2"
SEED_IMG="$BASE_DIR/seed.img"
USER_DATA_FILE="$BASE_DIR/user-data"
META_DATA_FILE="$BASE_DIR/meta-data"
PID_FILE="$BASE_DIR/vm.pid"
MONITOR_SOCK="$BASE_DIR/qemu-monitor.sock"
CONSOLE_SOCK="$BASE_DIR/qemu-console.sock"
LOG_DIR="$BASE_DIR/logs"
BOOT_LOG="$LOG_DIR/vm-boot.log"
DAEMON_LOG="$LOG_DIR/dxnest.log"
SSH_DIR="$BASE_DIR/ssh"
SSH_KEY="$BASE_DIR/dxnest_ed25519"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
CONFIG_FILE="$BASE_DIR/config.env"
DISK_MARKER="$BASE_DIR/.disk_size_gb"
ACCEL_MARKER="$BASE_DIR/.accel_mode"
LIFECYCLE_LOCK="$BASE_DIR/.lifecycle.lock"

# Remote Access (Public SSH via Cloudflare Tunnel) — Section 19b. A
# completely independent module: its own subdirectory, its own PID/log/
# token files, its own lock. It sits on top of the QEMU VM (reads
# HOST_SSH_PORT / is_vm_running / ssh_ready) but the VM never reads
# anything from here, and none of this is ever touched by
# create_vm_if_needed, start_vm, stop_vm, restart_vm, or Maintenance's
# Full Reset. Deliberately kept OUT of CONFIG_FILE/config.env: the
# token is a secret and config.env is meant for non-secret settings.
REMOTE_DIR="$BASE_DIR/remote"
CF_PID_FILE="$REMOTE_DIR/cloudflared.pid"
CF_LOG="$REMOTE_DIR/cloudflared.log"
CF_TOKEN_FILE="$REMOTE_DIR/cloudflared.token"
# Separate from CF_TOKEN_FILE on purpose (Section 10 of the Cloudflare spec):
# CF_API_TOKEN_FILE is the *setup/management* credential (scoped Cloudflare
# API Token used only during Setup/Repair to call api.cloudflare.com).
# CF_TOKEN_FILE is the *runtime* credential cloudflared actually runs with
# (a Tunnel Token). cloudflared is never invoked with the API token.
CF_API_TOKEN_FILE="$REMOTE_DIR/cloudflare-api.token"
REMOTE_LOCK="$REMOTE_DIR/.remote.lifecycle.lock"

# Persistent installation of the manager itself (separate concern from
# BASE_DIR, which holds the VM/disk/config). Self-install NEVER touches
# BASE_DIR — installing/repairing `dx` can never affect an existing VM.
INSTALL_LIB_DIR="/usr/local/lib/dx-nest"
INSTALL_MANAGER_PATH="$INSTALL_LIB_DIR/install.sh"
INSTALL_BIN_PATH="/usr/local/bin/dx"

IMAGE_URL_DEFAULT="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMAGE_SHA_URL_DEFAULT="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"

RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; MAGENTA='\033[1;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

VERSION="2.3.0"

# Defaults (overridable via config.env, never hard-coded credentials)
VM_RAM_GB="${VM_RAM_GB:-4}"
VM_CPU="${VM_CPU:-2}"
VM_DISK_GB="${VM_DISK_GB:-15}"
VM_USER="${VM_USER:-ubuntu}"
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
GUEST_SSH_PORT="22"
SANDBOX_RAM_GB="${SANDBOX_RAM_GB:-0}"
SANDBOX_CPU="${SANDBOX_CPU:-0}"
AUTH_MODE="${AUTH_MODE:-key}"   # key | password
VM_PASSWORD="${VM_PASSWORD:-}"  # only used if AUTH_MODE=password; never persisted to config.env, never logged

# Remote Access config — non-secret only. REMOTE_ACCESS_PROVIDER is empty
# ("") until Setup is run, or "cloudflare" once configured. The tunnel
# TOKEN is intentionally NOT a config.env key — it lives only in
# CF_TOKEN_FILE (0600), see Section 19b.
REMOTE_ACCESS_PROVIDER="${REMOTE_ACCESS_PROVIDER:-}"
CLOUDFLARE_SSH_HOST="${CLOUDFLARE_SSH_HOST:-}"
# Non-secret identifiers only (account/tunnel IDs are not secrets — they're
# visible in dashboard URLs). The API token and tunnel token are NEVER
# config.env keys; they live only in CF_API_TOKEN_FILE / CF_TOKEN_FILE.
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
CLOUDFLARE_TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"

# Log rotation defaults (P2-1)
LOG_MAX_SIZE="${LOG_MAX_SIZE:-2097152}"   # 2 MiB
LOG_ROTATIONS="${LOG_ROTATIONS:-3}"

# Whitelisted config.env keys (P0-2) — nothing outside this set is ever
# loaded. The Cloudflare tunnel token is deliberately never in this list
# (see CF_TOKEN_FILE, Section 19b) — config.env is not the secret store.
CONFIG_KEYS="VM_RAM_GB VM_CPU VM_DISK_GB VM_USER HOST_SSH_PORT SANDBOX_RAM_GB SANDBOX_CPU AUTH_MODE REMOTE_ACCESS_PROVIDER CLOUDFLARE_SSH_HOST CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TUNNEL_ID"

SUDO_CMD=""
[ "$(id -u)" -ne 0 ] && SUDO_CMD="sudo"

# ==========================================================
# Section 1: Logging helpers (+ simple size-based rotation)
# ==========================================================
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

rotate_log_if_needed() {
    # Rotates $1 -> $1.1 -> $1.2 ... up to LOG_ROTATIONS, when $1 has
    # grown past LOG_MAX_SIZE. Never touches a file below the threshold.
    local f="$1" n="$LOG_ROTATIONS" sz i
    [ -f "$f" ] || return 0
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    [ "${sz:-0}" -ge "$LOG_MAX_SIZE" ] || return 0
    for (( i = n; i >= 2; i-- )); do
        [ -f "${f}.$((i-1))" ] && mv -f "${f}.$((i-1))" "${f}.${i}" 2>/dev/null
    done
    mv -f "$f" "${f}.1" 2>/dev/null
    : > "$f" 2>/dev/null
    return 0
}

log_line() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    rotate_log_if_needed "$DAEMON_LOG" 2>/dev/null || true
    printf '[%s] %s\n' "$(_ts)" "$1" >> "$DAEMON_LOG" 2>/dev/null || true
}

info()  { printf "%b\n" "${CYAN}[i]${NC} $1"; log_line "INFO  $1"; }
ok()    { printf "%b\n" "${GREEN}[OK]${NC} $1"; log_line "OK    $1"; }
warn()  { printf "%b\n" "${YELLOW}[!]${NC} $1"; log_line "WARN  $1"; }
err()   { printf "%b\n" "${RED}[ERROR]${NC} $1" >&2; log_line "ERROR $1"; }
die()   { err "$1"; exit 1; }

trap 'err "Unexpected failure at line $LINENO (command: $BASH_COMMAND)"; exit 1' ERR

pause() { printf "%b" "\n${WHITE}Press Enter to continue...${NC}"; read -r _; }

# ==========================================================
# Section 2: Config load/save (secure parser — P0-2)
# ==========================================================
# config.env is data, never shell. It is parsed line-by-line against a
# strict KEY=VALUE pattern and a fixed whitelist of keys — it is never
# `source`d, so a corrupted or hostile config.env cannot execute code.
ensure_dirs() {
    $SUDO_CMD mkdir -p "$BASE_DIR" "$LOG_DIR" "$SSH_DIR"
    # Own the working dir as the current user, not root, so later steps
    # (writing config/seed/pid files) never need sudo and never end up
    # with root-owned files a non-root menu run can't touch.
    $SUDO_CMD chown -R "$(id -u):$(id -g)" "$BASE_DIR" 2>/dev/null || true
    chmod 750 "$BASE_DIR"
    chmod 700 "$SSH_DIR"
}

validate_config() {
    # Clamps/repairs any bad value instead of trusting it. Returns 0 if
    # everything was already valid, 1 if something had to be corrected.
    local bad=0
    if ! [[ "$VM_RAM_GB" =~ ^[0-9]+$ ]] || [ "$VM_RAM_GB" -lt 1 ] || [ "$VM_RAM_GB" -gt 256 ]; then
        warn "Invalid VM_RAM_GB '${VM_RAM_GB}' — resetting to default (4)."; VM_RAM_GB=4; bad=1
    fi
    if ! [[ "$VM_CPU" =~ ^[0-9]+$ ]] || [ "$VM_CPU" -lt 1 ] || [ "$VM_CPU" -gt 64 ]; then
        warn "Invalid VM_CPU '${VM_CPU}' — resetting to default (2)."; VM_CPU=2; bad=1
    fi
    if ! [[ "$VM_DISK_GB" =~ ^[0-9]+$ ]] || [ "$VM_DISK_GB" -lt 8 ] || [ "$VM_DISK_GB" -gt 2000 ]; then
        warn "Invalid VM_DISK_GB '${VM_DISK_GB}' — resetting to default (15)."; VM_DISK_GB=15; bad=1
    fi
    if ! [[ "$HOST_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$HOST_SSH_PORT" -lt 1024 ] || [ "$HOST_SSH_PORT" -gt 65535 ]; then
        warn "Invalid HOST_SSH_PORT '${HOST_SSH_PORT}' — resetting to default (2222)."; HOST_SSH_PORT=2222; bad=1
    fi
    if ! [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$VM_USER" = "root" ]; then
        warn "Invalid VM_USER '${VM_USER}' — resetting to default (ubuntu)."; VM_USER="ubuntu"; bad=1
    fi
    case "$AUTH_MODE" in
        key|password) ;;
        *) warn "Invalid AUTH_MODE '${AUTH_MODE}' — resetting to default (key)."; AUTH_MODE="key"; bad=1 ;;
    esac
    if ! [[ "$SANDBOX_RAM_GB" =~ ^[0-9]+$ ]]; then
        warn "Invalid SANDBOX_RAM_GB '${SANDBOX_RAM_GB}' — resetting to 0 (unset)."; SANDBOX_RAM_GB=0; bad=1
    fi
    if ! [[ "$SANDBOX_CPU" =~ ^[0-9]+$ ]]; then
        warn "Invalid SANDBOX_CPU '${SANDBOX_CPU}' — resetting to 0 (unset)."; SANDBOX_CPU=0; bad=1
    fi
    case "$REMOTE_ACCESS_PROVIDER" in
        ""|cloudflare) ;;
        *) warn "Invalid REMOTE_ACCESS_PROVIDER '${REMOTE_ACCESS_PROVIDER}' — resetting to unset."; REMOTE_ACCESS_PROVIDER=""; bad=1 ;;
    esac
    # Loose hostname syntax check only (labels, dots, hyphens) — this is
    # display/config validation, not DNS resolution or reachability.
    if [ -n "$CLOUDFLARE_SSH_HOST" ] && ! [[ "$CLOUDFLARE_SSH_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$ ]]; then
        warn "Invalid CLOUDFLARE_SSH_HOST '${CLOUDFLARE_SSH_HOST}' — clearing it. Re-run Setup."; CLOUDFLARE_SSH_HOST=""; bad=1
    fi
    if [ -n "$CLOUDFLARE_ACCOUNT_ID" ] && ! [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[A-Za-z0-9]{16,40}$ ]]; then
        warn "Invalid CLOUDFLARE_ACCOUNT_ID — clearing it."; CLOUDFLARE_ACCOUNT_ID=""; bad=1
    fi
    if [ -n "$CLOUDFLARE_TUNNEL_ID" ] && ! [[ "$CLOUDFLARE_TUNNEL_ID" =~ ^[A-Za-z0-9-]{16,40}$ ]]; then
        warn "Invalid CLOUDFLARE_TUNNEL_ID — clearing it."; CLOUDFLARE_TUNNEL_ID=""; bad=1
    fi
    return $bad
}

load_config() {
    [ -f "$CONFIG_FILE" ] || { validate_config || true; return 0; }
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*#.*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            case " $CONFIG_KEYS " in
                *" $key "*)
                    case "$key" in
                        VM_RAM_GB)      VM_RAM_GB="$value" ;;
                        VM_CPU)         VM_CPU="$value" ;;
                        VM_DISK_GB)     VM_DISK_GB="$value" ;;
                        VM_USER)        VM_USER="$value" ;;
                        HOST_SSH_PORT)  HOST_SSH_PORT="$value" ;;
                        SANDBOX_RAM_GB) SANDBOX_RAM_GB="$value" ;;
                        SANDBOX_CPU)    SANDBOX_CPU="$value" ;;
                        AUTH_MODE)      AUTH_MODE="$value" ;;
                        REMOTE_ACCESS_PROVIDER) REMOTE_ACCESS_PROVIDER="$value" ;;
                        CLOUDFLARE_SSH_HOST)    CLOUDFLARE_SSH_HOST="$value" ;;
                        CLOUDFLARE_ACCOUNT_ID)  CLOUDFLARE_ACCOUNT_ID="$value" ;;
                        CLOUDFLARE_TUNNEL_ID)   CLOUDFLARE_TUNNEL_ID="$value" ;;
                    esac ;;
                *) warn "Unknown configuration key in ${CONFIG_FILE}: '${key}' (ignored)." ;;
            esac
        else
            warn "Ignoring malformed line in ${CONFIG_FILE}: ${line}"
        fi
    done < "$CONFIG_FILE"
    validate_config || true
}

save_config() {
    umask 077
    cat > "$CONFIG_FILE" <<EOF
VM_RAM_GB=${VM_RAM_GB}
VM_CPU=${VM_CPU}
VM_DISK_GB=${VM_DISK_GB}
VM_USER=${VM_USER}
HOST_SSH_PORT=${HOST_SSH_PORT}
SANDBOX_RAM_GB=${SANDBOX_RAM_GB}
SANDBOX_CPU=${SANDBOX_CPU}
AUTH_MODE=${AUTH_MODE}
REMOTE_ACCESS_PROVIDER=${REMOTE_ACCESS_PROVIDER}
CLOUDFLARE_SSH_HOST=${CLOUDFLARE_SSH_HOST}
CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID}
CLOUDFLARE_TUNNEL_ID=${CLOUDFLARE_TUNNEL_ID}
EOF
    chmod 600 "$CONFIG_FILE"
}

# ==========================================================
# Section 3: Dependency installation (visible, checked, idempotent)
# ==========================================================
install_dependencies() {
    # P1-2: ssh/ssh-keygen are real requirements (Enter VPS, diagnostics,
    # known_hosts management) and are now checked like everything else.
    local need=()
    for c in qemu-system-x86_64 qemu-img cloud-localds wget curl socat ss ssh ssh-keygen; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    if [ ${#need[@]} -eq 0 ]; then
        ok "All required tools already present."
        return 0
    fi

    info "Missing tools: ${need[*]} — installing via apt (output shown, not hidden)."
    if ! $SUDO_CMD apt-get update -y; then
        die "apt-get update failed. Check network/DNS in this sandbox and re-run."
    fi
    if ! $SUDO_CMD apt-get install -y qemu-system-x86 qemu-utils wget curl \
        cloud-image-utils socat iproute2 openssh-client; then
        die "apt-get install failed. See the apt output above for the real error."
    fi

    for c in qemu-system-x86_64 qemu-img cloud-localds ssh ssh-keygen; do
        command -v "$c" >/dev/null 2>&1 || die "Dependency '$c' still missing after install — aborting."
    done
    ok "Dependencies installed and verified (including OpenSSH client)."
}

# ==========================================================
# Section 4: Base image download + integrity check (once)
# ==========================================================
download_base_image() {
    if [ -f "$IMAGE_PATH" ]; then
        ok "Base image already present at $IMAGE_PATH — not re-downloading."
        return 0
    fi

    info "Downloading Ubuntu 22.04 cloud image (one-time)..."
    local tmp="${IMAGE_PATH}.part"
    if ! wget -q --show-progress "$IMAGE_URL_DEFAULT" -O "$tmp"; then
        rm -f "$tmp"
        die "Download failed. Check network access for this sandbox."
    fi

    # Best-effort integrity check against Canonical's published checksums.
    # Note: 'current' is a moving pointer, so this verifies the download
    # wasn't corrupted in transit, not a pinned historical version. For
    # true reproducibility, snapshot the sandbox once the VM is set up
    # (see README) instead of re-downloading 'current' later.
    local sums_file
    sums_file=$(mktemp)
    if curl -fsSL "$IMAGE_SHA_URL_DEFAULT" -o "$sums_file" 2>/dev/null; then
        # Single awk per lookup (no grep|awk|head chain): awk's own exit
        # status is 0 whether or not a line matched, so this can never
        # trip `set -e`/pipefail the way a `grep | head` chain could
        # when grep finds zero matches (grep exits 1 on no match).
        local expected="" actual=""
        expected=$(awk '/jammy-server-cloudimg-amd64\.img$/{print $1; exit}' "$sums_file" 2>/dev/null) || expected=""
        actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1; exit}') || actual=""
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            rm -f "$tmp" "$sums_file"
            die "Checksum mismatch on downloaded image — refusing to use a corrupted/tampered file."
        fi
        ok "Image checksum verified against Canonical's SHA256SUMS."
    else
        warn "Could not fetch SHA256SUMS to verify the download; continuing without checksum verification."
    fi
    rm -f "$sums_file"

    mv "$tmp" "$IMAGE_PATH"
    chmod 600 "$IMAGE_PATH"
    ok "Base image ready at $IMAGE_PATH."
}

# ==========================================================
# Section 5: SSH keys, dedicated known_hosts, cloud-init
# ==========================================================
ensure_ssh_key() {
    if [ -f "${SSH_KEY}" ] && [ -f "${SSH_KEY}.pub" ]; then
        return 0
    fi
    info "Generating a dedicated SSH keypair for this VM..."
    ssh-keygen -t ed25519 -N "" -C "dxnest" -f "$SSH_KEY" -q
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    ok "SSH keypair created: ${SSH_KEY}(.pub)"
}

ensure_known_hosts() {
    # P1-1: DX-NEST never touches the user's own ~/.ssh/known_hosts.
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    [ -f "$KNOWN_HOSTS" ] || : > "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"
}

forget_known_host() {
    # Only ever called from an already-confirmed, explicit destructive
    # action (Full Reset). We only remove OUR entry, never touch the
    # user's system known_hosts.
    [ -f "$KNOWN_HOSTS" ] || return 0
    ssh-keygen -f "$KNOWN_HOSTS" -R "[127.0.0.1]:${HOST_SSH_PORT}" >/dev/null 2>&1 || true
}

# Builds the -o option array for every ssh invocation in this script.
# Re-run before each use since HOST_SSH_PORT/VM_USER can change at runtime.
ssh_opts() {
    SSH_BASE_OPTS=(
        -o UserKnownHostsFile="$KNOWN_HOSTS"
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=5
        -o IdentitiesOnly=yes
        -i "$SSH_KEY"
        -p "$HOST_SSH_PORT"
    )
}

build_cloud_init() {
    local pubkey
    pubkey=$(cat "${SSH_KEY}.pub")

    {
        echo "#cloud-config"
        echo "hostname: dxnest-vm"
        echo "users:"
        echo "  - name: ${VM_USER}"
        echo "    groups: sudo"
        echo "    shell: /bin/bash"
        echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
        echo "    lock_passwd: $( [ "$AUTH_MODE" = "password" ] && echo false || echo true )"
        echo "    ssh_authorized_keys:"
        echo "      - ${pubkey}"
        if [ "$AUTH_MODE" = "password" ] && [ -n "$VM_PASSWORD" ]; then
            echo "chpasswd:"
            echo "  list: |"
            echo "    ${VM_USER}:${VM_PASSWORD}"
            echo "  expire: False"
            echo "ssh_pwauth: true"
        else
            echo "ssh_pwauth: false"
        fi
        echo "package_update: false"
        echo "runcmd:"
        echo "  - [ systemctl, enable, --now, ssh ]"
    } > "$USER_DATA_FILE"

    # Stable instance-id so we don't accidentally trigger a full
    # cloud-init re-run (and possibly a fresh password/key set) on a
    # VM that has already been customized by the person logging in.
    if [ ! -f "$META_DATA_FILE" ]; then
        echo "instance-id: dxnest-$(date +%s)" > "$META_DATA_FILE"
        echo "local-hostname: dxnest-vm" >> "$META_DATA_FILE"
    fi

    if ! cloud-localds "$SEED_IMG" "$USER_DATA_FILE" "$META_DATA_FILE"; then
        die "cloud-localds failed to build seed.img — check the output above."
    fi
    chmod 600 "$SEED_IMG"
    ok "Cloud-init seed built."
}

# ==========================================================
# Section 5b: Disk size helpers + marker reconciliation (P1-3)
# ==========================================================
get_actual_disk_gb() {
    # Informational-only: qemu-img can legitimately fail here (e.g. the
    # image is currently locked by a running QEMU process). A single
    # awk with its own `exit` avoids the old `grep|grep|head` chain
    # (grep exits 1 on no match, which under pipefail used to make this
    # whole bare assignment trip `set -e` and kill the caller). The
    # trailing `|| bytes=""` is a second layer of defense in case
    # qemu-img itself is the one that fails.
    [ -f "$IMAGE_PATH" ] || { echo ""; return 0; }
    local bytes=""
    bytes=$(qemu-img info --output=json "$IMAGE_PATH" 2>/dev/null | awk '
        /"virtual-size"/ { match($0, /[0-9]+/); if (RSTART) { print substr($0, RSTART, RLENGTH); exit } }
    ' 2>/dev/null) || bytes=""
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo $(( bytes / 1024 / 1024 / 1024 ))
    else
        echo ""
    fi
}

get_disk_size_display() {
    # Human-readable disk size for Status. NEVER lets a qemu-img failure
    # (image locked by a running VM, transient error, etc.) propagate as
    # a fatal error — this is display-only information.
    [ -f "$IMAGE_PATH" ] || { echo "not created yet"; return 0; }
    local sz=""
    sz=$(qemu-img info "$IMAGE_PATH" 2>/dev/null | awk -F': ' '/virtual size/{print $2; exit}') || sz=""
    if [ -n "$sz" ]; then
        printf '%s' "$sz"
    else
        printf '%s' "UNKNOWN"
        log_line "WARN  Unable to read qcow2 virtual size (qemu-img info failed or image is locked)."
    fi
}

reconcile_disk_marker() {
    # Compares the marker file against the qcow2's ACTUAL virtual size.
    # Never resizes or deletes anything here — only reports/repairs the
    # bookkeeping marker itself. Purely informational: any failure here
    # must never take down the caller (status_vm in particular).
    [ -f "$IMAGE_PATH" ] || return 0
    local actual_gb="" marker_gb=""
    actual_gb=$(get_actual_disk_gb) || actual_gb=""
    [ -n "$actual_gb" ] || return 0

    if [ ! -f "$DISK_MARKER" ]; then
        echo "$actual_gb" > "$DISK_MARKER"
        info "Disk marker was missing — recorded actual size (${actual_gb}G)."
        return 0
    fi

    marker_gb=$(cat "$DISK_MARKER" 2>/dev/null || echo 0)
    if [ "$marker_gb" = "$actual_gb" ]; then
        return 0
    elif [ "$actual_gb" -gt "$marker_gb" ]; then
        info "Disk is larger (${actual_gb}G) than the recorded marker (${marker_gb}G) — updating marker."
        echo "$actual_gb" > "$DISK_MARKER"
    else
        warn "Disk size (${actual_gb}G) is SMALLER than the recorded marker (${marker_gb}G)."
        warn "This is unexpected. The marker was NOT changed and the disk was NOT touched — investigate manually."
    fi
}

# ==========================================================
# Section 6: One-time VM creation (disk sizing happens ONCE)
# ==========================================================
create_vm_if_needed() {
    ensure_dirs
    install_dependencies
    download_base_image
    ensure_ssh_key
    ensure_known_hosts

    if [ ! -f "$SEED_IMG" ]; then
        build_cloud_init
    fi

    if [ ! -f "$DISK_MARKER" ]; then
        local actual_gb=""
        actual_gb=$(get_actual_disk_gb) || actual_gb=""
        if [ -n "$actual_gb" ] && [ "$actual_gb" -ge "$VM_DISK_GB" ]; then
            info "Disk marker missing but image is already ${actual_gb}G (>= configured ${VM_DISK_GB}G)."
            info "Recording actual size, not resizing."
            echo "$actual_gb" > "$DISK_MARKER"
        else
            info "Resizing disk to ${VM_DISK_GB}G (one-time, at creation only)..."
            if ! qemu-img resize "$IMAGE_PATH" "${VM_DISK_GB}G"; then
                die "qemu-img resize failed."
            fi
            echo "$VM_DISK_GB" > "$DISK_MARKER"
            ok "Disk sized to ${VM_DISK_GB}G. This will never repeat automatically."
        fi
    else
        reconcile_disk_marker || true
        local sized=""; sized=$(cat "$DISK_MARKER" 2>/dev/null) || sized="?"
        info "Disk already sized to ${sized}G at creation. Use 'VPS Config -> Grow disk' to change it."
    fi

    save_config
}

# ==========================================================
# Section 7: Resource safety (Sandbox config + real host/cgroup)
# ==========================================================
detect_host_resources() {
    local mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    HOST_RAM_GB=$(( ${mem_kb:-0} / 1024 / 1024 ))
    HOST_CPU=$(nproc 2>/dev/null || echo 0)
}

sandbox_ram_display() { [ "$SANDBOX_RAM_GB" = "0" ] && echo "UNKNOWN" || echo "${SANDBOX_RAM_GB}G"; }
sandbox_cpu_display() { [ "$SANDBOX_CPU" = "0" ] && echo "UNKNOWN" || echo "${SANDBOX_CPU} vCPU"; }

check_resource_safety() {
    local safe=0
    if [ "$SANDBOX_RAM_GB" = "0" ] && [ "$SANDBOX_CPU" = "0" ]; then
        info "Sandbox resource limits could not be detected automatically (not set in VPS Config)."
        warn "Resource safety check against the Sandbox itself is informational only until you set them."
    fi
    detect_host_resources
    if [ "${HOST_RAM_GB:-0}" -gt 0 ] && [ "$VM_RAM_GB" -ge "$HOST_RAM_GB" ]; then
        warn "VM RAM (${VM_RAM_GB}G) is >= this Sandbox's total detected RAM (${HOST_RAM_GB}G). The host will be starved."
        safe=1
    fi
    if [ "${HOST_CPU:-0}" -gt 0 ] && [ "$VM_CPU" -ge "$HOST_CPU" ]; then
        warn "VM vCPU (${VM_CPU}) is >= this Sandbox's total detected vCPU (${HOST_CPU}). The host will be starved."
        safe=1
    fi
    if [ "$SANDBOX_RAM_GB" != "0" ] && [ "$VM_RAM_GB" -ge "$SANDBOX_RAM_GB" ]; then
        warn "VM RAM (${VM_RAM_GB}G) leaves no headroom out of the configured Sandbox RAM (${SANDBOX_RAM_GB}G)."
        safe=1
    fi
    if [ "$SANDBOX_CPU" != "0" ] && [ "$VM_CPU" -ge "$SANDBOX_CPU" ]; then
        warn "VM vCPU (${VM_CPU}) leaves no headroom out of the configured Sandbox vCPU (${SANDBOX_CPU})."
        safe=1
    fi
    return $safe
}

# ==========================================================
# Section 7b: KVM / TCG acceleration detection (P0-4)
# ==========================================================
probe_kvm() {
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "KVM"
    else
        echo "TCG"
    fi
}

compute_accel() {
    ACCEL_LABEL=$(probe_kvm)
    if [ "$ACCEL_LABEL" = "KVM" ]; then
        ACCEL_STRING="kvm:tcg"
    else
        ACCEL_STRING="tcg"
        warn "/dev/kvm is unavailable — falling back to TCG (software emulation, slower boot/runtime)."
    fi
}

# ==========================================================
# Section 8: Process / state detection (idempotency core)
# ==========================================================
is_vm_running() {
    # Cross-cutting #2: PID reuse safety. We never trust a bare PID —
    # we check /proc/<pid>/cmdline for our exact QEMU binary AND our
    # exact image path together, and cross-check /proc/<pid>/exe when
    # it is readable, before calling anything "running".
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1

    local cmdline=""
    if [ -r "/proc/$pid/cmdline" ]; then
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    fi
    if [ -z "$cmdline" ]; then
        cmdline=$(ps -p "$pid" -o cmd= 2>/dev/null || true)
    fi
    [ -n "$cmdline" ] || return 1

    case "$cmdline" in
        *qemu-system-x86_64*"$IMAGE_PATH"*) ;;
        *) return 1 ;;
    esac

    if [ -r "/proc/$pid/exe" ]; then
        local exe
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        if [ -n "$exe" ]; then
            case "$exe" in
                *qemu-system-x86_64*) ;;
                *) return 1 ;;
            esac
        fi
    fi
    return 0
}

port_open() {
    local port="$1"
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

ssh_ready() {
    port_open "$HOST_SSH_PORT" || return 1
    local banner
    banner=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${HOST_SSH_PORT}; head -c 4 <&3" 2>/dev/null || true)
    [ "$banner" = "SSH-" ]
}

ssh_auth_ok() {
    ssh_opts
    ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" true >/dev/null 2>&1
}

wait_for_ssh_auth() {
    local timeout="${1:-60}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        ssh_auth_ok && return 0
        sleep 3; waited=$((waited+3))
        printf "%b" "${CYAN}.${NC}"
    done
    echo ""
    return 1
}

# ==========================================================
# Section 8b: Connectivity diagnostics (used by restart/enter/network)
# ==========================================================
diagnose_vm_connectivity() {
    echo -e "${WHITE}Diagnostics:${NC}"
    local pid_display="none"
    [ -f "$PID_FILE" ] && pid_display=$(cat "$PID_FILE" 2>/dev/null || echo "unreadable")

    if is_vm_running; then
        printf "%b\n" "  QEMU         : ${GREEN}RUNNING${NC} (PID ${pid_display}, identity verified)"
    elif [ "$pid_display" != "none" ]; then
        printf "%b\n" "  QEMU         : ${RED}NOT RUNNING${NC} (stale PID file: ${pid_display})"
    else
        printf "%b\n" "  QEMU         : ${RED}NOT RUNNING${NC}"
    fi

    if port_open "$HOST_SSH_PORT"; then
        printf "%b\n" "  SSH Port     : ${GREEN}LISTENING${NC} (127.0.0.1:${HOST_SSH_PORT})"
    else
        printf "%b\n" "  SSH Port     : ${RED}NOT LISTENING${NC}"
    fi

    if ssh_ready; then
        printf "%b\n" "  SSH Banner   : ${GREEN}OK${NC}"
    else
        printf "%b\n" "  SSH Banner   : ${RED}NO BANNER${NC}"
    fi

    ssh_opts
    local out="" rc=0
    if out=$(ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" true 2>&1); then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        printf "%b\n" "  SSH Auth     : ${GREEN}OK${NC}"
    else
        local reason="unknown (exit ${rc})"
        case "$out" in
            *"Connection refused"*) reason="connection refused (SSH not up yet)" ;;
            *"Connection timed out"*|*"No route to host"*) reason="connection timeout / unreachable" ;;
            *"Permission denied"*) reason="authentication failed (wrong key or guest user not ready yet)" ;;
            *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
                reason="host key changed — the VM appears to have been reset/rebuilt. Use Maintenance to confirm and clear the old DX-NEST known_hosts entry." ;;
            *"Host key verification failed"*) reason="host key verification failed" ;;
        esac
        printf "%b\n" "  SSH Auth     : ${RED}FAILED${NC} — ${reason}"
    fi
    echo ""
}

# ==========================================================
# Section 9: Start / Stop / Restart
#   *_impl functions do the real work and take NO lock.
#   Public wrappers take the lock exactly once. restart_vm
#   also takes the lock exactly once and calls both impls,
#   so there is never nested flock() in the same process.
# ==========================================================
_start_vm_impl() {
    create_vm_if_needed

    if is_vm_running; then
        ok "VM is already running (PID $(cat "$PID_FILE")). Nothing to do."
        return 0
    fi

    # Stale pid file / leftover sockets from a previous unclean stop.
    rm -f "$PID_FILE" "$MONITOR_SOCK" "$CONSOLE_SOCK"

    if port_open "$HOST_SSH_PORT"; then
        err "Host port ${HOST_SSH_PORT} is already in use by something else. Change it in VPS Config."
        return 1
    fi

    check_resource_safety || warn "Continuing anyway since these are configured values, but consider lowering VM_RAM_GB/VM_CPU."

    compute_accel

    info "Starting VM (RAM=${VM_RAM_GB}G, CPU=${VM_CPU}, Accel=${ACCEL_LABEL}, SSH ${HOST_SSH_PORT}->22)..."
    mkdir -p "$LOG_DIR"
    rotate_log_if_needed "$BOOT_LOG"

    if ! qemu-system-x86_64 \
        -name dxnest-vm \
        -machine accel="${ACCEL_STRING}" \
        -m "${VM_RAM_GB}G" \
        -smp "${VM_CPU}" \
        -hda "$IMAGE_PATH" \
        -drive file="$SEED_IMG",format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::${HOST_SSH_PORT}-:${GUEST_SSH_PORT} \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -chardev socket,id=char0,path="$CONSOLE_SOCK",server=on,wait=off \
        -serial chardev:char0 \
        -monitor unix:"$MONITOR_SOCK",server=on,wait=off \
        -daemonize \
        -pidfile "$PID_FILE" \
        >>"$BOOT_LOG" 2>&1
    then
        err "QEMU failed to launch. Last lines of ${BOOT_LOG}:"
        tail -n 30 "$BOOT_LOG" 2>/dev/null || true
        return 1
    fi

    sleep 1
    if ! is_vm_running; then
        err "QEMU did not stay up. Last lines of ${BOOT_LOG}:"
        tail -n 30 "$BOOT_LOG" 2>/dev/null || true
        return 1
    fi

    echo "$ACCEL_LABEL" > "$ACCEL_MARKER" 2>/dev/null || true
    ok "QEMU launched in background (PID $(cat "$PID_FILE"), accel=${ACCEL_LABEL}). Logs: $BOOT_LOG"
    return 0
}

_stop_vm_impl() {
    if ! is_vm_running; then
        ok "VM is already stopped."
        rm -f "$PID_FILE" "$MONITOR_SOCK" "$CONSOLE_SOCK"
        return 0
    fi

    local pid=""
    pid=$(cat "$PID_FILE" 2>/dev/null) || pid=""
    if [ -z "$pid" ]; then
        err "PID file vanished between the running-check and reading it. Treating VM as already stopped."
        rm -f "$PID_FILE" "$MONITOR_SOCK" "$CONSOLE_SOCK"
        return 0
    fi
    info "Sending graceful shutdown (ACPI powerdown) to PID $pid..."
    if [ -S "$MONITOR_SOCK" ] && command -v socat >/dev/null 2>&1; then
        echo "system_powerdown" | timeout 5 socat - UNIX-CONNECT:"$MONITOR_SOCK" >/dev/null 2>&1 || true
    fi

    local waited=0
    while is_vm_running && [ "$waited" -lt 60 ]; do
        sleep 2; waited=$((waited+2))
    done

    if is_vm_running; then
        warn "Guest did not shut down gracefully in time. Sending SIGTERM to PID $pid."
        ps -p "$pid" -o cmd= 2>/dev/null | grep -q "qemu-system-x86_64" && kill "$pid" 2>/dev/null || true
        waited=0
        while is_vm_running && [ "$waited" -lt 20 ]; do sleep 1; waited=$((waited+1)); done
    fi

    if is_vm_running; then
        warn "Still running. Sending SIGKILL to PID $pid as last resort."
        ps -p "$pid" -o cmd= 2>/dev/null | grep -q "qemu-system-x86_64" && kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    if is_vm_running; then
        err "VM did not stop even after SIGKILL. Manual intervention may be required."
        return 1
    fi

    rm -f "$PID_FILE" "$MONITOR_SOCK" "$CONSOLE_SOCK"
    ok "VM stopped. Disk image and seed were not touched."
    return 0
}

start_vm() {
    exec 9>"$LIFECYCLE_LOCK"
    if ! flock -n 9; then
        err "Another start/stop/restart operation is already in progress. Try again shortly."
        return 1
    fi
    local rc=0
    _start_vm_impl || rc=$?
    flock -u 9
    return $rc
}

stop_vm() {
    exec 9>"$LIFECYCLE_LOCK"
    if ! flock -n 9; then
        err "Another start/stop/restart operation is already in progress. Try again shortly."
        return 1
    fi
    local rc=0
    _stop_vm_impl || rc=$?
    flock -u 9
    return $rc
}

restart_vm() {
    # P0-1: full verified restart — stop, verify stopped, start, verify
    # running, wait for SSH, verify SSH auth. No fake success.
    echo -e "${WHITE}Restarting VPS...${NC}"
    exec 9>"$LIFECYCLE_LOCK"
    if ! flock -n 9; then
        err "Another start/stop/restart operation is already in progress. Try again shortly."
        return 1
    fi

    if is_vm_running; then
        info "Stopping current VM..."
        if ! _stop_vm_impl; then
            flock -u 9
            err "Could not stop the running VM cleanly. Aborting restart — VM left as-is."
            return 1
        fi
        if is_vm_running; then
            flock -u 9
            err "VM is still detected as running after stop. Aborting restart to avoid a duplicate QEMU."
            return 1
        fi
        ok "VPS stopped"
        ok "VPS process cleared"
    else
        info "VM was not running — proceeding straight to start."
    fi

    if ! _start_vm_impl; then
        flock -u 9
        err "VPS failed to start during restart."
        return 1
    fi
    if ! is_vm_running; then
        flock -u 9
        err "QEMU did not stay up after restart. Check ${BOOT_LOG}."
        return 1
    fi
    ok "VPS started"
    ok "QEMU running"
    flock -u 9

    if wait_for_ssh 90 && wait_for_ssh_auth 30; then
        ok "SSH ready"
        ok "VPS restart completed"
        return 0
    fi

    err "VPS started but SSH is not ready."
    echo "  PID       : $(cat "$PID_FILE" 2>/dev/null || echo unknown)"
    echo "  QEMU log  : $BOOT_LOG"
    diagnose_vm_connectivity
    return 1
}

# ==========================================================
# Section 10: Health check with a visible progress indicator
# ==========================================================
wait_for_ssh() {
    local timeout="${1:-90}" waited=0
    printf "%b" "${YELLOW}Waiting for SSH to come up (up to ${timeout}s)...${NC}\n"
    while [ "$waited" -lt "$timeout" ]; do
        if ssh_ready; then
            ok "SSH is ready on 127.0.0.1:${HOST_SSH_PORT}."
            return 0
        fi
        sleep 3; waited=$((waited+3))
        printf "%b" "${CYAN}.${NC}"
    done
    echo ""
    err "SSH did not become ready within ${timeout}s. Use 'Console / Logs' to see what the guest is doing."
    return 1
}

# ==========================================================
# Section 11: Status
# ==========================================================
status_vm() {
    # Status is informational only. Every value read here (PID, uptime,
    # disk size, accel marker) must degrade to "UNKNOWN"/"?" rather than
    # ever crash the whole menu — this function used to bare-assign
    # `uptime_s=$(ps ... | tr ...)` and `disk_sz=$(qemu-img info ... |
    # awk ... | head -n1)` directly. Under `set -Eeuo pipefail`, if
    # `ps`/`qemu-img` failed (e.g. the qcow2 is locked by the running
    # QEMU process — a real, observed failure), pipefail made the WHOLE
    # pipeline's exit status non-zero, and because these were bare
    # `var=$(...)` statements (not inside an if/while), that tripped
    # `set -e` and killed the entire interactive menu. Every such read
    # below now uses the `var=$(...) || var=default` idiom, which is
    # exempt from `set -e` (the failing command is not the last one in
    # the `||` list), so a display-only read can fail without taking
    # the manager down with it.
    echo ""
    if is_vm_running; then
        local pid="" uptime_s=""
        pid=$(cat "$PID_FILE" 2>/dev/null) || pid=""
        [ -z "$pid" ] && pid="?"
        uptime_s=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || uptime_s=""
        printf "%b\n" "  VM Status : ${GREEN}RUNNING${NC}"
        printf "%b\n" "  PID       : ${pid}"
        [ -n "$uptime_s" ] && printf "%b\n" "  Uptime    : ${uptime_s}s"
        if ssh_ready; then
            printf "%b\n" "  SSH       : ${GREEN}READY${NC}"
        else
            printf "%b\n" "  SSH       : ${YELLOW}NOT READY YET${NC}"
        fi
        printf "%b\n" "  SSH Port  : 127.0.0.1:${HOST_SSH_PORT} -> guest:22"
        if [ -f "$ACCEL_MARKER" ]; then
            local accel=""; accel=$(cat "$ACCEL_MARKER" 2>/dev/null) || accel="UNKNOWN"
            [ -z "$accel" ] && accel="UNKNOWN"
            printf "%b\n" "  Accel     : ${CYAN}${accel} (active)${NC}"
        else
            printf "%b\n" "  Accel     : ${CYAN}UNKNOWN${NC}"
        fi
    else
        printf "%b\n" "  VM Status : ${RED}STOPPED${NC}"
        printf "%b\n" "  SSH Port  : 127.0.0.1:${HOST_SSH_PORT} -> guest:22 (not listening)"
        printf "%b\n" "  Accel     : ${CYAN}$(probe_kvm) available (not running)${NC}"
    fi
    printf "%b\n" "  RAM / CPU : ${VM_RAM_GB}G / ${VM_CPU} vCPU"
    printf "%b\n" "  Sandbox   : $(sandbox_ram_display) / $(sandbox_cpu_display)"
    if [ -f "$IMAGE_PATH" ]; then
        printf "%b\n" "  Disk      : $(get_disk_size_display)"
        reconcile_disk_marker || true
    else
        printf "%b\n" "  Disk      : ${RED}not created yet${NC}"
    fi
    echo ""
}

# ==========================================================
# Section 12: Enter VPS — smart, one-key path with recovery menu (P0-3)
# ==========================================================
enter_vps() {
    if ! is_vm_running; then
        info "VM is not running — starting it first..."
        if ! start_vm; then
            err "Could not start the VM."
            return 1
        fi
    fi

    local attempt=0 max_attempts=3
    while true; do
        attempt=$((attempt+1))

        if ! ssh_ready; then
            info "Waiting for SSH (attempt ${attempt}/${max_attempts})..."
            wait_for_ssh 60 || true
        fi

        if ssh_ready; then
            ssh_opts
            info "Connecting via SSH..."
            ssh "${SSH_BASE_OPTS[@]}" "${VM_USER}@127.0.0.1" || true
            return 0
        fi

        err "SSH connection attempt ${attempt}/${max_attempts} failed."
        diagnose_vm_connectivity

        if [ "$attempt" -ge "$max_attempts" ] || [ ! -t 0 ]; then
            err "Giving up after ${attempt} attempt(s). Use 'Console / Logs' or 'SSH / Network' for manual diagnosis."
            return 1
        fi

        echo -e "  ${BLUE}1${NC}  Retry SSH"
        echo -e "  ${BLUE}2${NC}  Show VPS Status"
        echo -e "  ${BLUE}3${NC}  Show QEMU Logs"
        echo -e "  ${BLUE}4${NC}  Show Console"
        echo -e "  ${BLUE}5${NC}  Restart VPS"
        echo -e "  ${BLUE}6${NC}  Return"
        printf "%b" "${YELLOW}> ${NC}"
        read -r rc_choice
        case "$rc_choice" in
            1) : ;;
            2) status_vm; pause; attempt=$((attempt-1)) ;;
            3) tail -n 60 "$BOOT_LOG" 2>/dev/null || echo "(no boot log yet)"; pause; attempt=$((attempt-1)) ;;
            4)
                if [ -S "$CONSOLE_SOCK" ]; then
                    info "Attaching to console. Ctrl+C detaches — it does not stop the VM."
                    socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:${CONSOLE_SOCK}" || true
                else
                    warn "No console socket available."
                fi
                attempt=$((attempt-1)) ;;
            5) restart_vm || true; attempt=0 ;;
            6) return 1 ;;
            *) warn "Invalid choice."; attempt=$((attempt-1)) ;;
        esac
    done
}

# ==========================================================
# Section 13: Console / Logs
# ==========================================================
console_menu() {
    while true; do
        clear
        print_header
        echo -e "${WHITE}Console / Logs${NC}"
        echo -e "  ${BLUE}1${NC}  Attach to serial console (Ctrl+] then 'q' + Enter via socat to detach)"
        echo -e "  ${BLUE}2${NC}  Tail boot log (${BOOT_LOG})"
        echo -e "  ${BLUE}3${NC}  Tail manager log (${DAEMON_LOG})"
        echo -e "  ${BLUE}0${NC}  Back"
        printf "%b" "${YELLOW}> ${NC}"
        read -r c
        case "$c" in
            1)
                if [ ! -S "$CONSOLE_SOCK" ]; then
                    warn "VM is not running, no console socket available."
                else
                    info "Attaching to serial console. This is a read/write bridge to the guest's tty,"
                    info "detaching (Ctrl+C here) only closes the bridge — it never stops the VM."
                    socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:${CONSOLE_SOCK}" || true
                fi
                pause ;;
            2) tail -n 60 "$BOOT_LOG" 2>/dev/null || echo "(no boot log yet)"; pause ;;
            3) tail -n 60 "$DAEMON_LOG" 2>/dev/null || echo "(no log yet)"; pause ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 14: SSH & Network menu (+ real diagnostics, P1-4)
# ==========================================================
ssh_network_menu() {
    while true; do
        clear
        print_header
        echo -e "${WHITE}SSH & Network${NC}"
        echo -e "  Host port forward : ${CYAN}127.0.0.1:${HOST_SSH_PORT} -> guest:22${NC}"
        echo -e "  SSH key           : ${CYAN}${SSH_KEY}${NC}"
        echo -e "  known_hosts       : ${CYAN}${KNOWN_HOSTS}${NC} (dedicated to DX-NEST, not your ~/.ssh)"
        echo -e "  Connect manually  : ${CYAN}ssh -o UserKnownHostsFile=${KNOWN_HOSTS} -i ${SSH_KEY} -p ${HOST_SSH_PORT} ${VM_USER}@127.0.0.1${NC}"
        echo ""
        echo -e "${YELLOW}Note:${NC} this VM only has a NAT'd local port inside the Sandbox, not a"
        echo -e "public IP. For access to the Sandbox itself, use Daytona's own SSH Access"
        echo -e "token or Web Terminal (port 22222) — that layer is separate from this VM."
        echo ""
        echo -e "  ${BLUE}1${NC}  Change host SSH port (requires VM restart)"
        echo -e "  ${BLUE}2${NC}  Show/print the public key to copy elsewhere"
        echo -e "  ${BLUE}3${NC}  Test host port (Sandbox layer)"
        echo -e "  ${BLUE}4${NC}  Test guest SSH auth"
        echo -e "  ${BLUE}5${NC}  Test guest DNS"
        echo -e "  ${BLUE}6${NC}  Test guest Internet"
        echo -e "  ${BLUE}7${NC}  Full network diagnostic"
        echo -e "  ${BLUE}0${NC}  Back"
        printf "%b" "${YELLOW}> ${NC}"
        read -r c
        case "$c" in
            1)
                printf "%b" "New host port [current ${HOST_SSH_PORT}]: "
                read -r newport
                if [[ "$newport" =~ ^[0-9]+$ ]] && [ "$newport" -ge 1024 ] && [ "$newport" -le 65535 ]; then
                    HOST_SSH_PORT="$newport"; save_config
                    ok "Port updated to ${HOST_SSH_PORT}. Restart the VM for it to take effect."
                else
                    warn "Invalid port. Must be 1024-65535."
                fi
                pause ;;
            2) cat "${SSH_KEY}.pub" 2>/dev/null || warn "No key yet."; pause ;;
            3)
                if port_open "$HOST_SSH_PORT"; then
                    ok "Host port ${HOST_SSH_PORT} is listening on 127.0.0.1 (Sandbox layer)."
                else
                    err "Host port ${HOST_SSH_PORT} is NOT listening."
                fi
                pause ;;
            4)
                if ssh_auth_ok; then
                    ok "Guest SSH auth: OK."
                else
                    err "Guest SSH auth: FAILED. Run 'Full network diagnostic' for a breakdown."
                fi
                pause ;;
            5)
                ssh_opts
                local dns_out=""
                if dns_out=$(ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" \
                    "getent hosts archive.ubuntu.com" 2>&1); then
                    ok "Guest DNS: OK (${dns_out})"
                else
                    err "Guest DNS: FAILED — ${dns_out}"
                fi
                pause ;;
            6)
                ssh_opts
                if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" \
                    "curl -fsS --max-time 5 -o /dev/null https://archive.ubuntu.com" >/dev/null 2>&1; then
                    ok "Guest Internet (HTTPS): OK."
                else
                    err "Guest Internet (HTTPS): FAILED."
                fi
                pause ;;
            7)
                echo -e "${WHITE}Full Network Diagnostic${NC}"
                echo -e "${CYAN}-- Host / Sandbox layer --${NC}"
                if port_open "$HOST_SSH_PORT"; then echo -e "  Host port      : ${GREEN}PASS${NC}"; else echo -e "  Host port      : ${RED}FAIL${NC}"; fi
                if is_vm_running; then echo -e "  QEMU           : ${GREEN}PASS${NC}"; else echo -e "  QEMU           : ${RED}FAIL${NC}"; fi
                echo -e "${CYAN}-- Ubuntu Guest layer --${NC}"
                if ssh_auth_ok; then
                    echo -e "  Guest SSH      : ${GREEN}PASS${NC}"
                    ssh_opts
                    if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" \
                        "getent hosts archive.ubuntu.com" >/dev/null 2>&1; then
                        echo -e "  Guest DNS      : ${GREEN}PASS${NC}"
                    else
                        echo -e "  Guest DNS      : ${RED}FAIL${NC}"
                    fi
                    if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" \
                        "curl -fsS --max-time 5 -o /dev/null https://archive.ubuntu.com" >/dev/null 2>&1; then
                        echo -e "  Guest Internet : ${GREEN}PASS${NC}"
                    else
                        echo -e "  Guest Internet : ${RED}FAIL${NC}"
                    fi
                else
                    echo -e "  Guest SSH      : ${RED}FAIL${NC} (cannot test DNS/Internet without SSH)"
                    echo -e "  Guest DNS      : ${YELLOW}SKIPPED${NC}"
                    echo -e "  Guest Internet : ${YELLOW}SKIPPED${NC}"
                fi
                echo ""
                echo -e "${YELLOW}Note:${NC} guest DNS/Internet failures usually mean the Sandbox's own"
                echo -e "network (or a domain allow-list) is blocking it — not a QEMU/DX-NEST bug."
                pause ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 15: VPS Config menu (RAM/CPU/Disk/Auth/User — explicit & safe)
# ==========================================================
vps_config_menu() {
    while true; do
        clear
        print_header
        echo -e "${WHITE}VPS Configuration${NC}"
        echo -e "  VM RAM        : ${CYAN}${VM_RAM_GB}G${NC}"
        echo -e "  VM CPU        : ${CYAN}${VM_CPU}${NC}"
        echo -e "  Disk (created): ${CYAN}$( [ -f "$DISK_MARKER" ] && cat "$DISK_MARKER" || echo "not created yet" )G${NC}"
        echo -e "  VM_USER       : ${CYAN}${VM_USER}${NC}"
        echo -e "  AUTH_MODE     : ${CYAN}${AUTH_MODE}${NC}"
        echo -e "  Sandbox RAM   : ${CYAN}$(sandbox_ram_display)${NC}"
        echo -e "  Sandbox CPU   : ${CYAN}$(sandbox_cpu_display)${NC}"
        echo ""
        echo -e "  ${BLUE}1${NC}  Set Sandbox's own RAM/CPU (from the Daytona dashboard, for safety checks)"
        echo -e "  ${BLUE}2${NC}  Set VM RAM (requires restart)"
        echo -e "  ${BLUE}3${NC}  Set VM CPU (requires restart)"
        echo -e "  ${BLUE}4${NC}  Grow disk (one-way, only while VM is stopped)"
        echo -e "  ${BLUE}5${NC}  Change AUTH_MODE (key / password)"
        echo -e "  ${BLUE}6${NC}  Change VM_USER"
        echo -e "  ${BLUE}0${NC}  Back"
        printf "%b" "${YELLOW}> ${NC}"
        read -r c
        case "$c" in
            1)
                printf "%b" "Sandbox RAM in GB (see Daytona dashboard): "; read -r r
                printf "%b" "Sandbox vCPU count: "; read -r cpu
                [[ "$r" =~ ^[0-9]+$ ]] && SANDBOX_RAM_GB="$r"
                [[ "$cpu" =~ ^[0-9]+$ ]] && SANDBOX_CPU="$cpu"
                save_config; ok "Saved."; pause ;;
            2)
                printf "%b" "New VM RAM in GB: "; read -r r
                if [[ "$r" =~ ^[0-9]+$ ]]; then
                    VM_RAM_GB="$r"; save_config
                    check_resource_safety || warn "That leaves little/no headroom for the Sandbox host."
                    ok "Saved. Restart the VM to apply."
                else
                    warn "Invalid value."
                fi
                pause ;;
            3)
                printf "%b" "New VM CPU count: "; read -r c2
                if [[ "$c2" =~ ^[0-9]+$ ]]; then
                    VM_CPU="$c2"; save_config
                    check_resource_safety || warn "That leaves little/no headroom for the Sandbox host."
                    ok "Saved. Restart the VM to apply."
                else
                    warn "Invalid value."
                fi
                pause ;;
            4)
                if is_vm_running; then
                    warn "Stop the VM first (disk resize is unsafe on a running VM)."
                else
                    local current; current=$( [ -f "$DISK_MARKER" ] && cat "$DISK_MARKER" || echo 0 )
                    printf "%b" "New TOTAL disk size in GB (must be > ${current}): "; read -r nd
                    if [[ "$nd" =~ ^[0-9]+$ ]] && [ "$nd" -gt "$current" ]; then
                        if qemu-img resize "$IMAGE_PATH" "${nd}G"; then
                            echo "$nd" > "$DISK_MARKER"
                            ok "Disk grown to ${nd}G. Remember to grow the filesystem inside the guest too (growpart + resize2fs)."
                        else
                            err "Resize failed."
                        fi
                    else
                        warn "New size must be a number greater than the current size."
                    fi
                fi
                pause ;;
            5)
                echo "Current AUTH_MODE: ${AUTH_MODE}"
                echo "  1) key       — SSH key only (recommended)"
                echo "  2) password  — password login enabled"
                printf "%b" "Choose [1-2]: "; read -r am
                case "$am" in
                    1) AUTH_MODE="key"; VM_PASSWORD="" ;;
                    2)
                        AUTH_MODE="password"
                        printf "%b" "New VM password (input hidden): "
                        read -rs VM_PASSWORD; echo ""
                        VM_PASSWORD="${VM_PASSWORD//$'\n'/}"
                        if [ -z "$VM_PASSWORD" ]; then
                            warn "Empty password rejected. AUTH_MODE left at 'key'."
                            AUTH_MODE="key"
                        fi ;;
                    *) warn "Invalid choice."; pause; continue ;;
                esac
                save_config
                if [ -f "$SEED_IMG" ]; then
                    warn "A VPS already exists. This only affects a REBUILT cloud-init seed"
                    warn "(Maintenance -> Remove seed.img, then Start) — it does NOT change the"
                    warn "currently running/existing guest automatically."
                fi
                ok "AUTH_MODE set to ${AUTH_MODE}."
                pause ;;
            6)
                printf "%b" "New VM_USER [current ${VM_USER}]: "
                read -r nu
                if [[ "$nu" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$nu" != "root" ]; then
                    VM_USER="$nu"; save_config
                    if [ -f "$SEED_IMG" ]; then
                        warn "A VPS already exists. Changing VM_USER may require rebuilding/reconfiguring"
                        warn "the guest (Maintenance -> Remove seed.img, then Start) — the existing guest"
                        warn "is NOT modified automatically, and its login user does not change on its own."
                    fi
                    ok "VM_USER set to ${VM_USER}. Takes effect on the next cloud-init build."
                else
                    warn "Invalid username (Linux username rules, and not 'root')."
                fi
                pause ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 19b: Remote Access — Public SSH (via Cloudflare Tunnel)
#
# Independent module. Reads is_vm_running/port_open/ssh_ready from the
# QEMU core (read-only) but is NEVER read by it. If everything in this
# section were deleted, `start_vm`/`stop_vm`/`restart_vm`/`enter_vps`/
# `status_vm` would be completely unaffected — that is by design and is
# the acceptance bar for every function below.
#
# Process-management pattern deliberately mirrors _start_vm_impl /
# _stop_vm_impl / is_vm_running (identity-verified PID, no blind kill,
# own flock, own log with the same rotation helper) so this doesn't
# introduce a second set of habits into the same file.
# ==========================================================
ensure_remote_dirs() {
    mkdir -p "$REMOTE_DIR" 2>/dev/null || true
    chmod 700 "$REMOTE_DIR" 2>/dev/null || true
}

# Resolves the cloudflared binary. Prints its path and returns 0 if a
# working binary is on PATH; prints nothing and returns 1 otherwise.
# Never assumes a fixed install location.
cloudflared_bin() {
    local b=""
    b=$(command -v cloudflared 2>/dev/null) || return 1
    [ -n "$b" ] && [ -x "$b" ] || return 1
    printf '%s' "$b"
    return 0
}

cloudflared_version() {
    local b=""
    b=$(cloudflared_bin) || { echo "not installed"; return 1; }
    "$b" --version 2>/dev/null | head -n1 || echo "unknown"
}

# Installs cloudflared from Cloudflare's official APT repository (never
# curl|bash, never a third-party mirror). Idempotent: if a working
# binary is already present, this is a no-op — we never silently
# replace a functioning install. Fails safely: any failure here leaves
# the rest of DX-NEST (QEMU, config, everything) completely untouched.
install_cloudflared() {
    if cloudflared_bin >/dev/null 2>&1; then
        ok "cloudflared already installed ($(cloudflared_version))."
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        err "No apt-get on this system — cannot use Cloudflare's official package repository."
        err "Install cloudflared manually from https://pkg.cloudflare.com/ and re-run."
        return 1
    fi
    info "Installing cloudflared from Cloudflare's official APT repository..."
    $SUDO_CMD mkdir -p --mode=0755 /usr/share/keyrings 2>/dev/null || true
    if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | $SUDO_CMD tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null; then
        err "Could not fetch Cloudflare's package-signing key. Network/DNS issue in this sandbox?"
        return 1
    fi
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        | $SUDO_CMD tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    if ! $SUDO_CMD apt-get update -y; then
        err "apt-get update failed after adding the Cloudflare repository."
        return 1
    fi
    if ! $SUDO_CMD apt-get install -y cloudflared; then
        err "apt-get install cloudflared failed. See apt output above."
        return 1
    fi
    local b=""
    if ! b=$(cloudflared_bin); then
        err "cloudflared installed but is not runnable (not on PATH / not executable)."
        return 1
    fi
    if ! "$b" --version >/dev/null 2>&1; then
        err "cloudflared binary at ${b} does not respond to --version — refusing to trust this install."
        return 1
    fi
    ok "cloudflared installed and verified: $(cloudflared_version)"
    return 0
}

# ---- Cloudflare API helpers (setup/management only — never used by the
# ---- running cloudflared process itself; see CF_API_TOKEN_FILE comment) --
#
# Zero-dependency by design (no jq, matching the rest of this project):
# Cloudflare's API returns compact-ish JSON: we flatten newlines and pull
# a field with a targeted grep+cut. This is intentionally narrow — it only
# has to survive the handful of flat fields we actually read (id, token,
# success, a single error message), not arbitrary JSON.
_cf_json_field() {
    local json="$1" field="$2"
    printf '%s' "$json" | tr -d '\n' | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E 's/.*:[[:space:]]*"//; s/"$//'
}
_cf_json_bool() {
    local json="$1" field="$2"
    printf '%s' "$json" | tr -d '\n' | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*(true|false)" | head -n1 | grep -o 'true\|false'
}

# Thin wrapper around curl. Never echoes the Authorization header. Returns
# the response body on stdout; sets CF_API_HTTP_STATUS. Every caller must
# check CF_API_HTTP_STATUS/success itself — this never assumes 200 means
# the operation you wanted actually happened (Cloudflare returns 200 with
# "success":false for some validation failures).
CF_API_HTTP_STATUS=""
cf_api() {
    local method="$1" path="$2" body="${3:-}"
    local api_tok=""
    api_tok=$(cat "$CF_API_TOKEN_FILE" 2>/dev/null) || { err "No Cloudflare API token on file."; return 1; }
    [ -n "$api_tok" ] || { err "Cloudflare API token file is empty."; return 1; }

    local tmp_body="" http_code=""
    tmp_body=$(mktemp "${REMOTE_DIR}/.cfresp.XXXXXX" 2>/dev/null) || { err "Could not create temp file for API response."; return 1; }
    if [ -n "$body" ]; then
        http_code=$(curl -s -o "$tmp_body" -w '%{http_code}' -X "$method" \
            -H "Authorization: Bearer ${api_tok}" -H "Content-Type: application/json" \
            --data "$body" "https://api.cloudflare.com/client/v4${path}" 2>/dev/null) || http_code=""
    else
        http_code=$(curl -s -o "$tmp_body" -w '%{http_code}' -X "$method" \
            -H "Authorization: Bearer ${api_tok}" "https://api.cloudflare.com/client/v4${path}" 2>/dev/null) || http_code=""
    fi
    unset api_tok
    CF_API_HTTP_STATUS="$http_code"
    if [ -z "$http_code" ]; then
        err "Could not reach api.cloudflare.com (network unreachable in this sandbox?)."
        rm -f "$tmp_body"
        return 1
    fi
    cat "$tmp_body" 2>/dev/null
    rm -f "$tmp_body"
    return 0
}

# GET /accounts — if the token can see exactly one account, auto-select it
# (Section 8: don't ask for an Account ID unless we genuinely have to).
cf_discover_account() {
    local resp="" ok_flag=""
    resp=$(cf_api GET "/accounts") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" != "true" ]; then
        return 1
    fi
    local count=0 first_id=""
    # Flatten and pull every "id":"..." inside the result array. This is
    # deliberately naive (see _cf_json_field comment) — good enough to
    # count accounts and grab the first one.
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        count=$((count+1))
        [ -z "$first_id" ] && first_id="$id"
    done < <(printf '%s' "$resp" | tr -d '\n' | grep -o '"result"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"//; s/"$//')
    if [ "$count" -eq 1 ]; then
        CLOUDFLARE_ACCOUNT_ID="$first_id"
        return 0
    fi
    return 1
}

# Deterministic tunnel name so re-running Setup never creates
# dx-nest-ssh-1, dx-nest-ssh-2, ... (Section 25 — duplicate protection).
_cf_tunnel_name() { printf 'dx-nest-%s' "$CLOUDFLARE_SSH_HOST"; }

# Reuse the tunnel recorded in CLOUDFLARE_TUNNEL_ID if it still exists;
# otherwise look one up by our deterministic name; otherwise create it.
cf_find_or_create_tunnel() {
    local resp="" ok_flag=""
    if [ -n "$CLOUDFLARE_TUNNEL_ID" ]; then
        resp=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}") || true
        ok_flag=$(_cf_json_bool "$resp" "success")
        if [ "$ok_flag" = "true" ]; then
            local deleted=""
            deleted=$(_cf_json_field "$resp" "deleted_at")
            if [ -z "$deleted" ]; then
                info "Reusing existing tunnel ${CLOUDFLARE_TUNNEL_ID} (no duplicate created)."
                return 0
            fi
        fi
        warn "Previously recorded tunnel ${CLOUDFLARE_TUNNEL_ID} no longer exists — will look up/create by name."
        CLOUDFLARE_TUNNEL_ID=""
    fi

    local name=""; name=$(_cf_tunnel_name)
    resp=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${name}&is_deleted=false") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" = "true" ]; then
        local existing_id=""
        existing_id=$(_cf_json_field "$resp" "id")
        if [ -n "$existing_id" ]; then
            CLOUDFLARE_TUNNEL_ID="$existing_id"
            info "Found existing tunnel '${name}' (${CLOUDFLARE_TUNNEL_ID}) — reusing it."
            return 0
        fi
    fi

    info "Creating Cloudflare Tunnel '${name}'..."
    resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "{\"name\":\"${name}\",\"config_src\":\"cloudflare\"}") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" != "true" ]; then
        err "Tunnel creation failed. $(_cf_json_field "$resp" "message")"
        return 1
    fi
    CLOUDFLARE_TUNNEL_ID=$(_cf_json_field "$resp" "id")
    [ -n "$CLOUDFLARE_TUNNEL_ID" ] || { err "Tunnel created but no ID returned."; return 1; }
    ok "Tunnel created: ${CLOUDFLARE_TUNNEL_ID}"
    return 0
}

# PUT the ingress config: our hostname -> ssh://localhost:2222, plus the
# mandatory catch-all rule.
cf_configure_route() {
    local resp="" ok_flag=""
    local body="{\"config\":{\"ingress\":[{\"hostname\":\"${CLOUDFLARE_SSH_HOST}\",\"service\":\"ssh://localhost:${HOST_SSH_PORT}\"},{\"service\":\"http_status:404\"}]}}"
    resp=$(cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations" "$body") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" != "true" ]; then
        err "Route configuration failed. $(_cf_json_field "$resp" "message")"
        return 1
    fi
    ok "Route configured: ${CLOUDFLARE_SSH_HOST} -> ssh://localhost:${HOST_SSH_PORT}"
    return 0
}

# GET the Tunnel Token for the tunnel we just created/reused, and write it
# straight into CF_TOKEN_FILE (0600) — the user never has to see or copy
# it themselves (Section 12).
cf_get_tunnel_token() {
    local resp="" ok_flag="" tok=""
    resp=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/token") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" != "true" ]; then
        err "Could not retrieve the tunnel token. $(_cf_json_field "$resp" "message")"
        return 1
    fi
    tok=$(printf '%s' "$resp" | tr -d '\n' | grep -o '"result"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"//; s/"$//')
    if [ -z "$tok" ]; then
        err "Tunnel token response did not contain a token."
        return 1
    fi
    local tok_tmp=""
    tok_tmp=$(mktemp "${REMOTE_DIR}/.token.XXXXXX" 2>/dev/null) || { err "Could not create temp file for the tunnel token."; unset tok; return 1; }
    umask 077
    printf '%s' "$tok" > "$tok_tmp"
    chmod 600 "$tok_tmp"
    unset tok
    if ! mv -f "$tok_tmp" "$CF_TOKEN_FILE"; then
        rm -f "$tok_tmp" 2>/dev/null
        err "Could not save the tunnel token file."
        return 1
    fi
    ok "Tunnel token retrieved and stored (never displayed)."
    return 0
}

# Best-effort only (Section 14): if the API token doesn't also carry DNS
# permission, or the zone can't be resolved, this fails quietly and Setup
# falls back to telling the user to add the DNS record themselves. Never
# touches any record other than the exact CNAME it creates.
cf_try_create_dns_record() {
    local root_zone="" resp="" ok_flag="" zone_id=""
    root_zone=$(printf '%s' "$CLOUDFLARE_SSH_HOST" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF }')
    [ -n "$root_zone" ] || return 1
    resp=$(cf_api GET "/zones?name=${root_zone}") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    [ "$ok_flag" = "true" ] || return 1
    zone_id=$(_cf_json_field "$resp" "id")
    [ -n "$zone_id" ] || return 1

    local body="{\"type\":\"CNAME\",\"name\":\"${CLOUDFLARE_SSH_HOST}\",\"content\":\"${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}"
    resp=$(cf_api POST "/zones/${zone_id}/dns_records" "$body") || return 1
    ok_flag=$(_cf_json_bool "$resp" "success")
    if [ "$ok_flag" = "true" ]; then
        ok "DNS record created: ${CLOUDFLARE_SSH_HOST} (CNAME -> ${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com)"
        return 0
    fi
    return 1
}

# [6] Open Cloudflare Token Setup — prints the OFFICIAL, undecorated
# dashboard URL. We deliberately do NOT append a permissionGroupKeys=...
# query string here: that parameter is not documented by Cloudflare for
# account-scoped tokens (see the open, unresolved cloudflare/cloudflare-docs
# issue #28511 asking Cloudflare to document it) — it is community
# reverse-engineering, not a stable contract. Guessing a permission-group
# key and silently pre-selecting the wrong scope would be worse than
# showing three clear manual steps.
remote_open_token_setup() {
    echo -e "${WHITE}Open Cloudflare Token Setup${NC}"
    echo ""
    echo "  1. Open: https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. Create Token -> Custom Token (there is no official 'Tunnel' template yet)"
    echo "     Permission: Account -> Cloudflare Tunnel -> Edit"
    echo "     Account Resources: the account you want DX-NEST to manage"
    echo "  3. Create Token, copy it, and come back here to run Setup."
    echo ""
    warn "This does NOT auto-create the token for you — Cloudflare has no officially"
    warn "documented way to pre-fill that form from a URL. It just saves you the"
    warn "navigation. This is a scoped API Token (setup/management credential),"
    warn "not the Tunnel Token that cloudflared actually runs with."
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "https://dash.cloudflare.com/profile/api-tokens" >/dev/null 2>&1 || true
    fi
    return 0
}

# ---- Secure token storage ----------------------------------------
# The token is asked for with hidden input, never echoed, never passed
# as a CLI argument (cloudflared's own --token-file flag lets us avoid
# that entirely — see remote_start), and never written to config.env.
remote_setup() {
    ensure_remote_dirs
    echo -e "${WHITE}Public SSH (via Cloudflare) — Setup${NC}"
    echo ""

    if [ "$AUTH_MODE" = "password" ]; then
        warn "WARNING:"
        warn "Your VPS SSH uses password authentication."
        warn ""
        warn "Because this VPS is reachable through a public hostname,"
        warn "Cloudflare Access is strongly recommended."
        printf "%b" "Continue? [y/N]: "
        read -r cont
        case "$cont" in y|Y|yes|YES) ;; *) warn "Setup cancelled."; return 1 ;; esac
    else
        info "AUTH_MODE is 'key'. Cloudflare Access is still recommended as defense-in-depth."
    fi

    info "This uses a scoped Cloudflare API Token (management credential) — not"
    info "OAuth, not a Global API Key. See option [6] if you haven't created one yet."
    printf "%b" "Cloudflare API Token (input hidden): "
    local api_token=""
    read -rs api_token; echo ""
    api_token="$(printf '%s' "$api_token" | tr -d '[:space:]')"
    if [ -z "$api_token" ]; then
        err "Empty API token — Setup aborted. Nothing was changed."
        return 1
    fi
    if [ "${#api_token}" -lt 20 ]; then
        err "That doesn't look like a valid Cloudflare API token (too short) — Setup aborted."
        return 1
    fi

    local api_tmp=""
    api_tmp=$(mktemp "${REMOTE_DIR}/.apitoken.XXXXXX" 2>/dev/null) || { err "Could not create a temp file for the API token."; unset api_token; return 1; }
    umask 077
    printf '%s' "$api_token" > "$api_tmp"
    chmod 600 "$api_tmp"
    unset api_token
    if ! mv -f "$api_tmp" "$CF_API_TOKEN_FILE"; then
        rm -f "$api_tmp" 2>/dev/null
        err "Could not save the API token file."
        return 1
    fi
    unset api_tmp

    printf "%b" "Public SSH hostname (e.g. ssh.example.com): "
    local host=""
    read -r host
    host="$(printf '%s' "$host" | tr -d '[:space:]')"
    if [ -z "$host" ]; then
        err "Empty hostname — Setup aborted. API token was saved; re-run Setup to finish."
        return 1
    fi
    if ! [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$ ]]; then
        err "That doesn't look like a valid hostname — Setup aborted."
        return 1
    fi
    CLOUDFLARE_SSH_HOST="$host"

    if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
        info "Discovering your Cloudflare account..."
        if ! cf_discover_account; then
            printf "%b" "Cloudflare Account ID: "
            local acct=""
            read -r acct
            acct="$(printf '%s' "$acct" | tr -d '[:space:]')"
            if [ -z "$acct" ]; then
                err "No account ID — Setup aborted. API token and hostname were saved; re-run Setup."
                REMOTE_ACCESS_PROVIDER="cloudflare"; save_config
                return 1
            fi
            CLOUDFLARE_ACCOUNT_ID="$acct"
        else
            ok "Account auto-detected: ${CLOUDFLARE_ACCOUNT_ID}"
        fi
    fi

    REMOTE_ACCESS_PROVIDER="cloudflare"
    save_config

    if ! cf_find_or_create_tunnel; then
        err "Could not create/find the Cloudflare Tunnel. Check the API token's permissions"
        err "(needs Account -> Cloudflare Tunnel -> Edit) and try Setup again."
        return 1
    fi
    save_config   # persist CLOUDFLARE_TUNNEL_ID immediately so a later failure can still reuse it

    if ! cf_configure_route; then
        err "Tunnel exists (${CLOUDFLARE_TUNNEL_ID}) but the route could not be configured. Retry Setup or Repair."
        return 1
    fi

    if ! cf_get_tunnel_token; then
        err "Tunnel and route are configured but the tunnel token could not be retrieved."
        err "Retry Setup or Repair — the API token needs Cloudflare Tunnel:Edit."
        return 1
    fi

    if cf_try_create_dns_record; then
        :
    else
        warn "DNS record was not created automatically (either the API token has no DNS"
        warn "permission, or ${CLOUDFLARE_SSH_HOST} isn't in a Cloudflare-managed zone)."
        warn "Make sure a DNS record for ${CLOUDFLARE_SSH_HOST} exists and is proxied,"
        warn "or add 'Zone -> DNS -> Edit' to the API token and re-run Setup."
    fi

    if ! install_cloudflared; then
        warn "cloudflared is not installed/working yet — Tunnel/route/token are saved,"
        warn "but Remote Access cannot start until cloudflared installs successfully."
        warn "Retry from Repair, or Start once network access allows the install."
        return 1
    fi

    ok "Remote Access configured for host: ${CLOUDFLARE_SSH_HOST}"
    warn "Cloudflare Access is recommended for public SSH."
    warn "For browser-based SSH and identity-based protection, configure a"
    warn "self-hosted Access application and Allow policy for your hostname"
    warn "in Cloudflare Zero Trust. DX-NEST cannot do this automatically —"
    warn "it has no Cloudflare API credentials."
    return 0
}

# Identity-verified PID check — same shape as is_vm_running(), adapted
# for cloudflared. Requires the process cmdline to contain both
# "cloudflared" and OUR token-file path, so an unrelated cloudflared
# process elsewhere on the box is never mistaken for ours.
is_cf_running() {
    [ -f "$CF_PID_FILE" ] || return 1
    local pid=""
    pid=$(cat "$CF_PID_FILE" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1

    local cmdline=""
    if [ -r "/proc/$pid/cmdline" ]; then
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    fi
    [ -z "$cmdline" ] && cmdline=$(ps -p "$pid" -o cmd= 2>/dev/null || true)
    [ -n "$cmdline" ] || return 1

    case "$cmdline" in
        *cloudflared*"$CF_TOKEN_FILE"*) ;;
        *) return 1 ;;
    esac

    if [ -r "/proc/$pid/exe" ]; then
        local exe=""
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        if [ -n "$exe" ]; then
            case "$exe" in
                *cloudflared*) ;;
                *) return 1 ;;
            esac
        fi
    fi
    return 0
}

remote_configured() {
    [ "$REMOTE_ACCESS_PROVIDER" = "cloudflare" ] && [ -n "$CLOUDFLARE_SSH_HOST" ] && [ -f "$CF_TOKEN_FILE" ] && [ -s "$CF_TOKEN_FILE" ]
}

_remote_start_impl() {
    ensure_remote_dirs

    if is_cf_running; then
        ok "Remote Access is already running (PID $(cat "$CF_PID_FILE"))."
        return 0
    fi
    rm -f "$CF_PID_FILE" 2>/dev/null

    local cf_bin=""
    if ! cf_bin=$(cloudflared_bin); then
        err "cloudflared is not installed. Run Setup, or Repair to reinstall it."
        return 1
    fi
    if ! remote_configured; then
        err "Remote Access is not configured (missing token/hostname). Run Setup first."
        return 1
    fi
    if ! is_vm_running; then
        err "Remote Access cannot start because VPS is stopped."
        err "Start VPS first."
        return 1
    fi
    if ! port_open "$HOST_SSH_PORT"; then
        err "127.0.0.1:${HOST_SSH_PORT} is not reachable — VPS SSH forward isn't up yet."
        return 1
    fi

    mkdir -p "$REMOTE_DIR"
    rotate_log_if_needed "$CF_LOG"
    info "Starting Cloudflare Tunnel (host: ${CLOUDFLARE_SSH_HOST})..."

    # No systemd on Daytona (P0 assumption of this whole project) — run
    # cloudflared as a plain background process we manage ourselves,
    # exactly like QEMU. --token-file (not --token) keeps the secret out
    # of argv/`ps`. --no-autoupdate keeps our PID stable (an in-place
    # self-update would replace the process out from under our tracking).
    nohup "$cf_bin" tunnel --no-autoupdate --loglevel info --logfile "$CF_LOG" \
        run --token-file "$CF_TOKEN_FILE" >>"$CF_LOG" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$CF_PID_FILE"

    sleep 1
    if ! is_cf_running; then
        err "cloudflared did not stay up. Last lines of ${CF_LOG}:"
        tail -n 20 "$CF_LOG" 2>/dev/null || true
        rm -f "$CF_PID_FILE"
        return 1
    fi

    local waited=0
    while [ "$waited" -lt 20 ]; do
        grep -qE "Registered tunnel connection|Connection [0-9a-f-]+ registered" "$CF_LOG" 2>/dev/null && break
        is_cf_running || break
        sleep 1; waited=$((waited+1))
    done

    if is_cf_running; then
        ok "Cloudflare Tunnel running (PID $(cat "$CF_PID_FILE")). Log: $CF_LOG"
        return 0
    fi
    err "cloudflared exited shortly after starting. Last lines of ${CF_LOG}:"
    tail -n 20 "$CF_LOG" 2>/dev/null || true
    rm -f "$CF_PID_FILE"
    return 1
}

_remote_stop_impl() {
    if ! is_cf_running; then
        ok "Remote Access is already stopped."
        rm -f "$CF_PID_FILE"
        return 0
    fi
    local pid=""
    pid=$(cat "$CF_PID_FILE" 2>/dev/null) || pid=""
    if [ -z "$pid" ]; then
        rm -f "$CF_PID_FILE"
        return 0
    fi

    info "Stopping Cloudflare Tunnel (PID $pid)..."
    # Never blind `kill $(cat pidfile)` — is_cf_running already verified
    # PID identity above, so it's safe to signal here.
    ps -p "$pid" -o cmd= 2>/dev/null | grep -q "cloudflared" && kill "$pid" 2>/dev/null || true

    local waited=0
    while is_cf_running && [ "$waited" -lt 15 ]; do sleep 1; waited=$((waited+1)); done

    if is_cf_running; then
        warn "cloudflared did not exit in time. Sending SIGKILL to PID $pid."
        ps -p "$pid" -o cmd= 2>/dev/null | grep -q "cloudflared" && kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    if is_cf_running; then
        err "cloudflared did not stop even after SIGKILL."
        return 1
    fi
    rm -f "$CF_PID_FILE"
    ok "Remote Access stopped."
    return 0
}

remote_start() {
    ensure_remote_dirs
    exec 8>"$REMOTE_LOCK"
    if ! flock -n 8; then
        err "Another Remote Access operation is already in progress. Try again shortly."
        return 1
    fi
    local rc=0
    _remote_start_impl || rc=$?
    flock -u 8
    return $rc
}

remote_stop() {
    ensure_remote_dirs
    exec 8>"$REMOTE_LOCK"
    if ! flock -n 8; then
        err "Another Remote Access operation is already in progress. Try again shortly."
        return 1
    fi
    local rc=0
    _remote_stop_impl || rc=$?
    flock -u 8
    return $rc
}

remote_restart() {
    ensure_remote_dirs
    exec 8>"$REMOTE_LOCK"
    if ! flock -n 8; then
        err "Another Remote Access operation is already in progress. Try again shortly."
        return 1
    fi
    is_cf_running && { _remote_stop_impl || true; }
    local rc=0
    _remote_start_impl || rc=$?
    flock -u 8
    return $rc
}

# Never crashes: every check below degrades to a status line instead of
# propagating a failure. This is the single most important property of
# this whole module (mirrors the hard lesson already learned in
# status_vm() — see its comment block).
remote_status() {
    ensure_remote_dirs
    echo ""
    if ! remote_configured; then
        printf "%b\n" "  Remote Access : ${YELLOW}NOT CONFIGURED${NC} (run Setup)"
        echo ""
        return 0
    fi

    local cf_bin="" cf_ok=1
    cf_bin=$(cloudflared_bin 2>/dev/null) || cf_ok=0

    if is_cf_running; then
        local pid=""; pid=$(cat "$CF_PID_FILE" 2>/dev/null) || pid="?"
        printf "%b\n" "  Cloudflare Tunnel : ${GREEN}RUNNING${NC}"
        printf "%b\n" "  PID               : ${pid}"
        printf "%b\n" "  Process           : ${GREEN}HEALTHY${NC}"
    elif [ "$cf_ok" -eq 0 ]; then
        printf "%b\n" "  Cloudflare Tunnel : ${RED}FAILED${NC} (cloudflared not installed — try Repair)"
    else
        printf "%b\n" "  Cloudflare Tunnel : ${YELLOW}STOPPED${NC}"
    fi

    if is_vm_running && ssh_ready; then
        printf "%b\n" "  VPS SSH           : ${GREEN}READY${NC}"
    elif is_vm_running; then
        printf "%b\n" "  VPS SSH           : ${YELLOW}NOT READY YET${NC}"
    else
        printf "%b\n" "  VPS SSH           : ${RED}VPS STOPPED${NC}"
    fi

    printf "%b\n" "  Endpoint          : ${CYAN}${CLOUDFLARE_SSH_HOST}${NC}"
    printf "%b\n" "  Route             : ssh://localhost:${HOST_SSH_PORT}"

    if is_cf_running && is_vm_running && ssh_ready; then
        : # fully healthy — nothing more to add
    elif is_cf_running; then
        printf "%b\n" "  ${YELLOW}Note: tunnel is up but the VPS/SSH side is not ready — this is a DEGRADED state, not a tunnel failure.${NC}"
    fi
    echo ""
    return 0
}

remote_connection_info() {
    echo -e "${WHITE}Public SSH (via Cloudflare) — Connection Info${NC}"
    if ! remote_configured; then
        warn "Not configured yet. Run Setup first."
        return 1
    fi
    echo ""
    echo -e "  Public SSH Host : ${CYAN}${CLOUDFLARE_SSH_HOST}${NC}"
    echo -e "  SSH target      : ${CYAN}${VM_USER}@${CLOUDFLARE_SSH_HOST}${NC}"
    echo -e "  Transport       : Cloudflare Tunnel"
    echo -e "  Origin          : ssh://localhost:${HOST_SSH_PORT}"
    echo ""
    echo -e "${WHITE}CLI access${NC} (requires the client-side 'cloudflared' on YOUR machine, not just here):"
    echo -e "  ssh ${VM_USER}@${CLOUDFLARE_SSH_HOST}"
    echo -e "  Add this to your ~/.ssh/config so OpenSSH knows how to reach it:"
    echo -e "    Host ${CLOUDFLARE_SSH_HOST}"
    echo -e "        ProxyCommand cloudflared access ssh --hostname %h"
    echo -e "  Ordinary OpenSSH cannot reach a Cloudflare Tunnel hostname without this"
    echo -e "  ProxyCommand — plain 'ssh user@host' will NOT work on its own."
    echo -e "  After the Cloudflare Access hop, normal guest SSH auth still applies"
    echo -e "  (AUTH_MODE=${AUTH_MODE}: you'll still get the usual $( [ "$AUTH_MODE" = password ] && echo password || echo key ) prompt)."
    echo ""
    echo -e "${WHITE}Browser access${NC} (only if Browser Rendering is enabled in Cloudflare Access):"
    echo -e "  https://${CLOUDFLARE_SSH_HOST}"
    echo -e "  DX-NEST does not enable this for you — configure it in Cloudflare Zero Trust."
    echo ""
    warn "Cloudflare Access is recommended for public SSH. Without it, anyone with"
    warn "the hostname can reach the tunnel's SSH port (guest SSH auth still applies)."
    return 0
}

remote_repair() {
    echo -e "${WHITE}Public SSH (via Cloudflare) — Repair${NC}"
    info "Repair never touches the VM, its disk, its SSH identity, or QEMU networking."
    ensure_remote_dirs
    chmod 700 "$REMOTE_DIR" 2>/dev/null || true
    [ -f "$CF_TOKEN_FILE" ] && chmod 600 "$CF_TOKEN_FILE" 2>/dev/null || true
    [ -f "$CF_API_TOKEN_FILE" ] && chmod 600 "$CF_API_TOKEN_FILE" 2>/dev/null || true

    if [ -f "$CF_PID_FILE" ] && ! is_cf_running; then
        warn "Removing stale PID file."
        rm -f "$CF_PID_FILE"
    fi

    if ! cloudflared_bin >/dev/null 2>&1; then
        warn "cloudflared missing — attempting reinstall."
        install_cloudflared || warn "Reinstall failed; see errors above."
    fi

    # If the runtime Tunnel Token is missing/empty but we still have the
    # management API token and a known tunnel, re-fetch it instead of
    # forcing the user through Setup again from scratch.
    if [ -f "$CF_API_TOKEN_FILE" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ] && [ -n "$CLOUDFLARE_TUNNEL_ID" ] \
        && { [ ! -s "$CF_TOKEN_FILE" ]; }; then
        info "Runtime tunnel token missing — re-fetching it via the stored API token..."
        cf_get_tunnel_token || warn "Could not re-fetch the tunnel token automatically. Run Setup again."
    fi

    if ! remote_configured; then
        warn "Not configured (missing token/hostname/binary) — run Setup."
        return 1
    fi

    if is_vm_running && port_open "$HOST_SSH_PORT"; then
        ok "Local SSH endpoint (127.0.0.1:${HOST_SSH_PORT}) looks reachable."
    else
        warn "Local SSH endpoint is not reachable right now (VPS stopped or SSH not up)."
    fi

    if is_cf_running; then
        info "Restarting Cloudflare Tunnel to apply repairs..."
        remote_restart || { err "Restart failed — see log: $CF_LOG"; return 1; }
    else
        info "Tunnel is not currently running — not auto-starting it (use Setup menu -> Status/Start)."
    fi
    ok "Repair complete."
    return 0
}

remote_disable() {
    echo -e "${WHITE}Public SSH (via Cloudflare) — Disable${NC}"
    remote_stop || true
    ok "Remote Access disabled. Token and hostname are preserved (Setup again is not required to re-enable — just start it from the submenu)."
    echo ""
    echo -e "  VPS Status     : $(is_vm_running && echo -e "${GREEN}RUNNING${NC}" || echo -e "${RED}STOPPED${NC}")"
    echo -e "  Remote Access  : ${YELLOW}DISABLED${NC}"
    return 0
}

remote_access_menu() {
    while true; do
        clear
        print_header
        echo -e "${WHITE}PUBLIC SSH (VIA CLOUDFLARE)${NC}"
        echo -e "${CYAN}----------------------------${NC}"
        remote_status
        echo -e "  ${BLUE}1${NC}  Setup"
        echo -e "  ${BLUE}2${NC}  Status"
        echo -e "  ${BLUE}3${NC}  Connection Info"
        echo -e "  ${BLUE}4${NC}  Repair"
        echo -e "  ${BLUE}5${NC}  Disable"
        echo -e "  ${BLUE}6${NC}  Open Cloudflare Token Setup"
        echo -e "  ${BLUE}0${NC}  Back"
        printf "%b" "${YELLOW}> ${NC}"
        read -r c
        case "$c" in
            1) remote_setup || true; if remote_configured; then remote_start || true; fi; pause ;;
            2) remote_status; pause ;;
            3) remote_connection_info || true; pause ;;
            4) remote_repair || true; pause ;;
            5) remote_disable || true; pause ;;
            6) remote_open_token_setup || true; pause ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 15b: Persistent `dx` command installation (self-install)
# ==========================================================
# This is entirely separate from BASE_DIR (the VM/disk/config). It only
# ever copies THIS running script to a stable system path and makes
# sure /usr/local/bin/dx points at it. It never downloads anything (no
# internet needed) and never touches the VM, so it is always safe to
# call — on every run, idempotently, or explicitly via Maintenance ->
# "Repair dx command" / `dx install`.
self_install() {
    local this_script=""
    this_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || this_script=""

    # Part 1: persist the manager script — skip quietly if we're not a
    # real file on disk (e.g. invoked via `bash <(curl ...)` process
    # substitution has no stable path — that's what bootstrap.sh's temp
    # file is for) or if we're already running from the installed copy.
    #
    # Installed via a temp-file-then-atomic-rename, not a direct
    # in-place `cp`, so a disk-full/permission/interrupted failure
    # midway can never leave a truncated, half-written
    # /usr/local/lib/dx-nest/install.sh behind — either the final
    # `mv` (atomic rename on the same filesystem) happens, or the
    # previous installed copy (if any) is left completely untouched.
    if [ -n "$this_script" ] && [ -f "$this_script" ] && [ "$this_script" != "$INSTALL_MANAGER_PATH" ]; then
        if $SUDO_CMD mkdir -p "$INSTALL_LIB_DIR" 2>/dev/null; then
            local install_tmp=""
            install_tmp=$($SUDO_CMD mktemp "${INSTALL_LIB_DIR}/.install.sh.XXXXXX" 2>/dev/null) || install_tmp=""
            if [ -n "$install_tmp" ] \
                && $SUDO_CMD cp -f "$this_script" "$install_tmp" 2>/dev/null \
                && $SUDO_CMD bash -n "$install_tmp" 2>/dev/null \
                && $SUDO_CMD chmod 755 "$install_tmp" 2>/dev/null \
                && $SUDO_CMD mv -f "$install_tmp" "$INSTALL_MANAGER_PATH" 2>/dev/null
            then
                ok "DX-NEST manager installed at ${INSTALL_MANAGER_PATH}"
            else
                warn "Could not install the persistent manager at ${INSTALL_MANAGER_PATH}"
                warn "(no root/sudo, disk full, or an invalid source file?). Any PREVIOUS"
                warn "installation there was left untouched. Run 'sudo -i' and re-run this"
                warn "script once to install it system-wide."
                [ -n "$install_tmp" ] && $SUDO_CMD rm -f "$install_tmp" 2>/dev/null
            fi
        else
            warn "Could not create ${INSTALL_LIB_DIR} (no root/sudo?) — 'dx' not installed this run."
        fi
    fi

    # Part 2: make sure the `dx` wrapper exists and points at the
    # installed manager — independent of how we were invoked, so this
    # also self-repairs a manually-deleted /usr/local/bin/dx. Same
    # temp-file-then-atomic-rename pattern as Part 1.
    if [ -f "$INSTALL_MANAGER_PATH" ]; then
        local need_wrapper=1
        if [ -f "$INSTALL_BIN_PATH" ] && grep -q "$INSTALL_MANAGER_PATH" "$INSTALL_BIN_PATH" 2>/dev/null; then
            need_wrapper=0
        fi
        if [ "$need_wrapper" -eq 1 ]; then
            local wrapper_tmp=""
            wrapper_tmp=$(mktemp 2>/dev/null) || wrapper_tmp=""
            if [ -n "$wrapper_tmp" ]; then
                printf '#!/bin/bash\nexec "%s" "$@"\n' "$INSTALL_MANAGER_PATH" > "$wrapper_tmp"
                chmod 755 "$wrapper_tmp" 2>/dev/null || true
                if $SUDO_CMD mv -f "$wrapper_tmp" "$INSTALL_BIN_PATH" 2>/dev/null; then
                    $SUDO_CMD chmod 755 "$INSTALL_BIN_PATH" 2>/dev/null || true
                    ok "Command available: dx"
                else
                    warn "Could not install /usr/local/bin/dx (no root/sudo?)."
                    rm -f "$wrapper_tmp" 2>/dev/null
                fi
            fi
        fi
    fi
    return 0
}

self_install_report() {
    # Explicit, user-visible verification (Maintenance -> Repair, and
    # the tail end of a fresh bootstrap install).
    echo -e "${WHITE}Installation check${NC}"
    [ -f "$INSTALL_MANAGER_PATH" ] && ok "persistent manager exists (${INSTALL_MANAGER_PATH})" \
        || warn "persistent manager NOT installed"
    if command -v dx >/dev/null 2>&1; then
        ok "dx command installed ($(command -v dx))"
    else
        warn "dx command NOT on PATH"
    fi
    [ -x "$INSTALL_BIN_PATH" ] && ok "dx command is executable" || warn "dx is not executable"
    [ -d "$BASE_DIR" ] && ok "config directory exists (${BASE_DIR})" || warn "config directory missing"
    [ -d "$SSH_DIR" ] && ok "SSH directory exists (${SSH_DIR})" || warn "SSH directory missing"
    for c in bash curl awk sed grep cat ps flock timeout ssh ssh-keygen \
             qemu-system-x86_64 qemu-img socat; do
        command -v "$c" >/dev/null 2>&1 && ok "required command available: $c" \
            || warn "required command missing: $c"
    done
    bash -n "$INSTALL_MANAGER_PATH" 2>/dev/null && ok "install.sh syntax valid" \
        || warn "install.sh syntax check skipped/failed (not installed yet, or unreadable)"
}

# ==========================================================
# Section 16: Maintenance (safe, confirmed destructive actions)
# ==========================================================
maintenance_menu() {
    while true; do
        clear
        print_header
        echo -e "${WHITE}Maintenance${NC}"
        echo -e "  ${BLUE}1${NC}  Re-check / reinstall dependencies"
        echo -e "  ${BLUE}2${NC}  Remove generated seed.img only (safe, rebuilt automatically)"
        echo -e "  ${BLUE}3${NC}  Full reset: stop VM and delete disk + seed + config (DESTRUCTIVE)"
        echo -e "  ${BLUE}4${NC}  Repair/verify 'dx' command (no download, no VM changes)"
        echo -e "  ${BLUE}0${NC}  Back"
        printf "%b" "${YELLOW}> ${NC}"
        read -r c
        case "$c" in
            1) install_dependencies; pause ;;
            2) rm -f "$SEED_IMG"; ok "seed.img removed — it will be rebuilt on next start."; pause ;;
            4) self_install; echo ""; self_install_report; pause ;;
            3)
                warn "This deletes ${IMAGE_PATH}, ${SEED_IMG}, ${CONFIG_FILE} and stops the VM."
                warn "It will also clear this VM's entry from DX-NEST's own known_hosts (not your system one)."
                printf "%b" "Type DELETE to confirm: "
                read -r confirm
                if [ "$confirm" = "DELETE" ]; then
                    is_vm_running && { stop_vm || true; }
                    rm -f "$IMAGE_PATH" "$SEED_IMG" "$CONFIG_FILE" "$DISK_MARKER" "$PID_FILE" \
                        "$MONITOR_SOCK" "$CONSOLE_SOCK" "$ACCEL_MARKER"
                    forget_known_host
                    ok "Full reset complete."
                else
                    warn "Confirmation text did not match — nothing was deleted."
                fi
                pause ;;
            0) return ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 17: UI — header/status + main menu (DX WARP visual style)
# ==========================================================
print_header() {
    local B="${CYAN}+---------------------------------------------------------------+${NC}"
    printf "%b\n" "$B"
    printf "%b\n" "${MAGENTA} ██████╗ ██╗  ██╗       ███╗   ██╗███████╗███████╗████████╗${NC}"
    printf "%b\n" "${MAGENTA} ██╔══██╗╚██╗██╔╝       ████╗  ██║██╔════╝██╔════╝╚══██╔══╝${NC}"
    printf "%b\n" "${YELLOW} ██║  ██║ ╚███╔╝  █████╗██╔██╗ ██║█████╗  ███████╗   ██║   ${NC}"
    printf "%b\n" "${YELLOW} ██║  ██║ ██╔██╗  ╚════╝██║╚██╗██║██╔══╝  ╚════██║   ██║   ${NC}"
    printf "%b\n" "${GREEN} ██████╔╝██╔╝ ██╗       ██║ ╚████║███████╗███████║   ██║   ${NC}"
    printf "%b\n" "${GREEN} ╚═════╝ ╚═╝  ╚═╝       ╚═╝  ╚═══╝╚══════╝╚══════╝   ╚═╝   ${NC}"
    printf "%b\n" "$B"
    printf "%b\n" "  Creator: ${MAGENTA}@COD-DEXTER${NC}   Free VPS Manager for Daytona   v${GREEN}${VERSION}${NC}"
    printf "%b\n" "$B"
}

main_menu() {
    while true; do
        clear
        print_header
        status_vm
        echo -e "${CYAN}+---------------------------------------------------------------+${NC}"
        echo -e "  ${BLUE}1${NC}  VPS Status"
        echo -e "  ${BLUE}2${NC}  Start VPS"
        echo -e "  ${BLUE}3${NC}  Stop VPS"
        echo -e "  ${BLUE}4${NC}  Restart VPS"
        echo -e "  ${BLUE}5${NC}  Enter VPS   ${YELLOW}(auto start + wait for SSH)${NC}"
        echo -e "  ${BLUE}6${NC}  Console / Logs"
        echo -e "  ${BLUE}7${NC}  SSH / Network"
        echo -e "  ${BLUE}8${NC}  VPS Config"
        echo -e "  ${BLUE}9${NC}  Maintenance"
        echo -e "  ${BLUE}10${NC} Public SSH (via Cloudflare)"
        echo -e "  ${BLUE}0${NC}  Exit"
        echo -e "${CYAN}+---------------------------------------------------------------+${NC}"
        printf "%b" "${YELLOW}Enter Choice [0-10]: ${NC}"
        read -r choice
        # NOTE: every lifecycle call below is guarded with `|| true`.
        # Under `set -e`, a bare failing command inside a case branch
        # would otherwise kill the whole menu instead of returning to
        # it — that footgun is intentionally avoided everywhere here.
        case "$choice" in
            1) status_vm; pause ;;
            2) start_vm || true; pause ;;
            3) stop_vm || true; pause ;;
            4) restart_vm || true; pause ;;
            5) enter_vps || true; pause ;;
            6) console_menu ;;
            7) ssh_network_menu ;;
            8) vps_config_menu ;;
            9) maintenance_menu ;;
            10) remote_access_menu ;;
            0) echo -e "${GREEN}Bye.${NC}"; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ==========================================================
# Section 18: CLI / non-interactive mode (P2-3)
# ==========================================================
print_usage() {
    cat <<EOF
DX-NEST v${VERSION} — Free VPS Manager for Daytona

Usage:
  $0                 Launch the interactive menu
  $0 <command>

Commands:
  status     Show VPS/QEMU/SSH status and exit
  start      Start the VPS (idempotent)
  stop       Stop the VPS (idempotent)
  restart    Restart the VPS with full verification (QEMU + SSH)
  enter      Start (if needed) and SSH into the VPS
  logs       Print the last 100 lines of the boot log
  console    Attach to the serial console
  network    Run a quick network diagnostic (host port + guest SSH)
  config     Print the current configuration
  install    (Re)install/repair the persistent 'dx' command — no download, no VM changes
  remote <status|start|stop|restart|info|setup|repair|disable>
             Manage Public SSH (via Cloudflare) — independent of the VPS itself;
             a tunnel failure never affects status/start/stop/restart/enter above
  help       Show this message

Exit codes: 0 on success, non-zero on failure.

This does not require internet once installed: 'dx' only needs the
network for the initial Ubuntu image download / apt dependency install,
the 'network' diagnostic, and 'remote' (Cloudflare) — the menu and
status always work offline.
EOF
}

run_cli() {
    local cmd="${1:-help}"
    ensure_dirs
    load_config
    self_install
    case "$cmd" in
        status) status_vm; exit 0 ;;
        start) if start_vm; then exit 0; else exit 1; fi ;;
        stop) if stop_vm; then exit 0; else exit 1; fi ;;
        restart) if restart_vm; then exit 0; else exit 1; fi ;;
        enter) if enter_vps; then exit 0; else exit 1; fi ;;
        logs)
            if [ -f "$BOOT_LOG" ]; then tail -n 100 "$BOOT_LOG"; exit 0; fi
            err "No boot log yet."; exit 1 ;;
        console)
            if [ -S "$CONSOLE_SOCK" ]; then
                socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:${CONSOLE_SOCK}"
                exit 0
            fi
            err "No console socket — VM is not running."; exit 1 ;;
        network)
            if ! is_vm_running; then err "VM is not running."; exit 1; fi
            local host_ok=1 auth_ok=1
            port_open "$HOST_SSH_PORT" && host_ok=0
            ssh_auth_ok && auth_ok=0
            echo "host_port=$([ $host_ok -eq 0 ] && echo PASS || echo FAIL)"
            echo "guest_ssh=$([ $auth_ok -eq 0 ] && echo PASS || echo FAIL)"
            if [ $host_ok -eq 0 ] && [ $auth_ok -eq 0 ]; then exit 0; else exit 1; fi ;;
        config)
            echo "VM_RAM_GB=${VM_RAM_GB}"
            echo "VM_CPU=${VM_CPU}"
            echo "VM_DISK_GB=${VM_DISK_GB}"
            echo "VM_USER=${VM_USER}"
            echo "HOST_SSH_PORT=${HOST_SSH_PORT}"
            echo "SANDBOX_RAM_GB=${SANDBOX_RAM_GB}"
            echo "SANDBOX_CPU=${SANDBOX_CPU}"
            echo "AUTH_MODE=${AUTH_MODE}"
            echo "REMOTE_ACCESS_PROVIDER=${REMOTE_ACCESS_PROVIDER}"
            echo "CLOUDFLARE_SSH_HOST=${CLOUDFLARE_SSH_HOST}"
            echo "CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID}"
            echo "CLOUDFLARE_TUNNEL_ID=${CLOUDFLARE_TUNNEL_ID}"
            exit 0 ;;
        install)
            # self_install already ran once, unconditionally, at the top
            # of run_cli() — just show the verification report here.
            self_install_report
            exit 0 ;;
        remote)
            local sub="${2:-status}"
            case "$sub" in
                status)  remote_status; exit 0 ;;
                start)   if remote_start; then exit 0; else exit 1; fi ;;
                stop)    if remote_stop; then exit 0; else exit 1; fi ;;
                restart) if remote_restart; then exit 0; else exit 1; fi ;;
                info)    if remote_connection_info; then exit 0; else exit 1; fi ;;
                setup)   if remote_setup; then remote_start || true; exit 0; else exit 1; fi ;;
                repair)  if remote_repair; then exit 0; else exit 1; fi ;;
                disable) if remote_disable; then exit 0; else exit 1; fi ;;
                *) err "Unknown 'remote' subcommand: ${sub}"; print_usage; exit 2 ;;
            esac ;;
        help|--help|-h) print_usage; exit 0 ;;
        *) err "Unknown command: ${cmd}"; print_usage; exit 2 ;;
    esac
}

# ==========================================================
# Entry point
# ==========================================================
# DXNEST_TEST_MODE=1 lets this file be `source`d (e.g. from a test
# harness) without launching the CLI dispatcher or the interactive menu.
if [ "${DXNEST_TEST_MODE:-0}" != "1" ]; then
    if [ $# -gt 0 ]; then
        run_cli "$@"
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        ensure_dirs
        load_config
        err "Interactive terminal required for the menu."
        print_usage
        exit 1
    fi

    ensure_dirs
    load_config
    self_install
    clear
    main_menu
fi
