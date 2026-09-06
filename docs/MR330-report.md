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

## A double free on every rejected finger, plus three `04f3:0c00` findings

Hi @depau — thanks for keeping this driver alive for as long as you have.

I have an **`04f3:0c00`**, which is in this MR's `id_table` but which I don't
think you have hardware for. I built the branch at `11f0316d` and ran it. The
first finding below is not about `0c00` at all and should reproduce on your
`0c4c`; the rest are `0c00`-specific. Patch attached for the first one.

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
get_enrolled_count   OUT 40 ff 04   ->   IN 40 01     (78 µs)
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

<!-- DO NOT POST UNTIL THIS PARAGRAPH IS TRUE.
     Run `sudo ./scripts/verify-crash-test.sh`. It must report PASSED with at
     least 4 real rejections. Then replace this comment with the actual
     numbers, e.g.:

       Running the patched build, I put N rejected verifies through the sensor
       (previously it died after 4-5) with no coredump.

     The analysis above stands on the source and the backtrace regardless, but
     a runtime claim you have not made yourself does not belong in a bug
     report. -->

I'd expect this to be reproducible on `0c4c` too — just present the wrong
finger to `fprintd-verify` five or six times in a row.

## 2. Three memory-safety bugs parsing the `finger_info` reply

`elanmoc2_get_user_id_string()` trusts the length of a reply that comes
straight off the wire. Patch attached; all three are confirmed under
AddressSanitizer with the bytes an `0c00` actually sends.

**(a) One-past-the-end write, on every call.**

```c
g_byte_array_set_size (user_id, max_len);
...
user_id->data[max_len] = '\0';          /* index max_len of a max_len array */
```

When `max_len == 0` the `GByteArray` has never allocated and `->data` is
`NULL`, so this is a NULL pointer write. `max_len` is 0 whenever the reply is
exactly as long as the header — which is what `0c00` returns, because
`finger_info` is rejected there with a 2-byte `40 ff` (§4):

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

## 3. `0c00`: enroll can escalate to a full sensor wipe

`check_enroll_collision` on this device returns:

```
OUT 40 ff 10   ->   IN 40 00 ff     (39 ms, returns without waiting for a finger)
```

`resp[1] = 0x00`, so in `elanmoc2_get_finger_error()`:

```c
if ((data_in[1] & 0xF0) == 0) { *out_can_retry = TRUE; return NULL; }
```

no error is raised, `ENROLL_GET_ENROLLED_FINGER_INFO` takes the "finger already
enrolled" branch with `print_index = 0`, and issues `finger_info` — which this
device rejects (§4). `ENROLL_ATTEMPT_DELETE` then builds a delete from a
malformed reply and fails. Then:

```c
case ENROLL_CHECK_DELETED:
  if (data_in[1] != 0) {
      fp_info ("Failed to delete finger %d, wiping sensor", self->print_index);
      fpi_ssm_jump_to_state (ssm, ENROLL_WIPE_SENSOR);
  }
```

So on `0c00`, a routine `fprintd-enroll` can destroy every stored template. This
matters today: people are installing this driver on `0c00` via AUR and the
Debian packaging.

Two suggestions, independent of each other:

1. Don't escalate a failed delete into a full wipe on **any** device — fail the
   enroll instead. Losing every enrolled finger because one delete failed is a
   surprising outcome for someone who asked to *add* a finger.
2. `cmd_check_enroll_collision` declares `in_len = 3` but only `resp[1]` is ever
   read. Here `resp[2] = 0xff` — possibly the real "not enrolled" indicator, in
   which case `0c00` should be jumping straight to `ENROLL_ENROLL`. I haven't
   assumed either way.

## 4. `0c00`: `finger_info` (`ff 12`) is rejected on every slot

```
finger_info(0..9)   OUT 40 ff 12 NN   ->   IN 40 ff     (155-183 µs, identical for all 10 slots)
```

Two bytes instead of the expected 64, with status `0xff`. By the driver's own
rule in `elanmoc2_get_finger_error()` the most-significant nibble is set, so
this is a terminal error, and `0xff` isn't in the `ELANMOC2_RESP_*` list.

`ff 04` works, so `0xff`-family opcodes are accepted in general — `ff 12`
specifically appears unsupported or differently shaped on this PID.

Since `IDENTIFY_GET_FINGER_INFO` runs after every successful match and
`elanmoc2_cmd_transceive()` sets `short_is_error = TRUE`, **the identify path
can't complete on `0c00` as currently written.** `0c00` likely needs a quirk
flag of its own, in the manner of `ELANMOC2_DEV_0C5E`.

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

## Open question I can't resolve

`get_enrolled_count` returns `0x01`, but no slot returns readable content and
all ten answer identically. So I can't tell whether `resp[1]` is genuinely a
count here or a status byte. I've avoided assuming there's a template on the
sensor.

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
<!-- add your repo link here, or delete this line -->
