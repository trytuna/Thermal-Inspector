import Foundation
import IOKit
import IOUSBHost

enum USBError: LocalizedError {
    case deviceNotFound(vendorID: Int, productID: Int)
    case interfaceNotFound(Int)
    case interfaceNotOpen(Int)

    var errorDescription: String? {
        switch self {
        case let .deviceNotFound(vendorID, productID):
            let ids = String(format: "%04X:%04X", vendorID, productID)
            return String(localized: "Camera not found (USB \(ids)).")
        case let .interfaceNotFound(number):
            return String(localized: "USB interface \(number) of the camera was not found.")
        case let .interfaceNotOpen(number):
            return String(localized: "USB interface \(number) is not open.")
        }
    }
}

/// A small, synchronous wrapper around Apple's IOUSBHost framework.
///
/// It offers exactly the handful of operations the camera needs – the same ones
/// the Python reference implementation uses from PyUSB/libusb:
/// control transfers, opening interfaces, alternate settings and bulk reads.
///
/// Not thread-safe: use one instance from one thread only.
final class USBDevice {
    private let device: IOUSBHostDevice
    private let deviceService: io_service_t
    private var interfaces: [Int: IOUSBHostInterface] = [:]
    private var pipes: [Int: IOUSBHostPipe] = [:]

    // MARK: Opening and closing

    /// Returns true if a device with these IDs is currently plugged in.
    static func isConnected(vendorID: Int, productID: Int) -> Bool {
        let service = findService(vendorID: vendorID, productID: productID)
        if service != IO_OBJECT_NULL { IOObjectRelease(service) }
        return service != IO_OBJECT_NULL
    }

    init(vendorID: Int, productID: Int) throws {
        let service = Self.findService(vendorID: vendorID, productID: productID)
        guard service != IO_OBJECT_NULL else {
            throw USBError.deviceNotFound(vendorID: vendorID, productID: productID)
        }
        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            IOObjectRelease(service)
            throw error
        }
        deviceService = service
    }

    deinit {
        close()
        IOObjectRelease(deviceService)
    }

    func close() {
        pipes.removeAll()
        for interface in interfaces.values { interface.destroy() }
        interfaces.removeAll()
        device.destroy()
    }

    /// Selects USB configuration 1 unless the system already did so.
    func configureIfNeeded() throws {
        if device.configurationDescriptor == nil {
            try device.__configure(withValue: 1, matchInterfaces: true)
        }
    }

    /// Opens (claims) one interface of the device so we can use its pipes.
    func openInterface(_ number: Int) throws {
        guard interfaces[number] == nil else { return }

        // After configuring, the interfaces show up in the IORegistry with a short delay.
        var service = IO_OBJECT_NULL
        for _ in 0..<20 {
            service = findInterfaceService(number)
            if service != IO_OBJECT_NULL { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard service != IO_OBJECT_NULL else { throw USBError.interfaceNotFound(number) }
        defer { IOObjectRelease(service) }

        interfaces[number] = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
    }

    func selectAlternateSetting(_ alternateSetting: Int, onInterface number: Int) throws {
        guard let interface = interfaces[number] else { throw USBError.interfaceNotOpen(number) }
        // Selecting an alternate setting invalidates all pipes of this interface.
        pipes.removeAll()
        try interface.selectAlternateSetting(alternateSetting)
    }

    // MARK: Transfers

    /// Sends a control request with an optional data stage to the device.
    func controlOut(requestType: UInt8, request: UInt8, value: UInt16 = 0, index: UInt16 = 0,
                    data: [UInt8] = [], timeout: TimeInterval = 1) throws {
        let buffer = data.isEmpty ? nil : NSMutableData(bytes: data, length: data.count)
        var usbRequest = IOUSBDeviceRequest()
        usbRequest.bmRequestType = requestType
        usbRequest.bRequest = request
        usbRequest.wValue = value
        usbRequest.wIndex = index
        usbRequest.wLength = UInt16(data.count)
        var transferred = 0
        try device.__send(usbRequest, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
    }

    /// Reads up to `length` bytes with a control request from the device.
    func controlIn(requestType: UInt8, request: UInt8, value: UInt16 = 0, index: UInt16 = 0,
                   length: Int, timeout: TimeInterval = 1) throws -> [UInt8] {
        guard let buffer = NSMutableData(length: length) else { return [] }
        var usbRequest = IOUSBDeviceRequest()
        usbRequest.bmRequestType = requestType
        usbRequest.bRequest = request
        usbRequest.wValue = value
        usbRequest.wIndex = index
        usbRequest.wLength = UInt16(length)
        var transferred = 0
        try device.__send(usbRequest, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        return [UInt8](UnsafeRawBufferPointer(start: buffer.bytes, count: transferred))
    }

    /// Performs one bulk IN transfer into `buffer` and returns the number of bytes received.
    /// The transfer ends early when the device sends a short packet.
    func bulkRead(endpoint: Int, onInterface number: Int, into buffer: NSMutableData,
                  timeout: TimeInterval) throws -> Int {
        let pipe = try pipe(endpoint: endpoint, interface: number)
        var transferred = 0
        try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        return transferred
    }

    /// Allocates a buffer that is optimized for USB transfers on this device.
    /// The buffer's `length` is what a bulk read requests. IOUSBHost buffers already
    /// have length == capacity (and throw if you try to change it).
    func makeTransferBuffer(capacity: Int) -> NSMutableData {
        if let buffer = try? device.ioData(withCapacity: capacity), buffer.length == capacity {
            return buffer
        }
        return NSMutableData(length: capacity)!
    }

    // MARK: Helpers

    private func pipe(endpoint: Int, interface number: Int) throws -> IOUSBHostPipe {
        if let pipe = pipes[endpoint] { return pipe }
        guard let interface = interfaces[number] else { throw USBError.interfaceNotOpen(number) }
        let pipe = try interface.copyPipe(withAddress: endpoint)
        pipes[endpoint] = pipe
        return pipe
    }

    private static func findService(vendorID: Int, productID: Int) -> io_service_t {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID), productID: NSNumber(value: productID),
            bcdDevice: nil, deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil,
            speed: nil, productIDArray: nil
        )
        return IOServiceGetMatchingService(kIOMainPortDefault, matching.takeRetainedValue())
    }

    /// Walks the children of our device in the IORegistry to find an interface by number.
    private func findInterfaceService(_ number: Int) -> io_service_t {
        var iterator = io_iterator_t()
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let property = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0),
               (property.takeRetainedValue() as? NSNumber)?.intValue == number {
                return child
            }
            IOObjectRelease(child)
        }
        return IO_OBJECT_NULL
    }
}
