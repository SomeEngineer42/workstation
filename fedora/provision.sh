#!/usr/bin/env bash
# Provision a Fedora workstation with the packages I always want.
#
# Idempotent: every step checks for prior state before touching the system.
# Safe to re-run.

set -euo pipefail

BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s ok%s   %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s warn%s %s\n' "$YELLOW" "$RESET" "$1"; }

need_sudo() { sudo -v || { echo "sudo required" >&2; exit 1; }; }

pkg_installed() { rpm -q "$1" &>/dev/null; }

dnf_install() {
    local missing=()
    for p in "$@"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        ok "already installed: $*"
        return
    fi
    sudo dnf install -y "${missing[@]}"
    ok "installed: ${missing[*]}"
}

# ---------- prerequisites ----------
install_prereqs() {
    say "prerequisites"
    dnf_install curl jq git python3 python3-gobject dnf-plugins-core
}

# ---------- Docker CE (docker.com repo) ----------
# Note: Fedora also ships podman/moby-engine. We explicitly install Docker CE
# from docker.com since that's what was requested.
install_docker() {
    say "Docker CE"
    local repofile=/etc/yum.repos.d/docker-ce.repo

    if ! [[ -f "$repofile" ]]; then
        sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
        ok "added Docker dnf repo"
    else
        ok "Docker dnf repo present"
    fi

    # If moby-engine or podman-docker is installed, dnf will resolve conflicts;
    # we don't force-remove them.
    dnf_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! getent group docker | grep -qw "$USER"; then
        sudo usermod -aG docker "$USER"
        warn "added $USER to docker group — log out/in (or 'newgrp docker') to use without sudo"
    else
        ok "$USER already in docker group"
    fi

    sudo systemctl enable --now docker.service
    ok "docker service active"
}

# ---------- VS Code (Microsoft dnf repo) ----------
install_vscode() {
    say "VS Code"
    local repofile=/etc/yum.repos.d/vscode.repo

    if ! rpm -q gpg-pubkey --qf '%{summary}\n' | grep -q 'Microsoft'; then
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        ok "imported Microsoft GPG key"
    else
        ok "Microsoft GPG key present"
    fi

    if ! [[ -f "$repofile" ]]; then
        sudo tee "$repofile" >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
        ok "added VS Code dnf repo"
    else
        ok "VS Code dnf repo present"
    fi

    dnf_install code
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
