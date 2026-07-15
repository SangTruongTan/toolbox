#!/usr/bin/env bash
#
# setup-i2c-permissions.sh — Fix ddcutil EACCES on /dev/i2c-* (Linux)
#
# Usage:
#   ./setup-i2c-permissions.sh           Install udev rule + add user to i2c group
#   ./setup-i2c-permissions.sh --quick   Temporary fix until reboot (chmod)

set -euo pipefail

QUICK=0
UDEV_RULE="/etc/udev/rules.d/99-monitor-input-i2c.rules"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is for Linux only." >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--quick]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$QUICK" -eq 1 ]]; then
  echo "→ Temporary fix: chmod a+rw /dev/i2c-* (lost on reboot)"
  sudo chmod a+rw /dev/i2c-* 2>/dev/null || sudo chmod a+rw /dev/i2c-[0-9]* 2>/dev/null
  echo "✓ Done. Test: ddcutil detect"
  exit 0
fi

echo "→ Setting up persistent i2c permissions for ddcutil"

if ! getent group i2c >/dev/null 2>&1; then
  echo "→ Creating group i2c"
  sudo groupadd --system i2c
fi

if groups "$USER" | grep -q '\bi2c\b'; then
  echo "✓ User $USER is already in group i2c"
else
  echo "→ Adding $USER to group i2c"
  sudo usermod -aG i2c "$USER"
  echo "! Log out and back in (or run: newgrp i2c) for group membership to apply"
fi

echo "→ Installing udev rule: $UDEV_RULE"
sudo tee "$UDEV_RULE" >/dev/null <<'EOF'
# monitor-input / ddcutil — grant i2c group RW on I2C devices
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
EOF

echo "→ Reloading udev"
sudo udevadm control --reload-rules
sudo udevadm trigger -s i2c-dev

# Apply to existing nodes immediately
if ls /dev/i2c-[0-9]* >/dev/null 2>&1; then
  echo "→ Updating permissions on existing /dev/i2c-* nodes"
  sudo chmod g+rw /dev/i2c-[0-9]* 2>/dev/null || true
  sudo chgrp i2c /dev/i2c-[0-9]* 2>/dev/null || true
fi

echo ""
echo "✓ Setup complete"
echo ""
echo "Next steps:"
echo "  1. Activate group (pick one):"
echo "       newgrp i2c"
echo "     or log out/in"
echo "  2. Test:"
echo "       ddcutil detect"
echo "       ddcutil -d 1 setvcp 0x60 16"
echo ""
echo "If it still fails after sleep/wake, retry or run: $0 --quick"
