#!/usr/bin/env bash
# Reproduce / confirm the elanmoc2 retry-GError double free (patch 0003).
#
# The bug is triggered by REJECTED verifies, not accepted ones: each
# "Finger not recognized" hands libfprint a GError the driver then frees
# again. So the test deliberately asks for BAD touches.
#
# Run as root:  sudo ./scripts/verify-crash-test.sh
set -uo pipefail

ROUNDS="${ROUNDS:-6}"
USERNAME="${SUDO_USER:-$(id -un)}"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }

echo "== which library is loaded =="
readlink -f /usr/lib/libfprint-2.so.2
echo

echo "== enabling driver debug logging =="
mkdir -p /etc/systemd/system/fprintd.service.d
cat > /etc/systemd/system/fprintd.service.d/10-debug.conf <<'CONF'
[Service]
Environment=G_MESSAGES_DEBUG=all
Environment=LIBUSB_DEBUG=3
CONF
systemctl daemon-reload
systemctl stop fprintd 2>/dev/null
echo "  drop-in written (remove it with: rm -r /etc/systemd/system/fprintd.service.d)"
echo

BEFORE=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
echo "== baseline: $BEFORE fprintd coredumps on record =="
echo

echo "== $ROUNDS verify attempts =="
echo "   Use the WRONG finger (or the side of a finger) every time."
echo "   Rejections are what exercise the buggy path."
echo
for i in $(seq 1 "$ROUNDS"); do
  echo "--- round $i/$ROUNDS ---"
  timeout 25 fprintd-verify "$USERNAME" 2>&1 | sed 's/^/    /'
  if ! systemctl is-active --quiet fprintd; then
    if systemctl show fprintd -p Result --value | grep -q core-dump; then
      echo "    !! fprintd DUMPED CORE on round $i -- bug still present"
      break
    fi
  fi
done
echo

AFTER=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)
echo "== result =="
echo "   coredumps before: $BEFORE"
echo "   coredumps after:  $AFTER"
if [ "$AFTER" -gt "$BEFORE" ]; then
  echo "   VERDICT: FAILED -- fprintd still crashes"
  coredumpctl info fprintd 2>&1 | sed -n '1,40p'
else
  echo "   VERDICT: PASSED -- no new coredump across $ROUNDS rejected verifies"
fi
echo

echo "== driver log for this run =="
journalctl --since "$SINCE" --no-pager 2>/dev/null \
  | grep -iE 'fprintd|elanmoc2|libfprint|coredump' | tail -60
