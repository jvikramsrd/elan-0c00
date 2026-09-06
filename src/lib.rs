#![warn(missing_docs)]
#![forbid(unsafe_code)]
#![warn(clippy::pedantic)]
#![allow(
    clippy::must_use_candidate,
    clippy::missing_errors_doc,
    clippy::module_name_repetitions
)]
//! Userspace driver for the ELAN "Match-on-Chip 2" fingerprint sensor family
//! (USB 04f3:0c00 and relatives), built on `rusb`.
//!
//! The protocol is a faithful port of the out-of-tree `elanmoc2` libfprint
//! driver (`depau/elanmoc2` @ 11f0316d), cross-checked against descriptors read
//! from a physical 04f3:0c00. See `NOTES.md` for the evidence trail.
//!
//! # Safety posture
//! Commands are tagged with an [`proto::Effect`]. Anything that writes
//! persistent biometric data is unreachable through the ordinary
//! [`device::ElanMoc2::transceive`] path and requires an explicit
//! [`device::DestructiveOps`] token. This driver never exports biometric
//! templates: on a match-on-chip sensor, matching happens on the device and the
//! template is not readable over USB.

pub mod device;
pub mod proto;

pub use device::{DestructiveOps, ElanMoc2, Error, FingerInfo, Result};
