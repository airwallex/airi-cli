#!/bin/sh
# airi-cli installer (beta)
#
# Downloads the prebuilt airi-cli binary for your platform from the GitHub
# release, installs it onto your PATH, and deploys the bundled agent skills
# into your local AI-agent skill directories.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/airwallex/airi-cli/master/install.sh | sh
#
# Environment variables:
#   AIRI_CLI_VERSION         pin a specific release tag (default: baked LATEST_VERSION)
#   AIRI_CLI_INSTALL_DIR     install location (default: $HOME/.local/bin)
#   AIRI_CLI_SKIP_CHECKSUM   set to 1 to skip SHA256 verification (local-dev only)
#   AIRI_CLI_SKIP_SKILLS     set to 1 to skip deploying agent skills
#   AIRI_CLI_SKILL_DIRS      space-separated skill dirs to deploy to
#                            (default: the CLI's built-in agent dirs)
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  unsupported platform
#   3  checksum mismatch
#   4  network failure

set -eu

# ─── Release source ─────────────────────────────────────────────────────────
# Binaries are distributed as GitHub release assets on this repo. Each release
# tag (e.g. v0.1.0) carries, per platform:
#
#   https://github.com/<REPO>/releases/download/<tag>/airi-cli_<os>_<arch>.tar.gz
#   https://github.com/<REPO>/releases/download/<tag>/airi-cli_<os>_<arch>.tar.gz.sha256
#
REPO="airwallex/airi-cli"

# Baked in at release time. Kept in sync with core/version/version.go and the
# README (enforced by scripts/check-version.sh). Update when cutting a release.
# Includes the leading "v" to match the release tag (e.g. v0.1.0).
LATEST_VERSION="v0.1.0"
# ────────────────────────────────────────────────────────────────────────────

BIN_NAME="airi-cli"
INSTALL_DIR="${AIRI_CLI_INSTALL_DIR:-$HOME/.local/bin}"
STATE_DIR="${HOME}/.local/state/airi"
VERSION="${AIRI_CLI_VERSION:-latest}"
SKIP_CHECKSUM="${AIRI_CLI_SKIP_CHECKSUM:-0}"

EXIT_GENERIC=1
EXIT_UNSUPPORTED=2
EXIT_CHECKSUM=3
EXIT_NETWORK=4

# Colors via terminfo so real ESC bytes are emitted (not literal '\033[…]').
# Falls back to empty strings when stdout isn't a tty (CI, log files).
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD=$(tput bold); DIM=$(tput dim); BLUE=$(tput setaf 4)
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1); RESET=$(tput sgr0)
else
    BOLD=''; DIM=''; BLUE=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi

_lang="${LANG:-}${LC_ALL:-}"
case "$_lang" in
    *UTF-8*|*utf-8*|*utf8*) G_STEP='→' G_OK='✓' G_WARN='!' G_ERR='✗' ;;
    *)                      G_STEP='*' G_OK='+' G_WARN='!' G_ERR='x' ;;
esac

header() { printf '\n%s%sairi-cli installer%s\n\n' "$BOLD" "$BLUE" "$RESET"; }
step()   { printf '  %s%s%s %s\n' "$BLUE" "$G_STEP" "$RESET" "$*"; }
ok()     { printf '  %s%s%s %s\n' "$GREEN" "$G_OK" "$RESET" "$*"; }
warn()   { printf '  %s%s%s %s\n' "$YELLOW" "$G_WARN" "$RESET" "$*" >&2; }
err() {
    code="${2:-$EXIT_GENERIC}"
    printf '\n  %s%s%s %s\n\n' "$RED" "$G_ERR" "$RESET" "$1" >&2
    exit "$code"
}

# Detect the platform and emit the "<os>_<arch>" fragment used in release asset
# filenames. macOS uses macos/arm64|x86_64; Linux uses linux/amd64|arm64 —
# matching the build-binaries CI job.
detect_platform() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$os" in
        darwin) os_label="macos" ;;
        linux)  os_label="linux" ;;
        *) err "Unsupported OS: $os (supported: darwin, linux)" "$EXIT_UNSUPPORTED" ;;
    esac
    case "$arch" in
        x86_64|amd64)
            case "$os_label" in
                macos) arch_label="x86_64" ;;
                *)     arch_label="amd64" ;;
            esac ;;
        arm64|aarch64) arch_label="arm64" ;;
        *) err "Unsupported architecture: $arch (supported: x86_64, arm64)" "$EXIT_UNSUPPORTED" ;;
    esac
    echo "${os_label}_${arch_label}"
}

resolve_rc_file() {
    case "${SHELL:-}" in
        */zsh)  echo "$HOME/.zshrc" ;;
        */bash) echo "$HOME/.bashrc" ;;
        */fish) echo "$HOME/.config/fish/config.fish" ;;
        *)      echo "$HOME/.profile" ;;
    esac
}

_patch_rc() {
    _file="$1"
    if [ -f "$_file" ] && grep -qF "$INSTALL_DIR" "$_file" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$_file")"
    # $PATH is intentionally literal — the rc file expands it at shell startup.
    # shellcheck disable=SC2016
    case "$_file" in
        */config.fish) printf '\nfish_add_path "%s"\n' "$INSTALL_DIR" >> "$_file" ;;
        *)             printf '\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$_file" ;;
    esac
}

ensure_path() {
    rc_file=$(resolve_rc_file)
    _patch_rc "$rc_file"
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [ "$os" = "linux" ] && [ "$rc_file" != "$HOME/.profile" ]; then
        _patch_rc "$HOME/.profile"
    fi
    return 0
}

check_writable() {
    dir="$1"; target="$dir"
    while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
    if [ ! -w "$dir" ]; then
        err "Cannot write to $target ($dir is not writable). Re-run with sudo or set AIRI_CLI_INSTALL_DIR."
    fi
}

compute_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# Verify the download against a published <asset>.sha256 sidecar. If the sidecar
# is absent the check is skipped with a warning rather than failing the install.
verify_checksum() {
    _asset_path="$1"; _asset_url="$2"; _tmp="$3"
    _sum_url="${_asset_url}.sha256"
    _sum_path="${_tmp}/expected.sha256"

    if ! curl -fsSL -o "$_sum_path" "$_sum_url" 2>/dev/null; then
        warn "No checksum published for this release; skipping verification."
        return 0
    fi
    _expected=$(awk '{print $1; exit}' "$_sum_path")
    _actual=$(compute_sha256 "$_asset_path") || err "Neither sha256sum nor shasum available; cannot verify."
    if [ "$_expected" != "$_actual" ]; then
        printf '\n  %s%s%s SHA256 mismatch\n    expected: %s\n    actual:   %s\n\n' \
            "$RED" "$G_ERR" "$RESET" "$_expected" "$_actual" >&2
        err "Refusing to install a tampered or corrupted binary." "$EXIT_CHECKSUM"
    fi
    ok "Checksum OK (${DIM}${_actual}${RESET})"
}

# Deploy the agent skills bundled in the binary into the local AI-agent skill
# directories. Skills are embedded in airi-cli, so this just invokes the CLI.
install_skills() {
    if [ "${AIRI_CLI_SKIP_SKILLS:-0}" = "1" ]; then
        warn "AIRI_CLI_SKIP_SKILLS=1 — skipping skill deployment."
        return 0
    fi
    step "Deploying agent skills"
    # Build optional --dir args from AIRI_CLI_SKILL_DIRS (space-separated).
    set --
    if [ -n "${AIRI_CLI_SKILL_DIRS:-}" ]; then
        for _d in $AIRI_CLI_SKILL_DIRS; do
            set -- "$@" --dir "$_d"
        done
    fi
    if "${INSTALL_DIR}/${BIN_NAME}" --no-telemetry -o text skills install "$@"; then
        return 0
    fi
    warn "Skill deployment failed; you can retry later with: ${BIN_NAME} skills install"
}

main() {
    command -v curl >/dev/null 2>&1 || err "curl is required but not installed"
    command -v tar  >/dev/null 2>&1 || err "tar is required but not installed"

    header

    if [ "$VERSION" = "latest" ]; then
        VERSION="$LATEST_VERSION"
    fi
    step "Version: ${BOLD}${VERSION}${RESET}"

    platform=$(detect_platform)
    asset="${BIN_NAME}_${platform}.tar.gz"
    url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"

    check_writable "$INSTALL_DIR"
    step "Downloading ${asset}"

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/airi-cli.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    if ! curl -fsSL -o "${tmp}/${asset}" "$url"; then
        err "Failed to download from $url" "$EXIT_NETWORK"
    fi

    if [ "$SKIP_CHECKSUM" = "1" ]; then
        warn "AIRI_CLI_SKIP_CHECKSUM=1 — skipping SHA256 verification (local-dev only)."
    else
        verify_checksum "${tmp}/${asset}" "$url" "$tmp"
    fi

    if ! tar -xzf "${tmp}/${asset}" -C "$tmp"; then
        err "Failed to extract ${asset}"
    fi
    if [ ! -f "${tmp}/${BIN_NAME}" ]; then
        err "Archive did not contain expected '${BIN_NAME}' binary"
    fi
    chmod +x "${tmp}/${BIN_NAME}"

    mkdir -p "$INSTALL_DIR"
    mv "${tmp}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    mkdir -p "$STATE_DIR"

    installed_version=$("${INSTALL_DIR}/${BIN_NAME}" --no-telemetry --version 2>/dev/null || echo "${VERSION#v}")
    ok "Installed ${BOLD}${BIN_NAME} ${installed_version}${RESET} to ${DIM}${INSTALL_DIR}/${BIN_NAME}${RESET}"

    install_skills

    case ":$PATH:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            if ensure_path; then
                rc_file=$(resolve_rc_file)
                ok "Added ${BOLD}${INSTALL_DIR}${RESET} to ${BOLD}${rc_file}${RESET}"
                printf '\n  Restart your shell or run:\n    %ssource %s%s\n' "$DIM" "$rc_file" "$RESET"
            else
                # shellcheck disable=SC2016
                printf '\n  %s%s%s %s%s%s is not on your PATH. Add it:\n    %sexport PATH="%s:$PATH"%s\n' \
                    "$YELLOW" "$G_WARN" "$RESET" "$BOLD" "$INSTALL_DIR" "$RESET" "$DIM" "$INSTALL_DIR" "$RESET"
            fi
            ;;
    esac

    printf '\n  Run %s%s --help%s to get started.\n\n' "$BOLD" "$BIN_NAME" "$RESET"
}

main "$@"
