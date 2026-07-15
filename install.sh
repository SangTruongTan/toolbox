#!/usr/bin/env bash
#
# install.sh — Install monitor-input on macOS or Linux
#
# Usage:
#   ./install.sh              Interactive install
#   ./install.sh --yes        Non-interactive (defaults yes)
#   ./install.sh --deps-only  Install dependencies only

set -euo pipefail

TOOLBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="${TOOLBOX_DIR}/monitor-input"
CONF_EXAMPLE="${TOOLBOX_DIR}/monitor-input.conf.example"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/monitor-input"
CONF_DEST="${CONF_DIR}/config"
BINDIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
SYMLINK="${BINDIR}/monitor-input"

YES=0
DEPS_ONLY=0
SKIP_DEPS=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m'
  YELLOW=$'\033[33m' BLUE=$'\033[34m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" RESET=""
fi

info()  { printf "%s→%s %s\n" "$BLUE" "$RESET" "$*"; }
ok()    { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn()  { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
die()   { printf "%s✗%s %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  local prompt=$1
  printf "%s [y/N] " "$prompt"
  local ans
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux)  printf 'linux' ;;
    *)      die "Unsupported OS: $(uname -s)" ;;
  esac
}

ensure_bindir() {
  mkdir -p "$BINDIR"
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *)
      warn "$BINDIR is not in PATH"
      info "Add to your shell rc:  export PATH=\"$BINDIR:\$PATH\""
      ;;
  esac
}

find_linux_ddcutil() {
  local p
  for p in \
    "$(command -v ddcutil 2>/dev/null || true)" \
    "$HOME/.linuxbrew/bin/ddcutil" \
    "/home/linuxbrew/.linuxbrew/bin/ddcutil" \
    /usr/bin/ddcutil \
    /usr/local/bin/ddcutil; do
    [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

linuxbrew_shellenv() {
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
  fi
}

install_deps_macos() {
  info "macOS dependencies"

  if ! have brew; then
    die "Homebrew is required. Install from https://brew.sh then re-run ./install.sh"
  fi

  if have m1ddc; then
    ok "m1ddc already installed ($(command -v m1ddc))"
  else
    info "Installing m1ddc…"
    brew install m1ddc
    ok "m1ddc installed"
  fi

  if ! have ssh-copy-id; then
    warn "ssh-copy-id not found (usually bundled with OpenSSH)"
  fi
}

install_deps_linux() {
  info "Linux dependencies"
  linuxbrew_shellenv

  if path="$(find_linux_ddcutil)"; then
    ok "ddcutil already installed ($path)"
    LINUX_DDCUTIL_PATH="$path"
    return 0
  fi

  if have brew; then
    info "Installing ddcutil via Homebrew…"
    brew install ddcutil
    linuxbrew_shellenv
    path="$(find_linux_ddcutil)" || die "ddcutil install via brew failed"
    ok "ddcutil installed ($path)"
    LINUX_DDCUTIL_PATH="$path"
    return 0
  fi

  if have apt-get; then
    info "Installing ddcutil via apt…"
    sudo apt-get update -qq
    sudo apt-get install -y ddcutil
    path="$(find_linux_ddcutil)" || path="/usr/bin/ddcutil"
    ok "ddcutil installed ($path)"
    LINUX_DDCUTIL_PATH="$path"
  elif have dnf; then
    info "Installing ddcutil via dnf…"
    sudo dnf install -y ddcutil
    path="$(find_linux_ddcutil)" || path="/usr/bin/ddcutil"
    ok "ddcutil installed ($path)"
    LINUX_DDCUTIL_PATH="$path"
  else
    die "No package manager found. Install ddcutil manually or install Homebrew for Linux."
  fi

  # I2C permissions (Debian/Ubuntu)
  if getent group i2c >/dev/null 2>&1; then
    if groups "$USER" | grep -q '\bi2c\b'; then
      ok "User $USER is in group i2c"
    else
      warn "Adding $USER to group i2c (log out/in afterward for DDC access)"
      sudo usermod -aG i2c "$USER"
    fi
  fi
}

install_script() {
  [[ -f "$SCRIPT_SRC" ]] || die "Missing $SCRIPT_SRC"
  chmod +x "$SCRIPT_SRC"
  ensure_bindir

  if [[ -L "$SYMLINK" || -e "$SYMLINK" ]]; then
    if [[ "$(readlink "$SYMLINK" 2>/dev/null || true)" == "$SCRIPT_SRC" ]]; then
      ok "Already linked: $SYMLINK → $SCRIPT_SRC"
    elif confirm "Replace existing $SYMLINK?"; then
      ln -sf "$SCRIPT_SRC" "$SYMLINK"
      ok "Linked $SYMLINK → $SCRIPT_SRC"
    else
      warn "Skipped symlink (use: $SCRIPT_SRC directly)"
    fi
  else
    ln -sf "$SCRIPT_SRC" "$SYMLINK"
    ok "Linked $SYMLINK → $SCRIPT_SRC"
  fi
}

write_config() {
  mkdir -p "$CONF_DIR"

  if [[ -f "$CONF_DEST" ]]; then
    ok "Config exists: $CONF_DEST"
    return 0
  fi

  [[ -f "$CONF_EXAMPLE" ]] || die "Missing $CONF_EXAMPLE"

  cp "$CONF_EXAMPLE" "$CONF_DEST"
  ok "Created config: $CONF_DEST"

  local os ddcutil_line remote_script_line
  os="$(detect_os)"
  remote_script_line="MONITOR_REMOTE_SCRIPT=\"${TOOLBOX_DIR}/monitor-input\""

  if [[ "$os" == "linux" ]]; then
    linuxbrew_shellenv
    local ddc_path
    ddc_path="${LINUX_DDCUTIL_PATH:-$(find_linux_ddcutil || true)}"
    if [[ -n "$ddc_path" ]]; then
      ddcutil_line="MONITOR_REMOTE_DDCUTIL=\"${ddc_path}\""
      if grep -q '^MONITOR_REMOTE_DDCUTIL=' "$CONF_DEST"; then
        sed -i.bak "s|^MONITOR_REMOTE_DDCUTIL=.*|${ddcutil_line}|" "$CONF_DEST"
      fi
      rm -f "${CONF_DEST}.bak"
      ok "Set MONITOR_REMOTE_DDCUTIL=$ddc_path"
    fi
  fi

  if grep -q '^MONITOR_REMOTE_SCRIPT=' "$CONF_DEST"; then
    sed -i.bak "s|^MONITOR_REMOTE_SCRIPT=.*|${remote_script_line}|" "$CONF_DEST"
    rm -f "${CONF_DEST}.bak"
  fi
}

print_banner() {
  printf "\n"
  printf "  %s╭──────────────────────────────────────╮%s\n" "$CYAN" "$RESET"
  printf "  %s│%s  %smonitor-input installer%s              %s│%s\n" \
    "$CYAN" "$RESET" "$BOLD" "$RESET" "$CYAN" "$RESET"
  printf "  %s╰──────────────────────────────────────╯%s\n" "$CYAN" "$RESET"
  printf "\n"
}

print_done() {
  local os; os="$(detect_os)"
  printf "\n"
  ok "Installation complete"
  printf "\n"
  info "Try:"
  if [[ "$os" == "macos" ]]; then
    printf "    monitor-input detect\n"
    printf "    monitor-input current\n"
    printf "    monitor-input dp2\n"
    printf "    monitor-input dp1 --via sangt@ubuntu-pc   # when Linux is active\n"
  else
    printf "    monitor-input detect\n"
    printf "    monitor-input current\n"
    printf "    monitor-input dp1\n"
  fi
  printf "\n"
  info "Config: $CONF_DEST"
  info "Edit MONITOR_REMOTE_HOST / display IDs for your setup."
  printf "\n"
}

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Options:
  -y, --yes         Accept defaults without prompting
  --deps-only       Install dependencies only (no symlink/config)
  --skip-deps       Skip dependency installation
  --bindir PATH     Install symlink to PATH (default: ~/.local/bin)
  -h, --help        Show help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) YES=1; shift ;;
      --deps-only) DEPS_ONLY=1; shift ;;
      --skip-deps) SKIP_DEPS=1; shift ;;
      --bindir) BINDIR="$2"; SYMLINK="${BINDIR}/monitor-input"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  local os; os="$(detect_os)"

  print_banner
  info "Platform: $os"
  info "Source:   $TOOLBOX_DIR"
  printf "\n"

  [[ "$SKIP_DEPS" -eq 1 ]] || {
    if [[ "$os" == "macos" ]]; then
      install_deps_macos
    else
      install_deps_linux
    fi
  }

  [[ "$DEPS_ONLY" -eq 1 ]] && { ok "Dependencies installed"; exit 0; }

  if confirm "Install monitor-input to $BINDIR and create config?"; then
    install_script
    write_config
    print_done
  else
    warn "Skipped file install. Run $SCRIPT_SRC directly from $TOOLBOX_DIR"
  fi
}

main "$@"
