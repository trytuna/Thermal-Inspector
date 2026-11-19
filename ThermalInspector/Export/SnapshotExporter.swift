import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Saves snapshots, videos and logs to the output folder (default: ~/Pictures/Thermal Inspector).
///
/// A snapshot consists of up to three files with the same base name:
/// * `.png`  – the image as seen on screen, with measurements and color bar
/// * `.csv`  – the full temperature matrix in °C (radiometric data for later analysis)
/// * `.json` – settings and measurement results
enum SnapshotExporter {
    struct Metadata: Codable {
        struct SpotResult: Codable {
            var label: String
            var x: Int
            var y: Int
            var temperature: Float
        }

        struct BoxResult: Codable {
            var label: String
            var x: Int
            var y: Int
            var width: Int
            var height: Int
            var minimum: Float
            var maximum: Float
            var mean: Float
        }

        var date: Date
        var camera: String
        var emissivity: Float
        var reflectedTemperature: Float
        var averagedFrames: Int
        var minimum: Float
        var maximum: Float
        var mean: Float
        var spots: [SpotResult]
        var boxes: [BoxResult]
        var note: String?
    }

    static var defaultOutputFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("Thermal Inspector", isDirectory: true)
    }

    /// A new file URL like ".../thermal-2026-11-19_14-03-22.png".
    static func newFileURL(in folder: URL, prefix: String, extension fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(prefix)-\(formatter.string(from: Date()))"
        return folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    /// Writes the PNG and, if enabled, CSV and JSON. Returns the URL of the PNG.
    @discardableResult
    static func saveSnapshot(image: CGImage, temperatures: ThermalFrame, metadata: Metadata, folder: URL,
                             includeTemperatureCSV: Bool, includeMetadataJSON: Bool) throws -> URL {
        let pngURL = try newFileURL(in: folder, prefix: "thermal", extension: "png")
        let baseURL = pngURL.deletingPathExtension()

        try writePNG(image, to: pngURL)

        if includeTemperatureCSV {
            try csv(for: temperatures).write(to: baseURL.appendingPathExtension("csv"), atomically: true, encoding: .utf8)
        }

        if includeMetadataJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: baseURL.appendingPathExtension("json"))
        }

        return pngURL
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The temperature matrix: one line per image row, values in °C with two decimals.
    static func csv(for frame: ThermalFrame) -> String {
        var lines: [String] = []
        lines.reserveCapacity(frame.height)
        for y in 0..<frame.height {
            let row = frame.values[(y * frame.width)..<((y + 1) * frame.width)]
            lines.append(row.map { String(format: "%.2f", $0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
