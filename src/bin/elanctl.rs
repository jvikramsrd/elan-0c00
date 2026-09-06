//! Command-line front-end for the ELAN elanmoc2 driver.
//!
//! Only read-only and non-persistent operations are reachable here. Enroll,
//! commit, delete and wipe exist in the library behind a `DestructiveOps`
//! token but are deliberately NOT wired into this CLI: they write or erase
//! biometric data on the physical sensor.

use elan_0c00::{proto, ElanMoc2};
use std::process::ExitCode;
use std::time::Instant;

fn usage() -> &'static str {
    "\
elanctl — ELAN elanmoc2 (04f3:0c00) driver

USAGE:
    elanctl <COMMAND>

COMMANDS:
    info        Firmware version, enrolled count, and enrolled slot metadata.
                Read-only: sends only get_fw_ver, get_enrolled_count,
                finger_info. Writes nothing.
    dump        Raw hex of every read-only reply, with the 0x40 frame-magic
                check disabled. Diagnostic. Sends no commands beyond those
                `info` already sends.
    collision   Send check_enroll_collision (ff 10) once and decode the reply.
                Read-only: this command queries, it never writes. Determines
                whether the elanmoc2 enroll path would abort safely or fall
                through to its delete-then-wipe branch on this device.
    identify    Wait for a finger and match it on-sensor. Stores nothing, but
                blocks until you touch the sensor. Ctrl-C aborts.
    help        This message.

NOT AVAILABLE (persistent writes; require explicit operator approval):
    enroll, commit, delete, wipe — implemented in the library behind
    DestructiveOps, intentionally not exposed on the CLI.

NOTE: needs write access to /dev/bus/usb/... — run under sudo, or install a
udev rule for 04f3:0c00.
"
}

fn main() -> ExitCode {
    let arg = std::env::args().nth(1).unwrap_or_else(|| "help".into());
    match arg.as_str() {
        "info" => run(cmd_info),
        "identify" => run(cmd_identify),
        "dump" => run(cmd_dump),
        "collision" => run(cmd_collision),
        "help" | "-h" | "--help" => {
            print!("{}", usage());
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("unknown command: {other}\n");
            print!("{}", usage());
            ExitCode::FAILURE
        }
    }
}

fn run(f: fn(&ElanMoc2) -> Result<(), Box<dyn std::error::Error>>) -> ExitCode {
    let dev = match ElanMoc2::open() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("open failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "opened ELAN 04f3:{:04x}, interface 0 claimed",
        dev.product_id()
    );
    match f(&dev) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn hex(b: &[u8]) -> String {
    b.iter()
        .map(|x| format!("{x:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn cmd_info(dev: &ElanMoc2) -> Result<(), Box<dyn std::error::Error>> {
    println!("\n-- read-only queries --");

    let t = Instant::now();
    match dev.firmware_version() {
        Ok(v) => println!(
            "  get_fw_ver          -> {v}  (raw [{}])  ({:?})",
            hex(&v.raw),
            t.elapsed()
        ),
        Err(e) => println!("  get_fw_ver          -> ERROR: {e}  ({:?})", t.elapsed()),
    }

    let t = Instant::now();
    let count = match dev.enrolled_count() {
        Ok(c) => {
            println!("  get_enrolled_count  -> {c}  ({:?})", t.elapsed());
            c
        }
        Err(e) => {
            println!("  get_enrolled_count  -> ERROR: {e}  ({:?})", t.elapsed());
            return Ok(());
        }
    };

    if count == 0 {
        println!("\n  no fingers enrolled on this sensor");
        return Ok(());
    }

    println!("\n-- enrolled slots (metadata only; templates never leave the sensor) --");
    for i in 0..count.min(proto::MAX_PRINTS as u8) {
        let t = Instant::now();
        match dev.finger_info(i) {
            Ok(f) => println!(
                "  slot {i}: user_id={:?} ({} bytes)  ({:?})",
                f.user_id_display(),
                f.user_id.len(),
                t.elapsed()
            ),
            Err(e) => println!("  slot {i}: ERROR: {e}  ({:?})", t.elapsed()),
        }
    }
    Ok(())
}

fn cmd_dump(dev: &ElanMoc2) -> Result<(), Box<dyn std::error::Error>> {
    println!("\n-- raw replies (frame-magic check DISABLED) --");

    for (label, cmd, payload) in [
        ("get_fw_ver        ", &proto::GET_FW_VER, Vec::new()),
        ("get_enrolled_count", &proto::GET_ENROLLED_COUNT, Vec::new()),
    ] {
        let t = Instant::now();
        match dev.transceive_raw(cmd, &payload) {
            Ok(r) => println!(
                "  {label} out={:>2}B in={:>2}B ep=0x{:02x} -> [{}]  ({:?})",
                cmd.out_len,
                r.len(),
                cmd.ep_in,
                hex(&r),
                t.elapsed()
            ),
            Err(e) => println!("  {label} ERROR: {e}  ({:?})", t.elapsed()),
        }
    }

    // Dump every slot, not just the enrolled ones, so the storage layout shows.
    println!(
        "\n-- finger_info, all {} slots, full 64-byte replies --",
        proto::MAX_PRINTS
    );
    for i in 0..proto::MAX_PRINTS as u8 {
        let t = Instant::now();
        match dev.transceive_raw(&proto::FINGER_INFO, &[i]) {
            Ok(r) => {
                let nonzero = r.iter().filter(|&&b| b != 0).count();
                println!(
                    "  slot {i}: {}B, {nonzero} non-zero  ({:?})",
                    r.len(),
                    t.elapsed()
                );
                println!("    {}", hex(&r));
            }
            Err(e) => println!("  slot {i}: ERROR: {e}  ({:?})", t.elapsed()),
        }
    }
    Ok(())
}

fn cmd_collision(dev: &ElanMoc2) -> Result<(), Box<dyn std::error::Error>> {
    println!("\n-- check_enroll_collision (ff 10), read-only --");
    println!("place a finger on the sensor if it waits (Ctrl-C aborts)...");

    let t = Instant::now();
    let r = dev.transceive_raw(&proto::CHECK_ENROLL_COLLISION, &[])?;
    println!("  raw reply: [{}]  ({:?})", hex(&r), t.elapsed());

    if r.len() < 2 {
        println!("  reply shorter than 2 bytes; cannot decode");
        return Ok(());
    }

    let st = proto::Status::from_byte(r[1]);
    println!("  status byte 0x{:02x} -> {st:?} ({})", r[1], st.describe());

    // Mirrors elanmoc2_enroll_run_state / ENROLL_GET_ENROLLED_FINGER_INFO.
    println!("\n-- what upstream's enroll path would do with this --");
    match st {
        proto::Status::NotEnrolled => println!(
            "  0xfd -> jumps straight to ENROLL_ENROLL.\n               SAFE: no delete, no wipe."
        ),
        proto::Status::Ok(idx) => println!(
            "  MSN clear -> treated as \"already enrolled at slot {idx}\".\n               Sends finger_info (known broken here), then ENROLL_ATTEMPT_DELETE.\n               If that delete fails, ENROLL_CHECK_DELETED jumps to ENROLL_WIPE_SENSOR.\n               *** DANGEROUS: enrolling could wipe the sensor. ***"
        ),
        _ => println!(
            "  terminal error, can_retry = false -> fpi_device_enroll_complete(error).\n               SAFE: aborts before reaching delete or wipe."
        ),
    }
    Ok(())
}

fn cmd_identify(dev: &ElanMoc2) -> Result<(), Box<dyn std::error::Error>> {
    let count = dev.enrolled_count()?;
    println!("\n{count} finger(s) enrolled");
    if count == 0 {
        println!("nothing to match against; not sending identify");
        return Ok(());
    }

    println!("place a finger on the sensor (Ctrl-C to abort)...");
    let t = Instant::now();
    let r = dev.transceive(&proto::IDENTIFY, &[]);
    match r {
        Ok(resp) if resp.len() >= 2 => {
            let st = proto::Status::from_byte(resp[1]);
            println!(
                "identify -> [{}] status={st:?} ({}) in {:?}",
                hex(&resp),
                st.describe(),
                t.elapsed()
            );
            if let proto::Status::Ok(idx) = st {
                match dev.finger_info(idx) {
                    Ok(f) => println!("matched slot {idx}: user_id={:?}", f.user_id_display()),
                    Err(e) => println!("matched slot {idx}, finger_info failed: {e}"),
                }
            }
        }
        Ok(resp) => println!(
            "identify -> short reply [{}] in {:?}",
            hex(&resp),
            t.elapsed()
        ),
        Err(e) => {
            println!("identify -> {e} after {:?}", t.elapsed());
            let _ = dev.abort();
        }
    }
    Ok(())
}
