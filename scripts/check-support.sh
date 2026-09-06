#!/usr/bin/env bash
# Identify an ELAN fingerprint sensor and report which libfprint driver, if any,
# handles it. Read-only: runs lsusb and reads package metadata. Touches nothing.
set -uo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { BOLD=""; RED=""; GRN=""; YEL=""; RST=""; }

# Driver ID tables, verified against libfprint v1.94.100 source and the
# out-of-tree elanmoc2 branch (depau/elanmoc2 @ 11f0316d).
ELAN_IMAGE="0903 0907 0c01 0c02 0c03 0c04 0c05 0c06 0c07 0c08 0c09 0c0a 0c0b \
0c0c 0c0d 0c0e 0c0f 0c10 0c11 0c12 0c13 0c14 0c15 0c16 0c17 0c18 0c19 0c1a \
0c1b 0c1c 0c1d 0c1e 0c1f 0c20 0c21 0c22 0c23 0c24 0c25 0c26 0c27 0c28 0c29 \
0c2a 0c2b 0c2c 0c2d 0c2e 0c2f 0c30 0c31 0c32 0c33 0c3d 0c42 0c4b 0c4d 0c4f \
0c58 0c63 0c6e"
ELANMOC="0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 \
0ca8 0cb0 0cb2"
ELANMOC2="0c00 0c4c 0c5e 0c7c 0c90"

in_list() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

echo "${BOLD}ELAN fingerprint sensor support check${RST}"
echo

command -v lsusb >/dev/null || { echo "${RED}lsusb not found${RST} (install usbutils)"; exit 1; }

mapfile -t FOUND < <(lsusb | grep -i '04f3:' || true)
if [ ${#FOUND[@]} -eq 0 ]; then
  echo "${YEL}No ELAN (04f3:*) USB device found.${RST}"
  echo "If your reader is SPI (ACPI ELAN7001/ELAN70A1) it uses the elanspi driver instead."
  exit 1
fi

rc=1
for line in "${FOUND[@]}"; do
  pid="$(sed -E 's/.*04f3:([0-9a-fA-F]{4}).*/\1/' <<<"$line" | tr 'A-F' 'a-f')"
  name="$(sed -E 's/.*04f3:[0-9a-fA-F]{4} //' <<<"$line")"

  echo "${BOLD}Found 04f3:${pid}${RST} — ${name}"

  # Touchpads and other non-fingerprint ELAN parts share the vendor id.
  if in_list "$pid" "$ELAN_IMAGE"; then
    echo "  driver:   ${GRN}elan${RST} (image sensor, in libfprint upstream)"
    echo "  status:   ${GRN}supported out of the box${RST}"
    rc=0
  elif in_list "$pid" "$ELANMOC"; then
    echo "  driver:   ${GRN}elanmoc${RST} (match-on-chip, in libfprint upstream)"
    echo "  status:   ${GRN}supported out of the box${RST}"
    rc=0
  elif in_list "$pid" "$ELANMOC2"; then
    echo "  driver:   ${YEL}elanmoc2${RST} (match-on-chip, ${BOLD}NOT in upstream libfprint${RST})"
    echo "  status:   ${YEL}needs the out-of-tree driver${RST} — see docs/INSTALL.md"
    echo "  upstream: https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330"
    if [ "$pid" = "0c00" ]; then
      echo "  ${YEL}note:${RST} on 0c00, finger_info (ff 12) is rejected and get_fw_ver"
      echo "        returns unframed BCD. Enroll/verify are ${BOLD}unproven${RST} on this PID."
      echo "        see docs/PROTOCOL.md"
    fi
    rc=0
  else
    echo "  driver:   ${RED}none known${RST}"
    echo "  status:   ${RED}unsupported${RST} (this may not be a fingerprint reader —"
    echo "            ELAN also ships touchpads under 04f3)"
  fi

  # Is a kernel driver holding the interface?
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idProduct" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "04f3" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "$pid" ] || continue
    for i in "$d"*:*; do
      [ -d "$i" ] || continue
      if [ -e "$i/driver" ]; then
        echo "  kernel:   interface $(basename "$i") bound to $(basename "$(readlink -f "$i/driver")")"
      else
        echo "  kernel:   no driver bound (expected; userspace claims it)"
      fi
    done
  done
  echo
done

echo "${BOLD}System libfprint${RST}"
if command -v fprintd-list >/dev/null; then
  out="$(timeout 20 fprintd-list "${SUDO_USER:-$USER}" 2>&1 || true)"
  if grep -qi 'no devices' <<<"$out"; then
    echo "  fprintd sees ${RED}no usable device${RST} — the installed libfprint has no driver for it"
  else
    echo "  fprintd output: $out"
  fi
else
  echo "  fprintd not installed"
fi

exit $rc
