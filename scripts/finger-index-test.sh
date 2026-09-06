#!/usr/bin/env bash
# Does finger_info (ff 12) honour its slot argument on 04f3:0c00?
#
# BACKGROUND:
#   `elanctl dump` shows all ten slots returning the SAME 64-byte record --
#   including slots past the enrolled count -- carrying the user id of finger 6
#   (FP_FINGER_RIGHT_THUMB) while fingers 6, 7 and 8 are all enrolled.
#   That says ff 12 ignores the index and answers with one fixed record.
#
#   IDENTIFY_CHECK_FINGER_INFO builds its FpPrint from that reply and hands it
#   to fp_print_equal() against the finger the caller asked to verify. If the
#   reply is always finger 6, two things must follow.
#
# PREDICTIONS (this script fails loudly if either is wrong):
#   A. verify right-index, PRESENT right-index  -> no-match  (correct finger rejected)
#   B. verify right-thumb, PRESENT right-middle -> match     (wrong finger accepted)
#
# Neither test writes to the sensor. Nothing is enrolled, deleted or wiped.
#
# Run as root:  sudo ./scripts/finger-index-test.sh
set -uo pipefail

USERNAME="${SUDO_USER:-$(id -un)}"
die() { echo "ABORT: $*" >&2; exit 3; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

command -v fprintd-verify >/dev/null 2>&1 || die "fprintd-verify not found"

echo "== preflight =="
ENROLLED=$(timeout 15 fprintd-list "$USERNAME" 2>&1)
printf '%s\n' "$ENROLLED" | sed 's/^/  /'
for f in right-thumb right-index-finger right-middle-finger; do
  printf '%s' "$ENROLLED" | grep -q "$f" \
    || die "$f is not enrolled; this test needs right-thumb, right-index-finger and right-middle-finger."
done
echo

mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  > /etc/systemd/system/fprintd.service.d/10-debug.conf
systemctl daemon-reload; systemctl stop fprintd 2>/dev/null
echo "  debug logging on (remove later: rm -r /etc/systemd/system/fprintd.service.d)"
echo

run_case () {
  local verify_as="$1" present="$2" expect="$3" label="$4"
  echo "== $label =="
  echo "   verifying as: $verify_as"
  echo "   PRESENT YOUR: $present"
  echo "   prediction:   $expect"
  echo
  local cursor out
  cursor=$(journalctl --lines=0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')
  out=$(timeout 30 fprintd-verify -f "$verify_as" "$USERNAME" 2>&1)
  printf '%s\n' "$out" | sed 's/^/    /'
  journalctl --after-cursor "$cursor" --no-pager 2>/dev/null \
    | grep -iE 'Identified finger|Creating new print|verify-match|verify-no-match' \
    | sed 's/^/    | /'
  if printf '%s' "$out" | grep -qiE 'verify-match'; then RESULT=match
  elif printf '%s' "$out" | grep -qiE 'no-match|not recognized'; then RESULT=no-match
  else RESULT=inconclusive; fi
  echo
  echo "   observed: $RESULT   (predicted: $expect)"
  echo
}

run_case right-index-finger "RIGHT INDEX finger (the correct one)" no-match \
         "TEST A -- correct finger, non-thumb slot"
A=$RESULT

run_case right-thumb "RIGHT MIDDLE finger (deliberately the wrong one)" match \
         "TEST B -- wrong finger, thumb slot"
B=$RESULT

echo "== verdict =="
if [ "$A" = inconclusive ] || [ "$B" = inconclusive ]; then
  echo "   INCONCLUSIVE -- a round did not reach the sensor. Nothing proven."
  exit 2
fi
if [ "$A" = no-match ] && [ "$B" = match ]; then
  echo "   CONFIRMED: ff 12 ignores its slot argument on 0c00."
  echo "   A correct non-thumb finger is REJECTED; a wrong finger is ACCEPTED"
  echo "   as right-thumb. Both follow from the driver rebuilding its print"
  echo "   from a fixed record. This belongs in the MR report."
  exit 0
fi
echo "   PREDICTIONS NOT MET (A=$A, B=$B)."
echo "   The fixed-record theory is wrong or incomplete. Do NOT write it up."
exit 1
