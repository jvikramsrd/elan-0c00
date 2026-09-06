# Testing

Exact configuration and outcomes for the changes in `patches/`. Every row is
something that was run, not something that should work.

## Hardware and software under test

```
Laptop      HP Pavilion Aero 13-be2xxx
Sensor      USB 04f3:0c00, "ELAN:ARM-M4", bcdDevice 2.83
            IF 0 vendor-class (0xff), 8 bulk endpoints, no kernel driver bound
Host        Arch Linux, kernel 7.1.9-arch1-2
glib        2.88.3
gcc         16
libfprint   1.94.9+11+g11f0316d (MR !330 branch, Depau/libfprint @ 11f0316d)
fprintd     1.94.5-2
```

## Patch series

| # | Patch | Status |
|---|---|---|
| 0002 | don't wipe the sensor when a delete fails; add `delete` | applied, shipped |
| 0003 | don't double-free the retry `GError` | applied, shipped, **verified on hardware** |
| 0004 | bound `finger_info` user-ID parsing by the returned length | applied, shipped, ASan-verified |

All three apply cleanly and in order to a pristine `11f0316d` checkout
(verified by extracting the tag and applying the series with `git apply`).

## Static / build checks — patch 0004

| Check | Command | Outcome |
|---|---|---|
| Compiles | `meson setup build-audit -Ddrivers=elanmoc2`; `ninja` | pass |
| Warning-free | grep the build log for `elanmoc2.c` | no warnings |
| `--werror` | `meson setup ... --werror` | `elanmoc2.c.o` builds; unrelated pre-existing failure in bundled NBIS (`nbis/mindtct/remove.c:1377`, `unused-but-set-variable`) |
| Unit tests | `meson test -C build-audit` | 2 ok / 3 fail / 28 skip |
| Regression | same command on **unpatched** `elanmoc2.c` | **identical** 2/3/28 — no regression |

The 3 failures are pre-existing and unrelated to this driver:

- `udev-hwdb` — the build was configured with `-Ddrivers=elanmoc2`, so the
  generated hwdb lists only the 5 elanmoc2 IDs and no longer matches the
  checked-in full-driver `autosuspend.hwdb`.
- `fpi-device` — `test_driver_initial_features_no_storage` fails on this
  branch; it runs against `virtual_device` and never loads elanmoc2.
- `metainfo-validate` — `appstreamcli` validation of an XML file.

Both aborting tests dump core, which is the source of any "Process crashed:
test-fpi-device / fprint-list-udev-hwdb" desktop notifications during a test
run. They are test binaries, not the fingerprint stack.

## Memory-safety verification — patch 0004

Reproducers carry the driver logic verbatim; the sensor is not involved, so
these are deterministic and need no hardware.

```sh
gcc -fsanitize=address            -g -O0 -o repro   scripts/asan-repro-upstream.c  $(pkg-config --cflags --libs glib-2.0)
gcc -fsanitize=address            -g -O0 -o repro2  scripts/asan-repro-upstream2.c $(pkg-config --cflags --libs glib-2.0)
gcc -fsanitize=address,undefined  -g -O0 -o fixed   scripts/asan-repro-patched.c   $(pkg-config --cflags --libs glib-2.0)
ASAN_OPTIONS=detect_leaks=0 ./repro 0 && ./repro2 2 && ./repro2 3 && ./fixed
```

| Input | Unpatched | Patched |
|---|---|---|
| 2-byte reply, offset 2 (**the real `0c00` reply**) | SEGV, WRITE to `0x0` | len 0, clean |
| 2-byte reply, offset 3 (`0c5e`) | heap-buffer-overflow, READ 61 B past a 2-byte region | len 0, clean |
| enroll-delete `memcpy`, 0-byte user ID | SEGV, READ from `NULL`, len 62 | copy 0, clean |
| 1-byte reply | (same underflow class) | len 0, clean |
| 0-byte reply | (same underflow class) | len 0, clean |
| 64-byte well-formed reply | user ID 62 B | **user ID 62 B, unchanged** |
| 64-byte well-formed, `0c5e` | user ID 61 B | **user ID 61 B, unchanged** |

Raw sanitizer output: `logs/20260906T105511Z_asan-elanmoc2-user-id.txt`.

## Hardware verification — patch 0003

`scripts/verify-crash-test.sh`, run against the installed patched library
(`libfprint-elanmoc2-0c00 1.94.9+11+g11f0316d-1`, = 0002+0003+0004) on the
`04f3:0c00`:

```
   rejections (CLI):     6 / 6
   rejections (journal): 12
   matches:              0
   rounds that failed to reach the sensor: 0
   coredumps before/after: 2 / 2

   VERDICT: PASSED -- 6 rejections, no new coredump.
```

Six consecutive rejected verifies with no new coredump. The unpatched build
died after 4-5 (two coredumps, 2026-09-06 09:57: SIGSEGV then SIGABRT, both
with `match_data_free` on the stack). The two counted coredumps are those
pre-patch ones; the count did not move.

The script refuses to report PASSED without positive proof the code path ran,
so this is not an absence-of-crash result: 6 CLI rejections and 12 journal
rejection events confirm the retry loop that double-freed was executed.

Raw output: `logs/20260906T110112Z_verify-crash-test-PASSED.txt`.

Scope note: this run exercised the **retry/rejection** path (patch 0003). It
did **not** reach `IDENTIFY_CHECK_FINGER_INFO`, because every round was a
no-match and that state only runs after a successful identify. Patch 0004's
parsing fixes therefore remain sanitizer-verified rather than
hardware-verified; what this run does show is that 0004 causes no regression
in the verify path.

## Hardware run — re-enroll experiment (patch 0002 delete, and a reachability finding)

`scripts/verify-reenroll-test.sh` was run to reach `ENROLL_ATTEMPT_DELETE` and
hardware-verify patch 0004 at that call site. **It did not reach that state**,
and the reason is itself a result.

What the journal shows (`logs/20260906T111322Z_reenroll-fprintd-deletes-first.txt`):

```
fprintd: Deleting enrolled finger right-index-finger for user jvikramsrd
fprintd: [elanmoc2] New delete operation
fprintd: Deleting finger 0 (user id 34 bytes)
fprintd: Finger 0 deleted
fprintd: [elanmoc2] DELETE_NUM_STATES completed successfully
fprintd: [elanmoc2] New clear storage operation
fprintd: Sent sensor wipe command, sensor will hang for ~5 seconds
fprintd: [elanmoc2] CLEAR_STORAGE_NUM_STATES completed successfully
fprintd: [elanmoc2] New enroll operation
fprintd: Enrolled count is 0, proceeding with enroll stage
   ... 8 stages ... enroll-completed
```

Confirmed on hardware by this run:

| Result | Evidence |
|---|---|
| **Patch 0002's `delete` works on `0c00`** | `Deleting finger 0 (user id 34 bytes)` → `Finger 0 deleted` → SSM completed successfully |
| **`clear_storage` works on `0c00`** | wipe sent, enrolled count re-read as 0, SSM completed successfully |
| A full enroll cycle completes | 8 stages + commit; 1 print before, 1 after; no coredump |

**Reachability finding.** Because patch 0002 adds `dev_class->delete`, fprintd
deletes the existing print through the delete API and *then* enrolls. The
driver's own collision path — `ENROLL_EARLY_REENROLL_CHECK` →
`ENROLL_GET_ENROLLED_FINGER_INFO` → `ENROLL_ATTEMPT_DELETE` — is therefore
never entered through fprintd. On the **unpatched** MR branch there is no
`delete`, so fprintd cannot delete first and the driver must handle the
collision itself; that is the route by which a routine re-enroll wiped the
sensor on `0c00`. Patch 0002 does not merely guard that path, it removes its
reachability for fprintd users.

**Script defect found and fixed in the same run.** The first version matched
the bare prefix `Deleting enrolled finger`, which also matches fprintd's own
`"Deleting enrolled finger %s for user %s"` (fprintd `device.c`), distinct from
the driver's `"Deleting enrolled finger %d"` (`elanmoc2.c`). It therefore
reported `ENROLL_ATTEMPT_DELETE` as entered while its predecessor states read
`no` — an impossible progression. The marker is now anchored on the numeric
finger index. The run was re-scored with the fixed marker and correctly reports
the state as not entered. Note the verdict logic still refused to pass, so the
false positive never produced a false PASSED.

## Packaging

```sh
cd packaging && makepkg -f --noconfirm
```

Builds `libfprint-elanmoc2-0c00` with 0002+0003+0004 applied. The shipped
`libfprint-2.so.2.0.0` contains `user id[%lu]` (the `G_GSIZE_FORMAT` from
0004) rather than the pre-patch `user id[%d]`, which confirms the patch is in
the binary.

## Not yet tested

- **Patch 0004 at the `ENROLL_ATTEMPT_DELETE` call site.** Still
  sanitizer-verified only. As above, that state is unreachable through fprintd
  once `delete` exists, so exercising it needs a libfprint client that enrolls
  without deleting first. The other call site,
  `IDENTIFY_CHECK_FINGER_INFO`, is unreachable on `0c00` for a different
  reason: identify never completes (§4).
- **`0c4c`, `0c5e`, `0c7c`, `0c90`.** No hardware here. Patch 0004 is
  device-independent, but the `0c5e` offset-3 path is only ASan-tested.
- **Identify on `0c00`.** Still blocked upstream of these patches by the
  `ff 12` rejection (`docs/MR330-report.md` §4).
