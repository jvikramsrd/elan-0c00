#!/usr/bin/env bash
# Hardware-verify patch 0004 on the ENROLL_ATTEMPT_DELETE path.
#
# WHAT THIS EXERCISES
#   Re-enrolling an ALREADY-ENROLLED finger drives the enroll SSM through
#   ENROLL_GET_ENROLLED_FINGER_INFO -> ENROLL_ATTEMPT_DELETE. That state calls
#   elanmoc2_get_user_id_string() on a finger_info reply that 04f3:0c00 rejects
#   with a 2-byte `40 ff`, then memcpy()s from it. Unpatched that is a NULL
#   write (bug 1) and a 62-byte read from NULL (bug 3); before patch 0002 a
#   failed delete then escalated to wiping every stored template.
#
# DESIGN NOTE, inherited from verify-crash-test.sh:
#   The verdict NEVER rests on the absence of a crash. It requires positive
#   proof that ENROLL_ATTEMPT_DELETE was entered AND that execution continued
#   past the memcpy that follows it. If the path was not reached, the result is
#   INCONCLUSIVE -- never PASSED.
#
# SAFETY:
#   Refuses to run unless the loaded library carries patch 0002's guard and
#   patch 0004's marker, and does NOT carry upstream's wipe-on-failed-delete
#   string. Running this against an unpatched library would wipe the sensor.
#
# Run as root:  sudo ./scripts/verify-reenroll-test.sh
set -uo pipefail

FINGER="${FINGER:-right-index-finger}"
USERNAME="${SUDO_USER:-$(id -un)}"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/var/backups/elan-0c00/fprint-$STAMP"

die() { echo "ABORT: $*" >&2; exit 3; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

echo "== preflight =="
for t in fprintd-enroll fprintd-list; do
  command -v "$t" >/dev/null || die "$t not found"
done

LIB=$(readlink -f /usr/lib/libfprint-2.so.2)
echo "  library:  $LIB"
echo -n "  owner:    "; pacman -Qo "$LIB" 2>/dev/null | sed 's/.*owned by //' || echo "(unowned)"

# NB: not `grep -q` on a strings pipe -- SIGPIPE + pipefail = false negatives.
have() { [ "$(strings -a "$LIB" | grep -cF "$1")" -gt 0 ]; }

have 'ELAN Match-on-Chip 2' \
  || die "loaded libfprint has no elanmoc2 driver; nothing can be tested."
have 'refusing to wipe the sensor' \
  || die "patch 0002 is NOT in the loaded library.
       Without it a failed delete WIPES EVERY ENROLLED TEMPLATE.
       Refusing to run. Install the patched package first."
have 'user id[%lu]' \
  || die "patch 0004 is NOT in the loaded library.
       This test would crash fprintd rather than verify anything.
       Refusing to run."
if have 'Failed to delete finger %d, wiping sensor'; then
  die "the loaded library still contains upstream's wipe-on-failed-delete.
       Refusing to run."
fi
echo "  0002 guard:   present (will not wipe)"
echo "  0004 fix:     present"
echo "  upstream wipe: absent"

systemctl start fprintd 2>/dev/null
BEFORE_LIST=$(timeout 20 fprintd-list "$USERNAME" 2>&1)
printf '%s\n' "$BEFORE_LIST" | grep -qi 'no devices available' \
  && die "fprintd sees no devices."
printf '%s\n' "$BEFORE_LIST" | grep -qi "$FINGER" \
  || die "$FINGER is not enrolled for $USERNAME.
       This test needs an ALREADY-ENROLLED finger to re-enroll.
       Enrolled now:
$(printf '%s\n' "$BEFORE_LIST" | sed -n 's/^ - /         /p')"
BEFORE_COUNT=$(printf '%s\n' "$BEFORE_LIST" | grep -c '^ - #')
echo "  enrolled:     $BEFORE_COUNT print(s), including $FINGER"

echo
echo "== backing up host-side print storage =="
mkdir -p "$BACKUP"
if [ -d "/var/lib/fprint/$USERNAME" ]; then
  cp -a "/var/lib/fprint/$USERNAME" "$BACKUP/" && echo "  $BACKUP/$USERNAME"
else
  echo "  (no /var/lib/fprint/$USERNAME to back up)"
fi
echo "  NOTE: this backs up the HOST record only. The template lives on the"
echo "        sensor; if the sensor is wiped, restoring this will not bring"
echo "        it back and you must re-enroll. That risk is irreducible."

echo
echo "== enabling driver debug logging =="
mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  > /etc/systemd/system/fprintd.service.d/10-debug.conf
systemctl daemon-reload; systemctl stop fprintd 2>/dev/null
echo "  (remove later: rm -r /etc/systemd/system/fprintd.service.d)"

BEFORE_CORES=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
sleep 1

echo
echo "== re-enrolling $FINGER =="
echo "   PRESENT THE SAME FINGER THAT IS ALREADY ENROLLED ($FINGER)."
echo "   A different finger takes the 'not enrolled' branch and tests nothing."
echo "   Expected: enroll fails with 'Could not delete the existing finger'."
echo
OUT=$(timeout 90 fprintd-enroll -f "$FINGER" "$USERNAME" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/    /'

sleep 2
LOG=$(journalctl --since "$SINCE" --no-pager 2>/dev/null | grep -iE 'elanmoc2|fprintd')

# --- state-machine markers -------------------------------------------------
saw() { printf '%s\n' "$LOG" | grep -qiF "$1"; }
M_REENROLL=0; M_INFO=0; M_DELETE=0; M_GUARD=0; M_DELETED=0; M_NOTENR=0; M_WIPE=0
saw 'need to check for re-enroll'                  && M_REENROLL=1
saw 'fetching finger info'                         && M_INFO=1
saw 'Deleting enrolled finger'                     && M_DELETE=1
saw 'aborting enroll rather than wiping the sensor' && M_GUARD=1
saw 'deleted, proceeding with enroll stage'        && M_DELETED=1
saw 'Finger not enrolled, proceeding'              && M_NOTENR=1
saw 'Wipe sensor command sent'                     && M_WIPE=1

AFTER_CORES=$(coredumpctl list --no-legend 2>/dev/null | grep -c fprintd)
systemctl start fprintd 2>/dev/null
AFTER_LIST=$(timeout 20 fprintd-list "$USERNAME" 2>&1)
AFTER_COUNT=$(printf '%s\n' "$AFTER_LIST" | grep -c '^ - #')
STILL_THERE=0
printf '%s\n' "$AFTER_LIST" | grep -qi "$FINGER" && STILL_THERE=1

echo
echo "== state machine reached =="
printf '   %-46s %s\n' "ENROLL_CHECK_NUM_ENROLLED (re-enroll branch)" "$([ $M_REENROLL = 1 ] && echo yes || echo no)"
printf '   %-46s %s\n' "ENROLL_GET_ENROLLED_FINGER_INFO (already enr.)" "$([ $M_INFO = 1 ] && echo yes || echo no)"
printf '   %-46s %s\n' "ENROLL_ATTEMPT_DELETE  <-- target state" "$([ $M_DELETE = 1 ] && echo YES || echo no)"
printf '   %-46s %s\n' "continued past the memcpy (0002 guard fired)" "$([ $M_GUARD = 1 ] && echo YES || echo no)"
printf '   %-46s %s\n' "sensor accepted the delete instead" "$([ $M_DELETED = 1 ] && echo yes || echo no)"
printf '   %-46s %s\n' "took 'not enrolled' branch (path NOT tested)" "$([ $M_NOTENR = 1 ] && echo yes || echo no)"
printf '   %-46s %s\n' "WIPE SENSOR command issued" "$([ $M_WIPE = 1 ] && echo '*** YES ***' || echo no)"

echo
echo "== result =="
echo "   prints before/after:    $BEFORE_COUNT / $AFTER_COUNT"
echo "   $FINGER still enrolled: $([ $STILL_THERE = 1 ] && echo yes || echo NO)"
echo "   coredumps before/after: $BEFORE_CORES / $AFTER_CORES"
echo

# --- verdict ---------------------------------------------------------------
if [ "$AFTER_CORES" -gt "$BEFORE_CORES" ]; then
  echo "   VERDICT: FAILED -- fprintd dumped core."
  [ $M_DELETE = 1 ] && echo "            It reached ENROLL_ATTEMPT_DELETE, so patch 0004 did not hold."
  coredumpctl info fprintd 2>&1 | sed -n '1,40p'
  exit 1
fi
if [ $M_WIPE = 1 ] || [ "$AFTER_COUNT" -lt "$BEFORE_COUNT" ] || [ $STILL_THERE = 0 ]; then
  echo "   VERDICT: FAILED -- stored templates were lost."
  echo "            Host-side backup: $BACKUP"
  echo "            The sensor template is gone regardless; re-enroll with:"
  echo "              fprintd-enroll -f $FINGER"
  exit 1
fi
if [ $M_DELETE = 0 ]; then
  echo "   VERDICT: INCONCLUSIVE -- ENROLL_ATTEMPT_DELETE was never entered."
  if [ $M_NOTENR = 1 ]; then
    echo "            The sensor did not recognise the finger, so the enroll took"
    echo "            the 'not enrolled' branch. Present the SAME finger that is"
    echo "            already enrolled and re-run."
  else
    echo "            The enroll did not get far enough. Nothing was tested."
  fi
  echo "            Do NOT read this as a pass."
  exit 2
fi
if [ $M_GUARD = 0 ] && [ $M_DELETED = 0 ]; then
  echo "   VERDICT: WEAK -- entered ENROLL_ATTEMPT_DELETE but no following log"
  echo "            line was seen, so it is not proven that execution continued"
  echo "            past the memcpy. Re-run with the debug drop-in in place."
  exit 2
fi
echo "   VERDICT: PASSED -- ENROLL_ATTEMPT_DELETE was entered and execution"
echo "            continued past the user-ID memcpy with no crash, and every"
echo "            enrolled template survived."
if [ $M_DELETED = 1 ]; then
  echo
  echo "   NOTE: the sensor ACCEPTED the delete this time, so the enroll went on"
  echo "         to re-enroll the finger rather than aborting. Check the current"
  echo "         enrollment; you may want to re-enroll $FINGER cleanly."
fi
