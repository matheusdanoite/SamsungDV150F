//
//  PTPTypes.swift
//  CameraSamsung
//
//  PTP/IP Protocol types, operation codes, and binary parsing utilities
//  Reference: CIPA DC-005 (PTP/IP) + Samsung proprietary extensions
//

import Foundation

// MARK: - PTP/IP Packet Types

enum PTPIPPacketType: UInt32 {
    case initCommandRequest   = 0x00000001
    case initCommandAck       = 0x00000002
    case initEventRequest     = 0x00000003
    case initEventAck         = 0x00000004
    case initFail             = 0x00000005
    case operationRequest     = 0x00000006
    case operationResponse    = 0x00000007
    case event                = 0x00000008
    case startDataPacket      = 0x00000009
    case dataPacket           = 0x0000000A
    case cancelTransaction    = 0x0000000B
    case endDataPacket        = 0x0000000C
    case probeRequest         = 0x0000000D
    case probeResponse        = 0x0000000E
}

// MARK: - PTP Operation Codes

enum PTPOperationCode: UInt16 {
    case undefined            = 0x1000
    case getDeviceInfo        = 0x1001
    case openSession          = 0x1002
    case closeSession         = 0x1003
    case getStorageIDs        = 0x1004
    case getStorageInfo       = 0x1005
    case getNumObjects        = 0x1006
    case getObjectHandles     = 0x1007
    case getObjectInfo        = 0x1008
    case getObject            = 0x1009
    case getThumb             = 0x100A
    case deleteObject         = 0x100B
    case sendObjectInfo       = 0x100C
    case sendObject           = 0x100D
    case initiateCapture      = 0x100E
    case formatStore          = 0x100F
    case resetDevice          = 0x1010
    case selfTest             = 0x1011
    case setObjectProtection  = 0x1012
    case powerDown            = 0x1013
    case getDevicePropDesc    = 0x1014
    case getDevicePropValue   = 0x1015
    case setDevicePropValue   = 0x1016
    case resetDevicePropValue = 0x1017
    case terminateOpenCapture = 0x1018
    case moveObject           = 0x1019
    case copyObject           = 0x101A
    case getPartialObject     = 0x101B
    case initiateOpenCapture  = 0x101C
    
    // Samsung vendor-specific
    case samsungGetObject     = 0x9001
    case samsungSendObject    = 0x9002
}

// MARK: - PTP Response Codes

enum PTPResponseCode: UInt16 {
    case undefined                   = 0x2000
    case ok                          = 0x2001
    case generalError                = 0x2002
    case sessionNotOpen              = 0x2003
    case invalidTransactionID        = 0x2004
    case operationNotSupported       = 0x2005
    case parameterNotSupported       = 0x2006
    case incompleteTransfer          = 0x2007
    case invalidStorageID            = 0x2008
    case invalidObjectHandle         = 0x2009
    case devicePropNotSupported      = 0x200A
    case invalidObjectFormatCode     = 0x200B
    case storeFull                   = 0x200C
    case objectWriteProtected        = 0x200D
    case storeReadOnly               = 0x200E
    case accessDenied                = 0x200F
    case noThumbnailPresent          = 0x2010
    case selfTestFailed              = 0x2011
    case partialDeletion             = 0x2012
    case storeNotAvailable           = 0x2013
    case specByFormatUnsupported     = 0x2014
    case noValidObjectInfo           = 0x2015
    case invalidCodeFormat           = 0x2016
    case unknownVendorCode           = 0x2017
    case captureAlreadyTerminated    = 0x2018
    case deviceBusy                  = 0x2019
    case invalidParentObject         = 0x201A
    case invalidDevicePropFormat     = 0x201B
    case invalidDevicePropValue      = 0x201C
    case invalidParameter            = 0x201D
    case sessionAlreadyOpened        = 0x201E
    case transactionCancelled        = 0x201F
    case specOfDestUnsupported       = 0x2020
    
    var isSuccess: Bool { self == .ok }
    
    var description: String {
        switch self {
        case .ok: return "OK"
        case .generalError: return "General Error"
        case .sessionNotOpen: return "Session Not Open"
        case .operationNotSupported: return "Operation Not Supported"
        case .deviceBusy: return "Device Busy"
        case .sessionAlreadyOpened: return "Session Already Opened"
        default: return "Error (0x\(String(rawValue, radix: 16)))"
        }
    }
}

// MARK: - PTP Object Format Codes

enum PTPObjectFormat: UInt16 {
    case undefined     = 0x3000
    case association   = 0x3001  // folder
    case script        = 0x3002
    case executable    = 0x3003
    case text          = 0x3004
    case html          = 0x3005
    case dpof          = 0x3006
    case aiff          = 0x3007
    case wav           = 0x3008
    case mp3           = 0x3009
    case avi           = 0x300A
    case mpeg          = 0x300B
    case asf           = 0x300C
    case jpeg          = 0x3801
    case tiff          = 0x3802
    case tiffIT        = 0x3803
    case jp2           = 0x3804  // JPEG 2000
    case bmp           = 0x3805
    case gif           = 0x3807
    case jfif          = 0x3808
    case pcd           = 0x3809
    case pict          = 0x380A
    case png           = 0x380B
    case tiffEP        = 0x380D
    // exifJPEG is the same as jpeg (0x3801)
    case mp4           = 0x300D
    
    var isImage: Bool {
        switch self {
        case .jpeg, .tiff, .bmp, .gif, .png, .jfif:
            return true
        default:
            return false
        }
    }
    
    var isVideo: Bool {
        switch self {
        case .avi, .mpeg, .asf, .mp4:
            return true
        default:
            return false
        }
    }
    
    var fileExtension: String {
        switch self {
        case .jpeg, .jfif: return "jpg"
        case .png: return "png"
        case .mp4: return "mp4"
        case .avi: return "avi"
        case .mpeg: return "mpg"
        default: return "bin"
        }
    }
}

// MARK: - PTP Data Structures

struct PTPDeviceInfo {
    var standardVersion: UInt16 = 0
    var vendorExtensionID: UInt32 = 0
    var vendorExtensionVersion: UInt16 = 0
    var vendorExtensionDesc: String = ""
    var functionalMode: UInt16 = 0
    var operationsSupported: [UInt16] = []
    var eventsSupported: [UInt16] = []
    var devicePropertiesSupported: [UInt16] = []
    var captureFormats: [UInt16] = []
    var imageFormats: [UInt16] = []
    var manufacturer: String = ""
    var model: String = ""
    var deviceVersion: String = ""
    var serialNumber: String = ""
}

struct PTPStorageInfo {
    var storageType: UInt16 = 0
    var filesystemType: UInt16 = 0
    var accessCapability: UInt16 = 0
    var maxCapacity: UInt64 = 0
    var freeSpaceInBytes: UInt64 = 0
    var freeSpaceInImages: UInt32 = 0
    var storageDescription: String = ""
    var volumeLabel: String = ""
}

struct PTPObjectInfo {
    var storageID: UInt32 = 0
    var objectFormat: UInt16 = 0
    var protectionStatus: UInt16 = 0
    var objectCompressedSize: UInt32 = 0
    var thumbFormat: UInt16 = 0
    var thumbCompressedSize: UInt32 = 0
    var thumbPixWidth: UInt32 = 0
    var thumbPixHeight: UInt32 = 0
    var imagePixWidth: UInt32 = 0
    var imagePixHeight: UInt32 = 0
    var imageBitDepth: UInt32 = 0
    var parentObject: UInt32 = 0
    var associationType: UInt16 = 0
    var associationDesc: UInt32 = 0
    var sequenceNumber: UInt32 = 0
    var filename: String = ""
    var captureDate: String = ""
    var modificationDate: String = ""
    var keywords: String = ""
    
    var format: PTPObjectFormat {
        PTPObjectFormat(rawValue: objectFormat) ?? .undefined
    }
}

// MARK: - Binary Data Reader

struct PTPDataReader {
    private let data: Data
    private(set) var offset: Int = 0
    
    init(data: Data) {
        self.data = data
    }
    
    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset >= data.count }
    
    mutating func readUInt8() -> UInt8 {
        guard offset < data.count else { return 0 }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }
    
    mutating func readUInt16() -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let value = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2))
            .withUnsafeBytes { $0.load(as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: value)
    }
    
    mutating func readUInt32() -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let value = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }
    
    mutating func readUInt64() -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let value = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 8))
            .withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }
    
    /// Read a PTP-style string (first byte is char count including null, then UTF-16LE chars)
    mutating func readPTPString() -> String {
        let numChars = Int(readUInt8())
        guard numChars > 0 else { return "" }
        
        var chars: [UInt16] = []
        for _ in 0..<numChars {
            let char = readUInt16()
            if char != 0 {
                chars.append(char)
            }
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }
    
    /// Read a PTP-style UInt16 array (first UInt32 is count, then that many UInt16 values)
    mutating func readUInt16Array() -> [UInt16] {
        let count = Int(readUInt32())
        var array: [UInt16] = []
        for _ in 0..<count {
            array.append(readUInt16())
        }
        return array
    }
    
    /// Read raw bytes
    mutating func readData(count: Int) -> Data {
        let actualCount = min(count, remaining)
        guard actualCount > 0 else { return Data() }
        let result = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + actualCount))
        offset += actualCount
        return result
    }
    
    mutating func skip(_ count: Int) {
        offset += min(count, remaining)
    }
}

// MARK: - Binary Data Writer

struct PTPDataWriter {
    private(set) var data = Data()
    
    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }
    
    mutating func writeUInt16(_ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
    
    mutating func writeUInt32(_ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }
    
    mutating func writeUInt64(_ value: UInt64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }
    
    /// Write a GUID (16 bytes)
    mutating func writeGUID(_ guid: UUID) {
        let uuid = guid.uuid
        data.append(contentsOf: [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ])
    }
    
    /// Write a PTP-style string
    mutating func writePTPString(_ string: String) {
        if string.isEmpty {
            writeUInt8(0)
            return
        }
        let utf16 = Array(string.utf16)
        writeUInt8(UInt8(utf16.count + 1)) // +1 for null terminator
        for char in utf16 {
            writeUInt16(char)
        }
        writeUInt16(0) // null terminator
    }
    
    mutating func writeData(_ rawData: Data) {
        data.append(rawData)
    }
}

// MARK: - PTP/IP Packet

struct PTPIPPacket {
    let type: PTPIPPacketType
    let payload: Data
    
    var serialized: Data {
        var writer = PTPDataWriter()
        let totalLength = UInt32(8 + payload.count) // 4 length + 4 type + payload
        writer.writeUInt32(totalLength)
        writer.writeUInt32(type.rawValue)
        writer.writeData(payload)
        return writer.data
    }
    
    static func parse(from data: Data) -> (packet: PTPIPPacket, consumed: Int)? {
        guard data.count >= 8 else { return nil }
        
        var reader = PTPDataReader(data: data)
        let length = Int(reader.readUInt32())
        let typeRaw = reader.readUInt32()
        
        guard length >= 8, data.count >= length else { return nil }
        guard let type = PTPIPPacketType(rawValue: typeRaw) else { return nil }
        
        let payloadLength = length - 8
        let payload = reader.readData(count: payloadLength)
        
        return (PTPIPPacket(type: type, payload: payload), length)
    }
}
