# Getting an `elanmoc2` fingerprint sensor working on Linux

For anyone whose laptop has an ELAN reader in the **`elanmoc2`** family:

```
04f3:0c00   04f3:0c4c   04f3:0c5e   04f3:0c7c   04f3:0c90
```

These are not supported by upstream libfprint. The driver lives on a branch that
has been in review since 2021
([MR !330](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330)).

## Step 0 — check what you actually have

```sh
./scripts/check-support.sh
```

or by hand:

```sh
lsusb | grep -i 04f3
```

ELAN also ships touchpads under vendor `04f3`, so a match is not automatically a
fingerprint reader. The script distinguishes the three USB driver families:

| your PID | driver | status |
|---|---|---|
| `0903 0907 0c01`–`0c33 0c3d 0c42 0c4b 0c4d 0c4f 0c58 0c63 0c6e` | `elan` | works already, upstream |
| `0c7d 0c7e 0c82 0c88 0c8c 0c8d 0c98 0c99 0c9c 0c9d 0c9f 0ca3 0ca7 0ca8 0cb0 0cb2` | `elanmoc` | works already, upstream |
| **`0c00 0c4c 0c5e 0c7c 0c90`** | **`elanmoc2`** | **this guide** |

If your PID is in the first two rows, you do not need any of this — install
`fprintd` and you are done. If it is in none of them, you have a different
device and this guide will not help.

## What to expect, honestly

| PID | evidence |
|---|---|
| `0c4c` | the driver's development target; the author has this part |
| `0c00` | **enroll and verify unproven.** Framing confirmed on real hardware, but `finger_info` (`ff 12`) is rejected on every slot and `get_fw_ver` replies without frame magic. See [`PROTOCOL.md`](PROTOCOL.md). |
| `0c5e` `0c7c` `0c90` | in the ID table; no first-hand results here |

Also true for every PID: `elanmoc2` implements `open`, `close`, `identify`,
`verify`, `enroll`, `clear_storage` and `cancel`, but **not `list` and not
`delete`**. You cannot enumerate or remove individual prints — only wipe all of
them.

This replaces your system libfprint with a fork. Read the rollback section
before you start.

## Option A — prebuilt packages (easiest)

**Arch / Manjaro / EndeavourOS** — AUR:

```sh
# newer branch
paru -S libfprint-elanmoc2-git
# or the older, longer-lived branch
paru -S libfprint-elanmoc2-working-git
```

Both conflict with and replace `libfprint`.

**Debian / Ubuntu / Mint / Pop!_OS** — community packaging:
<https://github.com/Greek64/libfprint-elanmoc2-deb>

Skip to [Enable fingerprint login](#enable-fingerprint-login) once installed.

## Option B — build from source (any distro)

### Dependencies

**Arch**
```sh
sudo pacman -S --needed base-devel git meson ninja \
  glib2 glib2-devel libgusb nss pixman libgudev \
  gobject-introspection cairo openssl systemd-libs
```
`glib2-devel` is easy to miss — without it meson fails with
`Dependency 'glib-2.0' tool variable 'glib_mkenums' contains erroneous value`.

**Debian / Ubuntu**
```sh
sudo apt install build-essential git meson ninja-build pkg-config \
  libglib2.0-dev libgusb-dev libnss3-dev libpixman-1-dev \
  libgudev-1.0-dev libgirepository1.0-dev libcairo2-dev \
  libssl-dev libsystemd-dev libudev-dev
```

**Fedora**
```sh
sudo dnf install gcc gcc-c++ git meson ninja-build \
  glib2-devel libgusb-devel nss-devel pixman-devel \
  libgudev-devel gobject-introspection-devel cairo-devel \
  openssl-devel systemd-devel
```

### Build

```sh
git clone -b elanmoc2 https://gitlab.freedesktop.org/Depau/libfprint.git
cd libfprint
meson setup build --prefix=/usr
meson compile -C build
```

To build only this driver (faster, fewer dependencies):

```sh
meson setup build --prefix=/usr -Ddrivers=elanmoc2 \
  -Dintrospection=false -Ddoc=false -Dgtk-examples=false -Dinstalled-tests=false
```

### Verify before installing

```sh
./build/libfprint/fprint-list-supported-devices | grep -i 04f3
```

Your PID must appear against `ELAN Match-on-Chip 2`. **If it does not, stop** —
installing will not help.

You can also test without installing anything system-wide, since the built
binaries carry an rpath into the build tree:

```sh
sudo ./build/examples/verify        # needs an enrolled print
```

### Install

```sh
sudo meson install -C build
sudo udevadm control --reload && sudo udevadm trigger
systemctl restart fprintd 2>/dev/null || true
```

On Arch, prefer the AUR package over `meson install` — pacman will otherwise
overwrite these files on the next `libfprint` upgrade, silently reverting you.

## Enable fingerprint login

```sh
sudo pacman -S fprintd     # or: apt install fprintd / dnf install fprintd
fprintd-list "$USER"       # should now show a device
fprintd-enroll             # writes a template to the sensor
fprintd-verify
```

**Debian / Ubuntu** — wire it into PAM:
```sh
sudo pam-auth-update       # tick "Fingerprint authentication"
```

**Arch / Fedora** — edit PAM by hand. Add as the *first* line of
`/etc/pam.d/system-local-login` (and `/etc/pam.d/sudo` if you want it there):
```
auth      sufficient  pam_fprintd.so
```

> Keep a root shell open while editing PAM. A malformed PAM stack can lock you
> out of your own machine. `sufficient` means password login still works if the
> fingerprint fails.

## Permissions without root

The device node is `root:root 0664`, so libusb needs elevation. To avoid `sudo`,
install a rule scoped to your PID:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="04f3", ATTR{idProduct}=="0c00", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/70-elan-fp.rules
sudo udevadm control --reload && sudo udevadm trigger
```

`uaccess` grants access to the locally logged-in user only. Replace `0c00` with
your PID. Not needed for `fprintd`, which runs as root.

## Rollback

Source install:
```sh
sudo ninja -C build uninstall
sudo pacman -S libfprint        # Arch
sudo apt install --reinstall libfprint-2-2   # Debian/Ubuntu
sudo dnf reinstall libfprint    # Fedora
```

AUR:
```sh
sudo pacman -Rns libfprint-elanmoc2-git && sudo pacman -S libfprint
```

If PAM was edited, remove the `pam_fprintd.so` line before removing the library,
or you may not be able to authenticate.

## Troubleshooting

**`fprintd-list` says "No devices available"**
The running libfprint has no driver for your PID. Confirm the fork is actually
loaded:
```sh
fprintd-list "$USER"
ldd /usr/lib/fprintd 2>/dev/null | grep fprint
pacman -Qo /usr/lib/libfprint-2.so.2      # Arch: which package owns it
```
A distro upgrade reinstalling stock `libfprint` is the usual cause.

**meson: `glib_mkenums contains erroneous value`**
Missing `glib2-devel` (Arch) / `libglib2.0-dev` (Debian) / `glib2-devel` (Fedora).

**Enroll fails partway, or verify never matches**
Expected on unproven PIDs. Capture what the sensor actually said:
```sh
G_MESSAGES_DEBUG=all fprintd-enroll 2>&1 | tee enroll.log
```
Then report it on MR !330 with your PID and `lsusb -v -d 04f3:<pid>` output.

**Sensor stops responding**
Replug, or:
```sh
sudo usbreset 04f3:<pid>          # from usbutils
```
A `clear_storage` (`ff 99`) wipe stalls the sensor for about five seconds; that
is normal.

**`Device contains 0 prints` / `manage-prints` fails**
`elanmoc2` implements no `list`. Not a bug in your setup.

## Reporting your results

Whatever the outcome, results on a PID other than `0c4c` are useful — the author
does not have that hardware. Post on
[MR !330](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330):

- `lsusb -v -d 04f3:<pid>` output
- whether `fprintd-enroll` and `fprintd-verify` succeed
- `G_MESSAGES_DEBUG=all` logs on failure
- ideally a umockdev capture:
  `sudo tests/create-driver-test.py --test custom elanmoc2 <pid>`

[`MR330-report.md`](MR330-report.md) in this repo is a template you can adapt.
