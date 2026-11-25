# install-software

Idempotent bootstrap script that rebuilds a known software set on Ubuntu, Debian, Fedora, Arch, openSUSE, and Alpine.

It installs a fixed list of system packages and user-level tools, skipping anything already present.

## What it installs

**System packages (distro-mapped):** `openssh`, `git`, `zsh`, `less`, `nano`, `sudo`, `curl`, `ca-certificates`, `man-db`, `groff`, `logrotate`, `perl`, `mailcap`, `openssl`, `vim`, `sysfsutils`, `texinfo`, plus `github-cli` and `tailscale`.

**User-level tools (into `~/.local`):** Claude Code CLI, Oh My Zsh, Mole CLI, magpie, purple, rtk, and pi agent when a source is provided.

Arch-specific items from the original inventory (kernel, keyring, `netctl`, firmware, side-by-side `openssl-3`) are intentionally not installed; the script explains why.

## Usage

```bash
./install-software.sh --dry-run          # preview only, changes nothing
./install-software.sh                    # system + user software
./install-software.sh --system-only
./install-software.sh --user-only
./install-software.sh --set-shell        # also switch login shell to zsh
./install-software.sh --force            # ignore "already present" checks
./install-software.sh --no-upgrade       # Arch: -Sy instead of full -Syu
./install-software.sh --artifacts DIR    # copy private binaries from DIR
```

### Already-installed detection

| Layer | Detection |
|---|---|
| System packages | package DB (`dpkg`/`rpm`/`pacman`/`apk`) or the corresponding command |
| `gh`, `tailscale` | command exists |
| `claude`, `purple`, `rtk`, `magpie` | command in PATH, `~/.local/bin`, or `/usr/local/bin` |
| `mole` | command or `~/.local/share/mole/mole` |
| Oh My Zsh | `~/.oh-my-zsh` |
| pi agent | `~/.pi/agent/bin/pi` |

Only missing packages are handed to the package manager. `--force` bypasses these checks.

### Private tools without public URLs

`magpie`, `purple`, `rtk`, and `pi` may not have public installers. Provide them via:

```bash
MAGPIE_URL=https://... PURPLE_URL=https://... ./install-software.sh
# or, from a machine with the same architecture:
mkdir -p art && cp ~/.local/bin/{magpie,purple,rtk} art/
cp -a ~/.pi/agent art/pi-home
cp -a ~/.local/share/pi-node art/pi-node
./install-software.sh --user-only --artifacts ./art
```

## Security notes

- Installer scripts are downloaded over HTTPS to a temp directory and executed (never `curl | sh`). For offline or audited environments, use `--artifacts` or point the `*_URL` variables at `file://` paths.
- On Arch, a full `pacman -Syu` is run when packages are missing, because a partial upgrade is unsafe. It prints a warning first; pass `--no-upgrade` to opt out.
- This script was validated with `bash -n`, `--dry-run`, and simulated package failures. It has not been executed end-to-end on every supported distribution.

## Manual follow-ups

```bash
sudo tailscale up        # Tailscale login
gh auth login            # GitHub login
gh auth setup-git        # git credentials for gh
```