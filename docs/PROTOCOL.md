# ELAN "Match-on-Chip 2" (elanmoc2) USB protocol

Sensor family: USB `04f3:0c00`, `0c4c`, `0c5e`, `0c7c`, `0c90`.
Reference part for this document: **`04f3:0c00`, `ELAN:ARM-M4`, `bcdDevice 2.83`**.

## Provenance and confidence

Two different classes of statement appear below. They are labelled, because
conflating them would be dishonest:

| Label | Meaning |
|---|---|
| **[OBSERVED]** | Read directly off the physical `04f3:0c00` on this machine. |
| **[PORTED]** | Transcribed from the `elanmoc2` driver source. **Not yet confirmed against `0c00` hardware.** |

Source for every **[PORTED]** claim:
`libfprint/drivers/elanmoc2/{elanmoc2.c,elanmoc2.h}` on branch `elanmoc2` @
`11f0316d` (`v1.94.9-11-g11f0316d`) of
<https://gitlab.freedesktop.org/Depau/libfprint.git>, licensed LGPL-2.1-or-later.

That driver was developed against **`0c4c`**, not `0c00`. `0c00` appears in its
ID table, but the branch head is titled "WIP add 0c7c". Treat byte-level details
as plausible-but-unverified for `0c00` until a capture says otherwise.

## USB topology [OBSERVED]

```
idVendor           0x04f3  (Elan Microelectronics)
idProduct          0x0c00
bcdDevice          2.83
bcdUSB             2.00        speed: full (12 Mbps)
bDeviceClass       0x00        bMaxPacketSize0: 8
iManufacturer      "ELAN"      iProduct: "ELAN:ARM-M4"      iSerial: none
bNumConfigurations 1           MaxPower: 100 mA, bus powered, remote wakeup
```

One interface, vendor-specific, **eight bulk endpoints**, all 64-byte:

```
IF 0 alt 0: bInterfaceClass 0xff, bInterfaceSubClass 0x00, bInterfaceProtocol 0x00
  EP 0x81 IN  Bulk 64   EP 0x01 OUT Bulk 64
  EP 0x82 IN  Bulk 64   EP 0x02 OUT Bulk 64
  EP 0x83 IN  Bulk 64   EP 0x03 OUT Bulk 64
  EP 0x84 IN  Bulk 64   EP 0x04 OUT Bulk 64
```

No kernel driver binds this interface (`usb-devices` reports `Driver=(none)`),
so userspace may claim it without detaching anything.

### Stray HID descriptor [OBSERVED]

The vendor-class interface carries a class-specific descriptor that `lsusb`
cannot decode and prints as `** UNRECOGNIZED: 09 21 10 01 00 01 22 15 00`:

| offset | field | value |
|---|---|---|
| 0 | bLength | 9 |
| 1 | bDescriptorType | `0x21` (HID) |
| 2–3 | bcdHID | 1.10 |
| 4 | bCountryCode | 0 |
| 5 | bNumDescriptors | 1 |
| 6 | subordinate bDescriptorType | `0x22` (Report) |
| 7–8 | subordinate wDescriptorLength | **21 bytes** |

The `elanmoc2` driver ignores this entirely and uses only bulk transfers. The
21-byte report descriptor has **not** been fetched yet; `elanctl`'s sibling
`probe` binary issues the standard `GET_DESCRIPTOR(0x22)` to retrieve it.
Its contents are an open question.

## Endpoint roles [PORTED]

```c
#define ELANMOC2_EP_CMD_OUT      (0x1 | FPI_USB_ENDPOINT_OUT)   /* 0x01 */
#define ELANMOC2_EP_CMD_IN       (0x3 | FPI_USB_ENDPOINT_IN)    /* 0x83 */
#define ELANMOC2_EP_MOC_CMD_IN   (0x4 | FPI_USB_ENDPOINT_IN)    /* 0x84 */
```

All three exist on `0c00` [OBSERVED]. Endpoints `0x02`, `0x04`, `0x81`, `0x82`
are present in hardware but unused by this protocol; `0x82` is `ELAN_EP_IMG_IN`
in the sibling `elan`/`elanmoc` drivers, which suggests the silicon is shared
with image-capable parts.

## Framing [OBSERVED on 04f3:0c00]

Confirmed on hardware. `get_enrolled_count` sent as `40 ff 04` on EP `0x01`
returned `40 01` on EP `0x83` in 78 µs. `finger_info` sent as `40 ff 12 NN`
returned a reply also beginning `0x40`. The magic byte, the endpoint pair and
the opcode encoding are therefore real, not inferred.

**Exception: `get_fw_ver` does not use this framing.** See below.


Every request and every response begins with the byte `0x40`.

```
Request  (bulk OUT, EP 0x01):
    [0x40] [opcode, 1 or 2 bytes] [payload ...] [0x00 padding ...]
    total length == cmd.out_len exactly (short writes are an error)

Response (bulk IN, cmd.ep_in):
    exactly cmd.in_len bytes
    resp[0] MUST be 0x40, else FP_DEVICE_ERROR_PROTO
```

From `elanmoc2_prepare_cmd`:

```c
buffer->data[0] = 0x40;
memcpy (&buffer->data[1], cmd->cmd, cmd->is_single_byte_command ? 1 : 2);
```

The buffer is zero-filled first, so all padding is `0x00`. Command-specific
payload bytes are written into fixed positions after the opcode.

## Hardware-confirmed behaviour on 04f3:0c00

Captured with `sudo elanctl dump` (raw mode, frame-magic check disabled):

```
get_fw_ver          out= 2B in= 2B ep=0x83 -> [02 83]   (94 µs)
get_enrolled_count  out= 3B in= 2B ep=0x83 -> [40 01]   (78 µs)
finger_info(0..9)   out= 4B in= 2B ep=0x83 -> [40 ff]   (155-183 µs, all 10 slots)
```

### 1. `get_fw_ver` returns raw BCD with no frame magic  [OBSERVED]

Reply is `02 83`. The device descriptor reports `bcdDevice 2.83`. Decoding each
byte as packed BCD gives major 2, minor 83 — an exact match. So the reply is a
bare two-byte version, **not** a `0x40`-framed message.

The reference driver would reject this as `FP_DEVICE_ERROR_PROTO`. It never
notices because **`cmd_get_fw_ver` is defined in `elanmoc2.h` but never
referenced anywhere in `elanmoc2.c`** — the command is dead code upstream, so
its reply framing has never been exercised. Likely an upstream bug.

### 2. `finger_info` is rejected on every slot  [OBSERVED]

`40 ff 12 NN` returns a 2-byte `40 ff` for **all** of slots 0-9, not the
documented 64-byte record. Byte 1 is `0xff`, whose most-significant nibble is
set, so by the driver's own rule it is a terminal error. `0xff` does not appear
in the reference driver's error list.

Note `get_enrolled_count` (`ff 04`) works, so the sensor does accept `0xff`-family
opcodes in general — `ff 12` specifically is unsupported or differently shaped
on this PID.

Upstream sets `short_is_error = TRUE` for this command, so the reference driver
would also fail here. **The `elanmoc2` identify path cannot work on 04f3:0c00 as
written**, since `IDENTIFY_GET_FINGER_INFO` follows every successful match.

### 3. `enroll` and `commit` work  [OBSERVED]

Through the `elanmoc2` C driver on real hardware: 8 enroll stages at roughly
0.7 s each, then `commit` (`ff 11`) succeeded and the template was stored. So
`ff 01` and `ff 11` are correct as documented for this PID.

The enroll state machine gates on `identify` (`ff 03`), **not** on
`check_enroll_collision` (`ff 10`) — `ff 10` is never issued during enrollment.
When `identify` reports no match, the driver jumps straight to `ENROLL_ENROLL`
and the broken `finger_info` is never reached.

Re-enrolling a finger the sensor already holds is the failing case: `identify`
returns a slot index, `finger_info` is then issued and rejected, the delete is
built from a malformed reply and fails, and the unpatched driver escalates to
`ENROLL_WIPE_SENSOR`.

### 4. Unresolved contradiction  [OBSERVED]

`get_enrolled_count` reports `1`, but no slot returns readable content, and all
ten slots answer identically. Either:

- `resp[1] = 0x01` is a *status* ("ok"), not a count, and the real count lives
  elsewhere; or
- the count is genuine and templates are simply not addressable through
  `ff 12` on this device.

Nothing captured so far distinguishes these. Do not assume the count is a count.

## Command table [PORTED]

| command | opcode | out_len | in_len | ep_in | cancellable | effect |
|---|---|---|---|---|---|---|
| `get_fw_ver` | `19` (1-byte) | 2 | 2 | `0x83` | no | read-only — **reply is unframed BCD, see above** |
| `get_enrolled_count` | `ff 04` | 3 | 2 | `0x83` | no | read-only |
| `finger_info` | `ff 12` | 4 | 64 | `0x83` | no | read-only — **rejected `40 ff` on 0c00** |
| `check_enroll_collision` | `ff 10` | 3 | 3 | `0x83` | no | read-only |
| `abort` | `ff 02` | 3 | 2 | `0x83` | no | transient |
| `identify` | `ff 03` | 3 | 2 | **`0x84`** | yes | transient |
| `enroll` | `ff 01` | 7 | 2 | **`0x84`** | yes | **persistent** |
| `commit` | `ff 11` | 72 | 2 | `0x83` | no | **persistent** |
| `delete` | `ff 13` | 72 | 2 | `0x83` | no | **persistent** |
| `wipe_sensor` | `ff 99` | 3 | 0 | `0x83` | no | **persistent** |

`get_fw_ver` is the only command using a single-byte opcode, so its frame is
exactly `40 19`. Every other command emits `40 ff XX`.

`wipe_sensor` expects **no reply** (`in_len == 0`) and stalls the sensor for
roughly five seconds; upstream logs "sensor will hang for ~5 seconds".

### Wire examples

```
get_enrolled_count   OUT 40 ff 04              IN  40 01        [OBSERVED]
get_fw_ver           OUT 40 19                 IN  02 83        [OBSERVED, unframed BCD]
finger_info(0)       OUT 40 ff 12 00           IN  40 ff        [OBSERVED, rejected]
finger_info (per elanmoc2, NOT seen on 0c00)  IN  40 xx <user-id ...>  (64 B)
identify             OUT 40 ff 03              IN  40 <status>            (on EP 0x84)
```

## Response semantics [PORTED]

### Enrolled count
`resp[1]` holds the number of enrolled fingers (`self->enrolled_num = data_in[1]`).

This query is issued with `short_is_error = false`: **a zero-length reply is
legal** and means "ask again". Upstream retries up to `ELANMOC2_MAX_RETRIES`
(3) before giving up with "Device refused to respond to query for number of
enrolled fingers".

### finger_info
Request: the slot index goes at **byte 3** — `buffer_out->data[3] = print_index`,
which is why `out_len` is 4.

Reply: 64 bytes. The user-id string starts at offset **2**, except on `0c5e`
where it starts at **3**. It is not NUL-terminated on the wire; copy out
`min(max_len, len - offset)` bytes and terminate yourself.

Maximum user-id length is `in_len - offset`, i.e. 62 bytes (61 on `0c5e`).

### Status byte
Status lives in `resp[1]`. Upstream's rule, verbatim from the source comment:

> Regular status codes never have the most-significant nibble set; errors do

```c
if ((data_in[1] & 0xF0) == 0)   /* ordinary status, operation may be retried */
```

For a successful `identify`, the low nibble carries the matched slot index.

| byte | meaning | retryable |
|---|---|---|
| `0x00`–`0x0f` | ordinary status / slot index | yes |
| `0x41` | move finger down | yes |
| `0x42` | move finger right | yes |
| `0x43` | move finger up | yes |
| `0x44` | move finger left | yes |
| `0xdd` | template storage full | no |
| `0xfb` | sensor surface dirty | yes |
| `0xfd` | no matching enrolled finger | no |
| `0xfe` | not enough finger surface | yes |
| `0xff` | command rejected **[OBSERVED, not in reference driver]** | no |

## Device parameters [PORTED]

```
ELANMOC2_ENROLL_TIMES     8      enroll stages before a template completes
ELANMOC2_MAX_PRINTS      10      template slots on the sensor
ELANMOC2_MAX_RETRIES      3      retries for a zero-length reply
ELANMOC2_CMD_MAX_LEN      2      maximum opcode length
send/recv timeout     10000 ms
scan type             FP_SCAN_TYPE_PRESS
```

Driver-data variants: `ELANMOC2_ALL_DEV = 0` for every PID except `0c5e`, which
sets `ELANMOC2_DEV_0C5E (1 << 0)` and shifts the user-id offset by one.

## Security properties

This is a **match-on-chip** sensor (`FP_TYPE_DEVICE`, not `FP_TYPE_IMAGE_DEVICE`).
Matching happens inside the sensor and the biometric template is never
transferred over USB. `finger_info` returns only an application-assigned user-id
string — there is no command in the table that reads out a template.

Refusing to export templates is therefore not a policy this driver enforces on
top of the hardware; the hardware does not offer the capability.

## Open questions

1. What are the 21 bytes of the HID report descriptor, and why does a
   bulk-only vendor device advertise one? (`probe` fetches it; not yet run
   with privileges.)
2. **Why is `ff 12` rejected on `0c00`?** Different opcode, different payload
   shape, or does it require prior state the reference driver's state machine
   establishes?
3. **Is `get_enrolled_count`'s `0x01` a count or a status?** This gates whether
   the sensor really holds a template.
4. `commit` and `delete` are both `out_len == 72`. The 69-byte payload layout
   after `40 ff XX` is not documented here and was not traced.
5. Do endpoints `0x02`/`0x04`/`0x81`/`0x82` respond to anything on `0c00`?
6. Does `0c00` need a quirk flag of its own, in the manner of
   `ELANMOC2_DEV_0C5E`? The `ff 12` rejection suggests yes.
