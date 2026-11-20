// SPDX-License-Identifier: Apache-2.0
// Ported from Thermal Camera Viewer / p3-ir-camera (Apache-2.0) – see NOTICE.

import Foundation
import os

/// Driver for the ThermalMaster P3 / P1 USB thermal cameras.
///
/// Port of `P3Camera` from the Python reference implementation, using
/// IOUSBHost (via `USBDevice`) instead of libusb.
final class P3Camera: ThermalCamera {
    let model: CameraModel
    private let settings: CameraSettings
    private let log = Logger(subsystem: "ThermalInspector", category: "USB")

    private var usb: USBDevice?
    private var assembler: P3FrameAssembler
    private var chunkBuffer: NSMutableData?

    init(model: CameraModel, settings: CameraSettings = CameraSettings()) {
        self.model = model
        self.settings = settings
        assembler = P3FrameAssembler(model: model)
    }

    // MARK: ThermalCamera

    func open() throws -> CameraInfo {
        let usb: USBDevice
        do {
            usb = try USBDevice(vendorID: P3Protocol.vendorID, productID: model.productID)
        } catch USBError.deviceNotFound {
            throw CameraError.notConnected
        }
        try usb.configureIfNeeded()
        try usb.openInterface(P3Protocol.controlInterface)
        try usb.openInterface(P3Protocol.streamingInterface)
        self.usb = usb
        chunkBuffer = usb.makeTransferBuffer(capacity: P3Protocol.readChunkSize)

        return CameraInfo(
            modelName: try readRegister(P3Command.readName, length: 30),
            firmwareVersion: try readRegister(P3Command.readVersion, length: 12),
            hardwareVersion: try readRegister(P3Command.readHardwareVersion, length: 64),
            serialNumber: try readRegister(P3Command.readSerial, length: 64),
            partNumber: try readRegister(P3Command.readPartNumber, length: 64)
        )
    }

    /// Starts the video stream.
    ///
    /// The sequence and the delays mimic what the official Windows tool does;
    /// the camera is picky about this.
    func startStreaming() throws {
        let usb = try connectedDevice()
        assembler = P3FrameAssembler(model: model)

        // Start from a defined state, in case a previous session did not stop the stream.
        try? usb.selectAlternateSetting(0, onInterface: P3Protocol.streamingInterface)

        try sendSetting(P3AccessoryProtocol.automaticShutter(settings.automaticShutter))
        for command in settings.commands { try perform(command) }

        try sendStartStream()
        Thread.sleep(forTimeInterval: 1.0)

        try usb.selectAlternateSetting(1, onInterface: P3Protocol.streamingInterface)
        try usb.controlOut(requestType: P3Protocol.requestTypeVendorOutDevice,
                           request: P3Protocol.requestStartStreamingInterface,
                           index: UInt16(P3Protocol.streamingInterface))
        Thread.sleep(forTimeInterval: 2.0)

        // The Windows tool issues one bulk read before the final start command.
        if let buffer = chunkBuffer {
            _ = try? usb.bulkRead(endpoint: P3Protocol.bulkInEndpoint, onInterface: P3Protocol.streamingInterface,
                                  into: buffer, timeout: 0.1)
        }

        try sendStartStream()
    }

    func readFrame() throws -> RawThermalFrame? {
        let usb = try connectedDevice()
        guard let buffer = chunkBuffer else { return nil }

        let count = try usb.bulkRead(endpoint: P3Protocol.bulkInEndpoint, onInterface: P3Protocol.streamingInterface,
                                     into: buffer, timeout: 10)
        return assembler.append(UnsafeRawBufferPointer(start: buffer.bytes, count: count))
    }


    func perform(_ command: CameraCommand) throws {
        switch command {
        case .triggerShutter:
            try sendCommand(P3Command.shutter)
            _ = try readStatus()
            try skipFrameAfterShutter()
        case .setGain, .setImageAdjustment, .setBurnProtection:
            if let body = P3AccessoryProtocol.settingCommand(command) { try sendSetting(body) }
        }
    }

    func close() {
        guard let usb else { return }
        try? usb.selectAlternateSetting(0, onInterface: P3Protocol.streamingInterface)
        usb.close()
        self.usb = nil
    }

    // MARK: Command protocol

    /// Every command is followed by status reads (0x02 after a write, 0x03 after a read).
    private func sendCommand(_ command: [UInt8]) throws {
        try connectedDevice().controlOut(requestType: P3Protocol.requestTypeVendorOut,
                                         request: P3Protocol.requestSendCommand, data: command)
    }

    private func readStatus() throws -> UInt8 {
        try connectedDevice().controlIn(requestType: P3Protocol.requestTypeVendorIn,
                                        request: P3Protocol.requestReadStatus, length: 1).first ?? 0
    }

    private func readResponse(length: Int) throws -> [UInt8] {
        try connectedDevice().controlIn(requestType: P3Protocol.requestTypeVendorIn,
                                        request: P3Protocol.requestReadResponse, length: length)
    }

    /// Reads a register and decodes it as a zero-terminated string.
    private func readRegister(_ command: [UInt8], length: Int) throws -> String {
        try sendCommand(command)
        _ = try readStatus()
        let data = try readResponse(length: length)
        _ = try readStatus()
        let text = data.prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends a 16-byte setting command (the camera gives no answer, only a status).
    private func sendSetting(_ body: [UInt8]) throws {
        try sendCommand(P3Command.withCRC(body))
        var status = try readStatus()
        if status == 4 {
            // Right after plugging in, the camera sometimes is not ready yet – try once more.
            Thread.sleep(forTimeInterval: 0.1)
            try sendCommand(P3Command.withCRC(body))
            status = try readStatus()
        }
        log.info("Sent \(body.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public), status \(status)")
    }

    private func sendStartStream() throws {
        try sendCommand(P3Command.startStream)
        _ = try readStatus()
        // 0x01 normally, 0x35 if the stream was already running – both are fine.
        _ = try readResponse(length: 1)
        _ = try readStatus()
    }

    /// After a manual shutter the camera sends one oddly segmented frame plus an
    /// extra partial segment. We simply read and discard it; the assembler
    /// resynchronises on the next regular frame.
    private func skipFrameAfterShutter() throws {
        let usb = try connectedDevice()
        guard let buffer = chunkBuffer else { return }

        var bytesToSkip = model.frameReadSize + model.shutterExtraBytes
        while bytesToSkip > 0 {
            let count = try usb.bulkRead(endpoint: P3Protocol.bulkInEndpoint, onInterface: P3Protocol.streamingInterface,
                                         into: buffer, timeout: 10)
            bytesToSkip -= count
        }
        assembler = P3FrameAssembler(model: model)
    }

    private func connectedDevice() throws -> USBDevice {
        guard let usb else { throw CameraError.notConnected }
        return usb
    }
}
