// SPDX-License-Identifier: Apache-2.0
// Ported from Thermal Camera Viewer / p3-ir-camera (Apache-2.0) – see NOTICE.

import Foundation

// Everything we know about the USB protocol of the ThermalMaster P3 / P1.
//
// Ported from thermal-camera-viewer (p3_camera.py), which itself is based on
// jvdillon/p3-ir-camera and the USB traffic analysis by @aeternium:
// https://github.com/jvdillon/p3-ir-camera/issues/2
//
// Summary of how the camera works:
//
// * It is NOT a standard UVC webcam. Commands are vendor-specific control
//   transfers, image data arrives on bulk endpoint 0x81 of interface 1.
// * Every command is an 18-byte packet, followed by "status" / "response"
//   control reads (see `P3Camera.sendCommand`).
// * One USB frame = start marker (12 bytes) + pixel data + end marker (12 bytes).
//   The pixel data contains two images stacked on top of each other:
//
//       rows 0 ..< h          8-bit IR image (hardware AGC, low byte of each pixel)
//       rows h ..< h+2        metadata
//       rows h+2 ..< 2h+2     16-bit temperature image in 1/64 Kelvin
//

enum P3Protocol {
    static let vendorID = 0x3474

    /// Size of the start and end frame markers in bytes.
    static let markerSize = 12

    /// We read the bulk endpoint in chunks of this size. Reading whole frames
    /// in one go is unreliable on macOS (overflow errors), chunks work fine.
    static let readChunkSize = 16_384

    static let bulkInEndpoint = 0x81
    static let controlInterface = 0
    static let streamingInterface = 1

    /// Raw temperature values are in 1/64 Kelvin.
    static let rawUnitsPerKelvin: Float = 64
    static let kelvinOffset: Float = 273.15

    // MARK: Control transfer parameters (bmRequestType / bRequest)

    /// Vendor request, host → device, recipient interface.
    static let requestTypeVendorOut: UInt8 = 0x41
    /// Vendor request, device → host, recipient interface.
    static let requestTypeVendorIn: UInt8 = 0xC1
    /// Vendor request, host → device, recipient device.
    static let requestTypeVendorOutDevice: UInt8 = 0x40

    static let requestSendCommand: UInt8 = 0x20
    static let requestReadResponse: UInt8 = 0x21
    static let requestReadStatus: UInt8 = 0x22
    /// Sent once after selecting the streaming alternate setting.
    static let requestStartStreamingInterface: UInt8 = 0xEE

    /// Response byte when the stream was already running ("5").
    static let responseAlreadyStreaming: UInt8 = 0x35

    /// Position (in 16-bit words) of the camera's internal frame counter in the metadata rows.
    /// See docs/HARDWARE-NOTES.md.
    static let frameCounterWord = 64
}

// MARK: - Commands

/// The pre-computed 18-byte command packets (including CRC, which the camera
/// does not actually check).
///
/// Layout: type (2) · parameter (2) · register (2) · reserved (8) · response length (2) · CRC16 (2),
/// all little-endian.
enum P3Command {
    static let readName = bytes("0101810001000000000000001e0000004f90")       // 30 bytes
    static let readVersion = bytes("0101810002000000000000000c0000001f63")    // 12 bytes
    static let readPartNumber = bytes("01018100060000000000000040000000654f") // 64 bytes
    static let readSerial = bytes("01018100070000000000000040000000104c")     // 64 bytes
    static let readHardwareVersion = bytes("010181000a00000000000000400000001959") // 64 bytes
    static let startStream = bytes("012f81000000000000000000010000004930")
    static let gainLow = bytes("012f41000000000000000000000000003c3a")
    static let gainHigh = bytes("012f41000100000000000000000000004939")
    /// Closes the shutter and runs a non-uniformity correction (NUC).
    static let shutter = bytes("01364300000000000000000000000000cd0b")

    /// Appends the CRC to a 16-byte command.
    static func withCRC(_ command: [UInt8]) -> [UInt8] {
        let crc = P3AccessoryProtocol.crc16XModem(command)
        return command + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}

// MARK: - Camera models

/// Sensor gain. High gain is more sensitive, low gain covers a wider range.
enum GainMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// −20 °C … 150 °C, higher sensitivity. Best for electronics.
    case high
    /// 100 °C … 600 °C, lower sensitivity (as the official app labels it).
    case low

    var id: String { rawValue }
}

struct CameraModel: Sendable, Equatable, Hashable {
    let name: String
    let productID: Int
    /// Sensor width in pixels.
    let width: Int
    /// Sensor height in pixels (same for the IR and the temperature image).
    let height: Int

    static let p3 = CameraModel(name: "P3", productID: 0x45A2, width: 256, height: 192)
    static let p1 = CameraModel(name: "P1", productID: 0x45C2, width: 160, height: 120)

    /// Total pixel rows per frame: IR image + 2 metadata rows + temperature image.
    var frameRows: Int { 2 * height + 2 }

    /// Pixel data per frame in bytes (without markers).
    var frameDataSize: Int { 2 * frameRows * width }

    /// Bytes we have to read from USB for one frame: start marker + pixel data + end marker.
    var frameReadSize: Int { frameDataSize + 2 * P3Protocol.markerSize }

    /// First row of the temperature image inside the frame.
    var temperatureRowStart: Int { height + 2 }

    /// After a manual shutter the camera sends an extra partial segment of this size first.
    var shutterExtraBytes: Int { 36 * width }
}

// MARK: - Frame markers

/// The 12-byte marker at the start and end of every frame.
struct FrameMarker: Equatable {
    let length: UInt8
    let sync: UInt8
    /// Frame counter – identical in the start and end marker of the same frame.
    let frameCounter: UInt32
    let secondaryCounter: UInt32
    /// Wraps at 2048 and increments by ~40 per frame. Used to detect dropped frames.
    let wrappingCounter: UInt16

    init(bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count >= P3Protocol.markerSize)
        length = bytes[0]
        sync = bytes[1]
        frameCounter = bytes.loadUnaligned(fromByteOffset: 2, as: UInt32.self).littleEndian
        secondaryCounter = bytes.loadUnaligned(fromByteOffset: 6, as: UInt32.self).littleEndian
        wrappingCounter = bytes.loadUnaligned(fromByteOffset: 10, as: UInt16.self).littleEndian
    }
}
