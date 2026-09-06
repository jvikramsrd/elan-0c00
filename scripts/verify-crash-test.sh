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

# A coredump count that does not move proves nothing unless verifies actually
# ran. Refuse to start rather than report a meaningless PASS.
for tool in fprintd-verify fprintd-list; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not found -- fprintd is not installed."
    echo "       Install it first; otherwise this test cannot exercise the bug."
    exit 1
  }
done

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
RAN=0
for i in $(seq 1 "$ROUNDS"); do
  echo "--- round $i/$ROUNDS ---"
  OUT=$(timeout 25 fprintd-verify "$USERNAME" 2>&1); RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    /'
  # 127 = command vanished; a round that never reached the sensor does not count
  if [ "$RC" -ne 127 ] && ! printf '%s' "$OUT" | grep -q 'No such file or directory'; then
    RAN=$((RAN + 1))
  fi
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
echo "   verify attempts that actually ran: $RAN / $ROUNDS"
echo "   coredumps before: $BEFORE"
echo "   coredumps after:  $AFTER"
if [ "$RAN" -eq 0 ]; then
  echo "   VERDICT: INCONCLUSIVE -- no verify reached the sensor, nothing was tested"
  exit 2
elif [ "$AFTER" -gt "$BEFORE" ]; then
  echo "   VERDICT: FAILED -- fprintd still crashes"
  coredumpctl info fprintd 2>&1 | sed -n '1,40p'
  exit 1
elif [ "$RAN" -lt 4 ]; then
  echo "   VERDICT: WEAK -- only $RAN rejections; the bug needs several to surface."
  echo "            Re-run and give it at least 6 wrong touches before trusting this."
  exit 2
else
  echo "   VERDICT: PASSED -- no new coredump across $RAN rejected verifies"
fi
echo

echo "== driver log for this run =="
journalctl --since "$SINCE" --no-pager 2>/dev/null \
  | grep -iE 'fprintd|elanmoc2|libfprint|coredump' | tail -60
