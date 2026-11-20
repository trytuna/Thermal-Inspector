import Foundation
import Testing
@testable import Thermal_Inspector

// MARK: - Frame assembly

/// Builds the bytes of one USB frame the way the camera sends it.
private func makeUSBFrame(model: CameraModel, frameCounter: UInt32, endCounter: UInt32? = nil,
                          temperatureRaw: UInt16) -> [UInt8] {
    func marker(sync: UInt8, counter: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [12, sync]
        withUnsafeBytes(of: counter.littleEndian) { bytes += $0 }
        bytes += [0, 0, 0, 0, 0, 0]
        return bytes
    }

    var pixels = [UInt8](repeating: 0, count: model.frameDataSize)
    let temperatureStart = model.temperatureRowStart * model.width * 2
    for index in stride(from: temperatureStart, to: pixels.count, by: 2) {
        pixels[index] = UInt8(temperatureRaw & 0xFF)
        pixels[index + 1] = UInt8(temperatureRaw >> 8)
    }
    return marker(sync: 0x8C, counter: frameCounter) + pixels + marker(sync: 0x8E, counter: endCounter ?? frameCounter)
}

/// Splits a frame into transfers like the camera: big chunks, then the 12-byte end marker separately.
private func splitIntoTransfers(_ frame: [UInt8]) -> [[UInt8]] {
    let body = Array(frame.dropLast(12))
    var transfers = stride(from: 0, to: body.count, by: 16_384).map {
        Array(body[$0..<min($0 + 16_384, body.count)])
    }
    transfers.append(Array(frame.suffix(12)))
    return transfers
}

private func feed(_ transfers: [[UInt8]], into assembler: inout P3FrameAssembler) -> [RawThermalFrame] {
    transfers.compactMap { transfer in transfer.withUnsafeBytes { assembler.append($0) } }
}

@Test func assemblerExtractsTemperatureImage() {
    let model = CameraModel.p3
    let raw = UInt16((30 + 273.15) * 64)
    var assembler = P3FrameAssembler(model: model)

    let frames = feed(splitIntoTransfers(makeUSBFrame(model: model, frameCounter: 7, temperatureRaw: raw)), into: &assembler)

    #expect(frames.count == 1)
    #expect(frames[0].width == 256 && frames[0].height == 192)
    #expect(frames[0].frameNumber == 7)
    #expect(frames[0].values.allSatisfy { $0 == raw })
}

@Test func assemblerResynchronisesAfterStartingMidFrame() {
    let model = CameraModel.p3
    var assembler = P3FrameAssembler(model: model)

    let first = splitIntoTransfers(makeUSBFrame(model: model, frameCounter: 1, temperatureRaw: 100))
    let second = splitIntoTransfers(makeUSBFrame(model: model, frameCounter: 2, temperatureRaw: 200))
    // Start listening in the middle of the first frame.
    let frames = feed(Array(first.dropFirst(3)) + second, into: &assembler)

    #expect(frames.count == 1)
    #expect(frames.first?.frameNumber == 2)
}

@Test func assemblerDropsFramesWithMismatchedMarkers() {
    let model = CameraModel.p1
    var assembler = P3FrameAssembler(model: model)

    let frames = feed(splitIntoTransfers(makeUSBFrame(model: model, frameCounter: 1, endCounter: 2, temperatureRaw: 100)),
                      into: &assembler)

    #expect(frames.isEmpty)
    #expect(assembler.droppedFrames == 1)
}

// MARK: - Radiometry

@Test func rawValuesConvertToCelsius() {
    let raw = Float((25.0 + 273.15) * 64)
    let celsius = Radiometry.celsius(fromRaw: [raw], settings: RadiometricSettings(emissivity: 1))
    #expect(abs(celsius[0] - 25) < 0.01)
}

@Test func emissivityCorrectionRaisesHotObjectTemperature() {
    // An object that appears 60 °C with ε = 0.9 is actually hotter than 60 °C.
    let raw = Float((60.0 + 273.15) * 64)
    let corrected = Radiometry.celsius(fromRaw: [raw], settings: RadiometricSettings(emissivity: 0.9, reflectedTemperature: 25))
    #expect(corrected[0] > 60)
    #expect(corrected[0] < 66)
}

@Test func averagerSmoothsNoise() {
    var averager = FrameAverager()
    averager.frameCount = 2
    _ = averager.add(RawThermalFrame(width: 1, height: 1, values: [100], frameNumber: 0))
    let average = averager.add(RawThermalFrame(width: 1, height: 1, values: [200], frameNumber: 1))
    #expect(average == [150])
}

// MARK: - Frames

/// 3 × 2 frame:   1 2 3
///                4 5 6
private let sampleFrame = ThermalFrame(width: 3, height: 2, values: [1, 2, 3, 4, 5, 6])

@Test func statisticsFindHottestAndColdestPixel() {
    let statistics = sampleFrame.statistics()
    #expect(statistics.minimum == 1 && statistics.coldest == PixelPoint(x: 0, y: 0))
    #expect(statistics.maximum == 6 && statistics.hottest == PixelPoint(x: 2, y: 1))
    #expect(statistics.mean == 3.5)

    let region = sampleFrame.statistics(in: PixelRect(from: PixelPoint(x: 1, y: 0), to: PixelPoint(x: 1, y: 1)))
    #expect(region.minimum == 2 && region.maximum == 5)
}

@Test func rotatingClockwiseTurnsRowsIntoColumns() {
    let rotated = sampleFrame.applying(ImageOrientation(quarterTurns: 1))
    // 4 1
    // 5 2
    // 6 3
    #expect(rotated.width == 2 && rotated.height == 3)
    #expect(rotated.values == [4, 1, 5, 2, 6, 3])
}

@Test func mirroringFlipsRows() {
    let mirrored = sampleFrame.applying(ImageOrientation(mirroredHorizontally: true))
    #expect(mirrored.values == [3, 2, 1, 6, 5, 4])
}

@Test func differenceSubtractsReference() {
    let difference = sampleFrame.subtracting(ThermalFrame(width: 3, height: 2, values: [1, 1, 1, 1, 1, 1]))
    #expect(difference?.values == [0, 1, 2, 3, 4, 5])
}

// MARK: - History

@Test func historyExportsOneColumnPerSeries() {
    var history = TemperatureHistory()
    let start = Date(timeIntervalSince1970: 0)
    history.record(["Max": 40, "P1": 30], at: start)
    history.record(["Max": 41], at: start.addingTimeInterval(1))

    let lines = history.csv().split(separator: "\n")
    #expect(lines[0] == "time,seconds,Max [°C],P1 [°C]")
    #expect(lines[2].hasSuffix(",1.00,41.00,"))
}

// MARK: - Settings

@MainActor
@Test func changedSidebarSettingsAreSaved() async throws {
    // The test host shares the app's UserDefaults – keep the user's saved settings intact.
    let key = "viewerSettings"
    let original = UserDefaults.standard.data(forKey: key)
    defer { UserDefaults.standard.set(original, forKey: key) }

    let model = AppModel()
    model.palette = .lava
    model.radiometry.emissivity = 0.42
    try await Task.sleep(for: .milliseconds(100))

    let saved = try #require(ViewerSettings.load())
    #expect(saved.palette == .lava)
    #expect(saved.radiometry.emissivity == 0.42)
}

// MARK: - Calibration

@Test func calibrationMonitorDetectsFreezeAndCorrection() {
    var monitor = CalibrationMonitor()
    #expect(monitor.update(counter: 10, meanTemperature: 300) == .normal)
    #expect(monitor.update(counter: 11, meanTemperature: 299.9) == .normal)
    // The camera repeats its frame while the shutter is closed (about 19 frames) …
    for _ in 0..<CalibrationMonitor.minimumFreezeFrames {
        #expect(monitor.update(counter: 11, meanTemperature: 299.9) == .frozen)
    }
    #expect(monitor.isCalibrating)
    // … then continues with a corrected image.
    let event = monitor.update(counter: 17, meanTemperature: 304.4)
    guard case let .calibrated(correction) = event else {
        Issue.record("expected a calibration, got \(event)")
        return
    }
    #expect(abs(correction - 4.5) < 0.01)
    #expect(monitor.isStable == false)
    #expect(monitor.update(counter: 18, meanTemperature: 304.4) == .normal)
}

@Test func skippedFramesAreNotMistakenForCalibration() {
    var monitor = CalibrationMonitor()
    _ = monitor.update(counter: 10, meanTemperature: 300)
    // The app dropped a few frames: the counter jumps, but the camera never repeated a frame.
    #expect(monitor.update(counter: 17, meanTemperature: 300) == .normal)
    #expect(monitor.lastCalibration == nil)

    // After a manual shutter, a jump is the calibration.
    monitor.expectManualCalibration()
    #expect(monitor.update(counter: 25, meanTemperature: 301) == .calibrated(correction: 1))
}

@Test func calibrationMonitorIgnoresSingleRepeatedFrames() {
    var monitor = CalibrationMonitor()
    _ = monitor.update(counter: 10, meanTemperature: 300)
    // Seen on the Mac without any calibration: one frame twice, then on as usual.
    #expect(monitor.update(counter: 10, meanTemperature: 300) == .frozen)
    #expect(monitor.update(counter: 11, meanTemperature: 300) == .normal)
    #expect(monitor.lastCalibration == nil)
}

@Test func calibrationMonitorHandlesCounterWrapAround() {
    var monitor = CalibrationMonitor()
    _ = monitor.update(counter: 65535, meanTemperature: 300)
    #expect(monitor.update(counter: 0, meanTemperature: 300) == .normal)
}

@Test func assemblerExtractsDetailImageAndCounter() {
    let model = CameraModel.p1
    var bytes = makeUSBFrame(model: model, frameCounter: 1, temperatureRaw: 100)
    // IR rows: gray value 42 in the low byte, chroma 128 in the high byte.
    for pixel in 0..<(model.width * model.height) {
        bytes[12 + pixel * 2] = 42
        bytes[12 + pixel * 2 + 1] = 128
    }
    // Camera frame counter = 0x1234 in metadata word 64.
    let counterOffset = 12 + model.height * model.width * 2 + 64 * 2
    bytes[counterOffset] = 0x34
    bytes[counterOffset + 1] = 0x12

    var assembler = P3FrameAssembler(model: model)
    let frame = feed(splitIntoTransfers(bytes), into: &assembler).first
    #expect(frame?.detailImage.allSatisfy { $0 == 42 } == true)
    #expect(frame?.cameraFrameCounter == 0x1234)
}

// MARK: - Moving measurements

@MainActor
@Test func boxesStayInsideTheImageWhenMoved() {
    let model = AppModel()
    model.injectTestFrame(width: 10, height: 8)
    model.addBox(PixelRect(from: PixelPoint(x: 1, y: 1), to: PixelPoint(x: 4, y: 3)))
    let box = model.boxes[0]

    model.moveBox(id: box.id, to: PixelPoint(x: 100, y: -5))
    #expect(model.boxes[0].rect == PixelRect(from: PixelPoint(x: 6, y: 0), to: PixelPoint(x: 9, y: 2)))

    model.addSpot(at: PixelPoint(x: 0, y: 0))
    model.moveSpot(id: model.spots[0].id, to: PixelPoint(x: 5, y: 6))
    #expect(model.spots[0].point == PixelPoint(x: 5, y: 6))
}

// MARK: - Stream parser (iOS External Accessory)

@Test func streamParserFindsFramesInArbitraryChunks() {
    let model = CameraModel.p1
    let first = makeUSBFrame(model: model, frameCounter: 1, temperatureRaw: 100)
    let second = makeUSBFrame(model: model, frameCounter: 2, temperatureRaw: 200)
    // Garbage before, between and a half frame after – then cut into odd-sized pieces.
    let stream = [UInt8](repeating: 0x55, count: 37) + first + [0x0C, 0x8C, 1, 2, 3] + second + Array(first.prefix(1000))

    var parser = P3StreamParser(model: model)
    var frames: [RawThermalFrame] = []
    for start in stride(from: 0, to: stream.count, by: 4093) {
        frames += parser.append(stream[start..<min(start + 4093, stream.count)])
    }

    #expect(frames.map(\.frameNumber) == [1, 2])
    #expect(frames[1].values.allSatisfy { $0 == 200 })
    #expect(parser.skippedBytes == 37 + 5)
}

@Test func calibrationMonitorIgnoresCounterThatNeverChanges() {
    var monitor = CalibrationMonitor()
    let start = Date()
    _ = monitor.update(counter: 7, meanTemperature: 300, now: start)
    #expect(monitor.update(counter: 7, meanTemperature: 300, now: start.addingTimeInterval(1)) == .frozen)
    #expect(monitor.update(counter: 7, meanTemperature: 300, now: start.addingTimeInterval(5)) == .normal)
    #expect(monitor.update(counter: 7, meanTemperature: 300, now: start.addingTimeInterval(6)) == .normal)
}

/// Packets recorded between the official iOS app and the camera (docs/HARDWARE-NOTES.md).
@Test func accessoryPacketsMatchRecordedTraffic() {
    func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    let command = bytes("10024100010000000000000000000000")
    #expect(P3AccessoryProtocol.packet(command: command, sequence: 1, isFirst: true)
            == bytes("01fe000010024100010000000000000000000000783d"))
    #expect(P3AccessoryProtocol.packet(command: bytes("10044700300000000000000000000000"), sequence: 2, isFirst: false)
            == bytes("02ff000010044700300000000000000000000000f1ba"))
    // Shutter and gain as sent by the official app.
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.shutter, sequence: 5, isFirst: false)
            == bytes("05ff000010024300000000000000000000000000cfc8"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.gainLow, sequence: 8, isFirst: false)
            == bytes("08ff0000012f41000000000000000000000000003c3a"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.gainHigh, sequence: 9, isFirst: false)
            == bytes("09ff0000012f41000100000000000000000000004939"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.automaticShutter(false), sequence: 5, isFirst: false)
            == bytes("05ff0000100241000000000000000000000000000d3e"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.automaticShutter(true), sequence: 1, isFirst: true)
            == bytes("01fe000010024100010000000000000000000000783d"))
    // Brightness 48 and anti-burn protection, as the official app sends them on connect.
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.imageAdjustment(.brightness, value: 48), sequence: 2, isFirst: false)
            == bytes("02ff000010044700300000000000000000000000f1ba"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.imageAdjustment(.contrast, value: 50), sequence: 3, isFirst: false)
            == bytes("03ff000010044a00320000000000000000000000b4d1"))
    #expect(P3AccessoryProtocol.packet(command: P3AccessoryProtocol.burnProtection(true), sequence: 4, isFirst: false)
            == bytes("04ff000010034b000100000000000000000000002d8e"))
    // Same checksum as the USB commands on the Mac.
    #expect(P3AccessoryProtocol.crc16XModem(Array(P3Command.gainHigh.prefix(16))) == 0x3949)
}
