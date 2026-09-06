#!/usr/bin/env bash
# Install the locally built elanmoc2 libfprint over the system one.
#
# This OVERWRITES a pacman-owned file. `pacman -Qkk libfprint` will report the
# library as modified afterwards, and the next libfprint package upgrade will
# silently revert it. Rollback instructions are printed at the end.
set -euo pipefail

# $HOME is /root under sudo; resolve the invoking user's home instead.
OWNER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
BUILD="${BUILD:-$OWNER_HOME/elan-0c00/work/moc2}"
LIB=/usr/lib/libfprint-2.so.2.0.0
# NEVER keep the backup in /usr/lib: ldconfig scans that directory, sees a second
# file carrying SONAME libfprint-2.so.2, and may repoint the symlink at the
# backup -- silently reverting the install.
BAKDIR=/var/backups/elan-0c00
BAK="$BAKDIR/libfprint-2.so.2.0.0.distro-orig"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -d "$BUILD/build" ] || { echo "no build at $BUILD/build"; exit 1; }

echo "== pre-flight =="
"$BUILD/build/libfprint/fprint-list-supported-devices" | grep -qi '04f3:0c00' \
  || { echo "ERROR: built library does not claim 04f3:0c00; refusing"; exit 1; }
echo "  built library claims 04f3:0c00  ok"

echo "== backing up the distro library =="
if [ -f "$BAK" ]; then
  echo "  $BAK already exists, keeping the original backup"
else
  mkdir -p "$BAKDIR"
  cp -a "$LIB" "$BAK"
  echo "  saved $BAK  (outside the ldconfig search path)"
fi

echo "== installing =="
# --no-rebuild: never rebuild as root, that would leave root-owned files in the
# build tree and break later unprivileged builds.
meson install -C "$BUILD/build" --no-rebuild

ldconfig
echo "  ldconfig done"

# ldconfig may rewrite the SONAME symlink; make sure it points at what we just
# installed, and verify by resolving the link rather than trusting the path.
ln -sfn "$(basename "$LIB")" /usr/lib/libfprint-2.so.2
ln -sfn libfprint-2.so.2 /usr/lib/libfprint-2.so
echo -n "  libfprint-2.so.2 resolves to: "; readlink -f /usr/lib/libfprint-2.so.2

echo "== verifying =="
echo -n "  installed library contains the elanmoc2 driver: "
# NB: do NOT pipe strings into `grep -q` here. grep exits at the first match,
# strings takes SIGPIPE, and `set -o pipefail` turns that into a failed
# pipeline -- reporting NO on a library that is in fact correct.
if strings "$(readlink -f /usr/lib/libfprint-2.so.2)" \
     | grep -c "ELAN Match-on-Chip 2" | grep -qv '^0$'; then
  echo "YES"
else
  echo "NO"
  echo "  ERROR: the installed library has no elanmoc2 driver; rolling back is advised"
fi
echo -n "  system library claims 04f3:0c00: "
python3 - <<'PY'
import struct
import os
d=open(os.path.realpath('/usr/lib/libfprint-2.so.2'),'rb').read()
f3=[o for o in range(0,len(d)-4,4) if struct.unpack_from('<I',d,o)[0]==0x04f3]
hit=any(struct.unpack_from('<I',d,o+k)[0]==0x0c00
        for o in f3 for k in range(-32,36,4) if 0<=o+k<len(d)-4)
print("YES" if hit else "NO")
PY

systemctl stop fprintd 2>/dev/null || true
pkill -f '/usr/lib/fprintd' 2>/dev/null || true
sleep 1

USER_NAME="${SUDO_USER:-root}"
echo "  fprintd-list $USER_NAME:"
timeout 25 fprintd-list "$USER_NAME" 2>&1 | sed 's/^/    /' || true

cat <<'EOF'

== ROLLBACK ==
  sudo pacman -S libfprint          # restore the distro package, or
  sudo cp -a /var/backups/elan-0c00/libfprint-2.so.2.0.0.distro-orig \
             /usr/lib/libfprint-2.so.2.0.0 && sudo ldconfig

NOTE: pacman -Qkk libfprint will now report this library as modified. The next
libfprint upgrade reverts it and fingerprint support will stop working with no
warning. For a durable install use the AUR package libfprint-elanmoc2-git.
EOF
