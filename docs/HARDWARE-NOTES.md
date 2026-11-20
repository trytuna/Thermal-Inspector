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

## iPhone / iPad (External Accessory)

Tested 2026-11-19 on an iPhone 14 Pro via Apple's Lightning to USB 3 Camera
Adapter, with a USB sniffer (Alex Taradov's USB Sniffer, high speed) between
adapter and camera. `Tools/usb-capture-summary.py` turns such a capture into a
readable list of transfers.

* iOS lists the camera as an accessory with the protocol `com.thermalmaster.pios3`
  (the name of USB interface 1). The iPhone itself talks iAP2 on interface 0
  (bulk 0x84 IN / 0x05 OUT; authentication, identification – unencrypted).
* When an app opens an `EASession`, iOS selects alternate setting 1 of interface 1.
  Everything the app writes goes to bulk OUT 0x02, everything it reads comes from
  bulk IN 0x81. When the session closes, iOS clears the endpoints and selects
  alternate setting 0.
* **Start/stop:** the app writes `00 01 01` to start the image stream and
  `00 00 00` to stop it. The first frames arrive about 3.5 s after the start
  packet. Without it the camera only streams if another app started it earlier –
  this is why the image sometimes did not appear.
* **Commands:** a 4-byte header, the 16-byte command, CRC-16/XMODEM of the
  command (little-endian, same CRC as over USB):

      01 fe 00 00 | 10 02 41 00 01 00 00 00 00 00 00 00 00 00 00 00 | 78 3d
      seq  │       command (16 bytes)                                  CRC
           └ fe for the first packet after connecting, ff afterwards

  The camera answered the first one with `01 00 00 2c` (sequence number + status?)
  on the stream endpoint. The command types differ from USB (`10 02` instead of
  `01 2f`), parameter and value look alike (`41` / `1` = gain high over USB).
* Commands recorded from the official app (sequence numbers left out):

  | Action | Command (first 6 of 16 bytes) | Notes |
  |---|---|---|
  | Shutter / NUC | `10 02 43 00 00 00` | own type; USB uses `01 36 43 00` – verified, the camera clicks |
  | Range "100–600 °C" | `01 2f 41 00 00 00` | **identical to USB gain low** |
  | Range "−20–150 °C" | `01 2f 41 00 01 00` | **identical to USB gain high** |
  | Range "automatic" | – | no command, decided by the app |
  | Automatic shutter on / off | `10 02 41 00 01 00` / `10 02 41 00 00 00` | sent on every connect, before the start packet; toggling the setting sends nothing until the next connect – verified |
  | High / low temperature alarm | – | no command, the app compares itself |
  | X³IR ("x³" button, 512×384 "super resolution") | – | no command, and the camera keeps sending 256×192 frames at the same data rate – the upscaling happens in the app |
  | Opening the settings | `01 01 81 00 0a 00 … 40 00`, `10 21 81 00 00 00 … 02 00` | read hardware version, read status |
  | Range change (first) | `01 01 81 00 01 00 … 1e 00` | USB "read name", sent before the first gain change |
  | While starting | `10 04 47 00 30 00` | image brightness = 48 (`basic_image_brightness_level_set`) |
  | While starting | `10 04 4a 00 32 00` | global contrast = 50 (`basic_global_contrast_level_set`) |
  | While starting | `10 03 4b 00 01 00` | sun / anti-burn protection on (`basic_sun_detect_switch_set`) |

  Thermal Inspector sends shutter, gain and the automatic shutter this way
  (`P3AccessoryProtocol`).
* **Over USB the same command set works** (the `10 xx` commands too): on the Mac,
  `10 02 41 00 <0/1>` as an 18-byte vendor command switches the automatic
  shutter, and `10 02 81 … 01` (`basic_auto_ffc_status_get`, 1-byte answer) reads
  it back – the camera reported exactly the value that was set (status 3 = OK).
  Verified on the Mac (2½ minutes each): off – no click, the frame counter never
  stood still for more than 1 frame; on – a click and a calibration with the
  counter standing still for 19 frames, then jumping by 6.
* **Image settings and burn-in protection** (brightness, contrast, noise
  reduction, detail enhancement, `basic_sun_detect_switch_set`) work over USB as
  well; see [AC020-COMMANDS.md](AC020-COMMANDS.md) for what was verified. Right
  after plugging in, the camera sometimes answers a setting with status 4 – sending
  it again a moment later works.
* Single repeated frames (counter stands still for 1 frame) happen now and then
  without any calibration. The app only counts a freeze of 5 frames or more as a
  calibration.
* **Measuring ranges:** high gain −20…150 °C, low gain 100…600 °C – as the official
  app labels them. The manual only gives the total range (−20…600 °C, ±2 °C or
  ±2 % of the reading). The "0…550 °C" in the Python code this project started
  from has no source and does not match the manufacturer's numbers.
* **Automatic shutter, verified by ear** (fresh replug, 3 minutes each, camera
  still): with `10 02 41 00 01 00` the shutter clicked twice and the app marked both
  calibrations; with `10 02 41 00 00 00` it never clicked. Over the iPhone the
  frame counter stands still during a calibration just like over USB.
* **Order matters:** send the automatic shutter command *before* the start packet
  (and wait for the short answer), as the official app does. Sent after the start
  packet to a freshly plugged-in camera, the stream stopped again after ~3 s and
  the app had to reconnect over and over. The camera only takes this setting while
  connecting, so Thermal Inspector reconnects when it is switched.
* Answers to commands were not visible as separate transfers, except
  `01 00 00 2c` after the very first command following a replug.
* Sending the 18-byte USB command packets without the 4-byte header has no effect.
* The meaning of the commands comes from InfiRay's command library in the official
  Android app – see [AC020-COMMANDS.md](AC020-COMMANDS.md) for the whole table,
  including commands that must never be sent.
* After the camera had been opened and closed a few times without the stop packet,
  it once stopped sending entirely until it was replugged.

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
