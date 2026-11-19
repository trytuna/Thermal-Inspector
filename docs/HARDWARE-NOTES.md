# P3 hardware notes

Findings from read-only probing of a ThermalMaster P3 (firmware 00.00.02.18,
hardware P3-00.04) on 2026-11-19. Complements the protocol description in
`ThermalInspector/Camera/P3Protocol.swift`.

## USB layout (as seen by macOS)

| Interface | Name | Class | Notes |
|---|---|---|---|
| 0 | `iAP Interface` | 0xFF / 0xF0 | Apple accessory protocol; macOS' `accessoryd` attaches to it. Opening it from the app still works. |
| 1 | `com.thermalmaster.pios3` | vendor | Bulk endpoint 0x81, alt setting 1 = streaming |

If the app quits without stopping the stream (alt setting back to 0), the camera
can hang and disappear from the bus until it is replugged – maybe with a pause.
The app therefore stops the stream in `applicationWillTerminate`.

## Registers (command type 0x0101, read)

Status after the read: `03` = OK, `04` = invalid register. The response buffer is
**not cleared** between reads – shorter answers keep stale bytes of the previous one.

| Reg | Content | Meaning (guess) |
|---|---|---|
| 0x01 | `P3` | model (known) |
| 0x02 | `00.00.02.18` | firmware (known) |
| 0x03 | `01.00.00` | ? version |
| 0x04 | `t4.00.00` | ? version (sensor/table?) |
| 0x05 | binary + `.00.00` | ? |
| 0x06 | `P30` | part number (known) |
| 0x07 | serial number | (known) |
| 0x08, 0x09, 0x0b | `P3-00.02` | ? hardware revisions of sub-boards |
| 0x0a | `P3-00.04` | hardware version (known) |
| 0x0c | `01.05` | ? |
| 0x0d | `00.02.01.05` | ? second firmware (ISP/FPGA?) |
| 0x0e | `RTC2121W` | probably the detector / ISP module part number |
| 0x0f | `P3` | model, long form (known) |
| 0x10 | `P3-00.01` | ? |
| 0x00, ≥ 0x11 | – | invalid (status 04) |

## Debug log

Reading 256 bytes from the status request (0xC1 / 0x22) returns a firmware log.
It echoes every received command, e.g. `[383969] I/std cmd: in : 1 1 81`
(command type bytes + parameter). **This makes sniffing the official app very
productive**: the camera itself logs what it was asked to do.

## Frame layout details

* **IR rows** (0 … h−1): YUYV with constant chroma (high byte always 128), i.e. an
  8-bit grayscale image from the camera's own image processing (AGC + detail
  enhancement). Shows more fine texture than a plain temperature mapping.
* **Metadata rows** (h, h+1): mostly constant, but some words change
  (from a 130 s recording at 25 fps):

| Word | Observation | Meaning |
|---|---|---|
| 64 | +1 per frame; stands still during calibration, then jumps by ~6 | **camera frame counter** (used by the app) |
| 68 | 19864 → 19496, slowly falling | unknown – *not* proven to be a temperature |
| 165, 168, 173, 179 | slow drift, jump together at each calibration | probably values captured at calibration (shutter / reference temperatures?) |
| 166, 167, 169, 170 | noisy (0 … 255) | unknown, not a counter |
| 70–75 | change every frame | timestamp / checksum? |
| 180 | +1 per frame, never stops | free-running counter |

## Automatic calibration (NUC)

* About every 90 s the camera closes its shutter for ~0.8 s.
* Meanwhile it **repeats the last frame** (identical data, frame counter word 64 stands still).
* Afterwards the counter jumps ahead and the whole image is corrected. Right after
  plugging in, the correction was **+4.5 K** – the readings had drifted that far
  within 90 s. The app shows this correction as a drift indicator
  (`CalibrationMonitor`), skips the repeated frames and marks calibrations in the history.

## Known commands

| Type | Param | Meaning |
|---|---|---|
| 0x0101 | 0x81 | read register |
| 0x1021 | 0x81 | status (returns "11") |
| 0x012f | 0x81 | start stream |
| 0x012f | 0x41 | set gain (register field = 0 low / 1 high) |
| 0x0136 | 0x43 | shutter / NUC |

## Probably present, not yet known

Related cameras (InfiRay P2 Pro and others) offer more commands; the P3 very
likely has similar ones:

* automatic shutter on/off and interval (the P3 recalibrates by itself every ~90 s; turning it off
  would also need a way to trigger it manually before measuring – which already exists)
* on-camera temperature parameters (emissivity, distance, humidity, ambient)
* image processing settings (contrast, brightness, detail enhancement, noise filter)
* temperature calibration / offset correction
* firmware update (dangerous – never probe blindly)

The safe way to find them is to record the USB traffic of the official app
(Windows "Temp Master" tool with Wireshark + USBPcap) while changing one setting
at a time, and to read the camera's debug log afterwards. Blindly sending
unknown write commands could change calibration data stored in the camera.
