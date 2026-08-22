#!/usr/bin/env bash
# Install workstation tooling on a fresh Debian- or Fedora-based GNOME system.
#
# Runs the OS-specific provision.sh (installs Docker, VS Code, prerequisites)
# then copies scripts into ~/.local/bin and systemd units into
# ~/.config/systemd/user, and enables the fixdisplays service.
#
# Everything is COPIED, not symlinked, so the repo can live anywhere and can
# be moved or deleted after install. To push local edits from the repo,
# re-run this script.
#
# Every step is idempotent — already-installed packages, existing apt/dnf
# sources, and up-to-date destination files are all no-ops.
#
# Layout:
#   common/            shared across all machines (fixdisplays, service)
#   debian/            Debian/Ubuntu-only (provision, update)
#   fedora/            Fedora-only (provision, update)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="$HOME/.local/bin"
UNIT_DST="$HOME/.config/systemd/user"

BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s ok%s   %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s warn%s %s\n' "$YELLOW" "$RESET" "$1"; }
die()  { printf '%serror%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        die "cannot read /etc/os-release"
    fi
    . /etc/os-release
    local ids="${ID:-} ${ID_LIKE:-}"
    case " $ids " in
        *" debian "*|*" ubuntu "*) echo "debian" ;;
        *" fedora "*|*" rhel "*)   echo "fedora" ;;
        *) die "unsupported OS: ID=$ID ID_LIKE=${ID_LIKE:-}" ;;
    esac
}

install_file() {
    # install_file <src> <dst> [mode]
    #   - If dst is a stale symlink or differs from src, back it up first.
    #   - No-op when src and dst already have identical content.
    local src="$1" dst="$2" mode="${3:-preserve}"
    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
        local backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
        mv "$dst" "$backup"
        warn "replaced symlink $dst (backup: $backup)"
    fi

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        ok "$dst (up to date)"
        return
    fi

    if [[ -f "$dst" ]]; then
        local backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$dst" "$backup"
        warn "backed up $dst -> $backup"
    fi

    if [[ "$mode" == "preserve" ]]; then
        install -m "$(stat -c '%a' "$src")" "$src" "$dst"
    else
        install -m "$mode" "$src" "$dst"
    fi
    ok "installed $dst"
}

install_dir() {
    # install_dir <src_dir> <dst_dir> — copy each regular file into place.
    local src_dir="$1" dst_dir="$2"
    [[ -d "$src_dir" ]] || return 0
    shopt -s nullglob
    local any=0
    for f in "$src_dir"/*; do
        [[ -f "$f" ]] || continue
        install_file "$f" "$dst_dir/$(basename "$f")"
        any=1
    done
    shopt -u nullglob
    (( any )) || warn "no files in $src_dir"
}

provision() {
    local os="$1"
    local script="$REPO_DIR/$os/provision.sh"
    [[ -x "$script" ]] || die "no provision script for $os at $script"
    say "provisioning ($os)"
    "$script"
}

main() {
    local os
    os="$(detect_os)"
    say "detected OS: $os"

    provision "$os"

    say "installing common scripts into $BIN_DST"
    install_dir "$REPO_DIR/common/bin" "$BIN_DST"

    say "installing $os scripts into $BIN_DST"
    install_dir "$REPO_DIR/$os/bin" "$BIN_DST"

    say "installing common systemd user units into $UNIT_DST"
    install_dir "$REPO_DIR/common/systemd/user" "$UNIT_DST"

    if [[ -d "$REPO_DIR/$os/systemd/user" ]]; then
        say "installing $os systemd user units into $UNIT_DST"
        install_dir "$REPO_DIR/$os/systemd/user" "$UNIT_DST"
    fi

    say "enabling fixdisplays.service"
    systemctl --user daemon-reload
    systemctl --user enable --now fixdisplays.service
    # Restart to pick up any script changes we just installed.
    systemctl --user restart fixdisplays.service
    ok "service active"

    printf '\n%sDone.%s Ensure %s%s%s is on your PATH.\n' \
        "$BOLD" "$RESET" "$DIM" "$BIN_DST" "$RESET"
}

main "$@"
