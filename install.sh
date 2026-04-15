#!/bin/sh
# Published copy; source of truth: fremkit-dev/fremkit:install.sh
# frem installer — POSIX sh, no bash required.
#
# Usage:
#   curl -sSL https://<public-installer-host>/install.sh | sh
#
# Environment overrides:
#   FREMKIT_VERSION   Pin a specific version (e.g. "0.1.0" or "v0.1.0")
#   FREMKIT_BIN_DIR   Install directory (default: /usr/local/bin or ~/.local/bin)
#   FREMKIT_RELEASE_API_URL
#                     Override latest-release metadata endpoint. The endpoint
#                     must return JSON containing "tag_name".
#   FREMKIT_DOWNLOAD_BASE_URL
#                     Override versioned download base. If set, the installer
#                     downloads:
#                       ${FREMKIT_DOWNLOAD_BASE_URL}/<version>/<tarball>
#                       ${FREMKIT_DOWNLOAD_BASE_URL}/<version>/checksums.txt
#                     Example:
#                       FREMKIT_DOWNLOAD_BASE_URL=https://downloads.fremkit.dev
#
# Exit codes:
#   0  success
#   1  unsupported OS/architecture
#   2  download failed
#   3  checksum mismatch
#   4  install failed

set -eu

REPO="fremkit-dev/fremkit"
USER_AGENT="frem-installer"
DEFAULT_RELEASE_API_URL="https://api.github.com/repos/$REPO/releases/latest"
DEFAULT_DOWNLOAD_BASE_URL="https://github.com/$REPO/releases/download"

# -------- logging --------
info()  { printf '==> %s\n' "$*"; }
warn()  { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

# -------- cleanup --------
TMPDIR=""
cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT INT TERM

# -------- detect OS/ARCH --------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
    linux)  ;;
    darwin) ;;
    *)
        error "unsupported OS: $OS (supported: linux, darwin)"
        exit 1
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        error "unsupported architecture: $ARCH (supported: amd64, arm64)"
        exit 1
        ;;
esac

# -------- musl detection (Linux only) --------
if [ "$OS" = "linux" ]; then
    if ls /lib/libc.musl-*.so.1 >/dev/null 2>&1 || \
       (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); then
        warn "detected musl libc — frem binaries are statically linked (CGO_ENABLED=0) and should work, but this is not extensively tested"
    fi
fi

# -------- resolve version --------
VERSION="${FREMKIT_VERSION:-}"

if [ -z "$VERSION" ]; then
    RELEASE_API_URL="${FREMKIT_RELEASE_API_URL:-$DEFAULT_RELEASE_API_URL}"
    info "resolving latest version from release metadata..."
    VERSION=$(
        curl -fsSL \
            -H "User-Agent: $USER_AGENT" \
            -H "Accept: application/vnd.github+json" \
            "$RELEASE_API_URL" 2>/dev/null \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' \
        | head -n1
    ) || true
fi

if [ -z "$VERSION" ]; then
    error "could not resolve latest version from release metadata"
    error "this may be a rate limit, network issue, or there may be no public releases yet"
    error "try: FREMKIT_VERSION=0.1.0 sh install.sh"
    exit 2
fi

# Normalize: strip leading v if present, keep a bare version
VERSION="${VERSION#v}"

info "installing frem v${VERSION} for ${OS}/${ARCH}"

# -------- pick install dir --------
BINDIR=""
choose_bindir() {
    # 1. env override
    if [ -n "${FREMKIT_BIN_DIR:-}" ]; then
        BINDIR="$FREMKIT_BIN_DIR"
        mkdir -p "$BINDIR" 2>/dev/null || true
        return 0
    fi

    # 2. /usr/local/bin if writable
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        BINDIR="/usr/local/bin"
        return 0
    fi

    # 3. /opt/homebrew/bin for mac arm64 if present and writable
    if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ] && \
       [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
        BINDIR="/opt/homebrew/bin"
        return 0
    fi

    # 4. ~/.local/bin — create if missing
    BINDIR="$HOME/.local/bin"
    mkdir -p "$BINDIR"
}
choose_bindir

if [ ! -w "$BINDIR" ]; then
    error "install directory not writable: $BINDIR"
    error "set FREMKIT_BIN_DIR to a writable directory, or re-run with sudo"
    exit 4
fi

info "install directory: $BINDIR"

# -------- download tarball + checksums --------
TARBALL="frem_${VERSION}_${OS}_${ARCH}.tar.gz"
DOWNLOAD_BASE_URL="${FREMKIT_DOWNLOAD_BASE_URL:-$DEFAULT_DOWNLOAD_BASE_URL}"
BASE_URL="${DOWNLOAD_BASE_URL%/}/v${VERSION}"
TAR_URL="${BASE_URL}/${TARBALL}"
SUMS_URL="${BASE_URL}/checksums.txt"

TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t frem-install)
if [ ! -d "$TMPDIR" ]; then
    error "failed to create temp dir"
    exit 4
fi

info "downloading ${TARBALL}"
if ! curl -fsSL -H "User-Agent: $USER_AGENT" -o "$TMPDIR/$TARBALL" "$TAR_URL"; then
    error "download failed: $TAR_URL"
    exit 2
fi

info "downloading checksums.txt"
if ! curl -fsSL -H "User-Agent: $USER_AGENT" -o "$TMPDIR/checksums.txt" "$SUMS_URL"; then
    error "checksum download failed: $SUMS_URL"
    exit 2
fi

# -------- verify checksum --------
EXPECTED=$(grep " $TARBALL\$" "$TMPDIR/checksums.txt" | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
    error "no checksum entry for $TARBALL in checksums.txt"
    exit 3
fi

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$TMPDIR/$TARBALL" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$TMPDIR/$TARBALL" | awk '{print $1}')
else
    error "no sha256 tool available (need sha256sum or shasum)"
    exit 3
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    error "checksum mismatch for $TARBALL"
    error "  expected: $EXPECTED"
    error "  actual:   $ACTUAL"
    exit 3
fi
info "checksum verified"

# -------- extract + install --------
if ! tar xzf "$TMPDIR/$TARBALL" -C "$TMPDIR"; then
    error "failed to extract $TARBALL"
    exit 4
fi

if [ ! -f "$TMPDIR/frem" ]; then
    error "frem binary not found in archive"
    exit 4
fi

if ! install -m 0755 "$TMPDIR/frem" "$BINDIR/frem"; then
    error "failed to install frem to $BINDIR"
    exit 4
fi

# -------- verify --------
if ! "$BINDIR/frem" version >/dev/null 2>&1; then
    warn "frem installed but 'frem version' check failed"
fi

info "installed: $BINDIR/frem"

# -------- PATH hint --------
case ":$PATH:" in
    *":$BINDIR:"*)
        ;;
    *)
        printf '\n'
        warn "$BINDIR is not in your PATH"
        printf '  add it with one of:\n'
        printf "    echo 'export PATH=\"%s:\$PATH\"' >> ~/.bashrc\n" "$BINDIR"
        printf "    echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc\n" "$BINDIR"
        printf '\n'
        ;;
esac

# -------- next steps --------
printf '\n'
info "next steps:"
printf '  frem auth login          # authenticate with the API\n'
printf '  frem completion install  # enable shell tab-completion\n'
