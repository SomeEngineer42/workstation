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
  applications/
    kill-chat-apps.desktop  dash button that pkills Discord and Zoom
  sysctl.d/
    60-inotify.conf    raise inotify watch limits (IDEs + Obsidian ENOSPC)

debian/                apt-based hosts
  provision.sh         backports kernel, CLI tooling, Docker CE, VS Code,
                       Claude Desktop, Chrome, Beyond Compare, apt/journal caps
  bin/update           apt upgrade + local .deb + GlobalProtect + Zoom + Discord

fedora/                dnf-based hosts
  provision.sh         Docker CE, VS Code, prerequisites
  bin/update           dnf upgrade + local .rpm + GlobalProtect + Zoom

install.sh             OS-aware: runs provision.sh, installs and applies
                       sysctl drop-ins into /etc/sysctl.d, then copies scripts
                       into ~/.local/bin, desktop entries into
                       ~/.local/share/applications, and units into
                       ~/.config/systemd/user. Idempotently pins the
                       kill-chat-apps entry to the GNOME dash.
```

## Install

```sh
git clone <this repo> </path/to/checkout>
cd </path/to/checkout>
./install.sh                     # needs sudo
```

The installer detects Debian vs Fedora via `/etc/os-release`, runs the
matching `provision.sh` (installs Docker CE, VS Code, and prerequisites via
the official upstream repos), then **copies** `common/` + the per-OS `bin/`
and systemd units into `~/.local/bin` and `~/.config/systemd/user`.

Files are copied rather than symlinked so the repo can live anywhere and be
moved or deleted after install. To push local edits from the repo, re-run
`./install.sh`. Every step is idempotent — already-installed packages,
existing apt/dnf sources, and up-to-date destination files are all no-ops.

**What provisioning installs**

- Prerequisites: `curl`, `jq`, `git`, `python3`, python GObject bindings
- Docker CE (docker.com repo) + compose plugin; adds `$USER` to `docker` group
- VS Code (Microsoft repo)
- Debian only: kernel and headers from `<codename>-backports`; CLI and build
  tooling; Claude Desktop, Chrome, and Beyond Compare from their vendor repos;
  apt no longer keeps downloaded `.deb`s and the journal is capped at 500M.
  Every package is marked manual so `update`'s `apt autoremove` can't take it.
  Zoom, Discord, and GlobalProtect have no apt repo — run `update` afterwards
  to install them.
- inotify limits raised to 524288 watches / 1024 instances, so IDEs don't
  starve Obsidian and other file watchers (`ENOSPC: System limit for number
  of file watchers reached`). Installed to `/etc/sysctl.d/` and applied
  immediately; Debian 13+ ignores `/etc/sysctl.conf`.

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
2. Add a `<osname>/provision.sh` for system-package setup.
3. Add the OS's ID to `detect_os()` in `install.sh`.
