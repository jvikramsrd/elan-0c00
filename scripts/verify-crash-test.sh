#!/usr/bin/env bash
# Confirm the elanmoc2 retry-GError double free (patch 0003) is fixed.
#
# DESIGN NOTE, learned the hard way (twice):
#   The bug manifests as fprintd dying. The naive test -- "count coredumps
#   before and after" -- therefore reports success whenever the test fails to
#   run at all. It passed with fprintd uninstalled, and passed again with the
#   wrong libfprint loaded and zero devices present.
#
#   So the verdict here NEVER rests on the absence of a crash. It requires
#   positive proof that the code path under test was executed: the driver must
#   have reported finger rejections, which is what drives the retry loop that
#   double-frees. No rejections observed => INCONCLUSIVE, never PASSED.
#
# Run as root:  sudo ./scripts/verify-crash-test.sh
set -uo pipefail

ROUNDS="${ROUNDS:-6}"
MIN_REJECTIONS="${MIN_REJECTIONS:-4}"
USERNAME="${SUDO_USER:-$(id -un)}"

die() { echo "ABORT: $*" >&2; exit 3; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

echo "== preflight =="

for tool in fprintd-verify fprintd-list; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found -- fprintd is not installed."
done

LIB=$(readlink -f /usr/lib/libfprint-2.so.2)
echo "  library:  $LIB"
echo -n "  owner:    "; pacman -Qo "$LIB" 2>/dev/null | sed 's/.*owned by //' || echo "(unowned)"

# NB: not `strings | grep -q`. grep -q exits at the first match, strings takes
# SIGPIPE, and `set -o pipefail` turns that into a false negative.
if [ "$(strings "$LIB" | grep -c 'ELAN Match-on-Chip 2')" -eq 0 ]; then
  die "the loaded libfprint has no elanmoc2 driver.
       This is stock libfprint; 04f3:0c00 will not be claimed and nothing
       can be tested. Install the patched package:
         cd packaging && sudo pacman -U libfprint-elanmoc2-0c00-*.pkg.tar.zst"
fi
echo "  elanmoc2: present"

systemctl start fprintd 2>/dev/null
DEVS=$(timeout 15 fprintd-list "$USERNAME" 2>&1)
printf '%s\n' "$DEVS" | grep -qi 'no devices available' \
  && die "fprintd sees no devices. The sensor is not being claimed:
       journalctl -u fprintd | grep -i 04F3"
printf '%s\n' "$DEVS" | grep -qiE 'finger' \
  || die "no enrolled fingerprints for $USERNAME. Enroll one first:
       sudo fprintd-enroll $USERNAME"
echo "  device+print: ok"
echo

echo "== enabling driver debug logging =="
mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  > /etc/systemd/system/fprintd.service.d/10-debug.conf
systemctl daemon-reload; systemctl stop fprintd 2>/dev/null
echo "  (remove later: rm -r /etc/systemd/system/fprintd.service.d)"
echo

BEFORE=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
echo "== $ROUNDS verify attempts =="
echo "   Use the WRONG finger every time. Rejections drive the buggy path."
echo

REJECTED=0; MATCHED=0; BROKEN=0
for i in $(seq 1 "$ROUNDS"); do
  echo "--- round $i/$ROUNDS ---"
  OUT=$(timeout 25 fprintd-verify "$USERNAME" 2>&1)
  printf '%s\n' "$OUT" | sed 's/^/    /'
  if printf '%s' "$OUT" | grep -qiE 'no-match|verify-no-match|not recognized|match failed'; then
    REJECTED=$((REJECTED + 1))
  elif printf '%s' "$OUT" | grep -qiE 'verify-match'; then
    MATCHED=$((MATCHED + 1))
    echo "    (matched -- present a DIFFERENT finger; matches don't test the bug)"
  else
    BROKEN=$((BROKEN + 1))
    echo "    (this round did not reach the sensor; it does not count)"
  fi
done
echo

# Independent corroboration from the driver itself, not just the CLI's wording.
LOGGED=$(journalctl --since "$SINCE" --no-pager 2>/dev/null \
         | grep -ciE 'error during verify|Finger not recognized' || true)
AFTER=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)

echo "== result =="
echo "   rejections (CLI):     $REJECTED / $ROUNDS"
echo "   rejections (journal): $LOGGED"
echo "   matches:              $MATCHED"
echo "   rounds that failed to reach the sensor: $BROKEN"
echo "   coredumps before/after: $BEFORE / $AFTER"
echo

if [ "$AFTER" -gt "$BEFORE" ]; then
  echo "   VERDICT: FAILED -- fprintd still dumped core."
  coredumpctl info fprintd 2>&1 | sed -n '1,40p'
  exit 1
fi
if [ "$REJECTED" -eq 0 ] && [ "$LOGGED" -eq 0 ]; then
  echo "   VERDICT: INCONCLUSIVE -- no rejection ever reached the driver."
  echo "            Nothing was tested. Do NOT read this as a pass."
  exit 2
fi
if [ "$REJECTED" -lt "$MIN_REJECTIONS" ]; then
  echo "   VERDICT: WEAK -- only $REJECTED rejections; needs >= $MIN_REJECTIONS."
  echo "            The double free took ~4-5 rejections to kill fprintd."
  exit 2
fi
echo "   VERDICT: PASSED -- $REJECTED rejections, no new coredump."
