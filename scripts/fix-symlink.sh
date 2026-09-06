#!/usr/bin/env bash
# Repair /usr/lib/libfprint-2.so.2 after a backup file with the same SONAME was
# left in /usr/lib, causing ldconfig to repoint the symlink at the backup.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }

STRAY=/usr/lib/libfprint-2.so.2.0.0.pacman-orig
SAFE=/var/backups/elan-0c00
REAL=/usr/lib/libfprint-2.so.2.0.0

echo "== before =="
ls -l /usr/lib/libfprint-2.so.2

if [ -f "$STRAY" ]; then
  mkdir -p "$SAFE"
  mv "$STRAY" "$SAFE/libfprint-2.so.2.0.0.distro-orig"
  echo "  moved the stray backup out of the ldconfig search path:"
  echo "    $SAFE/libfprint-2.so.2.0.0.distro-orig"
fi

ln -sfn "$(basename "$REAL")" /usr/lib/libfprint-2.so.2
ln -sfn libfprint-2.so.2 /usr/lib/libfprint-2.so
ldconfig

echo "== after =="
ls -l /usr/lib/libfprint-2.so.2
echo -n "  resolves to: "; readlink -f /usr/lib/libfprint-2.so.2
echo -n "  driver present: "
strings "$(readlink -f /usr/lib/libfprint-2.so.2)" | grep -q "ELAN Match-on-Chip 2" \
  && echo "elanmoc2 YES" || echo "elanmoc2 NO"

systemctl stop fprintd 2>/dev/null || true
pkill -x fprintd 2>/dev/null || true
sleep 1
echo "  fprintd-list ${SUDO_USER:-root}:"
timeout 25 fprintd-list "${SUDO_USER:-root}" 2>&1 | sed 's/^/    /' || true

cat <<EOF

== ROLLBACK ==
  sudo pacman -S libfprint     # restores the distro library cleanly
  (the distro original is also kept at $SAFE/libfprint-2.so.2.0.0.distro-orig)
EOF
