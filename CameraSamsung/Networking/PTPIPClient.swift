//
//  PTPIPClient.swift
//  CameraSamsung
//
//  Low-level PTP/IP protocol client using Network framework
//  Handles session management, commands, and data transfer
//

import Foundation
@preconcurrency import Network
import OSLog

private let logger = Logger(subsystem: "com.camerasamsung", category: "PTPIPClient")

/// Errors from PTP/IP communication
enum PTPIPError: Error, LocalizedError {
    case connectionFailed(String)
    case timeout
    case invalidResponse
    case sessionNotOpen
    case operationFailed(PTPResponseCode)
    case unexpectedPacketType
    case dataTransferFailed
    case disconnected
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .timeout: return "Request timed out"
        case .invalidResponse: return "Invalid response from camera"
        case .sessionNotOpen: return "No active session"
        case .operationFailed(let code): return "PTP operation failed: \(code.description)"
        case .unexpectedPacketType: return "Unexpected packet type received"
        case .dataTransferFailed: return "Data transfer failed"
        case .disconnected: return "Disconnected from camera"
        }
    }
}

/// A log entry for debug purposes
struct PTPLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let direction: Direction
    let message: String
    let rawData: Data?
    
    enum Direction: String {
        case sent = "→"
        case received = "←"
        case info = "ℹ"
        case error = "✗"
    }
}

/// PTP/IP client for communicating with Samsung cameras
@Observable
final class PTPIPClient {
    // MARK: - Properties
    
    private(set) var isConnected = false
    private(set) var sessionID: UInt32 = 0
    private(set) var deviceInfo: PTPDeviceInfo?
    private(set) var logEntries: [PTPLogEntry] = []
    
    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var transactionID: UInt32 = 1
    private let connectionGUID = UUID()
    private var receiveBuffer = Data()
    
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    
    // MARK: - Init
    
    init(host: String, port: UInt16 = 15740) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }
    
    /// Create TCP parameters for camera communication
    private func makeTCPParameters() -> NWParameters {
        let tcp = NWParameters.tcp
        return tcp
    }
    
    // No deinit — disconnect() is called explicitly by CameraConnectionManager
    
    // MARK: - Connection Lifecycle
    
    /// Connect to the camera and open a PTP session
    func connect() async throws {
        log(.info, "Connecting to \(host):\(port)...")
        
        // 1. Establish command connection
        try await establishCommandConnection()
        
        // 2. Send Init Command Request (with timeout)
        log(.info, "Sending PTP/IP InitCommandRequest...")
        try await withTimeout(seconds: 8, operation: "InitCommandRequest") {
            try await self.sendInitCommandRequest()
        }
        
        // 3. Establish event connection (with timeout)
        log(.info, "Establishing event connection...")
        try await withTimeout(seconds: 8, operation: "EventConnection") {
            try await self.establishEventConnection()
        }
        
        // 4. Open PTP session
        log(.info, "Opening session...")
        try await withTimeout(seconds: 8, operation: "OpenSession") {
            try await self.openSession()
        }
        
        // 5. Get device info
        log(.info, "Getting device info...")
        let info = try await withTimeout(seconds: 8, operation: "GetDeviceInfo") {
            try await self.getDeviceInfo()
        }
        self.deviceInfo = info
        
        isConnected = true
        log(.info, "Connected! Camera: \(info.model) (\(info.manufacturer))")
    }
    
    /// Disconnect from the camera
    func disconnect() {
        // Just cancel connections — do NOT create a Task here
        // as it captures self and causes retain cycle on deallocation
        commandConnection?.cancel()
        eventConnection?.cancel()
        commandConnection = nil
        eventConnection = nil
        isConnected = false
        sessionID = 0
        transactionID = 1
        log(.info, "Disconnected")
    }
    
    // MARK: - PTP Operations
    
    /// Get device info
    func getDeviceInfo() async throws -> PTPDeviceInfo {
        let data = try await executeDataInOperation(code: .getDeviceInfo)
        var reader = PTPDataReader(data: data)
        
        var info = PTPDeviceInfo()
        info.standardVersion = reader.readUInt16()
        info.vendorExtensionID = reader.readUInt32()
        info.vendorExtensionVersion = reader.readUInt16()
        info.vendorExtensionDesc = reader.readPTPString()
        info.functionalMode = reader.readUInt16()
        info.operationsSupported = reader.readUInt16Array()
        info.eventsSupported = reader.readUInt16Array()
        info.devicePropertiesSupported = reader.readUInt16Array()
        info.captureFormats = reader.readUInt16Array()
        info.imageFormats = reader.readUInt16Array()
        info.manufacturer = reader.readPTPString()
        info.model = reader.readPTPString()
        info.deviceVersion = reader.readPTPString()
        info.serialNumber = reader.readPTPString()
        
        return info
    }
    
    /// Get storage IDs
    func getStorageIDs() async throws -> [UInt32] {
        let data = try await executeDataInOperation(code: .getStorageIDs)
        var reader = PTPDataReader(data: data)
        let count = Int(reader.readUInt32())
        var ids: [UInt32] = []
        for _ in 0..<count {
            ids.append(reader.readUInt32())
        }
        return ids
    }
    
    /// Get storage info
    func getStorageInfo(storageID: UInt32) async throws -> PTPStorageInfo {
        let data = try await executeDataInOperation(code: .getStorageInfo, params: [storageID])
        var reader = PTPDataReader(data: data)
        
        var info = PTPStorageInfo()
        info.storageType = reader.readUInt16()
        info.filesystemType = reader.readUInt16()
        info.accessCapability = reader.readUInt16()
        info.maxCapacity = reader.readUInt64()
        info.freeSpaceInBytes = reader.readUInt64()
        info.freeSpaceInImages = reader.readUInt32()
        info.storageDescription = reader.readPTPString()
        info.volumeLabel = reader.readPTPString()
        
        return info
    }
    
    /// Get object handles from a storage
    func getObjectHandles(storageID: UInt32 = 0xFFFFFFFF, formatCode: UInt32 = 0, parentHandle: UInt32 = 0xFFFFFFFF) async throws -> [UInt32] {
        let data = try await executeDataInOperation(
            code: .getObjectHandles,
            params: [storageID, formatCode, parentHandle]
        )
        var reader = PTPDataReader(data: data)
        let count = Int(reader.readUInt32())
        var handles: [UInt32] = []
        for _ in 0..<count {
            handles.append(reader.readUInt32())
        }
        return handles
    }
    
    /// Get object info for a specific handle
    func getObjectInfo(handle: UInt32) async throws -> PTPObjectInfo {
        let data = try await executeDataInOperation(code: .getObjectInfo, params: [handle])
        var reader = PTPDataReader(data: data)
        
        var info = PTPObjectInfo()
        info.storageID = reader.readUInt32()
        info.objectFormat = reader.readUInt16()
        info.protectionStatus = reader.readUInt16()
        info.objectCompressedSize = reader.readUInt32()
        info.thumbFormat = reader.readUInt16()
        info.thumbCompressedSize = reader.readUInt32()
        info.thumbPixWidth = reader.readUInt32()
        info.thumbPixHeight = reader.readUInt32()
        info.imagePixWidth = reader.readUInt32()
        info.imagePixHeight = reader.readUInt32()
        info.imageBitDepth = reader.readUInt32()
        info.parentObject = reader.readUInt32()
        info.associationType = reader.readUInt16()
        info.associationDesc = reader.readUInt32()
        info.sequenceNumber = reader.readUInt32()
        info.filename = reader.readPTPString()
        info.captureDate = reader.readPTPString()
        info.modificationDate = reader.readPTPString()
        info.keywords = reader.readPTPString()
        
        return info
    }
    
    /// Download the full object data (photo/video)
    func getObject(handle: UInt32) async throws -> Data {
        return try await executeDataInOperation(code: .getObject, params: [handle])
    }
    
    /// Download the thumbnail for an object
    func getThumb(handle: UInt32) async throws -> Data {
        return try await executeDataInOperation(code: .getThumb, params: [handle])
    }
    
    /// Trigger a photo capture
    func initiateCapture(storageID: UInt32 = 0, formatCode: UInt32 = 0) async throws {
        try await executeSimpleOperation(code: .initiateCapture, params: [storageID, formatCode])
    }
    
    // MARK: - Private: Connection Setup
    
    private func establishCommandConnection() async throws {
        let connection = NWConnection(
            host: host,
            port: port,
            using: makeTCPParameters()
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: PTPIPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: PTPIPError.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        
        self.commandConnection = connection
        log(.info, "Command connection established")
    }
    
    private func sendInitCommandRequest() async throws {
        var writer = PTPDataWriter()
        writer.writeGUID(connectionGUID)
        writer.writePTPString("CameraSamsung iOS")
        writer.writeUInt32(1) // Protocol version
        
        let packet = PTPIPPacket(type: .initCommandRequest, payload: writer.data)
        let serialized = packet.serialized
        log(.sent, "InitCommandRequest (\(serialized.count) bytes): \(serialized.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))")
        try await send(packet, on: commandConnection!)
        
        log(.info, "Waiting for InitCommandAck...")
        let response = try await receivePacket(on: commandConnection!)
        log(.received, "Response type: 0x\(String(format: "%08X", response.type.rawValue)), payload: \(response.payload.count) bytes")
        if !response.payload.isEmpty {
            log(.received, "Response hex: \(response.payload.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        
        guard response.type == .initCommandAck else {
            log(.error, "Expected InitCommandAck (0x02), got: 0x\(String(format: "%08X", response.type.rawValue))")
            throw PTPIPError.unexpectedPacketType
        }
        
        log(.received, "Init Command Ack received")
    }
    
    private func establishEventConnection() async throws {
        let connection = NWConnection(
            host: host,
            port: port,
            using: makeTCPParameters()
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: PTPIPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: PTPIPError.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        
        // Send init event request
        var writer = PTPDataWriter()
        writer.writeUInt32(1) // Connection number from Init Command Ack
        
        let packet = PTPIPPacket(type: .initEventRequest, payload: writer.data)
        try await send(packet, on: connection)
        
        let response = try await receivePacket(on: connection)
        guard response.type == .initEventAck else {
            throw PTPIPError.unexpectedPacketType
        }
        
        self.eventConnection = connection
        log(.info, "Event connection established")
    }
    
    private func openSession() async throws {
        sessionID = 1
        transactionID = 1
        try await executeSimpleOperation(code: .openSession, params: [sessionID])
        log(.info, "Session opened (ID: \(sessionID))")
    }
    
    private func closeSession() async throws {
        try await executeSimpleOperation(code: .closeSession)
        sessionID = 0
        log(.info, "Session closed")
    }
    
    // MARK: - Private: Operations
    
    /// Execute an operation that returns no data phase (just response)
    private func executeSimpleOperation(code: PTPOperationCode, params: [UInt32] = []) async throws {
        let txnID = nextTransactionID()
        
        var writer = PTPDataWriter()
        writer.writeUInt32(1) // data phase: no data
        writer.writeUInt16(code.rawValue)
        writer.writeUInt32(txnID)
        for param in params {
            writer.writeUInt32(param)
        }
        
        let packet = PTPIPPacket(type: .operationRequest, payload: writer.data)
        try await send(packet, on: commandConnection!)
        log(.sent, "Operation 0x\(String(code.rawValue, radix: 16)) [txn=\(txnID)]")
        
        let response = try await receivePacket(on: commandConnection!)
        guard response.type == .operationResponse else {
            throw PTPIPError.unexpectedPacketType
        }
        
        var reader = PTPDataReader(data: response.payload)
        let responseCode = reader.readUInt16()
        let respCode = PTPResponseCode(rawValue: responseCode) ?? .generalError
        
        guard respCode.isSuccess else {
            log(.error, "Operation failed: \(respCode.description)")
            throw PTPIPError.operationFailed(respCode)
        }
    }
    
    /// Execute an operation that receives data (Data-In phase)
    private func executeDataInOperation(code: PTPOperationCode, params: [UInt32] = []) async throws -> Data {
        let txnID = nextTransactionID()
        
        var writer = PTPDataWriter()
        writer.writeUInt32(2) // data phase: data in
        writer.writeUInt16(code.rawValue)
        writer.writeUInt32(txnID)
        for param in params {
            writer.writeUInt32(param)
        }
        
        let packet = PTPIPPacket(type: .operationRequest, payload: writer.data)
        try await send(packet, on: commandConnection!)
        log(.sent, "Operation 0x\(String(code.rawValue, radix: 16)) [txn=\(txnID)]")
        
        // Receive data phase
        var allData = Data()
        
        // First: start data packet
        let startPacket = try await receivePacket(on: commandConnection!)
        if startPacket.type == .startDataPacket {
            // Read total length from start data
            var startReader = PTPDataReader(data: startPacket.payload)
            let _ = startReader.readUInt32() // transaction ID
            let totalLength = startReader.readUInt64()
            log(.received, "Start data: \(totalLength) bytes expected")
            
            // Read data + end data packets
            var receivedAll = false
            while !receivedAll {
                let dataPacket = try await receivePacket(on: commandConnection!)
                switch dataPacket.type {
                case .dataPacket:
                    var dataReader = PTPDataReader(data: dataPacket.payload)
                    let _ = dataReader.readUInt32() // transaction ID
                    let chunk = dataReader.readData(count: dataReader.remaining)
                    allData.append(chunk)
                case .endDataPacket:
                    var endReader = PTPDataReader(data: dataPacket.payload)
                    let _ = endReader.readUInt32() // transaction ID
                    let chunk = endReader.readData(count: endReader.remaining)
                    allData.append(chunk)
                    receivedAll = true
                case .operationResponse:
                    // Some cameras send data inline with response
                    receivedAll = true
                default:
                    throw PTPIPError.unexpectedPacketType
                }
            }
        } else if startPacket.type == .operationResponse {
            // No data phase, just response
            var reader = PTPDataReader(data: startPacket.payload)
            let responseCode = reader.readUInt16()
            let respCode = PTPResponseCode(rawValue: responseCode) ?? .generalError
            if !respCode.isSuccess {
                throw PTPIPError.operationFailed(respCode)
            }
            return Data()
        }
        
        // Read response
        let response = try await receivePacket(on: commandConnection!)
        guard response.type == .operationResponse else {
            // Maybe we already consumed it
            if allData.count > 0 { return allData }
            throw PTPIPError.unexpectedPacketType
        }
        
        var respReader = PTPDataReader(data: response.payload)
        let responseCode = respReader.readUInt16()
        let respCode = PTPResponseCode(rawValue: responseCode) ?? .generalError
        
        guard respCode.isSuccess else {
            log(.error, "Data operation failed: \(respCode.description)")
            throw PTPIPError.operationFailed(respCode)
        }
        
        log(.received, "Received \(allData.count) bytes of data")
        return allData
    }
    
    // MARK: - Private: Transport
    
    private func send(_ packet: PTPIPPacket, on connection: NWConnection) async throws {
        let data = packet.serialized
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: PTPIPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receivePacket(on connection: NWConnection) async throws -> PTPIPPacket {
        // First read the 4-byte length header
        let headerData = try await receiveExact(4, on: connection)
        var headerReader = PTPDataReader(data: headerData)
        let totalLength = Int(headerReader.readUInt32())
        
        guard totalLength >= 8 else {
            throw PTPIPError.invalidResponse
        }
        
        // Read the rest of the packet
        let remainingData = try await receiveExact(totalLength - 4, on: connection)
        
        // Reconstruct full packet
        var fullData = Data()
        var lengthWriter = PTPDataWriter()
        lengthWriter.writeUInt32(UInt32(totalLength))
        fullData.append(lengthWriter.data)
        fullData.append(remainingData)
        
        guard let parsed = PTPIPPacket.parse(from: fullData) else {
            throw PTPIPError.invalidResponse
        }
        
        return parsed.packet
    }
    
    private func receiveExact(_ count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            nonisolated(unsafe) var done = false
            let timeout = DispatchWorkItem {
                if !done {
                    done = true
                    continuation.resume(throwing: PTPIPError.timeout)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                guard !done else { return }
                done = true
                timeout.cancel()
                if let error = error {
                    continuation.resume(throwing: PTPIPError.connectionFailed(error.localizedDescription))
                } else if let content = content {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: PTPIPError.disconnected)
                } else {
                    continuation.resume(throwing: PTPIPError.timeout)
                }
            }
        }
    }
    
    /// Run an async operation with a timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: String, body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PTPIPError.timeout
            }
            
            guard let result = try await group.next() else {
                throw PTPIPError.timeout
            }
            group.cancelAll()
            
            return result
        }
    }
    
    // MARK: - Helpers
    
    private func nextTransactionID() -> UInt32 {
        let id = transactionID
        transactionID += 1
        return id
    }
    
    private func log(_ direction: PTPLogEntry.Direction, _ message: String) {
        let entry = PTPLogEntry(direction: direction, message: message, rawData: nil)
        Task { @MainActor in
            logEntries.append(entry)
            // Keep last 200 entries
            if logEntries.count > 200 {
                logEntries.removeFirst(logEntries.count - 200)
            }
        }
        
        switch direction {
        case .error:
            logger.error("\(message)")
        case .info:
            logger.info("\(message)")
        default:
            logger.debug("\(direction.rawValue) \(message)")
        }
    }
}
