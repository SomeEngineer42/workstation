#!/usr/bin/env bash
# Provision a Debian/Ubuntu workstation with the packages I always want.
#
# Idempotent: every step checks for prior state before touching the system.
# Safe to re-run.
#
# Scope: everything installable from an apt repo. The sideloaded .debs that
# have no repo at all (Zoom, Discord, GlobalProtect) are handled by
# `debian/bin/update`, which both installs and updates them — run `update`
# after this script on a fresh machine.

set -euo pipefail

BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s ok%s   %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s warn%s %s\n' "$YELLOW" "$RESET" "$1"; }

need_sudo() { sudo -v || { echo "sudo required" >&2; exit 1; }; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

apt_install() {
    # Install whatever is missing, then ALWAYS assert the manual mark.
    #
    # The mark matters: `debian/bin/update` ends with `apt autoremove -y`,
    # and anything we depend on that is only present as an auto-installed
    # dependency of something else is one upstream dependency change away
    # from being silently removed. Marking manual is idempotent and cheap.
    local missing=()
    for p in "$@"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        sudo apt-get install -y "${missing[@]}"
        ok "installed: ${missing[*]}"
    else
        ok "already installed: $*"
    fi
    sudo apt-mark manual "$@" >/dev/null
}

add_key() {
    # add_key <url> <dest> — download and dearmor an apt signing key.
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then
        ok "keyring present ($dest)"
        return
    fi
    sudo install -m 0755 -d "$(dirname "$dest")"
    if [[ "$dest" == *.asc ]]; then
        curl -fsSL "$url" | sudo tee "$dest" >/dev/null
    else
        curl -fsSL "$url" | sudo gpg --dearmor -o "$dest"
    fi
    sudo chmod a+r "$dest"
    ok "installed keyring ($dest)"
}

add_repo() {
    # add_repo <name> <uri> <suites> <components> <keyring> [architectures]
    # Writes a deb822 .sources file. No-op if any source for <name> exists.
    local name="$1" uri="$2" suites="$3" comps="$4" keyring="$5" arch="${6:-amd64}"
    if compgen -G "/etc/apt/sources.list.d/${name}.list" >/dev/null || \
       compgen -G "/etc/apt/sources.list.d/${name}.sources" >/dev/null; then
        ok "$name apt source present"
        return 1
    fi
    {
        echo "Types: deb"
        echo "URIs: $uri"
        echo "Suites: $suites"
        [[ -n "$comps" ]] && echo "Components: $comps"
        echo "Architectures: $arch"
        echo "Signed-By: $keyring"
    } | sudo tee "/etc/apt/sources.list.d/${name}.sources" >/dev/null
    ok "added $name apt source"
    return 0
}

APT_DIRTY=0
refresh() { (( APT_DIRTY )) && { sudo apt-get update -qq; APT_DIRTY=0; }; return 0; }

# ---------- prerequisites ----------
install_prereqs() {
    say "prerequisites"
    sudo apt-get update -qq
    # python3-gi drives fixdisplays (Mutter DBus); jq drives bin/update.
    apt_install ca-certificates curl gnupg jq git python3 python3-gi
}

# ---------- Debian-repo tooling ----------
install_cli_tools() {
    say "CLI tooling"
    apt_install \
        gh git-lfs ripgrep rsync \
        build-essential pkg-config libc6-dev zlib1g-dev \
        libfuse2t64 usbutils pavucontrol
}

# ---------- backports (current kernels) ----------
install_backports() {
    say "Debian backports"
    local codename; codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    local f=/etc/apt/sources.list.d/${codename}-backports.list
    if [[ -f "$f" ]]; then
        ok "backports present"
    else
        echo "deb http://deb.debian.org/debian ${codename}-backports main contrib non-free non-free-firmware" \
            | sudo tee "$f" >/dev/null
        APT_DIRTY=1
        ok "added ${codename}-backports"
    fi
}

install_kernel() {
    say "backports kernel"
    local codename; codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    # Backports is pinned below main, so both metapackages must be requested
    # from it explicitly. Headers alone leave the image on an older kernel.
    sudo apt-get install -y -t "${codename}-backports" linux-image-amd64 linux-headers-amd64
    sudo apt-mark manual linux-image-amd64 linux-headers-amd64 >/dev/null
    ok "kernel tracks ${codename}-backports"
}

# ---------- Docker CE ----------
install_docker() {
    say "Docker CE"
    local codename; codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    local keyring=/etc/apt/keyrings/docker.asc
    [[ -s /etc/apt/keyrings/docker.gpg ]] && keyring=/etc/apt/keyrings/docker.gpg
    add_key https://download.docker.com/linux/debian/gpg "$keyring"
    add_repo docker https://download.docker.com/linux/debian "$codename" stable "$keyring" && APT_DIRTY=1
    refresh
    # No docker-ce-rootless-extras: we use the rootful daemon via the docker group.
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! id -nG "$USER" | grep -qw docker; then
        sudo usermod -aG docker "$USER"
        warn "added $USER to docker group — log out/in (or 'newgrp docker') to use without sudo"
    else
        ok "$USER already in docker group"
    fi
    sudo systemctl enable --now docker.service
    ok "docker service active"
}

# ---------- editors / GUI apps from vendor repos ----------
install_vscode() {
    say "VS Code"
    add_key https://packages.microsoft.com/keys/microsoft.asc /usr/share/keyrings/microsoft.gpg
    add_repo vscode https://packages.microsoft.com/repos/code stable main \
        /usr/share/keyrings/microsoft.gpg && APT_DIRTY=1
    refresh
    apt_install code
}

install_claude_desktop() {
    say "Claude Desktop"
    # The package's postinst writes its own claude-desktop.list unless an
    # entry for this repo already exists, so this source stands in for it.
    add_key https://downloads.claude.ai/keys/claude-code.asc \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc
    add_repo claude-desktop https://downloads.claude.ai/claude-desktop/apt/stable stable main \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc "amd64,arm64" && APT_DIRTY=1
    refresh
    # Recommends (qemu-system-x86, ovmf, virtiofsd) back the Cowork local VM.
    apt_install claude-desktop
}

install_chrome() {
    say "Google Chrome"
    add_key https://dl.google.com/linux/linux_signing_key.pub /usr/share/keyrings/google-chrome.gpg
    add_repo google-chrome https://dl.google.com/linux/chrome-stable/deb/ stable main \
        /usr/share/keyrings/google-chrome.gpg && APT_DIRTY=1
    refresh
    apt_install google-chrome-stable
}

install_bcompare() {
    say "Beyond Compare"
    add_key https://www.scootersoftware.com/RPM-GPG-KEY-scootersoftware \
        /etc/apt/keyrings/scootersoftware.asc
    add_repo scootersoftware https://www.scootersoftware.com/debian/ bcompare5 non-free \
        /etc/apt/keyrings/scootersoftware.asc && APT_DIRTY=1
    refresh
    apt_install bcompare
}

# ---------- system hygiene ----------
configure_hygiene() {
    say "system hygiene"

    # Vendor repos ship ~230 MB .debs and auto-update often; without this the
    # archive cache grows without bound (it reached 25 GB before we caught it).
    local aptconf=/etc/apt/apt.conf.d/99-workstation-cache
    if [[ -f "$aptconf" ]]; then
        ok "apt cache policy present"
    else
        printf 'Binary::apt::APT::Keep-Downloaded-Packages "false";\nAPT::Periodic::MaxAge "30";\n' \
            | sudo tee "$aptconf" >/dev/null
        ok "apt will no longer retain downloaded .debs"
    fi

    # Cap the journal; it had grown to 1.7 GB.
    if grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null; then
        ok "journald size cap present"
    else
        echo 'SystemMaxUse=500M' | sudo tee -a /etc/systemd/journald.conf >/dev/null
        sudo systemctl restart systemd-journald
        ok "capped journal at 500M"
    fi
}

main() {
    [[ -r /etc/os-release ]] || { echo "cannot read /etc/os-release" >&2; exit 1; }
    need_sudo
    install_prereqs
    install_backports
    refresh
    install_kernel
    install_cli_tools
    install_docker
    install_vscode
    install_claude_desktop
    install_chrome
    install_bcompare
    configure_hygiene
    printf '\n%sDone.%s Run %supdate%s to install/refresh Zoom, Discord and GlobalProtect.\n' \
        "$BOLD" "$RESET" "$BOLD" "$RESET"
}

main "$@"
