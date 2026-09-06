#!/usr/bin/env bash
# Determine what the identify path actually does on a SUCCESSFUL match on 0c00.
#
# WHY THIS EXISTS:
#   verify-crash-test.sh deliberately uses WRONG fingers, because rejections
#   drive the retry loop that double-frees. A rejection returns early from
#   IDENTIFY_GET_FINGER_INFO and never issues finger_info (ff 12) at all.
#   So that test, by construction, never exercises the match path -- and the
#   match path is the one docs/MR330-report.md section 4 makes claims about.
#
#   This script uses the CORRECT finger, to find out whether:
#     (a) the match completes and finger_info is issued and tolerated, or
#     (b) the match completes without finger_info being reached, or
#     (c) the match cannot complete at all.
#
# SAME DISCIPLINE AS THE CRASH TEST: the verdict never rests on the absence of
#   a failure. It requires positive proof that a match actually occurred. No
#   verify-match observed => INCONCLUSIVE, never a pass.
#
# Run as root:  sudo ./scripts/verify-match-test.sh
set -uo pipefail

ROUNDS="${ROUNDS:-4}"
USERNAME="${SUDO_USER:-$(id -un)}"

die() { echo "ABORT: $*" >&2; exit 3; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

echo "== preflight =="
for tool in fprintd-verify fprintd-list; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found -- fprintd is not installed."
done

LIB=$(readlink -f /usr/lib/libfprint-2.so.2)
echo "  library:  $LIB"
if [ "$(strings "$LIB" | grep -c 'ELAN Match-on-Chip 2')" -eq 0 ]; then
  die "the loaded libfprint has no elanmoc2 driver."
fi
echo "  elanmoc2: present"

systemctl start fprintd 2>/dev/null
DEVS=$(timeout 15 fprintd-list "$USERNAME" 2>&1)
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

CURSOR=$(journalctl --lines=0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')
[ -n "$CURSOR" ] || die "could not obtain a journal cursor"

echo "== up to $ROUNDS verify attempts =="
echo "   Use the CORRECT finger -- the one you enrolled. Matches are the point."
echo

MATCHED=0
for i in $(seq 1 "$ROUNDS"); do
  echo "--- round $i/$ROUNDS ---"
  OUT=$(timeout 25 fprintd-verify "$USERNAME" 2>&1)
  printf '%s\n' "$OUT" | sed 's/^/    /'
  if printf '%s' "$OUT" | grep -qiE 'verify-match'; then
    MATCHED=$((MATCHED + 1))
    echo "    (matched)"
    break
  fi
done
echo

LOG=$(journalctl --after-cursor "$CURSOR" --no-pager 2>/dev/null)

# Positive markers, each proving a specific state was reached.
N_MATCH=$(printf '%s' "$LOG" | grep -c 'result verify-match' || true)
N_REQINFO=$(printf '%s' "$LOG" | grep -c 'requesting finger info' || true)
N_IDFAIL=$(printf '%s' "$LOG" | grep -c 'Identify failed' || true)
N_PROTO=$(printf '%s' "$LOG" | grep -ciE 'proto|invalid|malformed' || true)

echo "== driver trace =="
printf '%s' "$LOG" | grep -iE 'elanmoc2|Identified finger|requesting finger info|Identify failed|verify-match|verify-no-match|error during verify' \
  | sed 's/^/  /' | tail -40
echo

echo "== result =="
echo "   verify-match observed:                 $N_MATCH"
echo "   'requesting finger info' (ff 12 sent): $N_REQINFO"
echo "   'Identify failed':                     $N_IDFAIL"
echo "   proto/malformed complaints:            $N_PROTO"
echo

if [ "$N_MATCH" -eq 0 ]; then
  echo "   VERDICT: INCONCLUSIVE -- no match ever occurred, so the match path"
  echo "            was never entered. Nothing was tested. This is NOT evidence"
  echo "            that the path is broken; retry with the enrolled finger."
  exit 2
fi

if [ "$N_REQINFO" -gt 0 ]; then
  echo "   VERDICT: MATCH COMPLETES, AND ff 12 IS ISSUED."
  echo "            The driver identified a slot, sent finger_info, and still"
  echo "            reported verify-match. Section 4 of MR330-report.md, which"
  echo "            says the identify path cannot complete on 0c00, is WRONG"
  echo "            as written and must be corrected before posting."
else
  echo "   VERDICT: MATCH COMPLETES WITHOUT ff 12 BEING REACHED."
  echo "            Verify succeeds by a route that never issues finger_info."
  echo "            Section 4's claim needs narrowing to the identify-vs-verify"
  echo "            distinction rather than being dropped."
fi
exit 0
