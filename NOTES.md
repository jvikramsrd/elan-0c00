# ELAN 04f3:0c00 (ELAN:ARM-M4) — driver investigation notes

Host: Arch, kernel 7.1.9-arch1-2. libfprint 1.94.100-1, fprintd 1.94.5-2, libusb 1.0.30.
Device: bus 1, addr 3 (`/sys/bus/usb/devices/1-4`, node `/dev/bus/usb/001/003`).

## Loop 1 — enumeration, upstream-support check, read-only probe

### Commands run

```
lsusb -d 04f3:0c00
lsusb -v -d 04f3:0c00
usb-devices | grep -A12 04f3
journalctl -k | grep -i -E 'elan|usb 1-4'
grep -i 04F3 /usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb
grep -c 04f3 /usr/lib/udev/rules.d/70-libfprint-2.rules
fprintd-list $USER
python3 <id-table scanner> /usr/lib/libfprint-2.so.2.0.0
cargo build --release && ./target/release/probe
```

## CONFIRMED FACTS (observed, not assumed)

### Device topology
- `bcdUSB 2.00`, full speed (12 Mbps), `bcdDevice 2.83`, `bMaxPacketSize0 = 8`.
- `bDeviceClass 0x00`, 1 configuration, `MaxPower 100mA`, bus-powered, remote wakeup.
- Strings: `iManufacturer="ELAN"`, `iProduct="ELAN:ARM-M4"`, `iSerial = 0` (**none**).
- **1 interface** (IF 0, alt 0), `bInterfaceClass 0xff` (vendor specific), sub 0x00, proto 0x00.
- **8 endpoints, all Bulk, all wMaxPacketSize 64, bInterval 1**:
  `0x81/0x01`, `0x82/0x02`, `0x83/0x03`, `0x84/0x04` (IN/OUT pairs 1–4).
- **No kernel driver bound** to IF 0 (`usb-devices` → `Driver=(none)`; no `driver` symlink
  in sysfs). No detach needed; nothing is competing for the device.
- Kernel log shows clean enumeration, zero errors/resets.

### The odd bit: a HID descriptor on a vendor-class interface
The interface carries a 9-byte class-specific descriptor that `lsusb` prints as
`** UNRECOGNIZED: 09 21 10 01 00 01 22 15 00`. Decoded by our probe:

| field | value |
|---|---|
| bLength | 9 |
| bDescriptorType | **0x21 (HID)** |
| bcdHID | 1.10 |
| bCountryCode | 0 |
| bNumDescriptors | 1 |
| subordinate bDescriptorType | **0x22 (Report)** |
| subordinate wDescriptorLength | **21 bytes** |

So the device advertises a 21-byte HID **report descriptor** while declaring itself
vendor-class with bulk-only endpoints. Fetching that descriptor is a standard,
spec-defined, read-only `GET_DESCRIPTOR` — the safest possible next transfer.

### Upstream support: NOT supported by libfprint 1.94.100
Two sources disagree; the driver tables win.

- `60-autosuspend-libfprint-2.hwdb` **does** contain `usb:v04F3p0C00*`. This file is an
  autosuspend superset — it also lists 0c4b/0c57/0c5a/0c60/0c72/0c85/0c90/0ca2 etc.
  that appear in **no** driver table. **It is not a support claim.**
- `70-libfprint-2.rules` contains **zero** `04f3` USB entries (only ACPI `ELAN7001`
  SPI rules, 8 lines total).
- Binary scan of `libfprint-2.so.2.0.0` for `FpIdEntry` records (32-byte stride,
  `{u32 pid, u32 vid, ...}`) found **88** entries with `vid == 0x04f3`, in 3 tables:
  - 61 entries: `0903 0907 0c01 0c02 … 0c33 0c3d 0c42 0c4b 0c4d 0c4f 0c63 0c6e 0c58`
  - 16 entries: `0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 0ca8 0cb0 0cb2`
  - 11 entries: `2766 3057 3087 30c6 3128 3134 3148 30b2 30b2 309f 241f`
  - **`0c00` appears in none of them.** The `elan` table starts at `0c01` — our PID is
    exactly one below the supported range. Reverse-layout scan and a ±32-byte proximity
    scan both return zero hits for `0c00`.
- `fprintd-list $USER` → **`No devices available`** (rc=1). Independent confirmation.

**Conclusion: no existing Linux driver claims 04f3:0c00.** Proceeding with the Rust
userspace prototype is justified, and the `elan` family (0c01+) is the closest
upstream-compatible protocol reference.

## Probe results (`./target/release/probe`, unprivileged)
Descriptor walk succeeded and matched `lsusb` exactly, including the HID decode above.

Open failed: `Access denied (insufficient permissions)`.
`/dev/bus/usb/001/003` is `crw-rw-r-- root root` — libusb needs **write** access.
`sudo` on this host requires a password, so the open/control/bulk phase must be run
by the user. No udev rule installed (would be a persistent system change — not done
without asking).

## Safety policy encoded in `src/probe.rs`
- Opens **only** VID 0x04f3 / PID 0x0c00.
- Issues **only standard** `GET_DESCRIPTOR` control reads (`bmRequestType 0x81`).
  **No vendor-type control requests.**
- **Never performs a bulk/interrupt OUT transfer** — the device is never sent a
  command it isn't obliged to answer by USB spec.
- Bulk IN reads are passive (300 ms); with nothing queued the device NAKs and times
  out. Nothing is written, erased, enrolled, calibrated, or reconfigured.
- Releases the interface and never detaches a kernel driver.

## HYPOTHESES (unproven)
- H1: 0c00 is an early/pre-production or OEM variant of the `elan` 0c01–0c33 family and
  may speak the same protocol. Untested — would require sending vendor commands.
- H2: The 4 bulk EP pairs are functional channels (e.g. command / image / status),
  common in ELAN match-on-chip parts. Untested.
- H3: The HID report descriptor may name a vendor usage page that identifies the
  protocol family. **This is testable with a read-only standard request.**

## OPEN QUESTIONS
- What are the 21 bytes of the HID report descriptor?
- Does the device volunteer any data on a bulk IN with no prior OUT?
- Is this a match-on-chip (MOC) part (templates stored on device) or an image sensor?
- Is a vendor firmware blob required before the sensor responds at all?

## NOT DONE (requires explicit approval)
- Sending any vendor-specific command, including `elan`-family probe commands.
- Installing a udev rule (persistent system change).
- Anything touching firmware or enrollment storage.

---

# Loop 2 — upstream research: 0c00 IS a known device, and a driver exists

## RESOLVED: the hwdb contradiction
`libfprint/fprint-list-udev-hwdb.c:43` (present in **both** v1.94.100 and master
@6f9479c3, 2026-09-02):

```c
static const FpIdEntry allowlist_id_table[] = {
  /* Currently known and unsupported devices. */
  ...
  { .vid = 0x04f3, .pid = 0x0c00 },
```

So upstream libfprint **explicitly tracks 04f3:0c00 as a KNOWN UNSUPPORTED device**.
The hwdb entry exists solely to inhibit USB autosuspend on known readers; it is not a
support claim. `fprintd-list` → "No devices available" is the correct behaviour.

**Mainline libfprint, including current master, has no driver for 04f3:0c00.**

## FOUND: the `elanmoc2` out-of-tree driver supports 0c00
Branch `depau/elanmoc2` @ `11f0316d` (2025-07-27, "WIP add 0c7c"),
`git describe` = `v1.94.9-11-g11f0316d` (based on v1.94.9, does NOT contain v1.94.100).
Repo: https://gitlab.freedesktop.org/Depau/libfprint.git
(Second branch `elanmoc2-working` @ 3d489ebe, 2023-03-22, is older.)

`libfprint/drivers/elanmoc2/elanmoc2.c:1160`:
```c
static const FpIdEntry elanmoc2_id_table[] = {
  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c00, .driver_data = ELANMOC2_ALL_DEV},   /* <== OURS */
  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c4c, .driver_data = ELANMOC2_ALL_DEV},
  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c5e, .driver_data = ELANMOC2_DEV_0C5E},
  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c7c, .driver_data = ELANMOC2_ALL_DEV},
  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c90, .driver_data = ELANMOC2_ALL_DEV},
```
Corroboration: `0c4c`, `0c7c`, `0c90` also sit in upstream's known-unsupported
allowlist — a consistent story (elanmoc2 covers devices mainline declined).

### Endpoint cross-check — driver expectations vs OBSERVED hardware
| elanmoc2 `#define` | value | present on our device? |
|---|---|---|
| `ELANMOC2_EP_CMD_OUT` | `0x01` OUT | **yes** |
| `ELANMOC2_EP_CMD_IN`  | `0x83` IN  | **yes** |
| `ELANMOC2_EP_MOC_CMD_IN` | `0x84` IN | **yes** |

`G_DEFINE_TYPE (..., FP_TYPE_DEVICE)` → match-on-chip, `FP_SCAN_TYPE_PRESS`,
`nr_enroll_stages = 8`. Match-on-chip means templates never leave the sensor, which
suits the "do not export templates" constraint.

## CORRECTION to the Loop 1 plan
The plan to add `0c00` to the **`elan`** ID table was **wrong**. `elan` is
`FP_TYPE_IMAGE_DEVICE` (PIDs 0c01–0c33); `elanmoc` is MOC (PIDs 0c7d–0cb2). Our part
belongs to neither — it is an `elanmoc2` device. PID adjacency to 0c01 was a red
herring. Integrating `elanmoc2` is the correct upstream-compatible route.

## THREE distinct ELAN USB driver families (v1.94.100 tables, verified)
- `elan` (image, 61 IDs): 0903 0907 0c01…0c33 0c3d 0c42 0c4b 0c4d 0c4f 0c58 0c63 0c6e
- `elanmoc` (MOC, 16 IDs): 0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 0ca8 0cb0 0cb2
- `elanmoc2` (MOC, out-of-tree, 5 IDs): **0c00** 0c4c 0c5e 0c7c 0c90

## Build status
`meson setup build -Ddrivers=elanmoc2 -Dintrospection=false -Ddoc=false \
  -Dgtk-examples=false -Dinstalled-tests=false --prefix=/usr`
in worktree `~/elan-0c00/work/moc2`.

Configure **failed**: `glib-mkenums` missing. On Arch it now lives in `glib2-devel`
(core, 2.88.3-1, matches installed glib 2.88.3). Present already: nss, pixman,
libgudev, gobject-introspection, meson, ninja, gcc.

## Plan (revised)
1. Install `glib2-devel`, finish the build **in-tree** (do NOT install over system
   libfprint yet).
2. Zero-risk test: enumerate with the built lib — does it now claim 04f3:0c00 and
   name the driver? Enumeration matches on USB IDs and needs no device I/O.
3. Only then, with approval, `fp_device_open()` — the first step that sends real
   vendor commands.

## Still not done / still needs approval
- Any device-modifying step (enroll, delete, firmware). Enrollment writes persistent
  biometric data to the sensor and will not be run without an explicit go-ahead.

---

# Loop 3 — Rust driver written (protocol ported from elanmoc2)

## Protocol recovered (from depau/elanmoc2 @ 11f0316d, read line-by-line)

### Framing — `elanmoc2_prepare_cmd` + `elanmoc2_cmd_transceive_full`
```
OUT (bulk, EP 0x01): [0x40] [opcode 1..2 B] [payload] [0x00 pad ...]  == out_len exactly
IN  (bulk, cmd.ep_in): exactly in_len bytes; resp[0] MUST be 0x40 else protocol error
```
`buffer->data[0] = 0x40; memcpy(&buffer->data[1], cmd->cmd, is_single_byte ? 1 : 2);`
Receive-side check: `if (transfer->buffer[0] != 0x40) -> FP_DEVICE_ERROR_PROTO`.

### Command table (complete)
| command | opcode | out_len | in_len | ep_in | effect |
|---|---|---|---|---|---|
| get_fw_ver | `19` (1-byte) | 2 | 2 | 0x83 | read-only |
| get_enrolled_count | `ff 04` | 3 | 2 | 0x83 | read-only |
| finger_info | `ff 12` | 4 | 64 | 0x83 | read-only |
| check_enroll_collision | `ff 10` | 3 | 3 | 0x83 | read-only |
| abort | `ff 02` | 3 | 2 | 0x83 | transient |
| identify | `ff 03` | 3 | 2 | **0x84** | transient (blocks on finger) |
| enroll | `ff 01` | 7 | 2 | **0x84** | **PERSISTENT** |
| commit | `ff 11` | 72 | 2 | 0x83 | **PERSISTENT** |
| delete | `ff 13` | 72 | 2 | 0x83 | **PERSISTENT** |
| wipe_sensor | `ff 99` | 3 | 0 | 0x83 | **PERSISTENT** (stalls ~5 s) |

### Semantics
- `get_enrolled_count` reply: `resp[1]` = number enrolled. Sent with
  `short_is_error = false`; a zero-length reply is legal and must be retried,
  up to `ELANMOC2_MAX_RETRIES` (3).
- `finger_info` request: `buffer_out->data[3] = finger_index` (hence out_len 4).
- `finger_info` reply: user-id begins at offset **2**, or **3** on PID 0c5e.
  Not NUL-terminated; copy then terminate.
- Status byte `resp[1]`: `(b & 0xF0) == 0` -> ordinary/retryable status.
  Otherwise: 0x41/42/43/44 = move down/right/up/left, 0xdd = storage full,
  0xfb = sensor dirty, 0xfd = not enrolled, 0xfe = not enough surface.
- Match-on-chip: the biometric template never crosses USB. `finger_info`
  returns only a user-id string, so template export is not merely disallowed
  here, it is not offered by the hardware.

## Code written (`~/elan-0c00`)
```
src/lib.rs          crate root, safety posture documented
src/proto.rs        framing, full command table, Status decoding   (9 tests)
src/device.rs       rusb transport, retries, DestructiveOps gate   (4 tests)
src/bin/probe.rs    loop-1 read-only descriptor probe (unchanged)
src/bin/elanctl.rs  CLI: `info` (read-only), `identify`, `help`
```

### Safety design
- Every `Cmd` carries an `Effect` (`ReadOnly` / `Transient` / `Persistent`).
- `ElanMoc2::transceive` calls `gate_check`, which **refuses** every
  `Persistent` command before any USB I/O happens.
- Persistent commands are reachable only via `transceive_destructive`, which
  requires a `DestructiveOps` token whose sole constructor is
  `DestructiveOps::i_understand_this_modifies_stored_fingerprints()`.
- `elanctl` does **not** expose enroll/commit/delete/wipe at all.

## Verification (reproducible)
```
$ cargo fmt --check ; echo $?        -> 0
$ cargo clippy --all-targets --release -- -D warnings ; echo $?  -> 0
$ cargo build --release              -> Finished
$ cargo test --lib                   -> 13 passed; 0 failed
$ ./target/release/elanctl help      -> usage printed
$ ./target/release/elanctl info      -> open failed: usb: Access denied  (exit 1)
```
The 13 tests are hardware-free: they cover frame construction (magic byte,
1-vs-2-byte opcode, finger index at byte 3, zero padding to 72, oversized
payload rejection), Status nibble decoding, user-id offset per PID, and that
the gate refuses all four persistent commands while allowing all six safe ones.

## NOT YET VERIFIED ON HARDWARE
**No command in this table has been sent to the physical sensor yet.** The
byte-level protocol is a faithful port of a third-party WIP driver, not
something confirmed against 04f3:0c00. Everything above is "believed correct
by construction", not "observed working".

Blocked on: write access to `/dev/bus/usb/001/003` (root-owned 0664; sudo
needs a password on this host). Also still pending: `glib2-devel` for the
reference C build.

## Next
`sudo ./target/release/elanctl info` — sends only get_fw_ver,
get_enrolled_count, finger_info. First real hardware traffic.

---

# Loop 4 — hardening and documentation

## Correction: the Linux kernel is the wrong upstream
Fingerprint readers are not kernel drivers on Linux by design. The kernel
enumerates `04f3:0c00` as vendor-class USB and binds nothing (`Driver=(none)`);
all protocol work is userspace. There is no in-tree fingerprint subsystem to
submit to. Correct upstream is **libfprint** (LGPL-2.1+, freedesktop GitLab),
which also matches the original brief ("userspace/libfprint-compatible
implementation before considering a kernel driver").
Full reasoning: `docs/CONTRIBUTING-UPSTREAM.md`.

## Upstream state (queried, not assumed)
MR 330 "Add driver for ELAN MoC 0c4c", author `depau`:
- opened 2021-09-19, **still open**, last activity 2026-08-01
- `merge_status: cannot_be_merged` (conflicts with master)
- 189 comments, not a draft

Queried through the GitLab REST API; the web UI is behind Anubis and returns an
"Access Denied" page to non-browser clients:
```sh
curl -sS "https://gitlab.freedesktop.org/api/v4/projects/libfprint%2Flibfprint/merge_requests/330"
```
The driver targets `0c4c`; the author does not appear to have a `0c00`. That is
where a contribution has leverage.

## libfprint requirements (from HACKING.md + tests/README.md)
- Merge requests on freedesktop GitLab; gtk-doc on public API; no proprietary shims.
- New/variant device support is proven by a **umockdev capture**. For
  match-on-chip parts: write `custom.py`, record to `custom.pcapng` via
  `sudo tests/create-driver-test.py --test custom elanmoc2 0c00`, register the
  directory in `drivers_tests` in `tests/meson.build`, then `meson test`.
- The unsupported allowlist is generated:
  `meson compile -C build sync-unsupported-devices` — never hand-edit.

## Crate hardening
Lints raised to `#![warn(missing_docs)] #![forbid(unsafe_code)] #![warn(clippy::pedantic)]`.
All 33 resulting warnings fixed (every public item, field and enum variant now
documented). Replaced a `.collect::<Vec<String>>().join("")` with a `fold` per
clippy pedantic.

## Documentation added
- `docs/PROTOCOL.md` (214 lines) — full wire spec. Every claim tagged
  **[OBSERVED]** (read off this machine's hardware) or **[PORTED]**
  (transcribed from elanmoc2, unverified on 0c00). Includes 5 open questions.
- `docs/CONTRIBUTING-UPSTREAM.md` (203 lines) — kernel-vs-libfprint reasoning,
  MR 330 status, 5 ranked contribution routes, umockdev recipe, licensing.
- `README.md`, `LICENSE`, `.gitignore`.

## Licensing decision
Crate is **LGPL-2.1-or-later**. `proto.rs`/`device.rs` were written by reading
`elanmoc2.{c,h}` (LGPL-2.1+). Protocol facts are not copyrightable, but this is
a close structural port rather than a clean-room reimplementation, so matching
the source licence is the honest call. A permissive licence would require
re-deriving the protocol from own captures without reference to the source.

## Verification
```
cargo fmt --check                                     -> 0
cargo clippy --all-targets --release -- -D warnings   -> 0   (incl. pedantic)
cargo test                                            -> 13 passed; 0 failed
cargo doc --no-deps                                   -> 0
```

## UNCHANGED BLOCKER
Still **zero** bytes exchanged with the physical sensor. Everything remains
"correct by construction". `sudo ./target/release/elanctl info` is the
outstanding experiment.

---

# Loop 5 — FIRST HARDWARE TRAFFIC. Protocol partially confirmed, two anomalies.

## Commands run
```sh
sudo ./target/release/elanctl info
sudo ./target/release/elanctl dump    # raw mode, frame-magic check disabled
```
(`!` without a TTY fails: "sudo: a terminal is required to read the password".
Running it from the interactive prompt works.)

## Raw capture
```
opened ELAN 04f3:0c00, interface 0 claimed
get_fw_ver          out= 2B in= 2B ep=0x83 -> [02 83]   ( 94 us)
get_enrolled_count  out= 3B in= 2B ep=0x83 -> [40 01]   ( 78 us)
finger_info(0..9)   out= 4B in= 2B ep=0x83 -> [40 ff]   (155-183 us, all 10 slots)
```

## CONFIRMED [OBSERVED on 04f3:0c00]
1. **Device opens and interface 0 claims cleanly.** No kernel driver to detach.
2. **Framing is real.** `40 ff 04` -> `40 01`. Magic byte `0x40`, EP `0x01` OUT /
   EP `0x83` IN, and the `[0x40][opcode]` encoding all behave as ported.
   These move from [PORTED] to [OBSERVED].
3. Round-trip latency 78-183 us for all queries. No finger interaction needed.

## ANOMALY 1 — `get_fw_ver` reply is unframed BCD
Reply `02 83`, first byte `0x02` not `0x40`. Device descriptor says
`bcdDevice 2.83`. Packed-BCD decode: `bcd(0x02)=2`, `bcd(0x83)=83` -> **2.83**,
an exact match. So the reply is a bare 2-byte version, not a framed message.

Why upstream never caught it: `cmd_get_fw_ver` is **defined in `elanmoc2.h` but
never referenced in `elanmoc2.c`** (verified by grep in loop 2). Dead code, so
its reply framing was never exercised. This is an upstream bug.

## ANOMALY 2 — `finger_info` (`ff 12`) rejected on every slot
`40 ff 12 NN` -> `40 ff`, 2 bytes, identical for all slots 0-9. Byte 1 = `0xff`;
MSN set, so a terminal error by the driver's own rule. `0xff` is **not** in the
reference driver's error list.

`get_enrolled_count` (`ff 04`) works, so `0xff`-family opcodes are accepted in
general. `ff 12` specifically is unsupported or differently shaped on this PID.

Consequence: upstream sets `short_is_error = TRUE` here, and
`IDENTIFY_GET_FINGER_INFO` runs after every successful match — so **the
elanmoc2 identify path cannot work on 04f3:0c00 as written.**

## UNRESOLVED CONTRADICTION
`get_enrolled_count` says 1, but no slot returns readable content and all ten
answer identically. Either `resp[1] = 0x01` is a status rather than a count, or
templates are not addressable via `ff 12` here. Nothing so far distinguishes
these. **Do not assume a finger is enrolled.**

(Earlier report of "1 finger enrolled, empty user_id" in `info` mode was the
same `40 ff` reply, silently sliced to an empty user-id by the offset-2 read.
`finger_info` now returns `Error::Status(Rejected)` instead of an empty string.)

## Code changes
- `Status::Rejected` added for `0xff`, with `describe()` and retryability.
- `proto::bcd()` packed-BCD decoder.
- `ElanMoc2::transceive_raw()` — gated, but skips magic validation.
- `firmware_version()` now returns `FirmwareVersion { major, minor, raw }` via
  the raw path, `Display` as `2.83`.
- `finger_info()` checks the status byte and errors instead of returning an
  empty user-id.
- `elanctl dump` subcommand.

## Verification
```
cargo fmt --check                                    -> 0
cargo clippy --all-targets --release -- -D warnings  -> 0
cargo test --lib                                     -> 15 passed; 0 failed
cargo doc --no-deps                                  -> 0
```
Two new tests: `bcd_decodes_observed_firmware_bytes` (pins 02/83 -> 2/83 against
the observed capture) and `status_ff_is_rejected`.

## Next safest experiment
`sudo ./target/release/probe` — never yet run with privileges. Standard
`GET_DESCRIPTOR(0x22)` for the 21-byte HID report descriptor (open question 1),
string descriptors, and a passive bulk-IN listen on EP 0x81-0x84. Sends **no**
vendor commands.

## NOT DONE
No opcode guessing to find what replaces `ff 12`. The brief forbids sending
guessed commands, and blind `ff XX` sweeps could hit `ff 99` (wipe) or `ff 13`
(delete) semantics on adjacent values.

---

# Loop 6 — upstream report drafted

`docs/MR330-report.md` — draft comment for libfprint MR !330.

## Deliberate constraint in the draft
It states plainly that the results come from an **independent Rust
implementation of the wire protocol, not from building and running the C
branch**. We never installed `glib2-devel`, so the branch has never been
compiled here. Claiming otherwise on a five-year-old MR would be both false and
easy for the author to catch.

Content: hardware identification (HP Pavilion Aero 13-be2xxx, BIOS F.26),
descriptor dump, the confirmed framing, the two deviations with raw bytes and
timings, the count-vs-status open question, and an offer to build/capture/test.

## To strengthen it materially
1. `sudo pacman -S --needed glib2-devel`
2. `meson setup build -Ddrivers=elanmoc2 && meson compile -C build` in
   `work/moc2`
3. Run through `fprintd` against the built branch and report where it actually
   fails, rather than where we infer it would.
4. `sudo tests/create-driver-test.py --test custom elanmoc2 0c00` for a umockdev
   capture — this is what makes device support permanent upstream.

## Still not done
- No opcode sweep for a `ff 12` replacement (adjacent to delete/wipe).
- Nothing posted anywhere. The draft is local and unsent.

---

# Loop 7 — libfprint + elanmoc2 BUILT and claiming 04f3:0c00

`glib2-devel` installed by the user; configure and build now succeed.

```sh
cd ~/elan-0c00/work/moc2
meson setup build -Ddrivers=elanmoc2 -Dintrospection=false -Ddoc=false \
                  -Dgtk-examples=false -Dinstalled-tests=false --prefix=/usr
meson compile -C build          # 101/101 targets, no errors
```
Reports `libfprint 1.94.9`, `Drivers: elanmoc2`.

## VERIFIED without touching hardware
```
$ ./build/libfprint/fprint-list-supported-devices
USB ID | Driver
04f3:0c00 | ELAN Match-on-Chip 2      <== ours
04f3:0c4c | ELAN Match-on-Chip 2
04f3:0c5e | ELAN Match-on-Chip 2
04f3:0c7c | ELAN Match-on-Chip 2
04f3:0c90 | ELAN Match-on-Chip 2
```
Compare loop 1, where stock libfprint 1.94.100 listed no `0c00` driver at all
and `fprintd-list` said "No devices available".

## NEW FINDING — elanmoc2 implements no per-print list or delete
From `fpi_device_elanmoc2_class_init`:
```
open close identify verify enroll clear_storage cancel
```
`dev_class->list` and `dev_class->delete` are **not set**. Consequences:
- `examples/manage-prints` cannot work (it calls `fp_device_list_prints`).
- Storage management is all-or-nothing: `clear_storage` (the `ff 99` wipe) is
  the only removal path.
This is worth raising on MR !330 independently of the `0c00` issues.

`examples/manage-prints` also prompts `[<number>/A/n]` and deletes only on a
numeric index or uppercase `A`; `n` exits cleanly. Not used, since list is
unimplemented.

## elanmoc2_open sends no protocol commands
```c
g_usb_device_reset (...);
g_usb_device_claim_interface (..., 0, 0, ...);
self->dev_type = fpi_device_get_driver_data (...);
fpi_device_open_complete (device, NULL);
```
USB reset plus claim only. So opening the device is a zero-risk test.

## Tool added
`tools/fp-probe.c` — links against the freshly built libfprint (rpath into
`work/moc2/build/libfprint`, confirmed with `ldd`). Enumerates devices, prints
driver/name/scan-type/enroll-stages/feature flags, then opens and closes.
No enroll, no delete, no wipe.

Build line recorded in the file header; compiles clean with gcc.

## Next
`sudo ./tools/fp-probe` — first exercise of the real C driver against the
physical sensor.

---

# Loop 8 — documentation for other people's machines

## Added
- `scripts/check-support.sh` — read-only. Parses `lsusb`, classifies any `04f3`
  device against the three verified ELAN USB driver tables (`elan`, `elanmoc`,
  `elanmoc2`), reports kernel binding, and asks `fprintd-list` what the *system*
  libfprint thinks. Emits a PID-specific warning for `0c00`.
  Tested on this machine: correctly identifies `0c00` as `elanmoc2`,
  not-in-upstream, no kernel driver bound, and notes fprintd sees nothing.
  Deliberately warns that `04f3` also covers ELAN touchpads, so a vendor match
  is not automatically a fingerprint reader.
- `docs/INSTALL.md` (245 lines) — cross-distro. AUR
  (`libfprint-elanmoc2-git`, `libfprint-elanmoc2-working-git`) and the Debian
  packaging at `Greek64/libfprint-elanmoc2-deb`; source build with real
  dependency lists for Arch / Debian / Ubuntu / Fedora, extracted from
  `meson.build` rather than guessed; `fprintd` + PAM; udev `uaccess` rule;
  rollback; troubleshooting.
- `README.md` rewritten to lead with "does this apply to my laptop", with the
  full PID → driver table so a reader can self-select in one step.

## Warnings deliberately included
- Installing the fork **replaces system libfprint**; rollback documented before
  the install steps.
- On Arch, `meson install` is silently reverted by the next `libfprint` package
  upgrade — AUR is the durable route.
- PAM edits can lock you out; keep a root shell, and `sufficient` keeps password
  auth working.
- Per-PID expectations are stated up front: `0c4c` is the development target;
  `0c00` enroll/verify **unproven**; `0c5e`/`0c7c`/`0c90` untested here.
- `elanmoc2` has no `list`/`delete`, so `manage-prints` failing is not a
  misconfiguration.

## Verification
```
./scripts/check-support.sh   -> correct output on this machine (exit 0)
cargo fmt --check            -> 0
cargo clippy ... -D warnings -> 0
cargo test --lib             -> 15 passed
```
`shellcheck` not installed, so the script is unlinted.

## STILL OUTSTANDING
`sudo ./tools/fp-probe` has **not been run**. The C driver has never been
exercised against the physical sensor — only built, and confirmed to claim
`04f3:0c00` via `fprint-list-supported-devices`.

---

# Loop 9-10 — C driver opens 0c00; enroll path found to be WIPE-DANGEROUS; hazard patched

## fp-probe result [OBSERVED] — libfprint integration works
```
driver elanmoc2   name "ELAN Match-on-Chip 2"   scan type press   enroll stages 8
storage yes | identify yes | verify yes | list NO | delete NO | clear yes
opening (USB reset + claim)... ok      closing... ok
```
`fp_device_open_sync` succeeds on the physical sensor. Feature flags match the
source reading from loop 7 exactly.

## Why omarchy's fingerprint setup failed
`Impossible to enroll: ...NoSuchDevice: No devices available`.
fprintd loads `/usr/lib/libfprint-2.so.2` = stock libfprint 1.94.100-1, whose
tables contain no `0c00` (verified by binary scan). Our build was never
installed. `pacman -Q` confirms libfprint/fprintd were NOT modified by the
omarchy script; it only pulled build tooling.

## check_enroll_collision (ff 10) [OBSERVED] — the enroll path is dangerous
```
OUT 40 ff 10   ->   IN 40 00 ff    (39 ms, returned without waiting for a finger)
```
`resp[1] = 0x00`. In `elanmoc2_get_finger_error`:
```c
if ((data_in[1] & 0xF0) == 0) { *out_can_retry = TRUE; return NULL; }
```
No error -> `ENROLL_GET_ENROLLED_FINGER_INFO` treats it as "already enrolled at
slot 0" -> `print_index = 0` -> sends `finger_info` (known rejected on 0c00)
-> `ENROLL_ATTEMPT_DELETE` -> delete built from a malformed reply -> fails ->
`ENROLL_CHECK_DELETED`:
```c
if (data_in[1] != 0) { fp_info("Failed to delete finger %d, wiping sensor");
                       fpi_ssm_jump_to_state (ssm, ENROLL_WIPE_SENSOR); }
```
**Running `fprintd-enroll` on 04f3:0c00 with the unmodified driver would very
likely erase every stored template.** Confirmed by source, not speculation.

Note the reply is 3 bytes (`in_len = 3`) but upstream reads only `resp[1]`.
`resp[2] = 0xff` is unexamined; its meaning is unknown.

## Patch applied locally
`patches/0001-elanmoc2-no-wipe-on-failed-delete.patch` — replaces the
wipe escalation with a clean `fpi_device_enroll_complete(error)`. Rationale:
silently destroying every enrolled fingerprint because one delete failed is
indefensible regardless of device, and on 0c00 the delete can never succeed.

Verified unreachable afterwards: `ENROLL_WIPE_SENSOR` has zero `jump_to_state`
references left, `ENROLL_CHECK_DELETED` ends in `break` before it, and neither
branch calls `fpi_ssm_next_state`. `cmd_wipe_sensor` now reachable only through
`clear_storage`. Rebuilt clean.

## Install script bug fixed
`scripts/install-local.sh` used `$HOME`, which is `/root` under sudo ->
"no build at /root/elan-0c00/...". Now resolves `SUDO_USER`'s home via
`getent passwd`.

## Expectation for the next run
With the patch, enrollment is **safe but expected to FAIL**: the SSM should
still reach ENROLL_ATTEMPT_DELETE and abort with "Could not delete the existing
finger; refusing to wipe the sensor". That failure is the goal -- it yields the
`delete` response byte, which is new evidence, at zero risk.

---

# Loop 11 — ENROLLMENT WORKS ON 04f3:0c00

## Result: full enroll + commit succeeded
`sudo G_MESSAGES_DEBUG=all build/examples/enroll`, finger 6 (right index),
update = n:

```
Fingers enrolled: 1, need to check for re-enroll
Sent identification request                      <- cmd_identify (ff 03)
Finger not enrolled, proceeding with enroll stage   <- SAFE branch taken
Enroll command sent: 0/8 .. 7/8   (all 8 stages succeeded, ~0.7 s each)
Check re-enroll command sent
Finger is not enrolled, committing
Commit command sent
Commit succeeded
Print for finger FP_FINGER_RIGHT_INDEX enrolled
ENROLL_NUM_STATES completed successfully
```

So `enroll` (ff 01) and `commit` (ff 11) both work on this PID. The sensor
accepts and stores a template. **04f3:0c00 is functional under elanmoc2.**

`fprintd-list` now reports: `found 1 devices ... ELAN Match-on-Chip 2`.

## CORRECTION to loops 9-10
`ENROLL_EARLY_REENROLL_CHECK` sends **`cmd_identify` (ff 03)**, not
`cmd_check_enroll_collision` (ff 10). The `elanctl collision` probe therefore
tested the wrong command, and its "DANGEROUS" verdict did not describe the path
enrollment actually takes. `identify` returned "not enrolled" for a finger that
was not on the sensor, so the delete branch was never entered.

`ff 10` is not used by the enroll SSM at all. Its `40 00 ff` reply remains
unexplained but is not load-bearing.

## The wipe hazard is still real, but narrower than stated
It applies when `identify` **matches** — i.e. re-enrolling a finger already on
the sensor. Then:
`identify -> slot N -> finger_info (rejected, 40 ff) -> delete (malformed) ->
fails -> ENROLL_WIPE_SENSOR`.

That is a common user action ("enroll my index finger again"), so the bug
matters, but it does not fire on a first enroll of a new finger. Earlier notes
overstated the scope; this is the accurate statement.

Our patch converts that path into a clean error instead of a wipe.

## Still unknown
- What `delete` (ff 13) returns on 0c00 -- the re-enroll path was never reached.
- Meaning of `resp[2] = 0xff` in the `ff 10` reply.
- Why `finger_info` (ff 12) is rejected, given enroll/commit work fine.

## Next
`fprintd-enroll -f left-index-finger` then `fprintd-verify` -- end-to-end
through fprintd rather than the example binary. Use a **different finger** from
the one just enrolled: re-enrolling right index would take the delete path.
