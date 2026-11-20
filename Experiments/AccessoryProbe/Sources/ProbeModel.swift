import CoreGraphics
import ExternalAccessory
import Foundation
import Observation

/// Finds the P3 as an External Accessory, opens a session and reports everything it sees.
@Observable
final class ProbeModel {
    static let protocolName = "com.thermalmaster.pios3"

    struct Accessory: Identifiable {
        let id: Int
        let name: String
        let manufacturer: String
        let model: String
        let firmware: String
        let hardware: String
        let protocols: [String]
        var supportsP3: Bool { protocols.contains(ProbeModel.protocolName) }
    }

    private(set) var accessories: [Accessory] = []
    private(set) var isSessionOpen = false
    private(set) var statistics = AccessorySession.Statistics()
    private(set) var bytesPerSecond = 0.0
    private(set) var image: CGImage?
    private(set) var temperatureSummary = ""
    private(set) var log: [String] = []

    private var session: AccessorySession?
    private var rateSample = (bytes: 0, time: Date())
    private var lastImageUpdate = Date.distantPast

    init() {
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.addLog("Accessory connected")
            self?.refreshAccessories()
        }
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.addLog("Accessory disconnected")
            self?.closeSession()
            self?.refreshAccessories()
        }
        refreshAccessories()
        // For debugging from the command line: open the session right away.
        if CommandLine.arguments.contains("-autoOpen") { openSession() }
    }

    func refreshAccessories() {
        accessories = EAAccessoryManager.shared().connectedAccessories.map { accessory in
            Accessory(id: accessory.connectionID, name: accessory.name, manufacturer: accessory.manufacturer,
                      model: accessory.modelNumber, firmware: accessory.firmwareRevision,
                      hardware: accessory.hardwareRevision, protocols: accessory.protocolStrings)
        }
        addLog("Connected accessories: \(accessories.count)"
               + accessories.map { " · \($0.name) [\($0.protocols.joined(separator: ", "))]" }.joined())
    }

    // MARK: Session

    func openSession() {
        guard session == nil else { return }
        guard let accessory = EAAccessoryManager.shared().connectedAccessories
            .first(where: { $0.protocolStrings.contains(Self.protocolName) }) else {
            addLog("No accessory with protocol \(Self.protocolName)")
            return
        }
        guard let session = AccessorySession(accessory: accessory, protocolName: Self.protocolName) else {
            addLog("Could not open a session (EASession returned nil)")
            return
        }

        session.onLog = { [weak self] message in DispatchQueue.main.async { self?.addLog(message) } }
        session.onStatistics = { [weak self] statistics in DispatchQueue.main.async { self?.update(statistics) } }
        session.onFrame = { [weak self] frame in DispatchQueue.main.async { self?.show(frame) } }
        session.start()
        self.session = session
        isSessionOpen = true
        addLog("Session opened for \(accessory.name)")
    }

    func closeSession() {
        session?.stop()
        session = nil
        isSessionOpen = false
    }

    // MARK: Commands

    /// The 18-byte command packets the camera understands over USB control transfers.
    /// Over External Accessory we do not know the framing yet – these buttons try them raw.
    enum Command: String, CaseIterable, Identifiable {
        case startStream = "Start stream"
        case readName = "Read name"
        case readVersion = "Read version"
        case shutter = "Shutter"

        var id: String { rawValue }

        var bytes: [UInt8] {
            switch self {
            case .startStream: P3Command.startStream
            case .readName: P3Command.readName
            case .readVersion: P3Command.readVersion
            case .shutter: P3Command.shutter
            }
        }
    }

    func send(_ command: Command) {
        send(Data(command.bytes), label: command.rawValue)
    }

    /// Sends bytes typed as hex ("01 2f 81 00 …").
    func sendHex(_ text: String) {
        let digits = text.filter(\.isHexDigit)
        guard digits.count.isMultiple(of: 2), !digits.isEmpty else {
            addLog("Invalid hex input")
            return
        }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        send(Data(bytes), label: "custom")
    }

    private func send(_ data: Data, label: String) {
        guard let session else {
            addLog("Open a session first")
            return
        }
        addLog("→ \(label)")
        session.send(data)
    }

    // MARK: Updates

    private func update(_ statistics: AccessorySession.Statistics) {
        self.statistics = statistics
        let elapsed = Date().timeIntervalSince(rateSample.time)
        if elapsed >= 1 {
            bytesPerSecond = Double(statistics.bytesReceived - rateSample.bytes) / elapsed
            rateSample = (statistics.bytesReceived, Date())
        }
    }

    private func show(_ frame: RawThermalFrame) {
        // About 10 image updates per second are enough for a probe.
        guard Date().timeIntervalSince(lastImageUpdate) > 0.1 else { return }
        lastImageUpdate = Date()

        let celsius = frame.values.map { Float($0) / P3Protocol.rawUnitsPerKelvin - P3Protocol.kelvinOffset }
        let thermal = ThermalFrame(width: frame.width, height: frame.height, values: celsius)
        let statistics = thermal.statistics()
        let range = statistics.minimum...max(statistics.maximum, statistics.minimum + 1)
        image = ThermalRenderer.makeImage(frame: thermal, palette: .iron, range: range)
        let center = thermal.value(at: PixelPoint(x: frame.width / 2, y: frame.height / 2))
        temperatureSummary = String(format: "min %.1f °C · center %.1f °C · max %.1f °C",
                                    statistics.minimum, center, statistics.maximum)
    }

    private func addLog(_ message: String) {
        let time = Date().formatted(.dateTime.hour().minute().second())
        log.append("\(time)  \(message)")
        print("[Probe] \(message)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    var logText: String { log.joined(separator: "\n") }
}
