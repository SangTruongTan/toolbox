#!/usr/bin/env bash
#
# setup-i2c-permissions.sh — Fix ddcutil EACCES on /dev/i2c-* (Linux)
#
# Common cause: OpenRGB's 60-openrgb.rules adds uaccess ACLs with group::---
# which blocks users in group i2c even when device mode looks like 666.
#
# Usage:
#   ./setup-i2c-permissions.sh             Install fix (needs sudo)
#   ./setup-i2c-permissions.sh --quick     Temporary fix until reboot
#   ./setup-i2c-permissions.sh --diagnose  Show permission state

set -euo pipefail

QUICK=0
DIAGNOSE=0
UDEV_RULE="/etc/udev/rules.d/99-monitor-input-i2c.rules"
OPENRGB_RULE="/usr/lib/udev/rules.d/60-openrgb.rules"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is for Linux only." >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --diagnose) DIAGNOSE=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--quick] [--diagnose]

  (default)   Install udev rule, strip broken ACLs, add user to group i2c
  --quick     Temporary fix: setfacl -b + chmod (until reboot)
  --diagnose  Print i2c permission diagnostics
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

apply_now() {
  local dev
  echo "→ Stripping ACLs and setting permissions on /dev/i2c-*"
  if ! ls /dev/i2c-[0-9]* >/dev/null 2>&1; then
    echo "! No /dev/i2c-* devices found. Load module: sudo modprobe i2c-dev"
    return 1
  fi
  sudo setfacl -b /dev/i2c-[0-9]*
  sudo chgrp i2c /dev/i2c-[0-9]*
  sudo chmod g+rw /dev/i2c-[0-9]*
  # Ensure group members can access even if ACLs return after sleep
  sudo chmod o+rw /dev/i2c-[0-9]*
}

cmd_diagnose() {
  echo "=== User / groups ==="
  id
  echo ""
  echo "=== i2c-dev module ==="
  if lsmod | grep -q '^i2c_dev'; then
    echo "✓ i2c_dev loaded"
  else
    echo "✗ i2c_dev NOT loaded — run: sudo modprobe i2c-dev"
  fi
  echo ""
  echo "=== /dev/i2c-* (first 3 + monitor buses) ==="
  ls -la /dev/i2c-[0-9]* 2>/dev/null | head -5
  ls -la /dev/i2c-[5-9] /dev/i2c-10 2>/dev/null || true
  echo ""
  for dev in /dev/i2c-5 /dev/i2c-6 /dev/i2c-8; do
    [[ -e "$dev" ]] || continue
    echo "=== getfacl $dev ==="
    getfacl "$dev" 2>/dev/null || true
    echo ""
  done
  echo "=== Open test /dev/i2c-5 ==="
  if python3 -c 'import os; f=os.open("/dev/i2c-5", os.O_RDWR); os.close(f); print("✓ open OK")' 2>/dev/null; then
    :
  else
    echo "✗ Permission denied (see ACL group::--- if OpenRGB uaccess is active)"
  fi
  echo ""
  if [[ -f "$OPENRGB_RULE" ]]; then
    echo "=== Known conflict ==="
    echo "! $OPENRGB_RULE applies uaccess to all i2c devices."
    grep -n 'i2c' "$OPENRGB_RULE" || true
    echo "  This script installs a later rule + strips ACLs to fix it."
  fi
  echo ""
  echo "=== udev rules ==="
  grep -Hn 'i2c' /etc/udev/rules.d/*i2c* 2>/dev/null || echo "(no /etc/udev/rules.d/*i2c* rules)"
  echo ""
  if command -v ddcutil >/dev/null 2>&1; then
    echo "=== ddcutil detect ==="
    ddcutil detect 2>&1 | head -10
  fi
}

if [[ "$DIAGNOSE" -eq 1 ]]; then
  cmd_diagnose
  exit 0
fi

if [[ "$QUICK" -eq 1 ]]; then
  apply_now
  echo "✓ Temporary fix applied. Test: ddcutil detect"
  exit 0
fi

echo "→ Setting up persistent i2c permissions for ddcutil"

if ! getent group i2c >/dev/null 2>&1; then
  echo "→ Creating group i2c"
  sudo groupadd --system i2c
fi

if groups "$USER" | grep -q '\bi2c\b'; then
  echo "✓ User $USER is in group i2c"
else
  echo "→ Adding $USER to group i2c"
  sudo usermod -aG i2c "$USER"
  echo "! Log out and back in (or: newgrp i2c) for group membership"
fi

if [[ -f "$OPENRGB_RULE" ]]; then
  echo "! Detected OpenRGB udev rule — it conflicts with ddcutil (group::--- ACL)"
  echo "  Installing override rule to strip ACLs on i2c devices"
fi

if ! command -v setfacl >/dev/null 2>&1; then
  echo "→ Installing acl package (for setfacl)"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y acl
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y acl
  fi
fi

echo "→ Ensuring i2c-dev module loads at boot"
if ! lsmod | grep -q '^i2c_dev'; then
  sudo modprobe i2c-dev
fi
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf >/dev/null

echo "→ Installing udev rule: $UDEV_RULE"
sudo tee "$UDEV_RULE" >/dev/null <<'EOF'
# monitor-input / ddcutil — override OpenRGB uaccess ACLs on i2c devices
# OpenRGB 60-openrgb.rules sets TAG+=uaccess → group::--- blocks group i2c
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0666", \
  RUN+="/usr/bin/setfacl -b /dev/%k"
EOF

echo "→ Reloading udev"
sudo udevadm control --reload-rules
sudo udevadm trigger -s i2c-dev --action=add

apply_now

echo ""
echo "✓ Setup complete"
echo ""
echo "Test now (same shell — group i2c should already apply if you re-logged in):"
echo "  ./setup-i2c-permissions.sh --diagnose"
echo "  ddcutil detect"
echo "  ddcutil -d 1 setvcp 0x60 16"
echo ""
echo "If still failing in this shell only:  newgrp i2c"
