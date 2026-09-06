#!/usr/bin/env bash
# Which enrolled fingers does the 0c00 on-chip matcher actually recognise?
#
# WHY:
#   fprintd lists three prints (right-thumb=6, right-index=7, right-middle=8)
#   and get_enrolled_count reports 3. But:
#     * finger_info returns the SAME record -- finger 6's user id -- for all
#       ten slots, including slots past the count;
#     * verifying right-thumb with the thumb matched (18:36);
#     * verifying right-index with the index did NOT match, and the journal
#       shows no "Identified finger" line at all, so ff 03 itself found nothing.
#
#   So the failure is at the MATCHER, not at finger_info. This measures which
#   physical fingers the sensor recognises, instead of theorising about it.
#
# METHOD: for each enrolled finger, verify AS that finger while PRESENTING
#   that same finger. Record whether ff 03 matched, which slot it named, and
#   what user id the driver rebuilt. No writes; nothing is enrolled or erased.
#
# This script asserts NOTHING. It prints a table. Read it, then theorise.
#
# Run as root:  sudo ./scripts/enrolled-matrix-test.sh
set -uo pipefail

USERNAME="${SUDO_USER:-$(id -un)}"
die() { echo "ABORT: $*" >&2; exit 3; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
command -v fprintd-verify >/dev/null 2>&1 || die "fprintd-verify not found"

mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  > /etc/systemd/system/fprintd.service.d/10-debug.conf
systemctl daemon-reload; systemctl stop fprintd 2>/dev/null
echo "debug logging on (remove later: rm -r /etc/systemd/system/fprintd.service.d)"
echo

declare -a ROWS=()

probe () {
  local finger="$1" human="$2"
  echo "=============================================================="
  echo " verify as: $finger"
  echo " PRESENT:   $human"
  echo "=============================================================="
  local cursor out log ident created result
  cursor=$(journalctl --lines=0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')
  out=$(timeout 30 fprintd-verify -f "$finger" "$USERNAME" 2>&1)
  printf '%s\n' "$out" | sed 's/^/    /'
  log=$(journalctl --after-cursor "$cursor" --no-pager 2>/dev/null)

  ident=$(printf '%s' "$log" | grep -o 'Identified finger [0-9]*' | tail -1)
  created=$(printf '%s' "$log" | grep -o 'user id\[[0-9]*\]: .*' | tail -1)
  if printf '%s' "$out" | grep -qiE 'verify-match'; then result=MATCH
  elif printf '%s' "$out" | grep -qiE 'no-match|not recognized'; then result=no-match
  else result=inconclusive; fi

  [ -n "$ident" ]   || ident="(ff 03 found nothing)"
  [ -n "$created" ] || created="(finger_info never reached)"
  echo "    -> $result | $ident | $created"
  echo
  ROWS+=("$(printf '%-22s %-12s %-28s %s' "$finger" "$result" "$ident" "$created")")
}

probe right-thumb         "RIGHT THUMB"
probe right-index-finger  "RIGHT INDEX finger"
probe right-middle-finger "RIGHT MIDDLE finger"

echo "=============================================================="
echo " RESULT MATRIX -- each finger presented against its own slot"
echo "=============================================================="
printf '  %-22s %-12s %-28s %s\n' "verified as" "result" "identify" "rebuilt user id"
for r in "${ROWS[@]}"; do echo "  $r"; done
echo
echo "Read the 'identify' column first: it says whether the sensor's own"
echo "matcher recognised the finger, before any driver logic ran."
