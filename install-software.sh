#!/usr/bin/env bash
# ============================================================================
# install-software.sh
# Rebuild the software list from /home/a/installed-software-2026-11-25.md on
# Ubuntu / Debian / Fedora / Arch / openSUSE / Alpine.
#
# Usage:
#   ./install-software.sh                  # install system packages + user software
#   ./install-software.sh --dry-run        # print actions only, change nothing
#   ./install-software.sh --system-only    # system packages only
#   ./install-software.sh --user-only      # user-level software only
#   ./install-software.sh --artifacts DIR  # copy binaries with no public download
#   ./install-software.sh --set-shell      # also switch login shell to zsh
#   ./install-software.sh --force          # ignore "already present" checks
#   ./install-software.sh --no-upgrade     # Arch: refresh DB only, no full -Syu
#   ./install-software.sh --help
#
# Programs without a public download source can be supplied via env vars
# (https:// or file://):
#   CLAUDE_INSTALL_URL  TAILSCALE_INSTALL_URL  OMZ_INSTALL_URL  MOLE_REPO
#   MAGPIE_URL  PURPLE_URL  RTK_URL  PI_INSTALL_URL
#
# Security:
#   By default this script downloads official install scripts over HTTPS and
#   runs them. For offline or audited environments, either:
#     1) copy binaries from the source machine with --artifacts (same arch), or
#     2) download and verify them yourself, then point *_URL at file:// paths.
#
# Idempotency: existing packages, commands and directories are skipped;
#              use --force to reinstall over them.
# ============================================================================
set -euo pipefail

# ----------------------------- constants / defaults -------------------------
MARKER="# managed by install-software.sh (installed-software-2026-11-25.md)"
DRY_RUN=0
DO_SYSTEM=1
DO_USER=1
SET_SHELL=0
FORCE=0
UPGRADE=1
SKIP_COUNT=0
ARTIFACTS=""

CLAUDE_INSTALL_URL="${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}"
TAILSCALE_INSTALL_URL="${TAILSCALE_INSTALL_URL:-https://tailscale.com/install.sh}"
OMZ_INSTALL_URL="${OMZ_INSTALL_URL:-https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh}"
MOLE_REPO="${MOLE_REPO:-https://github.com/tw93/Mole}"
MOLE_BRANCH="${MOLE_BRANCH:-linux}"   # upstream main is macOS; Linux lives on 'linux'
MAGPIE_URL="${MAGPIE_URL:-}"
PURPLE_URL="${PURPLE_URL:-}"
RTK_URL="${RTK_URL:-}"
PI_INSTALL_URL="${PI_INSTALL_URL:-}"

# Colors (automatically disabled when not a terminal)
if [ -t 1 ]; then
  C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

log()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT+1)); printf '  - %s\n' "$*"; }
die()  { printf '%sError:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ----------------------------- argument parsing -----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --system-only)  DO_USER=0 ;;
    --user-only)    DO_SYSTEM=0 ;;
    --set-shell)    SET_SHELL=1 ;;
    --force)        FORCE=1 ;;
    --no-upgrade)   UPGRADE=0 ;;
    --artifacts)    shift; [ $# -gt 0 ] || die "--artifacts requires a directory argument"; ARTIFACTS=$1 ;;
    -h|--help)      usage ;;
    *)              die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# Reject a combination that would silently do nothing
if [ "$DO_SYSTEM" -eq 0 ] && [ "$DO_USER" -eq 0 ]; then
  die "--system-only and --user-only cannot be combined"
fi

# Let this run discover user-level installs (current process only; no config changes)
export PATH="$HOME/.local/bin:$HOME/.pi/agent/bin:$PATH"

# ----------------------------- execution wrappers ---------------------------
SUDO=()
if [ "$(id -u)" -eq 0 ]; then
  [ "$DO_USER" -eq 1 ] && warn "Running as root; user-level software will be installed under /root"
elif [ "$DO_SYSTEM" -eq 1 ]; then
  command -v sudo >/dev/null 2>&1 \
    || die "System packages require root or sudo (use --user-only to install user software only)"
  SUDO=(sudo)
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry]'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Command may live in /usr/sbin or /sbin, outside a normal user's PATH
have_any() {
  command -v "$1" >/dev/null 2>&1 \
    || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ]
}

# Safely read the first line of version output (avoids SIGPIPE exit under pipefail)
first_line() {
  local s=""
  s=$("$@" 2>/dev/null) || s=""
  printf '%s' "${s%%$'\n'*}"
  return 0
}

# Run a downloaded installer: prefer bash, fall back to sh
SCRIPT_RUNNER=sh
if have bash; then SCRIPT_RUNNER=bash; fi

# ---------------------------------------------------------------------------
# "Already present" detection: installed by the package manager, or the
# corresponding program/file is ready, counts as present.
# ---------------------------------------------------------------------------
pkg_installed() {
  local p=$1
  case "$PM" in
    apt)        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf|zypper) rpm -q "$p" >/dev/null 2>&1 ;;
    pacman)     pacman -Qq "$p" >/dev/null 2>&1 ;;
    apk)        apk info -e "$p" >/dev/null 2>&1 ;;
    *)          return 1 ;;
  esac
}

# Probe rules where the package name differs from the command name
pkg_probe() {
  local p=$1
  case "$p" in
    openssh|openssh-client|openssh-clients) have_any ssh ;;
    openssh-server)                          have_any sshd ;;
    ca-certificates)                         [ -f /etc/ssl/certs/ca-certificates.crt ] || have_any update-ca-certificates ;;
    man-db|man-pages|manpages)               have_any man ;;
    mailcap)                                 [ -f /etc/mailcap ] ;;
    texinfo)                                 have_any makeinfo || have_any texi2any ;;
    sysfsutils)                              have_any systool ;;
    github-cli|gh)                           have_any gh ;;
    vim)                                     have_any vim ;;
    *)                                       have_any "$p" ;;
  esac
}

is_present() {
  [ "$FORCE" -eq 1 ] && return 1
  pkg_installed "$1" && return 0
  pkg_probe "$1" && return 0
  return 1
}

# User-level program: present if found in PATH, ~/.local/bin or /usr/local/bin
path_present() {
  local n=$1
  [ "$FORCE" -eq 1 ] && return 1
  have_any "$n" && return 0
  [ -x "$HOME/.local/bin/$n" ] && return 0
  [ -x "/usr/local/bin/$n" ] && return 0
  return 1
}

# Download an installer into a temp dir and run it (never curl | sh)
fetch_exec() {
  local url=$1; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] download and run installer: %s\n' "$url"
    return 0
  fi
  have curl || die "curl is required to download $url"
  local d; d=$(mktemp -d)
  if ! curl -fsSL "$url" -o "$d/install.sh"; then
    rm -rf "$d"; die "Download failed: $url"
  fi
  ok "Downloaded $url ($(wc -c <"$d/install.sh") bytes), running it"
  if ! "$SCRIPT_RUNNER" "$d/install.sh" "$@"; then
    rm -rf "$d"
    return 1
  fi
  rm -rf "$d"
  return 0
}

# Download a single binary
fetch_binary() {
  local url=$1 dest=$2
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] download binary %s -> %s\n' "$url" "$dest"
    return 0
  fi
  have curl || die "curl is required to download $url"
  curl -fsSL "$url" -o "$dest.tmp"
  chmod 755 "$dest.tmp"
  mv "$dest.tmp" "$dest"
  ok "Installed $(basename "$dest")"
}

# ----------------------------- distro detection -----------------------------
detect_distro() {
  PM=""
  if   have apt-get; then PM=apt
  elif have dnf;     then PM=dnf
  elif have pacman;  then PM=pacman
  elif have zypper;  then PM=zypper
  elif have apk;     then PM=apk
  else die "Unsupported package manager (supported: apt / dnf / pacman / zypper / apk)"
  fi
  DISTRO="unknown distro"
  if [ -r /etc/os-release ]; then
    DISTRO=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
  fi
  ARCH=$(uname -m)
  log "Target system: $DISTRO ($ARCH), package manager: $PM"
}

# ----------------------------- package manager wrappers ---------------------
pkg_refresh() {
  case "$PM" in
    apt)    run "${SUDO[@]}" apt-get update -y ;;
    dnf)    run "${SUDO[@]}" dnf -y makecache ;;
    pacman)
      if [ "$UPGRADE" -eq 1 ]; then
        warn "pacman: full system upgrade (-Syu) to avoid a partial-upgrade state"
        run "${SUDO[@]}" pacman -Syu --noconfirm
      else
        warn "pacman: --no-upgrade set; refreshing the database only (-Sy). A partial upgrade can break the system."
        run "${SUDO[@]}" pacman -Sy --noconfirm
      fi ;;
    zypper) run "${SUDO[@]}" zypper --non-interactive refresh ;;
    apk)    run "${SUDO[@]}" apk update ;;
  esac
}

pkg_install() {
  [ $# -gt 0 ] || return 0
  case "$PM" in
    apt)    run "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf)    run "${SUDO[@]}" dnf install -y "$@" ;;
    pacman) run "${SUDO[@]}" pacman -S --needed --noconfirm "$@" ;;
    zypper) run "${SUDO[@]}" zypper --non-interactive install "$@" ;;
    apk)    run "${SUDO[@]}" apk add "$@" ;;
  esac
}

# Per-distro name differences: openssh -> client+server, github-cli -> gh
system_packages() {
  case "$PM" in
    apt)    PKGS=(openssh-client openssh-server git zsh less nano sudo curl
                  ca-certificates man-db groff logrotate perl mailcap openssl
                  vim sysfsutils texinfo) ;;
    dnf)    PKGS=(openssh-clients openssh-server git zsh less nano sudo curl
                  ca-certificates man-db groff logrotate perl mailcap openssl
                  vim sysfsutils texinfo) ;;
    pacman) PKGS=(openssh git zsh less nano sudo curl ca-certificates man-db
                  groff logrotate perl mailcap openssl vim sysfsutils texinfo) ;;
    zypper) PKGS=(openssh git zsh less nano sudo curl ca-certificates man-db
                  groff logrotate perl mailcap openssl vim sysfsutils texinfo) ;;
    apk)    PKGS=(openssh git zsh less nano sudo curl ca-certificates man-db
                  groff logrotate perl mailcap openssl vim sysfsutils texinfo) ;;
  esac
}

# GitHub CLI: official repo on Debian/Ubuntu, distro package elsewhere
install_gh() {
  if [ "$FORCE" -eq 0 ] && have_any gh; then
    skip "github-cli (gh) already present: $(first_line gh --version)"
    return 0
  fi
  if [ "$PM" = pacman ]; then
    pkg_install github-cli || warn "Failed to install github-cli; continuing"
    return 0
  fi
  if [ "$PM" != apt ]; then
    pkg_install gh || warn "gh not available in distro repos; see https://github.com/cli/cli#installation"
    return 0
  fi

  log "Installing GitHub CLI (official apt repo)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] add cli.github.com official apt repo and install gh\n'
    return 0
  fi
  have curl || { warn "curl is required; skipping gh"; return 0; }
  local d; d=$(mktemp -d)
  if ! curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$d/key.gpg" \
     || ! run "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings \
     || ! run "${SUDO[@]}" install -m 0644 "$d/key.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
    warn "Failed to set up the GitHub CLI apt repo; continuing"
    rm -rf "$d"
    return 0
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" > "$d/github-cli.list"
  if ! run "${SUDO[@]}" install -m 0644 "$d/github-cli.list" /etc/apt/sources.list.d/github-cli.list \
     || ! run "${SUDO[@]}" apt-get update -y \
     || ! run "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y gh; then
    warn "Failed to install gh; continuing"
  fi
  rm -rf "$d"
}

install_tailscale() {
  if [ "$FORCE" -eq 0 ] && have_any tailscale; then
    skip "tailscale already present: $(first_line tailscale version)"
    return 0
  fi
  log "Installing Tailscale (official installer, distro-aware)"
  fetch_exec "$TAILSCALE_INSTALL_URL" || warn "Tailscale install failed; continuing"
}

report_nonportable() {
  cat <<'EOF'
  The following list items are Arch/machine specific with no generic package;
  this script does not install them:
    base, archlinuxarm-keyring, linux-aarch64, linux-firmware-amd/ti
        -> kernel and firmware are managed by the target distribution
    netctl               -> replaced by NetworkManager or systemd-networkd
    ex-vi-compat, which, inetutils
        -> provided by the distro (vi / util-linux / net-tools); not needed
    openssl-3 (side-by-side with the main package)
        -> Ubuntu 22.04+/Debian 12+ ship OpenSSL 3.x by default;
           upgrade the distro instead of installing a parallel copy
EOF
}

# ----------------------------- system install -------------------------------
install_system() {
  log "Stage 1/2: system packages"
  system_packages
  local p
  local -a need=()
  if [ "$FORCE" -eq 1 ]; then
    warn "--force: ignoring \"already present\" checks, reinstalling everything"
    need=("${PKGS[@]}")
  else
    for p in "${PKGS[@]}"; do
      if is_present "$p"; then
        skip "$p already present"
      else
        need+=("$p")
      fi
    done
  fi

  if [ ${#need[@]} -gt 0 ]; then
    log "Installing ${#need[@]} package(s): ${need[*]}"
    pkg_refresh
    # A single bad package must not abort the whole run
    if ! pkg_install "${need[@]}"; then
      warn "Batch install failed; retrying each package separately"
      local -a failed=()
      for p in "${need[@]}"; do
        if ! pkg_install "$p"; then
          failed+=("$p")
          warn "Failed to install: $p"
        fi
      done
      if [ ${#failed[@]} -gt 0 ]; then
        warn "Still missing: ${failed[*]}"
      fi
    fi
  else
    ok "All system packages already present; skipping package manager install"
  fi

  install_gh
  install_tailscale
  report_nonportable

  if have openssl; then
    local v; v=$(openssl version 2>/dev/null || true)
    case "$v" in
      "OpenSSL 1."*) warn "Current: $v; the list requires OpenSSL 3.x - consider Ubuntu 22.04+/Debian 12+" ;;
      *)             ok "OpenSSL: $v" ;;
    esac
  fi
}

# ----------------------------- user-level install ---------------------------
ensure_local_bin_dir() {
  run mkdir -p "$HOME/.local/bin"
}

# Persist both user-level PATH entries. Must run after Oh My Zsh, because its
# fresh .zshrc (with a *commented* PATH line) does not exist before that.
ensure_path_persisted() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] persist ~/.local/bin and ~/.pi/agent/bin in shell rc files\n'
    return 0
  fi
  [ "$HOME" = "/root" ] && return 0

  local rc existed=0
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    existed=1
    if ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*\.local/bin' "$rc"; then
      printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$MARKER" >> "$rc"
      ok "Appended ~/.local/bin to PATH in $rc"
    fi
    if ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*\.pi/agent/bin' "$rc"; then
      printf '%s\nexport PATH="$HOME/.pi/agent/bin:$PATH"\n' "$MARKER" >> "$rc"
      ok "Appended ~/.pi/agent/bin to PATH in $rc"
    fi
  done

  if [ "$existed" -eq 0 ]; then
    if have zsh; then rc="$HOME/.zshrc"; else rc="$HOME/.bashrc"; fi
    printf '%s\nexport PATH="$HOME/.local/bin:$HOME/.pi/agent/bin:$PATH"\n' "$MARKER" > "$rc"
    ok "Created $rc with user-level PATH entries"
  fi
}

# Uniform handling for private programs: artifacts -> URL -> warning
install_user_program() {
  local name=$1 url=$2 envname=$3 v=""
  if path_present "$name"; then
    if have "$name"; then v=$(first_line "$name" --version); fi
    skip "$name already present${v:+: $v}"
    return 0
  fi
  if [ -n "$ARTIFACTS" ] && [ -f "$ARTIFACTS/$name" ]; then
    run install -Dm755 "$ARTIFACTS/$name" "$HOME/.local/bin/$name"
    ok "Copied $name from $ARTIFACTS"
    return 0
  fi
  if [ -n "$url" ]; then
    fetch_binary "$url" "$HOME/.local/bin/$name"
    return 0
  fi
  warn "Skipping $name: no public download URL. Use --artifacts DIR, or set $envname=<https|file URL>"
  MISSING+=("$name")
}

install_claude() {
  if path_present claude; then
    skip "claude already present: $(first_line claude --version)"
    return 0
  fi
  log "Installing Claude Code CLI (official installer, into ~/.local)"
  fetch_exec "$CLAUDE_INSTALL_URL"
}

install_ohmyzsh() {
  if [ "$FORCE" -eq 0 ] && [ -d "$HOME/.oh-my-zsh" ]; then skip "Oh My Zsh already present"; return 0; fi
  log "Installing Oh My Zsh (no shell change, .zshrc preserved)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] download and run %s (RUNZSH=no CHSH=no)\n' "$OMZ_INSTALL_URL"
    return 0
  fi
  have curl || die "curl is required"
  local d; d=$(mktemp -d)
  curl -fsSL "$OMZ_INSTALL_URL" -o "$d/install.sh"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes "$SCRIPT_RUNNER" "$d/install.sh" || warn "Oh My Zsh installer returned non-zero; check its output"
  rm -rf "$d"
}

install_mole() {
  if [ "$FORCE" -eq 0 ] && { path_present mole || [ -x "$HOME/.local/share/mole/mole" ]; }; then
    local mv=""
    if have mole; then mv=$(first_line mole --version); fi
    skip "mole already present${mv:+: $mv}"
    return 0
  fi
  log "Installing Mole CLI (clone $MOLE_REPO branch $MOLE_BRANCH, then run install.sh)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] git clone --depth 1 --branch %s %s <tmp> && %s <tmp>/install.sh\n' \
      "$MOLE_BRANCH" "$MOLE_REPO" "$SCRIPT_RUNNER"
    return 0
  fi
  have git || die "git is required to install mole"
  local d; d=$(mktemp -d)
  git clone --depth 1 --branch "$MOLE_BRANCH" "$MOLE_REPO" "$d/Mole"
  ( cd "$d/Mole" && "$SCRIPT_RUNNER" ./install.sh )
  rm -rf "$d"
  # The list also provides the `mo` entry point for mole
  if have mole && ! have mo; then
    run ln -sf "$HOME/.local/bin/mole" "$HOME/.local/bin/mo" || true
    if [ -f "$HOME/.local/share/mole/mole" ]; then
      run ln -sf "$HOME/.local/share/mole/mole" "$HOME/.local/bin/mo" || true
    fi
  fi
}

install_magpie() {
  install_user_program magpie "$MAGPIE_URL" MAGPIE_URL
  if have magpie; then
    log "Registering the magpie user service and login autostart"
    run magpie daemon install || warn "magpie daemon install failed; you can run it manually"
    run magpie autostart on  || warn "magpie autostart on failed; you can run it manually"
  fi
}

install_pi() {
  if [ "$FORCE" -eq 0 ] && { [ -x "$HOME/.pi/agent/bin/pi" ] || have pi; }; then
    skip "pi agent already present"
    return 0
  fi
  if [ -n "$PI_INSTALL_URL" ]; then
    log "Installing pi agent ($PI_INSTALL_URL)"
    fetch_exec "$PI_INSTALL_URL"
    return 0
  fi
  # Fallback: restore the agent and its bundled Node runtime from artifacts
  if [ -n "$ARTIFACTS" ] && { [ -d "$ARTIFACTS/pi-home" ] || [ -d "$ARTIFACTS/pi-node" ]; }; then
    if [ -d "$ARTIFACTS/pi-home" ]; then
      run mkdir -p "$HOME/.pi/agent"
      run cp -a "$ARTIFACTS/pi-home/." "$HOME/.pi/agent/"
      ok "Restored ~/.pi/agent from $ARTIFACTS/pi-home"
    fi
    if [ -d "$ARTIFACTS/pi-node" ]; then
      run mkdir -p "$HOME/.local/share/pi-node"
      run cp -a "$ARTIFACTS/pi-node/." "$HOME/.local/share/pi-node/"
      ok "Restored ~/.local/share/pi-node from $ARTIFACTS/pi-node"
    else
      warn "No $ARTIFACTS/pi-node found; pi may not start without its bundled Node runtime"
    fi
    return 0
  fi
  warn "Skipping pi: no public install URL. Pack ~/.pi/agent as <artifacts>/pi-home and ~/.local/share/pi-node as <artifacts>/pi-node on the source machine, then restore with --artifacts"
  MISSING+=("pi")
}

install_user() {
  log "Stage 2/2: user-level software (~/.local/bin, etc.)"
  ensure_local_bin_dir
  install_claude
  install_ohmyzsh
  ensure_path_persisted
  install_mole
  install_magpie
  install_user_program purple "$PURPLE_URL" PURPLE_URL
  install_user_program rtk "$RTK_URL" RTK_URL
  install_pi

  if [ "$SET_SHELL" -eq 1 ]; then
    log "Switching the login shell to zsh"
    if have zsh; then
      if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry] chsh -s %s %s\n' "$(command -v zsh)" "$(id -un)"; else
        chsh -s "$(command -v zsh)" "$(id -un)" || warn "chsh failed; run it manually"
      fi
    else
      warn "zsh not found; skipping chsh"
    fi
  fi
}

# ----------------------------- verification ---------------------------------
version_of() {
  case "$1" in
    openssl)   first_line openssl version ;;
    tailscale) first_line tailscale version ;;
    *)         first_line "$1" --version ;;
  esac
}

verify() {
  log "Verifying installation"
  local c found=0 missing=0
  for c in git zsh gh tailscale openssl claude magpie purple mole pi; do
    if have "$c"; then
      found=$((found+1))
      printf '  %s✓%s %-10s %s\n' "$C_G" "$C_0" "$c" "$(version_of "$c")"
    else
      missing=$((missing+1))
      printf '  %s✗%s %-10s not installed\n' "$C_Y" "$C_0" "$c"
    fi
  done
  printf '  -> %d ready, %d missing\n' "$found" "$missing"
}

# ----------------------------- main -----------------------------------------
MISSING=()
detect_distro
if [ "$DO_SYSTEM" -eq 1 ]; then install_system; fi
if [ "$DO_USER" -eq 1 ]; then install_user; fi
if [ "$DRY_RUN" -eq 0 ]; then verify; fi

cat <<EOF

$(printf '%s' "$C_B")Done$(printf '%s' "$C_0")
  - Source list: /home/a/installed-software-2026-11-25.md
  - dry-run: $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)
  - Items skipped as already present: ${SKIP_COUNT}
  - To force reinstall: pass --force

Manual steps still required:
  1) Tailscale login:  sudo tailscale up
  2) GitHub login:     gh auth login
  3) gh git credentials: gh auth setup-git
  4) Login shell:      ./install-software.sh --set-shell (or chsh -s "$(command -v zsh 2>/dev/null || echo /bin/zsh)")
  5) Skipped private tools: set MAGPIE_URL / PURPLE_URL / RTK_URL / PI_INSTALL_URL
     or copy them from the source machine with --artifacts DIR (same arch required)
EOF

if [ ${#MISSING[@]} -gt 0 ]; then
  printf '\n%sMissing:%s %s\n' "$C_Y" "$C_0" "${MISSING[*]}"
fi