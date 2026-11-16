# Reverse-engineering notes

How Hubless talks to the hardware, and how each fact was established.

## Approach

1. **G HUB itself (with [REA](https://github.com/morluto/rea))**: the official macOS
   download (`lghub_installer.zip`) is a bootstrap only. `rea inspect-artifact` on
   `lghub_installer` (universal Mach-O) plus string recovery showed the real payload comes
   from `https://updates.ghub.logitechg.com/pipeline/v2/update/...` as protobuf "depots" and
   "capsules" (`logi.protocol.updates.Depot`, `logi.protocol.manifest.DeviceResource`). Requests
   carry an AWS-SigV4-style `Authorization` header and depend on a "keymaster" key service, so
   anonymous requests get `403`. The G HUB agent binaries and device definitions cannot be
   fetched without running the installer, so this route stopped there.
2. **The devices themselves**: the protocols below were recovered by enumerating each device's
   self-description (HID++ feature table, USB/UVC descriptors), then confirming every
   read and write by reading the value back from the hardware. Open-source HID++ work (Solaar)
   was used to cross-check the parameter layouts.

## G560 (USB `046d:0a78`): HID++ 2.0 (protocol 4.2)

Vendor HID interface: usage page `0xFF43`, long report `0x11` (20 bytes).
Request: `11 FF <featureIndex> <fn<<4 | swid> <params…>`. Error reply: `11 FF FF <idx> <fn|swid> <code>`.

Feature table, from `0x0001` FeatureSet:

| idx | feature | use |
|----|---------|-----|
| 2 | `0x0003` firmware info | `U1 22.03.B0023` |
| 3 | `0x0005` device name | "G560 Gaming Speaker" |
| 4 | `0x8070` Color LED Effects | 4 zones (locations 1–4) |
| 5 | `0x8010` | not used |
| 6 | `0x8310` Equalizer | 10 bands |
| 7 | `0x8320` | not used |
| 8 | `0x8040` Brightness | global lighting brightness |
| 9 | `0x8305` Subwoofer level | 0…100, same value as G HUB's "Subwoofer level" |

**0x8070 lighting**: fn0 info → zone count. fn1 `(zone)` → location and effect count. fn2 `(zone, i)` → effect ID.
fn3 `(zone, effectIndex, 10 param bytes, persist)` sets an effect. fn14 `(zone)` reads it back.
Effects per zone: `0x0000` off, `0x0001` fixed, `0x0003` cycle, `0x0007` (unidentified onboard effect, preserved raw), `0x000A` breathing.

| effect | parameter bytes |
|--------|-----------------|
| fixed | `R G B ramp` |
| cycle | `0 0 0 0 0 periodHi periodLo intensity` |
| breathing | `R G B periodHi periodLo waveform intensity` |

**0x8040 brightness**: fn1 reads, fn2 `(hi, lo)` writes. The firmware accepts only **0, 25, 50 and 100**; 75 and other values return `INVALID_ARGUMENT`.

**0x8305 subwoofer level**: fn0 → `level` (0…100). fn1 `(level)` writes it; 101 and above return `INVALID_ARGUMENT`.
Found by probing: fn0 returned 79, the value G HUB showed.

**System volume** is not HID++. The G560 is a USB Audio Class device whose feature unit exposes hardware
volume on output channels 1 and 2 (−54…−4 dB) plus mute. Hubless drives it through CoreAudio
(`kAudioDevicePropertyVolumeScalar` / `kAudioDevicePropertyMute`). This is the same volume as the macOS
volume keys, so it is live state, not a profile setting.

**Zone locations** (confirmed with Identify): 1 = front left, 2 = front right, 3 = back left, 4 = back right.

**0x8310 EQ**: fn0 → `count=10, range, caps, min=-20, max=+6`. fn1 `(offset)` → frequencies
32, 64, 125, 250, 500, 1k, 2k, 4k, 8k and 16k Hz. fn2 reads the gains (signed bytes). fn3 `(0x02, gains…)` writes them.
**Accepted gains are −19…+5 dB**: the reported bounds are exclusive (verified by probing).

## C922 (USB `046d:085c`): USB Video Class

VideoControl interface 0. Camera Terminal ID 1 (`bmControls 0x020A2E`), Processing Unit ID 3
(`bmControls 0x175B`), and Logitech extension units 6 and 8–12 (not used).
Class requests go over the default pipe (`wIndex = unit<<8 | interface`). They work without
exclusive access, even while another app is streaming.

| control | unit/selector | range on this camera |
|---------|---------------|----------------------|
| Auto-exposure mode | CT 0x02 | mask 9 (1 = manual, 8 = auto) |
| Low-light priority | CT 0x03 | 0/1 |
| Exposure | CT 0x04 | 3…2047 (100 µs units) |
| Focus / Autofocus | CT 0x06 / 0x08 | 0…250 step 5 / 0–1 |
| Zoom | CT 0x0B | 100…500 |
| Pan / Tilt | CT 0x0D | ±36000 arc-sec, step 3600 (1°) |
| Brightness, Contrast, Saturation, Sharpness | PU 0x02/0x03/0x07/0x08 | 0…255 |
| Gain | PU 0x04 | 0…255 |
| White balance / Auto WB | PU 0x0A / 0x0B | 2000…6500 K |
| Backlight compensation | PU 0x01 | 0/1 |
| Anti-flicker | PU 0x05 | 1 = 50 Hz, 2 = 60 Hz |

Manual values are only written when their auto mode is off; otherwise the camera STALLs the request.
