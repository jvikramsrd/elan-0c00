# elan-0c00

Driver work, protocol documentation, and setup instructions for the **ELAN
"Match-on-Chip 2"** fingerprint sensor family — the ELAN readers that upstream
libfprint does not support:

```
04f3:0c00    04f3:0c4c    04f3:0c5e    04f3:0c7c    04f3:0c90
```

Contains a Rust userspace driver built on `rusb`, a written protocol spec, and a
cross-distro install guide for the existing C driver.

## Does this apply to my laptop?

```sh
./scripts/check-support.sh
```

It reads `lsusb` and tells you which of the three ELAN USB driver families your
reader belongs to, and whether you need anything at all. Read-only.

Quick version — `lsusb | grep -i 04f3`, then:

| your PID | driver | what to do |
|---|---|---|
| `0903 0907 0c01`–`0c33 0c3d 0c42 0c4b 0c4d 0c4f 0c58 0c63 0c6e` | `elan` | nothing — install `fprintd` |
| `0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 0ca8 0cb0 0cb2` | `elanmoc` | nothing — install `fprintd` |
| **`0c00 0c4c 0c5e 0c7c 0c90`** | **`elanmoc2`** | **[`docs/INSTALL.md`](docs/INSTALL.md)** |
| anything else under `04f3` | — | not this family; ELAN also ships touchpads |

## I just want my fingerprint reader to work

→ **[`docs/INSTALL.md`](docs/INSTALL.md)** — AUR and Debian packages, source
build for Arch / Debian / Ubuntu / Fedora, `fprintd` and PAM setup, permissions,
rollback, and troubleshooting.

Set expectations first:

| PID | status |
|---|---|
| `0c4c` | the `elanmoc2` author's own hardware; the development target |
| `0c00` | **enroll + commit CONFIRMED WORKING** on real hardware (8 stages, committed, `fprintd-list` sees the device). Caveat: re-enrolling an already-enrolled finger hits a broken `finger_info` and, unpatched, wipes the sensor — see `patches/` |
| `0c5e` `0c7c` `0c90` | listed in the driver; no first-hand results here |

On every PID, `elanmoc2` has no `list` and no `delete` — individual prints
cannot be enumerated or removed, only wiped wholesale.

## Why this repo exists

`04f3:0c00` is not merely missing from libfprint; it is explicitly tracked as a
**known-unsupported** device in `fprint-list-udev-hwdb.c`. The only driver that
names it has been in review since 2021
([MR !330](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330)),
was written against `0c4c`, and its author does not appear to have a `0c00`.

This repo exists to close that gap with evidence: a written protocol spec, and
independent testing on real `0c00` hardware.

### What has actually been confirmed on `0c00`

```
get_enrolled_count   OUT 40 ff 04      ->  IN 40 03     (128 µs)   real count, three enrolled
get_fw_ver           OUT 40 19         ->  IN 02 83     ( 94 µs)   no frame magic; BCD 2.83
finger_info(0..9)    OUT 40 ff 12 NN   ->  IN 40 00 ..  (~230 µs)  same record for all 10 slots
```

**The sensor works.** Enroll, commit, identify, verify and delete all function
on this branch; three fingers are enrolled and each verifies to its own slot.
libfprint lists `0c00` in `allowlist_id_table[]` as known-unsupported, and on
MR !330 it isn't.

`finger_info` (`ff 12`) ignores its slot argument here — it returns the record
of the most recently identified finger, and `40 ff` when no identify has
succeeded since the device was opened. That is latent, not a live bug: both
call sites in the driver identify first. It is also why an earlier revision of
these notes wrongly recorded `ff 12` as "rejected"; probing a match-on-chip
command cold, outside the driver's state machine, measures sensor state rather
than command support.

The interface also carries a stray HID descriptor despite being
`bInterfaceClass 0xff`. Its 21-byte report descriptor is one vendor Feature
report (ID `0xBC`, 7 x 8 bits) with **no Input or Output items**, and the device
has no interrupt endpoint — a control-endpoint side channel, not a second data
path, which is why the driver is right to ignore it. Unprompted, every bulk IN
endpoint times out: the protocol is strictly request/response.

And end-to-end, through the `elanmoc2` C driver on real hardware:

```
Fingers enrolled: 1, need to check for re-enroll
Finger not enrolled, proceeding with enroll stage
Enroll stage 8 of 8 passed.   Commit succeeded.
Print for finger FP_FINGER_RIGHT_INDEX enrolled
```

Two deviations from what the driver expects, both documented in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) with the reasoning.

## The Rust driver

An independent implementation of the same wire protocol, used to gather the
evidence above without building all of libfprint.

```sh
cargo build --release

./target/release/elanctl help
sudo ./target/release/elanctl info      # fw version, enrolled count, slots
sudo ./target/release/elanctl dump      # raw hex, frame-magic check disabled
sudo ./target/release/probe             # USB descriptors, HID report descriptor
```

| binary | what it does |
|---|---|
| `probe` | Descriptors, the interface's stray HID descriptor, the HID report descriptor via standard `GET_DESCRIPTOR`, and a passive listen on each bulk IN endpoint. No vendor commands, no bulk OUT. |
| `elanctl info` | `get_fw_ver`, `get_enrolled_count`, `finger_info`. Read-only. |
| `elanctl dump` | Same commands, raw hex, no frame-magic enforcement. Diagnostic. |
| `elanctl identify` | Waits for a finger, matches on-sensor. Stores nothing. |

It is **not** a replacement for libfprint and cannot be merged into it —
libfprint is C. For a working fingerprint login, use
[`docs/INSTALL.md`](docs/INSTALL.md).

### Safety design

Every command carries an `Effect`:

| effect | commands |
|---|---|
| `ReadOnly` | `get_fw_ver`, `get_enrolled_count`, `finger_info`, `check_enroll_collision` |
| `Transient` | `abort`, `identify` |
| `Persistent` | `enroll`, `commit`, `delete`, `wipe_sensor` |

`transceive` runs `gate_check`, which **refuses every `Persistent` command
before any USB I/O**. They are reachable only via `transceive_destructive` with
a `DestructiveOps` token whose sole constructor is
`i_understand_this_modifies_stored_fingerprints()`. The CLI does not expose them.

This is a match-on-chip sensor: matching happens inside the device and the
template never crosses USB. No command reads a template out, so template export
is not a policy this crate enforces — the hardware does not offer it.

## Documentation

| file | contents |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | Get your reader working. Start here. |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Wire format, command table, status codes. Every claim tagged `[OBSERVED]` or `[PORTED]`. |
| [`docs/CONTRIBUTING-UPSTREAM.md`](docs/CONTRIBUTING-UPSTREAM.md) | How to get this device supported upstream, and why the target is libfprint rather than the Linux kernel. |
| [`docs/MR330-report.md`](docs/MR330-report.md) | Draft report for MR !330, adaptable to your PID. |
| [`NOTES.md`](NOTES.md) | Chronological investigation log: commands, results, dead ends. |

## Development

```sh
cargo fmt --check
cargo clippy --all-targets --release -- -D warnings
cargo test
cargo doc --no-deps --open
```

All clean; 15 unit tests covering frame construction, status decoding, BCD
version parsing, per-PID user-id offsets, and the destructive-command gate. No
hardware required.

## Contributing your results

Results on any PID other than `0c4c` are genuinely useful, since the driver's
author cannot test them. Even "it does not work, here is the error" moves MR
!330 forward. See [`docs/CONTRIBUTING-UPSTREAM.md`](docs/CONTRIBUTING-UPSTREAM.md).

## License

**LGPL-2.1-or-later**, matching libfprint. The protocol implementation was
derived by reading the `elanmoc2` driver (LGPL-2.1-or-later) by Davide Depau —
a close structural port rather than a clean-room reimplementation, so it
inherits that licence.

## Credits

- Davide Depau (`depau`) — the `elanmoc2` driver this work builds on
- The libfprint project — <https://fprint.freedesktop.org/>
