#!/bin/bash
# ==========================================================
#  DX-NEST bootstrap
#  Downloads install.sh from a real file (never a process
#  substitution), validates it (HTTP success + `bash -n`
#  syntax check), then execs it. Never runs an unvalidated
#  or non-HTTPS source.
#
#  Why this exists as a separate file: `bash <(curl -sSL
#  https://raw.githubusercontent.com/.../install.sh)` has no
#  stable on-disk path, so install.sh's own self-install step
#  (which copies itself to /usr/local/lib/dx-nest/install.sh)
#  can't find a real file to copy. This script downloads to a
#  REAL temp file first, so self-install works, AND it tries
#  more than one source in case github.com/
#  raw.githubusercontent.com are blocked in this network.
#
#  Usage:
#    bash <(curl -sSL https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/bootstrap.sh)
#
#  Override the source (e.g. GitHub is blocked here):
#    DXNEST_INSTALL_URL="https://your-mirror/install.sh" \
#      bash <(curl -sSL https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/bootstrap.sh)
# ==========================================================

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "%b\n" "${CYAN}[i]${NC} $1"; }
ok()   { printf "%b\n" "${GREEN}[OK]${NC} $1"; }
warn() { printf "%b\n" "${YELLOW}[!]${NC} $1"; }
err()  { printf "%b\n" "${RED}[ERROR]${NC} $1" >&2; }

# Default source list. Only add fallbacks that are genuinely reachable
# mirrors of the same repo content — never a made-up/unverified URL.
DEFAULT_SOURCES=(
    "https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/install.sh"
    "https://cdn.jsdelivr.net/gh/COD-DEXTER/DX-NEST@main/install.sh"
)

SOURCES=()
if [ -n "${DXNEST_INSTALL_URL:-}" ]; then
    SOURCES=("$DXNEST_INSTALL_URL")
elif [ -n "${DXNEST_SOURCE_URL:-}" ]; then
    SOURCES=("$DXNEST_SOURCE_URL")
else
    SOURCES=("${DEFAULT_SOURCES[@]}")
fi

if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to bootstrap DX-NEST but is not installed."
    exit 1
fi

TMP_INSTALLER=$(mktemp /tmp/dxnest-install.XXXXXX.sh)
TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

downloaded=0
total=${#SOURCES[@]}
idx=0
for u in "${SOURCES[@]}"; do
    idx=$((idx+1))

    if [[ "$u" != https://* ]]; then
        warn "Skipping non-HTTPS source: $u"
        continue
    fi

    if [ "$idx" -eq 1 ]; then
        info "Trying source ${idx}/${total}: $u"
    else
        warn "Primary source unavailable."
        info "Trying fallback source ${idx}/${total}: $u"
    fi

    : > "$TMP_ERR"
    if ! curl -fsSL --connect-timeout 8 --max-time 30 "$u" -o "$TMP_INSTALLER" 2>"$TMP_ERR"; then
        curl_err=""
        curl_err=$(cat "$TMP_ERR" 2>/dev/null) || curl_err=""
        case "$curl_err" in
            *"Could not resolve host"*) warn "  Reason: DNS resolution failed." ;;
            *"timed out"*|*"Connection timed out"*|*"Operation timed out"*) warn "  Reason: connection timed out." ;;
            *"SSL"*|*"TLS"*|*"certificate"*) warn "  Reason: TLS/certificate error." ;;
            *"Connection refused"*|*"couldn't connect"*) warn "  Reason: connection refused / network blocked." ;;
            *) warn "  Reason: download failed (HTTP error or network block)." ;;
        esac
        continue
    fi

    if [ ! -s "$TMP_INSTALLER" ]; then
        warn "  Downloaded file is empty."
        continue
    fi

    if ! bash -n "$TMP_INSTALLER" 2>/dev/null; then
        err "Downloaded installer from ${u} failed syntax validation — refusing to run it."
        continue
    fi

    ok "Installer source reachable and validated: $u"
    downloaded=1
    break
done

if [ "$downloaded" -ne 1 ]; then
    err "Unable to retrieve a valid DX-NEST installer from any configured source."
    err "Tried: ${SOURCES[*]}"
    err "Possible causes: DNS failure, connection timeout, TLS error, or this network blocking these hosts."
    err "Override the source with: DXNEST_INSTALL_URL=https://your-mirror/install.sh bash <(curl -sSL .../bootstrap.sh)"
    rm -f "$TMP_INSTALLER"
    exit 1
fi

chmod 755 "$TMP_INSTALLER"
ok "Handing off to the validated installer..."
# exec, not source: install.sh manages its own `set -Eeuo pipefail` and
# entry point. It self-installs itself to /usr/local/lib/dx-nest and
# creates /usr/local/bin/dx from this real temp file, then opens the
# menu (or runs the CLI command if any extra args were passed through).
exec bash "$TMP_INSTALLER" "$@"
