// SPDX-License-Identifier: Apache-2.0
// Ported from Thermal Camera Viewer / p3-ir-camera (Apache-2.0) – see NOTICE.

import Foundation

/// One frame straight from the camera.
struct RawThermalFrame: Sendable {
    let width: Int
    let height: Int
    /// Row-major temperatures in raw sensor units (1/64 K), `width * height` entries.
    let values: [UInt16]
    let frameNumber: UInt32
    /// The camera's own 8-bit grayscale image (automatic contrast and detail
    /// enhancement done in the camera), `width * height` entries. Empty if unavailable.
    var detailImage: [UInt8] = []
    /// The camera's internal frame counter. It stops while the camera repeats the
    /// last frame during its automatic recalibration. Nil if unavailable.
    var cameraFrameCounter: UInt16?
    /// The two metadata rows as 16-bit words (see docs/HARDWARE-NOTES.md). Empty if unavailable.
    var metadata: [UInt16] = []
}

/// Reassembles complete frames from the stream of bulk USB transfers.
///
/// The camera sends each frame as several bulk transfers and always finishes a
/// frame with a separate 12-byte transfer containing the end marker. We read in
/// fixed-size chunks and use that 12-byte transfer to stay in sync:
///
/// * a 12-byte transfer *before* the frame is complete means we started reading
///   in the middle of a frame → start over;
/// * a complete frame that did *not* end with a 12-byte transfer is out of sync → start over.
///
/// This is a direct port of `P3Camera.read_frame` from the Python reference.
/// It contains no USB code, so it can be unit-tested with synthetic data.
struct P3FrameAssembler {
    let model: CameraModel

    private(set) var completedFrames = 0
    private(set) var droppedFrames = 0

    private var buffer: [UInt8]
    private var position = 0

    init(model: CameraModel) {
        self.model = model
        buffer = [UInt8](repeating: 0, count: model.frameReadSize)
    }

    /// Feeds one bulk transfer. Returns a frame when this transfer completed one.
    mutating func append(_ chunk: UnsafeRawBufferPointer) -> RawThermalFrame? {
        let frameSize = model.frameReadSize
        let markerSize = P3Protocol.markerSize
        let end = position + chunk.count

        let isEndMarkerTransfer = chunk.count == markerSize
        let endMarkerTooEarly = isEndMarkerTransfer && end < frameSize
        let frameCompleteWithoutEndMarker = end >= frameSize && !isEndMarkerTransfer
        let overflow = end > frameSize

        if endMarkerTooEarly || frameCompleteWithoutEndMarker || overflow {
            if position > 0 { droppedFrames += 1 }
            position = 0
            return nil
        }

        buffer.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: position).copyMemory(from: chunk.baseAddress!, byteCount: chunk.count)
        }
        position = end

        guard position == frameSize else { return nil }
        position = 0
        return finishFrame()
    }

    /// Validates the markers of the buffered frame and extracts the images.
    private mutating func finishFrame() -> RawThermalFrame? {
        let frame = buffer.withUnsafeBytes { RawThermalFrame(frameBytes: $0, model: model) }
        if frame == nil {
            droppedFrames += 1
        } else {
            completedFrames += 1
        }
        return frame
    }
}

extension RawThermalFrame {
    /// Parses one complete frame: start marker + pixel data + end marker
    /// (`model.frameReadSize` bytes). Returns nil if the markers do not belong together.
    init?(frameBytes bytes: UnsafeRawBufferPointer, model: CameraModel) {
        let markerSize = P3Protocol.markerSize
        guard bytes.count >= model.frameReadSize else { return nil }
        let frameBytes = UnsafeRawBufferPointer(rebasing: bytes[0..<model.frameReadSize])
        let startMarker = FrameMarker(bytes: UnsafeRawBufferPointer(rebasing: frameBytes[0..<markerSize]))
        let endMarker = FrameMarker(bytes: UnsafeRawBufferPointer(rebasing: frameBytes[(frameBytes.count - markerSize)...]))

        // Start and end marker must belong to the same frame.
        guard startMarker.frameCounter == endMarker.frameCounter else { return nil }

        let width = model.width
        let height = model.height
        let pixelCount = width * height

        let temperatureOffset = markerSize + model.temperatureRowStart * width * 2
        var values = [UInt16](repeating: 0, count: pixelCount)
        for index in values.indices {
            values[index] = frameBytes.loadUnaligned(fromByteOffset: temperatureOffset + index * 2, as: UInt16.self).littleEndian
        }

        // The detail image is YUYV with constant chroma: the low byte of each pixel is the gray value.
        var detailImage = [UInt8](repeating: 0, count: pixelCount)
        for index in detailImage.indices {
            detailImage[index] = frameBytes[markerSize + index * 2]
        }

        let metadataOffset = markerSize + height * width * 2
        let metadata = (0..<(2 * width)).map {
            frameBytes.loadUnaligned(fromByteOffset: metadataOffset + $0 * 2, as: UInt16.self).littleEndian
        }

        self.init(width: width, height: height, values: values, frameNumber: startMarker.frameCounter,
                  detailImage: detailImage, cameraFrameCounter: metadata[P3Protocol.frameCounterWord], metadata: metadata)
    }
}
