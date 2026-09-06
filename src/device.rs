//! USB transport and operations for the ELAN elanmoc2 sensor family.

use crate::proto::{self, Cmd, Effect, Status};
use rusb::{Context, Device, DeviceHandle, UsbContext};
use std::fmt;
use std::time::Duration;

/// Timeout for a bulk OUT command transfer.
pub const SEND_TIMEOUT: Duration = Duration::from_millis(10_000);
/// Timeout for a bulk IN reply transfer.
pub const RECV_TIMEOUT: Duration = Duration::from_millis(10_000);

/// Anything that can go wrong talking to the sensor.
#[derive(Debug)]
pub enum Error {
    /// Underlying libusb failure.
    Usb(rusb::Error),
    /// No device with a supported VID:PID is attached.
    NotFound,
    /// Reply did not begin with [`proto::FRAME_MAGIC`].
    BadMagic {
        /// The byte actually received in position 0.
        got: u8,
    },
    /// Reply was shorter than the command's declared `in_len`.
    Short {
        /// Bytes the command's `in_len` declared.
        expected: usize,
        /// Bytes actually read.
        got: usize,
    },
    /// Payload too large for the command's frame.
    PayloadTooLarge {
        /// Name of the offending command.
        cmd: &'static str,
    },
    /// Sensor returned a terminal status byte.
    Status(Status),
    /// Sensor answered a query with zero bytes `MAX_RETRIES` times.
    NoResponse {
        /// Name of the command that went unanswered.
        cmd: &'static str,
    },
    /// A persistent-effect command was attempted without a capability token.
    Gated {
        /// Name of the refused persistent-effect command.
        cmd: &'static str,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Usb(e) => write!(f, "usb: {e}"),
            Error::NotFound => write!(f, "no supported ELAN sensor found"),
            Error::BadMagic { got } => {
                write!(f, "bad frame magic: expected 0x40, got 0x{got:02x}")
            }
            Error::Short { expected, got } => {
                write!(f, "short read: expected {expected} bytes, got {got}")
            }
            Error::PayloadTooLarge { cmd } => write!(f, "payload too large for {cmd}"),
            Error::Status(s) => write!(f, "sensor status: {} ({s:?})", s.describe()),
            Error::NoResponse { cmd } => write!(f, "no response to {cmd} after retries"),
            Error::Gated { cmd } => write!(
                f,
                "{cmd} writes persistent data and requires an explicit DestructiveOps token"
            ),
        }
    }
}

impl std::error::Error for Error {}

impl From<rusb::Error> for Error {
    fn from(e: rusb::Error) -> Self {
        Error::Usb(e)
    }
}

/// Convenience alias for this crate's fallible operations.
pub type Result<T> = std::result::Result<T, Error>;

/// Capability token required for any command that writes persistent biometric
/// data (enroll, commit, delete, wipe).
///
/// It has no public constructor beyond the deliberately verbose associated
/// function below, so a persistent-effect command cannot be reached by
/// accident or by a caller that merely has a [`ElanMoc2`] handle.
#[derive(Debug)]
pub struct DestructiveOps {
    _private: (),
}

impl DestructiveOps {
    /// Mint the token. Naming is intentionally hard to type by mistake.
    ///
    /// # Safety contract
    /// Calling this asserts the operator has consented to modifying stored
    /// fingerprint templates on the physical sensor.
    pub fn i_understand_this_modifies_stored_fingerprints() -> Self {
        DestructiveOps { _private: () }
    }
}

/// Sensor firmware version, decoded from the two raw BCD bytes of
/// `get_fw_ver`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FirmwareVersion {
    /// Major component (`bcd(raw[0])`).
    pub major: u8,
    /// Minor component (`bcd(raw[1])`).
    pub minor: u8,
    /// The two bytes exactly as the sensor sent them.
    pub raw: [u8; 2],
}

impl fmt::Display for FirmwareVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{:02}", self.major, self.minor)
    }
}

/// One enrolled slot as reported by `FINGER_INFO`.
#[derive(Debug, Clone)]
pub struct FingerInfo {
    /// Zero-based slot index on the sensor.
    pub index: u8,
    /// Raw user-id bytes, trailing NULs trimmed.
    pub user_id: Vec<u8>,
}

impl FingerInfo {
    /// User-id rendered as UTF-8 when printable, otherwise as lowercase hex.
    pub fn user_id_display(&self) -> String {
        match std::str::from_utf8(&self.user_id) {
            Ok(s) if s.chars().all(|c| !c.is_control()) => s.to_string(),
            _ => {
                use std::fmt::Write as _;
                self.user_id.iter().fold(String::new(), |mut acc, b| {
                    let _ = write!(acc, "{b:02x}");
                    acc
                })
            }
        }
    }
}

/// An opened elanmoc2 sensor with interface 0 claimed.
pub struct ElanMoc2 {
    handle: DeviceHandle<Context>,
    pid: u16,
    interface: u8,
    claimed: bool,
}

impl ElanMoc2 {
    /// Finds and opens the first attached sensor whose PID the elanmoc2 driver
    /// claims, then claims interface 0.
    pub fn open() -> Result<Self> {
        let ctx = Context::new()?;
        let dev = Self::find(&ctx)?;
        let pid = dev.device_descriptor()?.product_id();
        let handle = dev.open()?;

        let interface = 0u8;
        // The sensor is vendor-class and normally unbound, but detach politely
        // rather than failing if something claimed it.
        if handle.kernel_driver_active(interface).unwrap_or(false) {
            handle.detach_kernel_driver(interface)?;
        }
        let mut me = ElanMoc2 {
            handle,
            pid,
            interface,
            claimed: false,
        };
        me.handle.claim_interface(interface)?;
        me.claimed = true;
        Ok(me)
    }

    fn find(ctx: &Context) -> Result<Device<Context>> {
        for dev in ctx.devices()?.iter() {
            let Ok(d) = dev.device_descriptor() else {
                continue;
            };
            if d.vendor_id() == proto::VID && proto::SUPPORTED_PIDS.contains(&d.product_id()) {
                return Ok(dev);
            }
        }
        Err(Error::NotFound)
    }

    /// USB product ID of the opened sensor.
    pub fn product_id(&self) -> u16 {
        self.pid
    }

    /// Sends `cmd` with `payload` and returns the reply body.
    ///
    /// Refuses any [`Effect::Persistent`] command; those go through
    /// [`ElanMoc2::transceive_destructive`].
    pub fn transceive(&self, cmd: &Cmd, payload: &[u8]) -> Result<Vec<u8>> {
        gate_check(cmd)?;
        self.transceive_unchecked(cmd, payload)
    }

    /// Sends a persistent-effect command. Requires a [`DestructiveOps`] token.
    pub fn transceive_destructive(
        &self,
        cmd: &Cmd,
        payload: &[u8],
        _token: &DestructiveOps,
    ) -> Result<Vec<u8>> {
        self.transceive_unchecked(cmd, payload)
    }

    fn transceive_unchecked(&self, cmd: &Cmd, payload: &[u8]) -> Result<Vec<u8>> {
        let out = proto::frame(cmd, payload).ok_or(Error::PayloadTooLarge { cmd: cmd.name })?;
        self.handle
            .write_bulk(proto::EP_CMD_OUT, &out, SEND_TIMEOUT)?;

        if cmd.in_len == 0 {
            return Ok(Vec::new());
        }

        let mut buf = vec![0u8; cmd.in_len];
        let n = self.handle.read_bulk(cmd.ep_in, &mut buf, RECV_TIMEOUT)?;
        buf.truncate(n);

        if n == 0 {
            return Ok(buf); // caller decides whether to retry
        }
        if buf[0] != proto::FRAME_MAGIC {
            return Err(Error::BadMagic { got: buf[0] });
        }
        Ok(buf)
    }

    /// Sends `cmd` and returns the reply **without enforcing the frame magic**.
    ///
    /// Diagnostic path only. `get_fw_ver` on 04f3:0c00 was observed to reply
    /// with a byte other than [`proto::FRAME_MAGIC`] in position 0, so the
    /// ordinary path cannot read it. Still gated: persistent commands are
    /// refused here exactly as in [`ElanMoc2::transceive`].
    pub fn transceive_raw(&self, cmd: &Cmd, payload: &[u8]) -> Result<Vec<u8>> {
        gate_check(cmd)?;
        let out = proto::frame(cmd, payload).ok_or(Error::PayloadTooLarge { cmd: cmd.name })?;
        self.handle
            .write_bulk(proto::EP_CMD_OUT, &out, SEND_TIMEOUT)?;
        if cmd.in_len == 0 {
            return Ok(Vec::new());
        }
        let mut buf = vec![0u8; cmd.in_len];
        let n = self.handle.read_bulk(cmd.ep_in, &mut buf, RECV_TIMEOUT)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Retries a query that the sensor may answer with zero bytes.
    fn transceive_retrying(&self, cmd: &Cmd, payload: &[u8]) -> Result<Vec<u8>> {
        for _ in 0..proto::MAX_RETRIES {
            let r = self.transceive(cmd, payload)?;
            if !r.is_empty() {
                return Ok(r);
            }
        }
        Err(Error::NoResponse { cmd: cmd.name })
    }

    // --- read-only operations -------------------------------------------

    /// Reads the sensor firmware version.
    ///
    /// Uses the raw path deliberately: on 04f3:0c00 the `get_fw_ver` reply
    /// carries no frame magic, it is two packed-BCD bytes (`02 83` for
    /// firmware 2.83, matching `bcdDevice`).
    pub fn firmware_version(&self) -> Result<FirmwareVersion> {
        let r = self.transceive_raw(&proto::GET_FW_VER, &[])?;
        if r.len() < 2 {
            return Err(Error::Short {
                expected: 2,
                got: r.len(),
            });
        }
        Ok(FirmwareVersion {
            major: proto::bcd(r[0]),
            minor: proto::bcd(r[1]),
            raw: [r[0], r[1]],
        })
    }

    /// Number of fingers currently enrolled on the sensor.
    pub fn enrolled_count(&self) -> Result<u8> {
        let r = self.transceive_retrying(&proto::GET_ENROLLED_COUNT, &[])?;
        if r.len() < 2 {
            return Err(Error::Short {
                expected: 2,
                got: r.len(),
            });
        }
        Ok(r[1])
    }

    /// Reads the stored user-id for one slot. Reads metadata only — this does
    /// not and cannot retrieve the biometric template itself, which never
    /// leaves the sensor on a match-on-chip part.
    pub fn finger_info(&self, index: u8) -> Result<FingerInfo> {
        let r = self.transceive_retrying(&proto::FINGER_INFO, &[index])?;

        // OBSERVED on 04f3:0c00: a 2-byte reply `40 ff` for every slot. Treat
        // an error status as an error rather than silently yielding an empty
        // user-id, which is what a naive offset slice would do.
        if r.len() >= 2 {
            let st = Status::from_byte(r[1]);
            if !matches!(st, Status::Ok(_)) {
                return Err(Error::Status(st));
            }
        }

        let off = proto::user_id_offset(self.pid);
        if r.len() < off {
            return Err(Error::Short {
                expected: off,
                got: r.len(),
            });
        }
        let mut user_id = r[off..].to_vec();
        while user_id.last() == Some(&0) {
            user_id.pop();
        }
        Ok(FingerInfo { index, user_id })
    }

    /// Cancels an in-flight cancellable command.
    pub fn abort(&self) -> Result<()> {
        self.transceive(&proto::ABORT, &[])?;
        Ok(())
    }
}

/// Refuses any command that writes persistent biometric data.
///
/// Split out as a free function so the refusal path is unit-testable without
/// a physical sensor attached.
pub fn gate_check(cmd: &Cmd) -> Result<()> {
    if cmd.effect == Effect::Persistent {
        return Err(Error::Gated { cmd: cmd.name });
    }
    Ok(())
}

impl Drop for ElanMoc2 {
    fn drop(&mut self) {
        if self.claimed {
            let _ = self.handle.release_interface(self.interface);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_refuses_every_persistent_command() {
        for c in [
            proto::ENROLL,
            proto::COMMIT,
            proto::DELETE,
            proto::WIPE_SENSOR,
        ] {
            match gate_check(&c) {
                Err(Error::Gated { cmd }) => assert_eq!(cmd, c.name),
                other => panic!("{} was NOT gated: {other:?}", c.name),
            }
        }
    }

    #[test]
    fn gate_allows_read_only_and_transient_commands() {
        for c in [
            proto::GET_FW_VER,
            proto::GET_ENROLLED_COUNT,
            proto::FINGER_INFO,
            proto::CHECK_ENROLL_COLLISION,
            proto::ABORT,
            proto::IDENTIFY,
        ] {
            assert!(gate_check(&c).is_ok(), "{} should be allowed", c.name);
        }
    }

    #[test]
    fn finger_info_display_prefers_utf8() {
        let f = FingerInfo {
            index: 0,
            user_id: b"FP1-alice".to_vec(),
        };
        assert_eq!(f.user_id_display(), "FP1-alice");
    }

    #[test]
    fn finger_info_display_falls_back_to_hex() {
        let f = FingerInfo {
            index: 0,
            user_id: vec![0xde, 0xad, 0xbe, 0xef],
        };
        assert_eq!(f.user_id_display(), "deadbeef");
    }
}
