// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finds frames in a continuous byte stream, e.g. from an iOS External Accessory session.
///
/// Unlike `P3FrameAssembler`, which relies on the boundaries of the USB bulk
/// transfers, this parser only uses the content: it looks for a start marker
/// (length 12, sync 0x8C/0x8D) and accepts the frame if, exactly one frame later,
/// there is a matching end marker (sync 0x8E/0x8F, same frame counter).
struct P3StreamParser {
    let model: CameraModel

    private(set) var completedFrames = 0
    /// Bytes thrown away while searching for the next frame.
    private(set) var skippedBytes = 0

    private var buffer: [UInt8] = []

    init(model: CameraModel) {
        self.model = model
    }

    /// Adds received bytes and returns all frames completed by them.
    mutating func append(_ bytes: some Collection<UInt8>) -> [RawThermalFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [RawThermalFrame] = []
        let frameSize = model.frameReadSize
        var position = 0

        while buffer.count - position >= frameSize {
            guard let start = nextStartMarker(from: position) else {
                // No start marker in the buffer – keep only the last byte (a marker could begin there).
                skippedBytes += buffer.count - 1 - position
                position = buffer.count - 1
                break
            }
            skippedBytes += start - position
            position = start
            guard buffer.count - position >= frameSize else { break }

            let frame = buffer.withUnsafeBytes { bytes in
                hasEndMarker(at: position + frameSize - P3Protocol.markerSize)
                    ? RawThermalFrame(frameBytes: UnsafeRawBufferPointer(rebasing: bytes[position...]), model: model)
                    : nil
            }
            if let frame {
                frames.append(frame)
                completedFrames += 1
                position += frameSize
            } else {
                // Looked like a start marker but was pixel data – search on.
                skippedBytes += 1
                position += 1
            }
        }

        buffer.removeFirst(position)
        return frames
    }

    private func nextStartMarker(from position: Int) -> Int? {
        var index = position
        while index + 1 < buffer.count {
            if buffer[index] == UInt8(P3Protocol.markerSize), buffer[index + 1] == 0x8C || buffer[index + 1] == 0x8D {
                return index
            }
            index += 1
        }
        return nil
    }

    private func hasEndMarker(at index: Int) -> Bool {
        buffer[index] == UInt8(P3Protocol.markerSize) && (buffer[index + 1] == 0x8E || buffer[index + 1] == 0x8F)
    }
}
