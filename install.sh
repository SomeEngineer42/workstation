#!/usr/bin/env bash
# Install workstation tooling on a fresh Debian- or Fedora-based GNOME system.
#
# Runs the OS-specific provision.sh (installs Docker, VS Code, prerequisites),
# installs and applies sysctl drop-ins into /etc/sysctl.d,
# then copies scripts into ~/.local/bin, desktop entries into
# ~/.local/share/applications, and systemd units into
# ~/.config/systemd/user, makes gcr-ssh-agent the only SSH agent, and enables
# the fixdisplays service.
#
# Everything is COPIED, not symlinked, so the repo can live anywhere and can
# be moved or deleted after install. To push local edits from the repo,
# re-run this script.
#
# Every step is idempotent — already-installed packages, existing apt/dnf
# sources, and up-to-date destination files are all no-ops.
#
# Layout:
#   common/            shared across all machines (fixdisplays, service,
#                      dash desktop entries, sysctl drop-ins)
#   debian/            Debian/Ubuntu-only (provision, update)
#   fedora/            Fedora-only (provision, update)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="$HOME/.local/bin"
UNIT_DST="$HOME/.config/systemd/user"
APPS_DST="$HOME/.local/share/applications"

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

install_sysctl() {
    # install_sysctl <src_dir> — copy *.conf into /etc/sysctl.d and apply
    # each one that changed, so no reboot is needed.
    local src_dir="$1"
    [[ -d "$src_dir" ]] || return 0
    shopt -s nullglob
    for f in "$src_dir"/*.conf; do
        local dst="/etc/sysctl.d/$(basename "$f")"
        if [[ -f "$dst" ]] && cmp -s "$f" "$dst"; then
            ok "$dst (up to date)"
            continue
        fi
        sudo install -m 0644 "$f" "$dst"
        sudo sysctl -q -p "$dst"
        ok "installed and applied $dst"
    done
    shopt -u nullglob
}

provision() {
    local os="$1"
    local script="$REPO_DIR/$os/provision.sh"
    [[ -x "$script" ]] || die "no provision script for $os at $script"
    say "provisioning ($os)"
    "$script"
}

pin_to_dash() {
    # pin_to_dash <desktop-file-basename> — append entry to
    # org.gnome.shell.favorite-apps if missing. Leaves order alone otherwise
    # so the user can drag pins around without us clobbering it.
    local entry="$1"
    if ! command -v gsettings >/dev/null; then
        warn "gsettings not found; skipping dash pin for $entry"
        return
    fi
    local current
    current="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo '[]')"
    if [[ "$current" == *"'$entry'"* ]]; then
        ok "dash favorite $entry (already pinned)"
        return
    fi
    local updated
    if [[ "$current" == "[]" || "$current" == "@as []" ]]; then
        updated="['$entry']"
    else
        updated="${current%]}, '$entry']"
    fi
    gsettings set org.gnome.shell favorite-apps "$updated"
    ok "pinned $entry to dash"
}

main() {
    local os
    os="$(detect_os)"
    say "detected OS: $os"

    provision "$os"

    say "installing common sysctl settings into /etc/sysctl.d"
    install_sysctl "$REPO_DIR/common/sysctl.d"

    say "installing common scripts into $BIN_DST"
    install_dir "$REPO_DIR/common/bin" "$BIN_DST"

    say "installing $os scripts into $BIN_DST"
    install_dir "$REPO_DIR/$os/bin" "$BIN_DST"

    say "making gcr-ssh-agent the only SSH agent"
    "$BIN_DST/ssh-agent-check" --fix || warn "ssh agent setup incomplete; see above"

    say "installing common desktop entries into $APPS_DST"
    install_dir "$REPO_DIR/common/applications" "$APPS_DST"
    pin_to_dash "kill-chat-apps.desktop"

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
