# Draft comment for libfprint MR !330

Target: <https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330>

**Review before posting.** This goes out publicly under your name. Check that
you're comfortable with the tone, and re-run the commands so you're posting
output you generated yourself.

**Status:** the branch has been built and run against real `04f3:0c00`
hardware. Raw protocol bytes were gathered with an independent Rust tool;
driver-level results and the crash come from the built branch itself. Both are
labelled below.

**Lead with the double free.** It is not `0c00`-specific — it fires on any
elanmoc2 device whenever the sensor rejects a finger, which includes `0c4c`.
The `0c00` findings follow it.

---

## `04f3:0c00` works on this branch — plus a double free on every rejected finger

Hi @depau — thanks for keeping this driver alive for as long as you have.

I have an **`04f3:0c00`**, which is in this MR's `id_table` but which I don't
think you have hardware for. I built the branch at `11f0316d` and ran it.

**The headline is that it works.** Enroll, commit, identify, verify and delete
all function on `0c00`. I have three fingers enrolled; each verifies to its own
slot with its own user id, and PAM authentication through fprintd opens root
sessions. libfprint currently tracks this PID in
`allowlist_id_table[]` as known-unsupported, and on this branch it plainly
isn't.

The rest of this is what I found while getting there. The first item is not
`0c00`-specific and should reproduce on your `0c4c` — it is a memory-safety bug
and there's a patch attached. Two more are `0c00` protocol notes, and one is a
design question rather than a bug.

### Hardware

```
HP Pavilion Aero Laptop 13-be2xxx (BIOS F.26)
Arch Linux, kernel 7.1.9, libfprint built from this branch @ 11f0316d

idVendor 0x04f3  idProduct 0x0c00  bcdDevice 2.83
iManufacturer "ELAN"  iProduct "ELAN:ARM-M4"  iSerial none
bcdUSB 2.00, full speed, bMaxPacketSize0 8

IF 0 alt 0: bInterfaceClass 0xff, 8 bulk endpoints, all wMaxPacketSize 64:
  EP 0x81/0x01, 0x82/0x02, 0x83/0x03, 0x84/0x04
No kernel driver binds the interface.
```

So `ELANMOC2_EP_CMD_OUT` (0x01), `ELANMOC2_EP_CMD_IN` (0x83) and
`ELANMOC2_EP_MOC_CMD_IN` (0x84) all exist on this part.

### What works

`fprint-list-supported-devices` lists `04f3:0c00 | ELAN Match-on-Chip 2`, the
device opens cleanly, and enroll completes and commits (8 stages;
`fprintd-list` then shows the finger):

```
driver elanmoc2   name "ELAN Match-on-Chip 2"   scan type press   enroll stages 8
storage yes | identify yes | verify yes | list no | delete no | clear yes
fp_device_open_sync ... ok      fp_device_close_sync ... ok
```

Framing is exactly as the driver describes — `[0x40][opcode]` out on EP 0x01,
reply on EP 0x83 beginning `0x40`:

```
get_enrolled_count   OUT 40 ff 04   ->   IN 40 03     (128 µs, three enrolled)
```

And end to end, each finger matching to its own slot:

```
verified as           identify   user id rebuilt from the finger_info reply
right-thumb (6)       slot 2     FP1-20260906-6-3EC6E5EF-jvikramsrd
right-index (7)       slot 0     FP1-20260906-7-1B3AC5EE-jvikramsrd
right-middle (8)      slot 1     FP1-20260906-8-00B0ACA7-jvikramsrd
```

---

## 1. Double free of the retry `GError` — not device-specific

`fpi_device_verify_report()` and `fpi_device_identify_report()` **take
ownership** of the `GError` they are handed. Both store it directly:

```c
/* libfprint/fpi-device.c, in both functions */
data->error = error;
```

and `match_data_free()` later releases it with `g_clear_error (&data->error)`.
Other drivers honour that — `virtual-device-storage.c:93` passes
`g_steal_pointer (&error)`.

`elanmoc2_identify_verify_report()` passes `*error` instead:

```c
fpi_device_identify_report (device, NULL, print, *error);   /* elanmoc2.c:503 */
...
fpi_device_verify_report (device, result, print, *error);   /* elanmoc2.c:526 */
```

while every caller holds that same error in a `g_autoptr(GError)`:

```c
elanmoc2_identify_run_state (FpiSsm *ssm, FpDevice *device)
{
  g_autoptr(GError) error = NULL;                       /* :595  caller still owns it */
  ...
  case IDENTIFY_GET_FINGER_INFO:
    error = elanmoc2_get_finger_error (buffer_in, &can_retry);
    if (error != NULL && can_retry)
      {
        elanmoc2_identify_verify_report (device, NULL, &error);   /* :609  libfprint takes it */
        fpi_ssm_jump_to_state (ssm, IDENTIFY_IDENTIFY);           /* ...and we loop */
      }
```

So the error is freed twice: by the autoptr when the state handler returns, and
again by `match_data_free()` when the task data is destroyed.

The window isn't narrow. This is the *retry* path — it runs every time the
sensor doesn't recognise a finger, and then jumps back to `IDENTIFY_IDENTIFY`
to try again, so the free-after-free repeats per bad touch. On my `0c00`,
fprintd reliably dies after a handful of rejected verifies:

```
fprintd[1684]: Device reported an error during verify: Finger not recognized
fprintd[1684]: Driver reported an error code without setting match result to error!
kernel: traps: fprintd[1684] general protection fault ip:7fcccd4a8ea7 ... in libc.so.6
systemd-coredump[3374]: Process 1684 (fprintd) ... dumped core.
  #3  match_data_free (libfprint-2.so.2 + 0xb439)
  #6  glib_autoptr_clear_GTask (libfprint-2.so.2 + 0x17871)
```

and on the abort path:

```
fprintd[3390]: free(): invalid pointer
systemd-coredump[4001]: Process 3390 (fprintd) ... dumped core.
  #8  match_data_free (libfprint-2.so.2 + 0xb439)
```

That `Driver reported an error code without setting match result to error!` line
immediately before each crash is the same call site: `:526` passes
`FPI_MATCH_FAIL` alongside a non-NULL error, and `fpi_device_verify_report()`
warns about the mismatch.

The fix is to steal the error at both report sites, and to set
`FPI_MATCH_ERROR` when one is present. Patch attached; it applies cleanly to
`11f0316d` and builds clean against the full default driver set.

Running the patched build I put 6 rejected verifies through the sensor in a row -- the unpatched build reliably died after 4-5 -- with no new coredump:

```
   rejections (CLI):     6 / 6
   rejections (journal): 12
   matches:              0
   rounds that failed to reach the sensor: 0
   coredumps before/after: 2 / 2
```

(The two counted coredumps are the pre-patch ones quoted above.) Raw
output: `logs/20260906T110112Z_verify-crash-test-PASSED.txt`.

I'd expect this to be reproducible on `0c4c` too — just present the wrong
finger to `fprintd-verify` five or six times in a row.

## 2. Three memory-safety bugs parsing the `finger_info` reply

`elanmoc2_get_user_id_string()` trusts the length of a reply that comes
straight off the wire. Patch attached; all three are confirmed under
AddressSanitizer.

**(a) One-past-the-end write, on every call.**

```c
g_byte_array_set_size (user_id, max_len);
...
user_id->data[max_len] = '\0';          /* index max_len of a max_len array */
```

This is out of bounds unconditionally: the array holds exactly `max_len`
bytes, so `max_len` is never a valid index, whatever the device or the reply.
For a non-empty reply it is a one-byte heap overflow.

The `max_len == 0` case is worse — the `GByteArray` has never allocated, so
`->data` is `NULL` and this becomes a NULL pointer write. That needs a reply
exactly as long as the header. I should be precise about when an `0c00`
produces one, because my first draft of this report got it wrong: `finger_info`
answers `40 ff` when it is issued with **no successful identify since the
device was opened** (§4). Both of your call sites identify first, so the driver
as written does not reach it on this PID — the crash below is from a
synthesised short reply, not from a live capture:

```
== V1: 2-byte reply, normal device (offset 2) ==
    [max_len=0  array->data=(nil)]
AddressSanitizer: SEGV on unknown address 0x000000000000
The signal is caused by a WRITE memory access.
```

**(b) Unsigned underflow defeats the bounds check.**

```c
guint max_len = MIN (elanmoc2_get_user_id_max_length (self),
                     g_bytes_get_size (finger_info_response) - offset);
```

`g_bytes_get_size()` returns `gsize`. A reply shorter than `offset` wraps the
subtraction to ~2^64, `MIN()` then selects the 61/62-byte maximum, and the
`memcpy()` reads that many bytes out of a much smaller buffer. Reachable with
a 2-byte reply on an `0c5e`, where `offset` is 3:

```
    computed max_len = 61  (from a 2-byte reply!)
AddressSanitizer: heap-buffer-overflow
READ of size 61 at 0x7b8a53de0013
0x7b8a53de0013 is located 1 bytes after 2-byte region
```

**(c) `ENROLL_ATTEMPT_DELETE` copies a fixed 62 bytes out of that buffer.**

```c
gsize user_id_bytes = MIN (cmd_delete.out_len - 4, ELANMOC2_USER_ID_MAX_LEN);
memcpy (&buffer_out->data[4], g_bytes_get_data (user_id, NULL), user_id_bytes);
```

Neither operand depends on how many bytes the sensor returned, so the length
is always 62. On `0c00` the `GBytes` is empty and `g_bytes_get_data()` returns
`NULL`. `DELETE_SEND` already bounds this by the real length; this call site
was not updated to match.

```
    user_id real size = 0, memcpy len = 62, src = (nil)
AddressSanitizer: SEGV ... caused by a READ memory access.
```

The patch compares before subtracting, allocates one extra byte so the
terminator is in bounds, and returns the payload length so the caller can
bound its own copy. The helper now hands back a NUL-terminated `gchar *`,
which is what both call sites want anyway. It also guards the `ENROLL_COMMIT`
log line, which reads `data_in[2]` after asserting only two bytes.

After the patch the same inputs — plus 0- and 1-byte replies — parse to an
empty user ID and return cleanly under ASan and UBSan, while a well-formed
64-byte reply still yields the identical 62-byte user ID. Raw output:
`logs/20260906T105511Z_asan-elanmoc2-user-id.txt`, reproducers in `scripts/asan-repro-*.c`.

## 3. A design question: failed delete escalates to a full sensor wipe

This started as a `0c00` bug report. It isn't one — I could not substantiate
it, and I'd rather say so than let it stand. What's left is a design question
about code that is device-independent.

The mechanism is real and it is in the tree today:

```c
case ENROLL_CHECK_DELETED:
  if (data_in[1] != 0) {
      fp_info ("Failed to delete finger %d, wiping sensor", self->print_index);
      fpi_ssm_jump_to_state (ssm, ENROLL_WIPE_SENSOR);
  }
```

**The question:** should one failed delete erase every enrolled template? Losing
every finger because a single delete failed is a surprising outcome for someone
who asked to *add* one, and the user is never told it happened. Failing the
enroll instead seems safer on any device. That holds regardless of whether
anything actually triggers it.

**What I could not substantiate.** I originally claimed a routine
`fprintd-enroll` reaches this on `0c00`, via a `finger_info` rejection
producing a malformed delete. Two things sank it:

- `finger_info` is **not** rejected on `0c00`. It answers correctly whenever an
  identify precedes it (§4), which is exactly the case in
  `ENROLL_GET_ENROLLED_FINGER_INFO` — `print_index` is set from the identify
  reply immediately before. So the delete is built from a well-formed record
  and there is no reason to expect it to fail.
- The enroll path never issues `check_enroll_collision` (`ff 10`) at all. I had
  built the chain on that command; tracing the state machine on hardware, it is
  never sent during enrollment.

For completeness, `ff 10` does answer on this device when issued directly, and
the second byte may be worth a look independently of any of the above:

```
OUT 40 ff 10   ->   IN 40 00 ff     (39 ms, returns without waiting for a finger)
```

`cmd_check_enroll_collision` declares `in_len = 3` but only `resp[1]` is read.
Here `resp[2] = 0xff`. I don't know what it means and I'm not assuming.

### Adding `delete` also removes the path's reachability

Worth knowing before you decide how to fix this. I implemented
`dev_class->delete` locally (`elanmoc2_delete_print`, using the same framing
`ENROLL_ATTEMPT_DELETE` uses) and it works on `0c00`:

```
fprintd: [elanmoc2] New delete operation
fprintd: Deleting finger 0 (user id 34 bytes)
fprintd: Finger 0 deleted
fprintd: [elanmoc2] DELETE_NUM_STATES completed successfully
```

`clear_storage` works too — wipe sent, enrolled count re-read as 0, SSM
completed.

The side effect is the interesting part. With a `delete` available, fprintd
deletes the existing print through the delete API and *then* starts a fresh
enroll:

```
fprintd: Deleting enrolled finger right-index-finger for user jvikramsrd
   ... delete ... clear storage ...
fprintd: [elanmoc2] New enroll operation
fprintd: Enrolled count is 0, proceeding with enroll stage
   ... 8 stages ... enroll-completed
```

So `ENROLL_EARLY_REENROLL_CHECK` → `ENROLL_GET_ENROLLED_FINGER_INFO` →
`ENROLL_ATTEMPT_DELETE` is never entered through fprintd once `delete` exists.
Without `delete` — which is the state of this MR today — fprintd has no way to
remove the print first, so the driver's own collision path has to run, and on
`0c00` that is the route to the wipe.

That suggests the in-enroll delete-and-retry dance may not need to exist at
all for fprintd users, though I don't know what other libfprint clients rely
on. Raw journal: `logs/20260906T111322Z_reenroll-fprintd-deletes-first.txt`.

## 4. `0c00`: `finger_info` (`ff 12`) ignores its slot argument

This one is latent — it costs you nothing today — but it is a real protocol
difference on this PID and it will bite whoever next writes code that walks
slots.

`ff 12` on `0c00` returns the record of the **most recently identified
finger**, regardless of the index in payload byte 3. With no successful
identify since the device was opened, it returns a 2-byte `40 ff`.

Three fingers enrolled (6, 7, 8). After a verify that matched finger 6, every
one of the ten slots answers identically — including the seven that hold
nothing:

```
get_enrolled_count -> 40 03
slot 0..9  ->  40 00 "FP1-20260906-6-3EC6E5EF-jvikramsrd"   (all ten)
```

After a verify that matched finger 8 instead, the same ten slots return
finger 8's record instead. The reply tracks the last match, not the index:

```
slot 0..9  ->  40 00 "FP1-20260906-8-00B0ACA7-jvikramsrd"   (all ten)
```

**Your driver is unaffected as written**, and I want to be clear about that.
Both `cmd_finger_info` call sites — `IDENTIFY_GET_FINGER_INFO`, and the
re-enroll check that sets `print_index` from the identify reply — issue it
immediately after an `ff 03` that just named the slot. So the record you get
back is always the one you wanted, by construction. There is no `list` vfunc,
so nothing else enumerates. Verify and identify work correctly on `0c00`; I
have three fingers enrolled and each matches to its own slot with its own
user id.

Where it would bite is any future path that reads a slot without identifying
first — enumerating stored prints, a delete-by-index, a storage audit. On this
PID those would all silently return the same record.

I don't know whether this is `0c00`-specific. It is worth someone with a
`0c4c` running the equivalent check, which is two commands: identify with one
finger, then read a slot belonging to a different one.

## 5. `0c00`: `get_fw_ver` reply carries no `0x40` magic

```
get_fw_ver   OUT 40 19   ->   IN 02 83     (94 µs)
```

First byte is `0x02`, not `0x40`, so `elanmoc2_cmd_usb_callback()`'s check

```c
if (transfer->actual_length > 0 && transfer->buffer[0] != 0x40)
```

would fail this with `FP_DEVICE_ERROR_PROTO`.

The reply looks like a bare packed-BCD version: `bcd(0x02)=2`, `bcd(0x83)=83`
→ **2.83**, which matches this device's `bcdDevice 2.83` exactly.

This hasn't surfaced because **`cmd_get_fw_ver` is defined in `elanmoc2.h` but
never referenced in `elanmoc2.c`** — the command is never issued, so its reply
framing has never been exercised. Worth either wiring it up with a
magic-exempt path, or dropping the definition.

## What I still can't answer

- **Whether `ff 12` ignoring its slot index is `0c00`-specific.** I have only
  this PID. It's two commands to check on a `0c4c`: identify with one finger,
  then read a slot belonging to a different one.
- **What `resp[2]` of `check_enroll_collision` means.** It's `0xff` here and
  the driver never reads it.
- **What the `0xBC` HID feature report holds.** The interface advertises a
  21-byte HID report descriptor despite being `bInterfaceClass 0xff`; it
  declares a single vendor Feature report and no Input or Output items, so it
  is a control-endpoint side channel and your ignoring it looks correct.
  Reading its contents means a vendor `GET_REPORT` and I've kept to read-only
  standard requests.

`get_enrolled_count` I *can* now answer: it's a genuine count, not a status
byte — `0` with nothing enrolled, `3` with three.

## Offer

Glad to help if any of this is useful — happy to:

- produce a umockdev capture (`tests/create-driver-test.py --test custom elanmoc2 0c00`)
- test patches on `0c00`
- try any specific command sequence you'd like bytes for
- open the double-free fix as its own MR against master if you'd rather keep
  this one focused

I deliberately haven't gone opcode-hunting for a `ff 12` replacement, since
adjacent values are `ff 13` (delete) and `ff 99` (wipe) and I'd rather not
guess on a sensor I care about.

Full write-up, the probing tool, and the patches:
<https://github.com/jvikramsrd/elan-0c00>
