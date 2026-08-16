#!/usr/bin/env bash
# Install workstation tooling on a fresh Debian- or Fedora-based GNOME system.
#
# Runs the OS-specific provision.sh (installs Docker, VS Code, prerequisites)
# then symlinks scripts into ~/.local/bin and systemd units into
# ~/.config/systemd/user, and enables the fixdisplays service. Everything is
# symlinked so edits in the repo are live.
#
# Provisioning and symlinking are both idempotent — steps that are already
# done are skipped, so this is safe to re-run at any time.
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

link() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" && "$(readlink -f "$dst" || true)" == "$(readlink -f "$src")" ]]; then
        ok "$dst -> $src (already linked)"
        return
    fi
    if [[ -e "$dst" || -L "$dst" ]]; then
        local backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
        mv "$dst" "$backup"
        warn "moved existing $dst -> $backup"
    fi
    ln -s "$src" "$dst"
    ok "linked $dst -> $src"
}

link_dir() {
    # link_dir <src_dir> <dst_dir> — link each regular file inside src_dir.
    local src_dir="$1" dst_dir="$2"
    [[ -d "$src_dir" ]] || return 0
    shopt -s nullglob
    local any=0
    for f in "$src_dir"/*; do
        [[ -f "$f" ]] || continue
        link "$f" "$dst_dir/$(basename "$f")"
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

    say "linking common scripts into $BIN_DST"
    link_dir "$REPO_DIR/common/bin" "$BIN_DST"

    say "linking $os scripts into $BIN_DST"
    link_dir "$REPO_DIR/$os/bin" "$BIN_DST"

    say "linking common systemd user units into $UNIT_DST"
    link_dir "$REPO_DIR/common/systemd/user" "$UNIT_DST"

    if [[ -d "$REPO_DIR/$os/systemd/user" ]]; then
        say "linking $os systemd user units into $UNIT_DST"
        link_dir "$REPO_DIR/$os/systemd/user" "$UNIT_DST"
    fi

    say "enabling fixdisplays.service"
    systemctl --user daemon-reload
    systemctl --user enable --now fixdisplays.service
    ok "service active"

    printf '\n%sDone.%s Ensure %s%s%s is on your PATH.\n' \
        "$BOLD" "$RESET" "$DIM" "$BIN_DST" "$RESET"
}

main "$@"
