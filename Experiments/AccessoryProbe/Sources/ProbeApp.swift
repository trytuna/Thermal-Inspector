import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        WindowGroup {
            ProbeView(model: model)
        }
    }
}

/// One screen with everything needed to test the camera on iPhone/iPad.
struct ProbeView: View {
    let model: ProbeModel
    @State private var customHex = ""

    var body: some View {
        NavigationStack {
            List {
                accessorySection
                sessionSection
                imageSection
                logSection
            }
            .navigationTitle("P3 Probe")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshAccessories() }
            }
        }
    }

    private var accessorySection: some View {
        Section("1 · Accessory") {
            if model.accessories.isEmpty {
                Text("No accessory found. Plug in the camera.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.accessories) { accessory in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(accessory.manufacturer) \(accessory.name)").bold()
                    Text("Model \(accessory.model) · FW \(accessory.firmware) · HW \(accessory.hardware)")
                        .font(.caption)
                    Text(accessory.protocols.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(accessory.supportsP3 ? .green : .secondary)
                }
            }
        }
    }

    private var sessionSection: some View {
        Section("2 · Session") {
            if model.isSessionOpen {
                Button("Close Session", role: .destructive) { model.closeSession() }
            } else {
                Button("Open Session") { model.openSession() }
                    .disabled(!model.accessories.contains(where: \.supportsP3))
            }

            LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(model.statistics.bytesReceived), countStyle: .binary))
            LabeledContent("Rate", value: "\(ByteCountFormatter.string(fromByteCount: Int64(model.bytesPerSecond), countStyle: .binary))/s")
            LabeledContent("Reads", value: "\(model.statistics.reads)")
            LabeledContent("Frames found", value: "\(model.statistics.framesParsed)")
            LabeledContent("Skipped bytes", value: "\(model.statistics.skippedBytes)")

            // Try the known USB commands as raw bytes over the accessory stream.
            ForEach(ProbeModel.Command.allCases) { command in
                Button("Send “\(command.rawValue)”") { model.send(command) }
                    .disabled(!model.isSessionOpen)
            }
            HStack {
                TextField("Hex bytes, e.g. 01 2f 81 00 …", text: $customHex)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Send") { model.sendHex(customHex) }
                    .disabled(!model.isSessionOpen)
            }
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        if let image = model.image {
            Section("3 · Image") {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                Text(model.temperatureSummary)
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private var logSection: some View {
        Section {
            ForEach(Array(model.log.suffix(80).enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button("Copy") { UIPasteboard.general.string = model.logText }
                ShareLink(item: model.logText)
            }
        }
    }
}
