# P3 Probe (experiment)

A minimal iPhone/iPad app to find out whether the ThermalMaster P3 can be used
from iOS. It is **not** a finished app.

## Background

On the Mac the app talks to the camera with USB control transfers (commands) and
bulk transfers (image data). iOS apps cannot do that. But the P3 is an MFi
accessory: USB interface 0 is Apple's iAP2 interface, and interface 1 is named
`com.thermalmaster.pios3` – an External Accessory protocol. iOS apps can open
that protocol with the External Accessory framework and get a byte stream.

Open questions this app answers:

1. Does iOS show the camera as an accessory with this protocol?
2. Can a session be opened, and does image data arrive?
3. Which commands start the stream / trigger the shutter over the accessory stream?

## Installing it on your iPhone or iPad

The app is not distributed through the App Store. You build and install it
yourself with Xcode – no paid developer account needed, a free Apple ID works.
The project contains no signing team; Xcode signs the app with **your** account.

1. Install **Xcode** from the Mac App Store and open it once.
2. Open `Experiments/AccessoryProbe/AccessoryProbe.xcodeproj`.
3. Add your Apple ID: **Xcode → Settings → Accounts → +**.
4. Select the **AccessoryProbe** target → **Signing & Capabilities** → choose your
   team under **Team** (a free account shows up as "Your Name (Personal Team)").
   The bundle identifier gets your team ID appended automatically, so it is unique.
5. Connect the iPhone/iPad with a cable, unlock it and tap **Trust** if asked.
   Select it as run destination in the toolbar.
6. On the device, enable **Developer Mode**: *Settings → Privacy & Security →
   Developer Mode* (it asks to restart). The option appears after the device
   was connected to Xcode once.
7. Press **Run** (⌘R). With a free account, the first start is blocked: on the
   device open *Settings → General → VPN & Device Management*, tap your Apple ID
   under *Developer App* and choose **Trust**. Then start the app again.

With a free account the app stops working after 7 days – just press Run in
Xcode again. A paid developer account extends this to one year.

An iPhone with Lightning needs an adapter for the USB-C camera, e.g. Apple's
"Lightning to USB 3 Camera Adapter". Whether iOS passes an MFi accessory
through it is part of the test.

<details>
<summary>For contributors: regenerating the project</summary>

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate`.

Choosing a team in Xcode writes your team ID into `project.pbxproj`. Do not
commit that change – `xcodegen generate` (or `git checkout` of the file) removes it.

</details>

## Test procedure

1. Start the app, then plug in the camera. Section **1 · Accessory** should list
   it with the protocol `com.thermalmaster.pios3` in green.
2. Tap **Open Session**. Watch **Received** / **Rate**:
   * Data arriving without any command → the camera streams by itself.
   * **Frames found** > 0 and an image in section 3 → the frame format is the same as over USB.
3. If nothing arrives, tap **Send “Start stream”**, then the other commands, and
   watch the log for answers.
4. Tap **Copy** in the log section and send the log.

The log contains the accessory's name, model and firmware, but no serial number.
