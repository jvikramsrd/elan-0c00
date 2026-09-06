//! Read-only USB probe for the ELAN 04f3:0c00 fingerprint sensor.
//!
//! SAFETY POLICY (enforced by construction):
//!   * Only VID 0x04f3 / PID 0x0c00 is ever opened.
//!   * Only *standard*, spec-defined GET_DESCRIPTOR control reads are issued.
//!     No vendor-specific (bmRequestType type=vendor) requests are sent.
//!   * No bulk/interrupt OUT transfer is ever performed, so the device is
//!     never given a command it did not already have to answer by USB spec.
//!   * Bulk IN reads are passive: with nothing queued the device NAKs and we
//!     time out. Nothing is written, erased, enrolled, or reconfigured.

use rusb::{Context, Direction, TransferType, UsbContext};
use std::time::{Duration, Instant};

const VID: u16 = 0x04f3;
const PID: u16 = 0x0c00;

/// Standard GET_DESCRIPTOR on an interface (used for the HID report descriptor).
const REQ_GET_DESCRIPTOR: u8 = 0x06;
const DESC_HID_REPORT: u16 = 0x22;

fn hex(buf: &[u8]) -> String {
    buf.iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ctx = Context::new()?;

    let device = ctx
        .devices()?
        .iter()
        .find(|d| {
            d.device_descriptor()
                .map(|dd| dd.vendor_id() == VID && dd.product_id() == PID)
                .unwrap_or(false)
        })
        .ok_or("ELAN 04f3:0c00 not found on any bus")?;

    let dd = device.device_descriptor()?;
    println!("== DEVICE 04f3:0c00 ==");
    println!("  bus {} addr {}", device.bus_number(), device.address());
    println!("  speed              {:?}", device.speed());
    println!(
        "  bcdUSB             {:x}.{:02x}",
        dd.usb_version().major(),
        dd.usb_version().minor()
    );
    println!(
        "  bcdDevice          {}.{}",
        dd.device_version().major(),
        dd.device_version().minor()
    );
    println!("  bDeviceClass       0x{:02x}", dd.class_code());
    println!("  bMaxPacketSize0    {}", dd.max_packet_size());
    println!("  bNumConfigurations {}", dd.num_configurations());

    // ---- descriptor walk (no open required) ----
    for ci in 0..dd.num_configurations() {
        let cfg = device.config_descriptor(ci)?;
        println!(
            "\n== CONFIG {} == interfaces={} max_power={}mA self_powered={}",
            cfg.number(),
            cfg.num_interfaces(),
            cfg.max_power(),
            cfg.self_powered()
        );
        for iface in cfg.interfaces() {
            for alt in iface.descriptors() {
                println!(
                    "  IF {} alt {}: class=0x{:02x} sub=0x{:02x} proto=0x{:02x} eps={}",
                    alt.interface_number(),
                    alt.setting_number(),
                    alt.class_code(),
                    alt.sub_class_code(),
                    alt.protocol_code(),
                    alt.num_endpoints()
                );
                if let Some(extra) = Some(alt.extra()).filter(|e| !e.is_empty()) {
                    println!(
                        "    class-specific extra ({} B): {}",
                        extra.len(),
                        hex(extra)
                    );
                    decode_hid_descriptor(extra);
                }
                for ep in alt.endpoint_descriptors() {
                    println!(
                        "    EP 0x{:02x} {:?} {:?} wMaxPacketSize={} bInterval={}",
                        ep.address(),
                        ep.direction(),
                        ep.transfer_type(),
                        ep.max_packet_size(),
                        ep.interval()
                    );
                }
            }
        }
    }

    // ---- open (needs write access to /dev/bus/usb/...) ----
    println!("\n== OPEN ==");
    let handle = match device.open() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("  open failed: {e}  (run as root, or add a udev rule)");
            return Err(e.into());
        }
    };
    println!("  opened ok");

    let timeout = Duration::from_millis(1000);
    let langs = handle.read_languages(timeout)?;
    println!("  languages: {langs:?}");
    if let Some(&lang) = langs.first() {
        for (name, idx) in [
            ("iManufacturer", dd.manufacturer_string_index()),
            ("iProduct", dd.product_string_index()),
            ("iSerialNumber", dd.serial_number_string_index()),
        ] {
            match idx {
                Some(_) => println!(
                    "  {name}: {:?}",
                    match name {
                        "iManufacturer" => handle.read_manufacturer_string(lang, &dd, timeout),
                        "iProduct" => handle.read_product_string(lang, &dd, timeout),
                        _ => handle.read_serial_number_string(lang, &dd, timeout),
                    }
                ),
                None => println!("  {name}: <none>"),
            }
        }
    }

    let iface = 0u8;
    match handle.kernel_driver_active(iface) {
        Ok(true) => println!("  kernel driver ACTIVE on iface {iface} (not detaching)"),
        Ok(false) => println!("  no kernel driver on iface {iface}"),
        Err(e) => println!("  kernel_driver_active: {e}"),
    }
    handle.claim_interface(iface)?;
    println!("  claimed interface {iface}");

    // ---- standard GET_DESCRIPTOR: HID report descriptor ----
    // bmRequestType 0x81 = IN | Standard | Interface. Spec-defined, read-only.
    println!("\n== HID REPORT DESCRIPTOR (standard GET_DESCRIPTOR, read-only) ==");
    let mut buf = [0u8; 256];
    let t0 = Instant::now();
    match handle.read_control(
        rusb::request_type(
            Direction::In,
            rusb::RequestType::Standard,
            rusb::Recipient::Interface,
        ),
        REQ_GET_DESCRIPTOR,
        DESC_HID_REPORT << 8,
        iface as u16,
        &mut buf,
        timeout,
    ) {
        Ok(n) => {
            println!("  got {n} bytes in {:?}", t0.elapsed());
            println!("  {}", hex(&buf[..n]));
            decode_report_descriptor(&buf[..n]);
        }
        Err(e) => println!("  error after {:?}: {e}", t0.elapsed()),
    }

    // ---- passive bulk IN listen: send nothing, see if device volunteers data ----
    println!("\n== PASSIVE BULK IN (no OUT sent; short timeout expected) ==");
    let cfg = device.config_descriptor(0)?;
    let in_eps: Vec<u8> = cfg
        .interfaces()
        .flat_map(|i| i.descriptors().collect::<Vec<_>>())
        .flat_map(|a| a.endpoint_descriptors().collect::<Vec<_>>())
        .filter(|e| e.direction() == Direction::In && e.transfer_type() == TransferType::Bulk)
        .map(|e| e.address())
        .collect();
    for ep in in_eps {
        let mut rb = [0u8; 64];
        let t = Instant::now();
        match handle.read_bulk(ep, &mut rb, Duration::from_millis(300)) {
            Ok(n) => println!(
                "  EP 0x{ep:02x}: {n} B in {:?} -> {}",
                t.elapsed(),
                hex(&rb[..n])
            ),
            Err(e) => println!("  EP 0x{ep:02x}: {e} after {:?}", t.elapsed()),
        }
    }

    handle.release_interface(iface)?;
    println!("\n== done (released, device state unmodified) ==");
    Ok(())
}

/// Decode a class-specific HID descriptor (bDescriptorType 0x21) if present.
fn decode_hid_descriptor(extra: &[u8]) {
    let mut i = 0;
    while i + 2 <= extra.len() {
        let len = extra[i] as usize;
        let dtype = extra[i + 1];
        if len == 0 || i + len > extra.len() {
            break;
        }
        if dtype == 0x21 && len >= 9 {
            let d = &extra[i..i + len];
            println!(
                "    -> HID descriptor: bcdHID={:x}.{:02x} country={} numDesc={} \
                 subordinate: type=0x{:02x} len={}",
                d[3],
                d[2],
                d[4],
                d[5],
                d[6],
                u16::from_le_bytes([d[7], d[8]])
            );
        }
        i += len;
    }
}

/// Minimal HID report-descriptor item decoder (enough to read usage page/size/count).
fn decode_report_descriptor(d: &[u8]) {
    let mut i = 0;
    while i < d.len() {
        let b = d[i];
        let size = match b & 0x03 {
            3 => 4,
            n => n as usize,
        };
        let ty = (b >> 2) & 0x03;
        let tag = b >> 4;
        let data = &d[i + 1..(i + 1 + size).min(d.len())];
        let val = data.iter().rev().fold(0u32, |a, &x| (a << 8) | x as u32);
        let ty_s = ["Main", "Global", "Local", "Reserved"][ty as usize];
        let name = match (ty, tag) {
            (1, 0x0) => "Usage Page",
            (1, 0x1) => "Logical Minimum",
            (1, 0x2) => "Logical Maximum",
            (1, 0x7) => "Report Size",
            (1, 0x8) => "Report ID",
            (1, 0x9) => "Report Count",
            (2, 0x0) => "Usage",
            (0, 0x8) => "Input",
            (0, 0x9) => "Output",
            (0, 0xB) => "Feature",
            (0, 0xA) => "Collection",
            (0, 0xC) => "End Collection",
            _ => "?",
        };
        println!("    [{ty_s}] {name} (0x{b:02x}) = 0x{val:x} ({val})");
        i += 1 + size;
    }
}
