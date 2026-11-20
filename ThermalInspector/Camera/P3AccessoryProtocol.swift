import Foundation

/// What the camera understands over the iPhone/iPad connection (External Accessory,
/// protocol `com.thermalmaster.pios3`).
///
/// Found by recording the USB traffic between an iPhone running the official app and
/// the camera (see docs/HARDWARE-NOTES.md). Everything the app writes goes to the
/// camera's bulk OUT endpoint; answers and the image stream come back on bulk IN.
///
/// * `00 01 01` starts the image stream, `00 00 00` stops it. Without the start
///   packet the camera only streams if another app has started it before.
/// * Commands are the same 16-byte packets as over USB (`P3Command`) with a 4-byte
///   header in front: sequence number, `0xFE` for the first packet after
///   connecting and `0xFF` afterwards, and two zero bytes. They end with the
///   CRC-16/XMODEM of the 16 command bytes (little-endian), like over USB.
///   The USB commands for the gain work unchanged; the shutter has its own type.
enum P3AccessoryProtocol {
    static let startStream: [UInt8] = [0x00, 0x01, 0x01]
    static let stopStream: [UInt8] = [0x00, 0x00, 0x00]

    /// Closes the shutter and recalibrates (what the official app sends; over USB
    /// the shutter is `01 36 43 00 …`).
    static let shutter: [UInt8] = [0x10, 0x02, 0x43, 0x00] + [UInt8](repeating: 0, count: 12)
    /// Switches the automatic shutter (recalibration about every 90 s) on or off.
    /// The official app sends this whenever it connects, with its "automatic shutter" setting.
    static func automaticShutter(_ on: Bool) -> [UInt8] {
        [0x10, 0x02, 0x41, 0x00, on ? 1 : 0, 0x00] + [UInt8](repeating: 0, count: 10)
    }
    /// Brightness, contrast … of the camera's grayscale image, 0 … 100
    /// (`basic_image_brightness_level_set` etc., see docs/AC020-COMMANDS.md).
    static func imageAdjustment(_ adjustment: ImageAdjustment, value: Int) -> [UInt8] {
        let subcommand: UInt8 = switch adjustment {
        case .brightness: 0x47          // the official app sends 48–50
        case .contrast: 0x4A            // "global contrast", the official app sends 50
        case .detailEnhancement: 0x45
        case .noiseReduction: 0x44
        }
        return [0x10, 0x04, subcommand, 0x00, UInt8(clamping: min(max(value, 0), 100)), 0x00]
            + [UInt8](repeating: 0, count: 10)
    }

    /// Sun / burn-in protection on or off (`basic_sun_detect_switch_set`); the official app turns it on.
    static func burnProtection(_ on: Bool) -> [UInt8] {
        [0x10, 0x03, 0x4B, 0x00, on ? 1 : 0, 0x00] + [UInt8](repeating: 0, count: 10)
    }

    /// The 16-byte command for a camera command (without shutter, which differs per connection).
    static func settingCommand(_ command: CameraCommand) -> [UInt8]? {
        switch command {
        case .setGain(.high): gainHigh
        case .setGain(.low): gainLow
        case let .setImageAdjustment(adjustment, value): imageAdjustment(adjustment, value: value)
        case let .setBurnProtection(on): burnProtection(on)
        case .triggerShutter: nil
        }
    }

    static let gainHigh = Array(P3Command.gainHigh.prefix(16))
    static let gainLow = Array(P3Command.gainLow.prefix(16))

    /// Wraps a 16-byte command for the accessory connection.
    static func packet(command: [UInt8], sequence: UInt8, isFirst: Bool) -> [UInt8] {
        precondition(command.count == 16, "Commands are 16 bytes without CRC")
        let crc = crc16XModem(command)
        return [sequence, isFirst ? 0xFE : 0xFF, 0x00, 0x00] + command + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    /// CRC-16/XMODEM (polynomial 0x1021, start value 0).
    static func crc16XModem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
