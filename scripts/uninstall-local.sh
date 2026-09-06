#!/usr/bin/env bash
# Remove the files `meson install` (scripts/install-local.sh) wrote into /usr.
#
# Those files are not owned by pacman, so `pacman -S libfprint` aborts with
# "exists in filesystem" and REFUSES THE WHOLE TRANSACTION -- which is how you
# end up with no fprintd installed at all. Run this before reinstalling either
# the distro package or the proper package in packaging/.
set -uo pipefail

BUILD="${BUILD:-$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)/elan-0c00/work/moc2}"
LOG="$BUILD/build/meson-logs/install-log.txt"
BAK=/var/backups/elan-0c00/libfprint-2.so.2.0.0.distro-orig

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -r "$LOG" ] || { echo "no meson install log at $LOG"; exit 1; }

echo "== removing files installed by meson =="
removed=0; kept=0
while IFS= read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  [ -e "$f" ] || [ -L "$f" ] || continue
  # Never delete something pacman owns -- that would break another package.
  if pacman -Qo "$f" >/dev/null 2>&1; then
    echo "  KEEP (pacman-owned): $f"; kept=$((kept + 1)); continue
  fi
  if [ -d "$f" ]; then
    rmdir "$f" 2>/dev/null && echo "  rmdir $f"
  else
    rm -f "$f" && echo "  rm    $f" && removed=$((removed + 1))
  fi
done < "$LOG"

echo
echo "  removed: $removed   kept (pacman-owned): $kept"
ldconfig
echo "  ldconfig done"

echo
if [ -f "$BAK" ]; then
  echo "NOTE: the distro library backup is still at"
  echo "        $BAK"
  echo "      Leave it; it is your fallback. pacman will lay down its own copy."
fi
echo
echo "Next:"
echo "  sudo pacman -S fprintd libfprint      # stock, no elanmoc2 -- reader will NOT work"
echo "  ...or, to keep the reader working:"
echo "  cd packaging && makepkg -si && sudo pacman -S fprintd"
