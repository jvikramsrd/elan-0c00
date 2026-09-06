//! Wire protocol for the ELAN "Match-on-Chip 2" (elanmoc2) sensor family.
//!
//! Every fact in this module was read out of the `elanmoc2` driver on branch
//! `depau/elanmoc2` @ 11f0316d (`v1.94.9-11-g11f0316d`) of
//! <https://gitlab.freedesktop.org/Depau/libfprint.git>, cross-checked against
//! the descriptors observed on the attached 04f3:0c00. Nothing here is guessed.
//!
//! # Framing
//! Request  (bulk OUT, EP 0x01): `[0x40] [cmd 1..2 bytes] [payload] [0x00 pad]`
//!                               padded to exactly `out_len` bytes.
//! Response (bulk IN, `cmd.ep_in`): exactly `in_len` bytes, and `resp[0]` must
//!                               be `0x40` or the exchange is a protocol error.

/// Every request and every response begins with this byte.
pub const FRAME_MAGIC: u8 = 0x40;

/// Bulk OUT endpoint carrying commands (`ELANMOC2_EP_CMD_OUT`).
pub const EP_CMD_OUT: u8 = 0x01;
/// Bulk IN endpoint for ordinary replies (`ELANMOC2_EP_CMD_IN`).
pub const EP_CMD_IN: u8 = 0x83;
/// Bulk IN endpoint for long-running match/enroll replies (`ELANMOC2_EP_MOC_CMD_IN`).
pub const EP_MOC_CMD_IN: u8 = 0x84;

/// USB vendor ID shared by all ELAN sensors.
pub const VID: u16 = 0x04f3;

/// Product IDs the upstream `elanmoc2` driver claims.
pub const SUPPORTED_PIDS: &[u16] = &[0x0c00, 0x0c4c, 0x0c5e, 0x0c7c, 0x0c90];

/// The device on this machine.
pub const PID_0C00: u16 = 0x0c00;
/// Variant with a 3-byte (rather than 2-byte) user-id offset.
pub const PID_0C5E: u16 = 0x0c5e;

/// Retries allowed when the sensor answers a query with zero bytes.
pub const MAX_RETRIES: u32 = 3;
/// Enroll stages the sensor expects before a template is complete.
pub const ENROLL_STAGES: u32 = 8;
/// Maximum templates storable on the sensor.
pub const MAX_PRINTS: usize = 10;

/// Whether a command may write to the sensor's persistent state.
///
/// This is what the [`crate::device::DestructiveOps`] gate keys off, so it is
/// deliberately part of the command definition rather than a caller decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    /// Reads only. Cannot alter stored templates or device configuration.
    ReadOnly,
    /// Alters device state that does not survive a power cycle (e.g. aborting).
    Transient,
    /// Writes or erases persistent biometric data. Gated.
    Persistent,
}

/// A single protocol command.
#[derive(Debug, Clone, Copy)]
pub struct Cmd {
    /// Human-readable name, used in error messages.
    pub name: &'static str,
    /// Opcode bytes placed directly after [`FRAME_MAGIC`].
    pub cmd: &'static [u8],
    /// Exact length of the OUT transfer, including magic and zero padding.
    pub out_len: usize,
    /// Exact length of the IN transfer. Zero means no response is read.
    pub in_len: usize,
    /// Which bulk IN endpoint carries the reply.
    pub ep_in: u8,
    /// Whether the sensor may block on this command waiting for a finger.
    pub is_cancellable: bool,
    /// Whether this command can alter device state. See [`Effect`].
    pub effect: Effect,
}

// --- read-only commands -------------------------------------------------

/// Reads the sensor firmware version. Upstream's only single-byte opcode.
///
/// **[OBSERVED on 04f3:0c00]** The reply does *not* carry [`FRAME_MAGIC`].
/// It is two raw BCD bytes: `02 83`, matching the device descriptor's
/// `bcdDevice 2.83` exactly. Read it with
/// [`crate::device::ElanMoc2::transceive_raw`], never the framed path.
///
/// The reference `elanmoc2` driver defines this command but never calls it,
/// so its magic check was never exercised against a reply.
pub const GET_FW_VER: Cmd = Cmd {
    name: "get_fw_ver",
    cmd: &[0x19],
    out_len: 2,
    in_len: 2,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::ReadOnly,
};

/// Returns the number of enrolled fingers in `resp[1]`.
///
/// The sensor may legally answer with zero bytes; retry up to [`MAX_RETRIES`].
pub const GET_ENROLLED_COUNT: Cmd = Cmd {
    name: "get_enrolled_count",
    cmd: &[0xff, 0x04],
    out_len: 3,
    in_len: 2,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::ReadOnly,
};

/// Reads the stored user-id for one slot. Payload byte 3 is the finger index.
///
/// **[OBSERVED on 04f3:0c00]** This device answers `40 ff` (2 bytes, status
/// `0xff`) for every slot 0..9, rather than the documented 64-byte record —
/// even though `get_enrolled_count` reports a non-zero count. The command
/// appears unsupported or differently shaped on this PID. See
/// `docs/PROTOCOL.md`.
pub const FINGER_INFO: Cmd = Cmd {
    name: "finger_info",
    cmd: &[0xff, 0x12],
    out_len: 4,
    in_len: 64,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::ReadOnly,
};

/// Asks whether a presented finger is already enrolled.
pub const CHECK_ENROLL_COLLISION: Cmd = Cmd {
    name: "check_enroll_collision",
    cmd: &[0xff, 0x10],
    out_len: 3,
    in_len: 3,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::ReadOnly,
};

// --- transient ----------------------------------------------------------

/// Cancels an in-flight cancellable command. Touches no stored data.
pub const ABORT: Cmd = Cmd {
    name: "abort",
    cmd: &[0xff, 0x02],
    out_len: 3,
    in_len: 2,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::Transient,
};

/// Waits for a finger and matches it against stored templates.
///
/// Matching itself stores nothing, but the sensor blocks until a finger is
/// presented, so this is classed transient rather than read-only.
pub const IDENTIFY: Cmd = Cmd {
    name: "identify",
    cmd: &[0xff, 0x03],
    out_len: 3,
    in_len: 2,
    ep_in: EP_MOC_CMD_IN,
    is_cancellable: true,
    effect: Effect::Transient,
};

// --- persistent (gated) -------------------------------------------------

/// Captures one enrollment stage. **Writes persistent biometric data.**
pub const ENROLL: Cmd = Cmd {
    name: "enroll",
    cmd: &[0xff, 0x01],
    out_len: 7,
    in_len: 2,
    ep_in: EP_MOC_CMD_IN,
    is_cancellable: true,
    effect: Effect::Persistent,
};

/// Commits a completed enrollment to sensor storage. **Persistent write.**
pub const COMMIT: Cmd = Cmd {
    name: "commit",
    cmd: &[0xff, 0x11],
    out_len: 72,
    in_len: 2,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::Persistent,
};

/// Deletes one stored template. **Persistent, destructive.**
pub const DELETE: Cmd = Cmd {
    name: "delete",
    cmd: &[0xff, 0x13],
    out_len: 72,
    in_len: 2,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::Persistent,
};

/// Erases **all** enrolled templates. The sensor stalls ~5 s while it runs.
pub const WIPE_SENSOR: Cmd = Cmd {
    name: "wipe_sensor",
    cmd: &[0xff, 0x99],
    out_len: 3,
    in_len: 0,
    ep_in: EP_CMD_IN,
    is_cancellable: false,
    effect: Effect::Persistent,
};

/// Status byte returned in `resp[1]`.
///
/// Upstream's rule: a most-significant nibble of zero is an ordinary status
/// (the operation may be retried); anything else is a terminal error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Most-significant nibble clear: ordinary status, retryable.
    ///
    /// For a successful `identify` the payload is the matched slot index.
    Ok(u8),
    /// Finger sat too high; move it down. (`0x41`)
    MoveDown,
    /// Finger sat too far left; move it right. (`0x42`)
    MoveRight,
    /// Finger sat too low; move it up. (`0x43`)
    MoveUp,
    /// Finger sat too far right; move it left. (`0x44`)
    MoveLeft,
    /// Sensor template storage is full. (`0xdd`)
    MaxEnrolledReached,
    /// Sensor surface needs cleaning. (`0xfb`)
    SensorDirty,
    /// No enrolled template matched. (`0xfd`)
    NotEnrolled,
    /// Too little finger contact to process. (`0xfe`)
    NotEnoughSurface,
    /// Command rejected. **[OBSERVED on 04f3:0c00]** returned by
    /// `finger_info` for every slot. Not present in the reference driver's
    /// error list. (`0xff`)
    Rejected,
    /// Status byte not described by the reference driver.
    Unknown(u8),
}

impl Status {
    /// Decodes a raw status byte from `resp[1]`.
    pub fn from_byte(b: u8) -> Self {
        if b & 0xF0 == 0 {
            return Status::Ok(b);
        }
        match b {
            0x41 => Status::MoveDown,
            0x42 => Status::MoveRight,
            0x43 => Status::MoveUp,
            0x44 => Status::MoveLeft,
            0xdd => Status::MaxEnrolledReached,
            0xfb => Status::SensorDirty,
            0xfd => Status::NotEnrolled,
            0xfe => Status::NotEnoughSurface,
            0xff => Status::Rejected,
            other => Status::Unknown(other),
        }
    }

    /// Whether the caller may sensibly retry the operation.
    pub fn is_retryable(self) -> bool {
        matches!(
            self,
            Status::Ok(_)
                | Status::MoveDown
                | Status::MoveRight
                | Status::MoveUp
                | Status::MoveLeft
                | Status::SensorDirty
                | Status::NotEnoughSurface
        )
    }

    /// Short human-readable description of the status.
    pub fn describe(self) -> &'static str {
        match self {
            Status::Ok(_) => "ok",
            Status::MoveDown => "move finger down",
            Status::MoveRight => "move finger right",
            Status::MoveUp => "move finger up",
            Status::MoveLeft => "move finger left",
            Status::MaxEnrolledReached => "sensor storage full",
            Status::SensorDirty => "sensor surface dirty",
            Status::NotEnrolled => "no matching enrolled finger",
            Status::NotEnoughSurface => "not enough finger surface on sensor",
            Status::Rejected => "command rejected by sensor",
            Status::Unknown(_) => "unknown status",
        }
    }
}

/// Byte offset of the user-id inside a 64-byte `FINGER_INFO` reply.
///
/// 0c5e reserves one extra byte; every other supported PID uses 2.
pub fn user_id_offset(pid: u16) -> usize {
    if pid == PID_0C5E {
        3
    } else {
        2
    }
}

/// Decodes one packed-BCD byte, e.g. `0x83` -> 83.
pub fn bcd(b: u8) -> u8 {
    (b >> 4) * 10 + (b & 0x0f)
}

/// Builds the OUT buffer for `cmd`, appending `payload` after the opcode.
///
/// Returns `None` if `payload` cannot fit within `cmd.out_len`.
pub fn frame(cmd: &Cmd, payload: &[u8]) -> Option<Vec<u8>> {
    let header = 1 + cmd.cmd.len();
    if header + payload.len() > cmd.out_len {
        return None;
    }
    let mut buf = vec![0u8; cmd.out_len];
    buf[0] = FRAME_MAGIC;
    buf[1..header].copy_from_slice(cmd.cmd);
    buf[header..header + payload.len()].copy_from_slice(payload);
    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_sets_magic_and_pads_to_out_len() {
        let b = frame(&GET_ENROLLED_COUNT, &[]).unwrap();
        assert_eq!(b, vec![0x40, 0xff, 0x04]);
        assert_eq!(b.len(), GET_ENROLLED_COUNT.out_len);
    }

    #[test]
    fn frame_single_byte_opcode_is_not_padded_into_two() {
        // get_fw_ver is upstream's only `is_single_byte_command`; the opcode
        // occupies one byte, so the frame is exactly [0x40, 0x19].
        let b = frame(&GET_FW_VER, &[]).unwrap();
        assert_eq!(b, vec![0x40, 0x19]);
    }

    #[test]
    fn finger_info_puts_index_at_byte_three() {
        // Upstream: `buffer_out->data[3] = self->print_index;`
        let b = frame(&FINGER_INFO, &[7]).unwrap();
        assert_eq!(b, vec![0x40, 0xff, 0x12, 7]);
    }

    #[test]
    fn frame_zero_pads_long_commands() {
        let b = frame(&COMMIT, &[1, 2, 3]).unwrap();
        assert_eq!(b.len(), 72);
        assert_eq!(&b[..6], &[0x40, 0xff, 0x11, 1, 2, 3]);
        assert!(b[6..].iter().all(|&x| x == 0));
    }

    #[test]
    fn frame_rejects_oversized_payload() {
        assert!(frame(&GET_ENROLLED_COUNT, &[1, 2, 3]).is_none());
    }

    #[test]
    fn status_msn_zero_is_retryable_ok() {
        assert_eq!(Status::from_byte(0x00), Status::Ok(0x00));
        assert_eq!(Status::from_byte(0x05), Status::Ok(0x05));
        assert!(Status::from_byte(0x05).is_retryable());
    }

    #[test]
    fn status_terminal_errors_are_not_retryable() {
        assert_eq!(Status::from_byte(0xfd), Status::NotEnrolled);
        assert!(!Status::from_byte(0xfd).is_retryable());
        assert!(!Status::from_byte(0xdd).is_retryable());
    }

    #[test]
    fn bcd_decodes_observed_firmware_bytes() {
        // OBSERVED on 04f3:0c00: get_fw_ver -> [02 83], and the device
        // descriptor reports bcdDevice 2.83.
        assert_eq!(bcd(0x02), 2);
        assert_eq!(bcd(0x83), 83);
    }

    #[test]
    fn status_ff_is_rejected() {
        assert_eq!(Status::from_byte(0xff), Status::Rejected);
        assert!(!Status::from_byte(0xff).is_retryable());
    }

    #[test]
    fn user_id_offset_matches_variant() {
        assert_eq!(user_id_offset(PID_0C00), 2);
        assert_eq!(user_id_offset(PID_0C5E), 3);
    }

    #[test]
    fn destructive_commands_are_marked_persistent() {
        for c in [ENROLL, COMMIT, DELETE, WIPE_SENSOR] {
            assert_eq!(c.effect, Effect::Persistent, "{} must be gated", c.name);
        }
        for c in [GET_FW_VER, GET_ENROLLED_COUNT, FINGER_INFO] {
            assert_eq!(c.effect, Effect::ReadOnly, "{} must be read-only", c.name);
        }
    }
}
