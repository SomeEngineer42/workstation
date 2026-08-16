#!/usr/bin/env bash
# Provision a Debian/Ubuntu workstation with the packages I always want.
#
# Idempotent: every step checks for prior state before touching the system.
# Safe to re-run.

set -euo pipefail

BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s ok%s   %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s warn%s %s\n' "$YELLOW" "$RESET" "$1"; }

need_sudo() { sudo -v || { echo "sudo required" >&2; exit 1; }; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

apt_install() {
    local missing=()
    for p in "$@"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        ok "already installed: $*"
        return
    fi
    sudo apt-get install -y "${missing[@]}"
    ok "installed: ${missing[*]}"
}

# ---------- prerequisites ----------
install_prereqs() {
    say "prerequisites"
    sudo apt-get update -qq
    apt_install ca-certificates curl gnupg jq git python3 python3-gi
}

# ---------- Docker CE (docker.com repo) ----------
install_docker() {
    say "Docker CE"
    local keyring=/etc/apt/keyrings/docker.gpg

    # Accept either .gpg (our default) or .asc (Docker's newer install docs)
    # to avoid setting up a duplicate keyring alongside an existing one.
    if [[ -s /etc/apt/keyrings/docker.gpg || -s /etc/apt/keyrings/docker.asc ]]; then
        [[ -s /etc/apt/keyrings/docker.asc ]] && keyring=/etc/apt/keyrings/docker.asc
        ok "Docker apt keyring present ($keyring)"
    else
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | \
            sudo gpg --dearmor -o "$keyring"
        sudo chmod a+r "$keyring"
        ok "installed Docker apt keyring ($keyring)"
    fi

    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "$codename" ]] || { echo "cannot detect codename" >&2; exit 1; }

    if compgen -G '/etc/apt/sources.list.d/docker*.list' >/dev/null || \
       compgen -G '/etc/apt/sources.list.d/docker*.sources' >/dev/null; then
        ok "Docker apt source present"
    else
        printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' \
            "$(dpkg --print-architecture)" "$keyring" "$codename" | \
            sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -qq
        ok "added Docker apt source ($codename)"
    fi

    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! getent group docker | grep -qw "$USER"; then
        sudo usermod -aG docker "$USER"
        warn "added $USER to docker group — log out/in (or 'newgrp docker') to use without sudo"
    else
        ok "$USER already in docker group"
    fi

    sudo systemctl enable --now docker.service
    ok "docker service active"
}

# ---------- VS Code (Microsoft apt repo) ----------
install_vscode() {
    say "VS Code"
    local keyring=/etc/apt/keyrings/packages.microsoft.gpg

    if [[ -s /etc/apt/keyrings/packages.microsoft.gpg || -s /etc/apt/keyrings/microsoft.asc ]]; then
        [[ -s /etc/apt/keyrings/microsoft.asc ]] && keyring=/etc/apt/keyrings/microsoft.asc
        ok "Microsoft apt keyring present ($keyring)"
    else
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
            sudo gpg --dearmor -o "$keyring"
        sudo chmod a+r "$keyring"
        ok "installed Microsoft apt keyring"
    fi

    if compgen -G '/etc/apt/sources.list.d/vscode*.list' >/dev/null || \
       compgen -G '/etc/apt/sources.list.d/vscode*.sources' >/dev/null; then
        ok "VS Code apt source present"
    else
        printf 'deb [arch=amd64,arm64,armhf signed-by=%s] https://packages.microsoft.com/repos/code stable main\n' \
            "$keyring" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt-get update -qq
        ok "added VS Code apt source"
    fi

    apt_install code
}

main() {
    if ! [[ -r /etc/os-release ]]; then echo "cannot read /etc/os-release" >&2; exit 1; fi
    need_sudo
    install_prereqs
    install_docker
    install_vscode
    printf '\n%sDone.%s\n' "$BOLD" "$RESET"
}

main "$@"
