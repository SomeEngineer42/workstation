# workstation

Personal tooling I want to carry across machines. Supports Debian/Ubuntu and
Fedora hosts running GNOME.

## Layout

```
common/                shared across all machines
  bin/
    fixdisplays        best monitor layout via Mutter DBus (one-shot)
    fixdisplays-watch  runs fixdisplays on Mutter MonitorsChanged
  systemd/user/
    fixdisplays.service

debian/                apt-based hosts
  provision.sh         Docker CE, VS Code, prerequisites
  bin/update           apt upgrade + local .deb + GlobalProtect + Zoom + Discord

fedora/                dnf-based hosts
  provision.sh         Docker CE, VS Code, prerequisites
  bin/update           dnf upgrade + local .rpm + GlobalProtect + Zoom

install.sh             OS-aware: runs provision.sh, then symlinks scripts
                       into ~/.local/bin and units into ~/.config/systemd/user
```

## Install

```sh
git clone <this repo> ~/dev/workstation
cd ~/dev/workstation
./install.sh                     # needs sudo
```

The installer detects Debian vs Fedora via `/etc/os-release`, runs the
matching `provision.sh` (installs Docker CE, VS Code, and prerequisites via
the official upstream repos), then links `common/` + the per-OS `bin/` and
systemd units into `~/.local/bin` and `~/.config/systemd/user`.

Everything is a symlink so repo edits are live. Every step is idempotent —
already-installed packages, existing apt/dnf sources, and correct symlinks
are all no-ops. Re-running is always safe.

**What provisioning installs**

- Prerequisites: `curl`, `jq`, `git`, `python3`, python GObject bindings
- Docker CE (docker.com repo) + compose plugin; adds `$USER` to `docker` group
- VS Code (Microsoft repo)

## What `fixdisplays` does

- Any external monitor present → disable the builtin panel (eDP), enable each
  external at its EDID-preferred (native) resolution and highest refresh,
  laid out left-to-right by connector name. First external is primary.
- No external → enable the builtin at its best mode.
- Idempotent. First application of a target uses Mutter's `TEMPORARY` method
  (no prompt). Repeating the same target within `CONFIRM_WINDOW_SEC` uses
  `PERSISTENT` (Mutter prompts to confirm and writes it into
  `~/.config/monitors.xml`) — the escape hatch for flapping configs.

State: `~/.cache/fixdisplays/history.json` (auto-trimmed).

## Verify

```sh
journalctl --user -u fixdisplays -f    # live log
~/.local/bin/fixdisplays               # apply now
```

## Tuning

- `CONFIRM_WINDOW_SEC` in `common/bin/fixdisplays` — 0 disables the fallback
  prompt entirely.
- `RUN_DELAYS_MS` in `common/bin/fixdisplays-watch` — when to reapply after a
  hotplug event.

## Adding a new OS

1. Create `<osname>/bin/` and drop OS-specific scripts in there.
2. Add the OS's ID to `detect_os()` in `install.sh` and to `check_deps()` if
   the package names differ.
