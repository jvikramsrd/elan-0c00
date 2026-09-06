# How to get `04f3:0c00` supported upstream

## Read this first: the Linux kernel is the wrong target

Fingerprint readers are **not** kernel drivers on Linux, by deliberate design.

The kernel's job for a device like this ends at enumerating it on the USB bus.
`04f3:0c00` presents `bInterfaceClass 0xff` (vendor-specific) with plain bulk
endpoints, so the kernel exposes it through `usbfs` and binds no driver — which
is exactly what `usb-devices` reports (`Driver=(none)`). All protocol handling,
matching, template storage and policy lives in **userspace**.

A USB fingerprint driver sent to LKML would be rejected on architecture
grounds, not on quality. There is no `drivers/usb/fingerprint/` to contribute
to, and no in-tree fingerprint subsystem that would accept one.

The upstream that matters is **libfprint**:

- Project: <https://gitlab.freedesktop.org/libfprint/libfprint>
- Consumed by `fprintd`, which is what GNOME/KDE/PAM actually talk to
- License: LGPL-2.1-or-later
- Contribution process: `HACKING.md` in that repo

(The kernel *is* involved in one narrow case — ELAN's **SPI** sensors need
`spidev` binding, which is why `70-libfprint-2.rules` carries ACPI rules for
`ELAN7001`/`ELAN70A1`. That does not apply to this USB part.)

## The current upstream situation

`04f3:0c00` is not unknown to libfprint. It is explicitly tracked as a
**known-unsupported** device:

```c
/* libfprint/fprint-list-udev-hwdb.c */
static const FpIdEntry allowlist_id_table[] = {
  /* Currently known and unsupported devices. */
  ...
  { .vid = 0x04f3, .pid = 0x0c00 },
```

That list only generates `60-autosuspend-libfprint-2.hwdb`, whose purpose is to
inhibit USB autosuspend on readers the library recognises but cannot drive. It
is **not** a support claim — a distinction worth knowing, because the hwdb entry
looks like support at a glance and is not.

Confirmed absent from every driver ID table in v1.94.100 and in master
@`6f9479c3` (2026-09-02). The three in-tree ELAN USB families are:

| driver | type | PIDs |
|---|---|---|
| `elan` | `FP_TYPE_IMAGE_DEVICE` | `0903 0907 0c01`–`0c33 0c3d 0c42 0c4b 0c4d 0c4f 0c58 0c63 0c6e` |
| `elanmoc` | match-on-chip | `0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 0ca8 0cb0 0cb2` |
| `elanmoc2` | match-on-chip, **out of tree** | `0c00 0c4c 0c5e 0c7c 0c90` |

`0c00` sits one PID below `elan`'s contiguous range, which is a tempting but
**false** lead — it is an `elanmoc2` part, not an image sensor.

### The open merge request

Everything hinges on one long-running MR:

- **<https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330>**
- Title: "Add driver for ELAN MoC 0c4c" — author `depau`
- Opened **2021-09-19**, still **open**, last activity **2026-08-01**
- **189** comments
- `merge_status: cannot_be_merged` — it currently conflicts with master

Queried via:
```sh
curl -sS "https://gitlab.freedesktop.org/api/v4/projects/libfprint%2Flibfprint/merge_requests/330"
```
(The web UI is behind Anubis bot protection; the REST API answers fine.)

The driver was written for `0c4c`. `0c00` is listed in its ID table but the
author does not have one — the branch head is literally "WIP add 0c7c". **That
gap is the contribution opportunity.**

## What libfprint actually requires

From `HACKING.md`:

> Drivers are not usually written by libfprint developers, but when they are, we require:
> - 3 stand-alone devices. Not in a laptop or another embedded device …
> - specifications of the protocol.
>
> If you are an end-user, you can file a feature request with the "Driver Request" tag …
> If you are an enterprising hacker, please file a new merge request with the driver patches integrated.

Also mandatory:
- Public API additions need gtk-doc comments.
- No shims around proprietary blobs. Clean-room / free reimplementation only.
- Code style is enforced by `scripts/uncrustify.sh`.

## Contribution routes, most to least valuable

### 1. Test MR 330 on `0c00` and report results  ← start here

The author has `0c4c`; you have `0c00`. A credible "works / does not work on
`0c00`, here is the evidence" report on a five-year-old MR is worth more than
new code, and needs no C.

What to post on MR 330:
- `lsusb -v -d 04f3:0c00` output
- Whether `fprintd-enroll` / `fprintd-verify` succeed against the built branch
- Exact failure bytes if not, using `docs/PROTOCOL.md` for vocabulary
- A umockdev capture (below)

### 2. Supply a umockdev capture for `0c00`

libfprint's regression tests are umockdev recordings, so a capture is how a
device becomes *permanently* supported rather than anecdotally working. From
`tests/README.md`:

> For match-on-chip devices you would instead create a test specific `custom.py`
> script, capture it and store the capture to `custom.pcapng`.

Procedure:

```sh
# 1. build libfprint with the driver enabled
meson setup build -Ddrivers=elanmoc2
meson compile -C build

# 2. record. the variant argument creates tests/elanmoc2-0c00/
sudo tests/create-driver-test.py --test custom elanmoc2 0c00

# 3. register the test
#    add "elanmoc2-0c00" to drivers_tests in tests/meson.build
#    then chown the generated directory back to yourself

# 4. verify
meson test -C build
```

Note from that README: capture tests need not use a real fingerprint — the side
of a finger or an arm produces a usable image. For a match-on-chip part you are
recording the command exchange, not an image.

### 3. Rebase MR 330 onto master

`cannot_be_merged` means conflicts. A clean rebase is unglamorous and is very
often the single thing blocking a stale MR. Coordinate on the MR thread first
so the work is not duplicated.

### 4. File / subscribe to a Driver Request issue

<https://gitlab.freedesktop.org/libfprint/libfprint/issues> with the
"Driver Request" label, if no `0c00` issue already exists.

### 5. Move `0c00` out of the unsupported allowlist

Once it genuinely works, `0c00` should leave `allowlist_id_table[]`. That list
is generated — regenerate with `meson compile -C build sync-unsupported-devices`
rather than editing by hand.

## Where this Rust crate fits

Be clear-eyed about this: **libfprint is C, and a Rust reimplementation cannot
be merged into it.** This crate is not the contribution vehicle.

What it is good for:

- **`docs/PROTOCOL.md`** — a written protocol specification, which is one of the
  two things `HACKING.md` explicitly asks for and which MR 330 does not include.
  This is directly contributable as prose.
- An independent implementation. Where this crate and `elanmoc2` disagree about
  the wire format, one of them has a bug — useful signal for review.
- A minimal, dependency-light harness for poking `0c00` without building all of
  libfprint.

## Licensing

`src/proto.rs` and `src/device.rs` were written by reading `elanmoc2.c` and
`elanmoc2.h`, which are **LGPL-2.1-or-later**.

Protocol facts (opcodes, offsets, framing) are not themselves copyrightable, but
this crate is a close structural port, not an independent reimplementation from
captures. The honest and safe course is to license this crate
**LGPL-2.1-or-later** to match, and to credit the `elanmoc2` author.

If you ever want a permissive licence, that requires re-deriving the protocol
from your own USB captures without reference to the LGPL source — a genuine
clean-room process, not a rewrite of code you have read.

## Reference commands

```sh
# device facts
lsusb -v -d 04f3:0c00
usb-devices | grep -A12 04f3
journalctl -k | grep -i 'usb 1-4'

# what libfprint currently claims
grep -i 04F3 /usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb
fprintd-list "$USER"

# MR status without the web UI
curl -sS "https://gitlab.freedesktop.org/api/v4/projects/libfprint%2Flibfprint/merge_requests/330"

# this crate
cargo test && cargo clippy --all-targets -- -D warnings
sudo ./target/release/elanctl info
```
