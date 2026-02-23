//
//  SamsungDLNAClient.swift
//  CameraSamsung
//
//  Samsung cameras use UPnP/DLNA over HTTP instead of PTP/IP.
//  Port 7676: DLNA device description + SOAP services
//  Port 7679: HTTP MJPEG live stream
//
//  Based on reverse-engineering of Samsung NX300 protocol:
//  - Device description: GET /smp_2_
//  - Content Directory SCPD: GET /smp_3_
//  - Content Directory Control (SOAP): POST /smp_4_
//  - Connection Manager SCPD: GET /smp_6_
//  - Connection Manager Control: POST /smp_7_
//  - Live stream: GET /livestream.avi (on port 7679)
//

import Foundation
import Network
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.camerasamsung", category: "SamsungDLNA")

/// Errors from Samsung DLNA communication
enum SamsungDLNAError: Error, LocalizedError {
    case connectionFailed(String)
    case invalidResponse(Int)
    case noData
    case parseError(String)
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidResponse(let code): return "HTTP \(code)"
        case .noData: return "No data received"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .timeout: return "Request timed out"
        }
    }
}

/// Camera information from DLNA device description
struct SamsungCameraInfo {
    var friendlyName: String = ""
    var manufacturer: String = ""
    var modelName: String = ""
    var modelDescription: String = ""
    var modelNumber: String = ""
    var serialNumber: String = ""
    var uuid: String = ""
    var services: [DLNAService] = []
    var rawXML: String = ""
}

struct DLNAService {
    var serviceType: String = ""
    var serviceId: String = ""
    var controlURL: String = ""
    var eventSubURL: String = ""
    var scpdURL: String = ""
}

/// Camera capabilities from GetInformation SOAP call
struct SamsungCameraCapabilities {
    var resolutions: [(width: Int, height: Int)] = []
    var flashModes: [String] = []
    var defaultFlash: String = ""
    var maxZoom: Int = 0
    var availableShots: Int = 0
    var highQualityStreamURL: String = ""
    var lowQualityStreamURL: String = ""
    var rawXML: String = ""
}

/// A file entry from DLNA Browse
struct DLNAMediaItem {
    var id: String = ""
    var title: String = ""
    var url: String = ""
    var thumbnailURL: String = ""
    var mimeType: String = ""
    var size: Int64 = 0
    var resolution: String = ""
    var date: String = ""
}

/// Samsung DLNA Client for communicating with Samsung cameras
@Observable
final class SamsungDLNAClient {
    // MARK: - Properties
    
    private(set) var isConnected = false
    private(set) var cameraInfo: SamsungCameraInfo?
    private(set) var capabilities: SamsungCameraCapabilities?
    private(set) var logEntries: [PTPLogEntry] = []
    
    private let host: String
    private let port: UInt16
    private let session: URLSession
    private var controlURL: String = ""
    private let deviceID = UUID().uuidString
    private var heartbeatTimer: Timer?
    
    var baseURL: String { "http://\(host):\(port)" }
    var streamBaseURL: String { "http://\(host):7679" }
    
    // MARK: - Init
    
    init(host: String, port: UInt16 = 7676) {
        self.host = host
        self.port = port
        
        // Configure URLSession to use WiFi and have short timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.allowsCellularAccess = false  // Force WiFi
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Connection
    
    /// Connect to camera: fetch device description and capabilities
    func connect() async throws {
        log(.info, "Connecting to Samsung DLNA at \(baseURL)...")
        
        // Step 0: Probe for the correct XML descriptor endpoint
        guard let descriptorPath = try await probeForDescriptor() else {
            throw SamsungDLNAError.connectionFailed("Could not find DLNA XML descriptor endpoint on port 7676")
        }
        
        // Step 1: Get device description
        let info = try await getDeviceDescription(path: descriptorPath)
        self.cameraInfo = info
        log(.info, "Camera: \(info.friendlyName)")
        log(.info, "Model: \(info.modelName) (\(info.manufacturer))")
        log(.info, "Serial: \(info.serialNumber)")
        log(.info, "Services: \(info.services.count)")
        
        for service in info.services {
            log(.info, "  Service: \(service.serviceType)")
            log(.info, "    Control: \(service.controlURL)")
            log(.info, "    EventSub: \(service.eventSubURL)")
            log(.info, "    SCPD: \(service.scpdURL)")
            if service.serviceType.contains("ContentDirectory") {
                self.controlURL = service.controlURL
            }
        }
        
        // Step 2: Try to get camera capabilities
        do {
            let caps = try await getInformation()
            self.capabilities = caps
            log(.info, "Available shots: \(caps.availableShots)")
            log(.info, "Max zoom: \(caps.maxZoom)")
            log(.info, "Stream URL (high): \(caps.highQualityStreamURL)")
            log(.info, "Stream URL (low): \(caps.lowQualityStreamURL)")
            log(.info, "Resolutions: \(caps.resolutions.map { "\($0.width)x\($0.height)" }.joined(separator: ", "))")
        } catch {
            log(.error, "GetInformation failed: \(error.localizedDescription)")
            log(.info, "Continuing without capabilities...")
        }
        
        // Register the client immediately to trigger connection prompt
        await registerClient()
        
        // Start heartbeat to keep connection alive
        await startHeartbeat()
        
        // Debug: Fetch and log SCPD to find official actions
        for service in info.services {
            await fetchAndLogSCPD(service: service)
        }
        
        isConnected = true
        log(.info, "Connected to Samsung DLNA camera!")
    }
    
    private func probeForDescriptor() async throws -> String? {
        log(.info, "Probing for XML descriptor (using known DV150F path: /smp_6_)...")
        let url = "\(baseURL)/smp_6_"
        if let (data, response) = try? await httpGet(url: url) {
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if response.statusCode == 200 && (contentType.contains("xml") || contentType.contains("text")) {
                let prefix = String(data: data.prefix(50), encoding: .ascii) ?? ""
                if prefix.contains("<?xml") || prefix.contains("<root") || prefix.contains("xmlns") {
                    log(.info, "FOUND POTENTIAL DESCRIPTOR: /smp_6_")
                    return "/smp_6_"
                }
            }
        }
        
        log(.error, "Could not fetch descriptor at /smp_6_")
        return nil
    }

    // MARK: - DLNA Operations
    
    /// Fetch device description
    func getDeviceDescription(path: String) async throws -> SamsungCameraInfo {
        let url = "\(baseURL)\(path)"
        log(.sent, "GET \(url)")
        
        let (data, response) = try await httpGet(url: url)
        let statusCode = response.statusCode
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        
        log(.received, "HTTP \(statusCode), \(data.count) bytes, Content-Type: \(contentType)")
        
        // Log raw hex of first bytes for encoding diagnosis
        let hexDump = data.prefix(100).map { String(format: "%02X", $0) }.joined(separator: " ")
        log(.received, "Raw hex (first 100 bytes): \(hexDump)")
        
        // Try multiple encodings
        let xml = decodeData(data)
        log(.received, "XML (first 500 chars): \(String(xml.prefix(500)))")
        
        guard statusCode == 200 else {
            throw SamsungDLNAError.invalidResponse(statusCode)
        }
        
        return parseDeviceDescription(xml: xml)
    }
    
    /// Get camera capabilities via SOAP GetInformation
    func getInformation() async throws -> SamsungCameraCapabilities {
        let soapAction = "urn:schemas-upnp-org:service:ContentDirectory:1#GetInformation"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetInformation xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
            </u:GetInformation>
          </s:Body>
        </s:Envelope>
        """
        
        let targetPath = controlURL.isEmpty ? "/smp_4_" : controlURL
        let url = "\(baseURL)\(targetPath)"
        log(.sent, "SOAP GetInformation → \(url)")
        
        let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
        let statusCode = response.statusCode
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let xml = decodeData(data)
        
        log(.received, "HTTP \(statusCode), \(data.count) bytes, Content-Type: \(contentType)")
        log(.received, "SOAP response (first 500 chars): \(String(xml.prefix(500)))")
        
        guard statusCode == 200 else {
            throw SamsungDLNAError.invalidResponse(statusCode)
        }
        
        return parseCapabilities(xml: xml)
    }
    
    /// Browse media files via SOAP Browse
    func browseFiles(objectID: String = "0", startIndex: Int = 0, requestedCount: Int = 100) async throws -> [DLNAMediaItem] {
        let soapAction = "urn:schemas-upnp-org:service:ContentDirectory:1#Browse"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(objectID)</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>\(startIndex)</StartingIndex>
              <RequestedCount>\(requestedCount)</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
        
        let targetPath = controlURL.isEmpty ? "/smp_4_" : controlURL
        let url = "\(baseURL)\(targetPath)"
        log(.sent, "SOAP Browse(objectID=\(objectID)) → \(url)")
        
        let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
        let statusCode = response.statusCode
        let xml = decodeData(data)
        
        log(.received, "HTTP \(statusCode), \(data.count) bytes")
        log(.received, "Browse response (first 500 chars): \(String(xml.prefix(500)))")
        
        guard statusCode == 200 else {
            throw SamsungDLNAError.invalidResponse(statusCode)
        }
        
        return parseBrowseResult(xml: xml)
    }
    
    /// Recursively browse all files across all containers (folders)
    func browseAllFiles(objectID: String = "0") async throws -> [DLNAMediaItem] {
        var allItems: [DLNAMediaItem] = []
        
        let soapAction = "urn:schemas-upnp-org:service:ContentDirectory:1#Browse"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(objectID)</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>0</StartingIndex>
              <RequestedCount>100</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
        
        let targetPath = controlURL.isEmpty ? "/smp_4_" : controlURL
        let url = "\(baseURL)\(targetPath)"
        log(.sent, "SOAP BrowseAll(objectID=\(objectID)) → \(url)")
        
        do {
            let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
            guard response.statusCode == 200 else {
                log(.error, "Browse \(objectID) returned HTTP \(response.statusCode)")
                return allItems
            }
            
            let xml = decodeData(data)
            
            let soapParser = DLNASOAPResultParser()
            soapParser.parse(xml: xml)
            let unescaped = soapParser.resultString
            
            if unescaped.isEmpty {
                log(.error, "No <Result> in Browse response for \(objectID)")
                return allItems
            }
            
            let didlParser = DLNABrowseParser()
            didlParser.parse(xml: unescaped)
            
            allItems.append(contentsOf: didlParser.items)
            log(.info, "Found \(didlParser.items.count) items in objectID=\(objectID)")
            
            for containerID in didlParser.containers {
                log(.info, "Recursing into container \(containerID)...")
                try await Task.sleep(for: .milliseconds(500)) // Throttle
                let subItems = try await browseAllFiles(objectID: containerID)
                allItems.append(contentsOf: subItems)
            }
        } catch {
            log(.error, "Browse \(objectID) failed: \(error.localizedDescription)")
        }
        
        return allItems
    }
    
    /// Initialize session for stability (like the Python script does)
    func initializeSession() async {
        let soapAction = "urn:schemas-upnp-org:service:ContentDirectory:1#GetDeviceConfiguration"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetDeviceConfiguration xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"/>
          </s:Body>
        </s:Envelope>
        """
        
        let targetPath = controlURL.isEmpty ? "/smp_4_" : controlURL
        let url = "\(baseURL)\(targetPath)"
        log(.sent, "SOAP GetDeviceConfiguration → \(url)")
        
        do {
            let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
            log(.received, "Session init: HTTP \(response.statusCode), \(data.count) bytes")
        } catch {
            log(.error, "Session init failed: \(error.localizedDescription)")
        }
    }
    
    /// Register the iPhone with the camera to trigger the connection prompt
    func registerClient() async {
        let deviceName = UIDevice.current.name
        
        // Try multiple common Samsung action names
        let actions = [
            "urn:schemas-upnp-org:service:ContentDirectory:1#X_SetClientInfo",
            "urn:schemas-upnp-org:service:ContentDirectory:1#SetClientInfo",
            "urn:schemas-upnp-org:service:ContentDirectory:1#X_SamsungSetClientInfo"
        ]
        
        for soapAction in actions {
            let actionName = soapAction.components(separatedBy: "#").last ?? ""
            let soapBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:\(actionName) xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
                  <DeviceName>\(deviceName)</DeviceName>
                  <DeviceID>\(deviceID)</DeviceID>
                </u:\(actionName)>
              </s:Body>
            </s:Envelope>
            """
            
            let targetPath = controlURL.isEmpty ? "/smp_11_" : controlURL
            let url = "\(baseURL)\(targetPath)"
            log(.sent, "Handshake Attempt: \(actionName) → \(url)")
            
            do {
                let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
                if response.statusCode == 200 {
                    log(.info, "Handshake successful with \(actionName)!")
                    return
                } else {
                    log(.info, "Handshake \(actionName) failed: HTTP \(response.statusCode)")
                }
            } catch {
                log(.error, "Handshake \(actionName) error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Start a periodic heartbeat to prevent the camera from closing the connection
    func startHeartbeat() async {
        heartbeatTimer?.invalidate()
        
        // Run heartbeat every 30 seconds
        await MainActor.run {
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task {
                    try? await self?.browseFiles(objectID: "0", startIndex: 0, requestedCount: 1)
                    self?.log(.info, "Heartbeat sent")
                }
            }
        }
    }
    
    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    /// Trigger a photo capture via SOAP
    func capturePhoto() async throws {
        let soapAction = "urn:schemas-upnp-org:service:ContentDirectory:1#X_CaptureImage"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:X_CaptureImage xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
            </u:X_CaptureImage>
          </s:Body>
        </s:Envelope>
        """
        
        let targetPath = controlURL.isEmpty ? "/smp_4_" : controlURL
        let url = "\(baseURL)\(targetPath)"
        log(.sent, "SOAP X_CaptureImage → \(url)")
        
        let (data, response) = try await httpPost(url: url, body: soapBody, soapAction: soapAction)
        log(.received, "HTTP \(response.statusCode), \(data.count) bytes")
        
        let xml = decodeData(data)
        log(.received, "Response: \(String(xml.prefix(200)))")
    }
    
    /// Download a file from the camera
    func downloadFile(url fileURL: String) async throws -> Data {
        log(.sent, "GET \(fileURL)")
        let (data, response) = try await httpGet(url: fileURL)
        log(.received, "HTTP \(response.statusCode), \(data.count) bytes")
        
        guard response.statusCode == 200 else {
            throw SamsungDLNAError.invalidResponse(response.statusCode)
        }
        
        return data
    }
    
    /// Get live stream URLs
    func getStreamURLs() -> (high: URL?, low: URL?) {
        let highURL = capabilities?.highQualityStreamURL.isEmpty == false
            ? URL(string: capabilities!.highQualityStreamURL)
            : URL(string: "\(streamBaseURL)/livestream.avi")
        
        let lowURL = capabilities?.lowQualityStreamURL.isEmpty == false
            ? URL(string: capabilities!.lowQualityStreamURL)
            : URL(string: "\(streamBaseURL)/qvga_livestream.avi")
        
        return (highURL, lowURL)
    }
    
    // MARK: - HTTP Transport
    
    private func httpGet(url urlString: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw SamsungDLNAError.connectionFailed("Invalid URL: \(urlString)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Samsung MobileLink", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse ?? HTTPURLResponse()
            return (data, httpResponse)
        } catch {
            throw SamsungDLNAError.connectionFailed(error.localizedDescription)
        }
    }
    
    private func httpPost(url urlString: String, body: String, soapAction: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw SamsungDLNAError.connectionFailed("Invalid URL: \(urlString)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(soapAction)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("Samsung MobileLink", forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse ?? HTTPURLResponse()
            return (data, httpResponse)
        } catch {
            throw SamsungDLNAError.connectionFailed(error.localizedDescription)
        }
    }
    
    /// Decode data trying multiple encodings
    private func decodeData(_ data: Data) -> String {
        // Try UTF-8 first
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str
        }
        // Try ASCII
        if let str = String(data: data, encoding: .ascii), !str.isEmpty {
            return str
        }
        // Try Latin-1 (ISO 8859-1)
        if let str = String(data: data, encoding: .isoLatin1), !str.isEmpty {
            return str
        }
        // Try UTF-16
        if let str = String(data: data, encoding: .utf16), !str.isEmpty {
            return str
        }
        return "[Unable to decode \(data.count) bytes]"
    }
    
    // MARK: - XML Parsing (using XMLParser)
    
    private func parseDeviceDescription(xml: String) -> SamsungCameraInfo {
        let parser = DLNADeviceParser()
        parser.parse(xml: xml)
        return parser.info
    }
    
    private func parseCapabilities(xml: String) -> SamsungCameraCapabilities {
        let parser = DLNACapabilitiesParser()
        parser.parse(xml: xml)
        return parser.caps
    }
    
    private func parseBrowseResult(xml: String) -> [DLNAMediaItem] {
        let soapParser = DLNASOAPResultParser()
        soapParser.parse(xml: xml)
        
        let didlParser = DLNABrowseParser()
        didlParser.parse(xml: soapParser.resultString)
        
        return didlParser.items
    }
    
    /// Fetch and log the SCPD XML for debugging
    func fetchAndLogSCPD(service: DLNAService) async {
        guard !service.scpdURL.isEmpty else { return }
        let url = "\(baseURL)\(service.scpdURL)"
        log(.info, "Fetching SCPD for \(service.serviceType) → \(url)")
        
        do {
            let (data, response) = try await httpGet(url: url)
            if response.statusCode == 200 {
                let xml = decodeData(data)
                log(.received, "SCPD XML for \(service.serviceType):")
                // Log in chunks if it's too large for the console
                let chunkSize = 800
                var index = xml.startIndex
                while index < xml.endIndex {
                    let nextIndex = xml.index(index, offsetBy: chunkSize, limitedBy: xml.endIndex) ?? xml.endIndex
                    let chunk = String(xml[index..<nextIndex])
                    log(.received, ">> \(chunk)")
                    index = nextIndex
                }
            } else {
                log(.error, "Failed to fetch SCPD: HTTP \(response.statusCode)")
            }
        } catch {
            log(.error, "Error fetching SCPD: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Logging
    
    private func log(_ direction: PTPLogEntry.Direction, _ message: String) {
        let entry = PTPLogEntry(direction: direction, message: message, rawData: nil)
        Task { @MainActor in
            logEntries.append(entry)
            if logEntries.count > 200 {
                logEntries.removeFirst(logEntries.count - 200)
            }
        }
        logger.info("\(direction.rawValue) \(message)")
    }
}

// MARK: - XMLParser Delegates

final class DLNADeviceParser: NSObject, XMLParserDelegate {
    var info = SamsungCameraInfo()
    private var currentPath: [String] = []
    private var currentText = ""
    private var currentService: DLNAService?
    
    func parse(xml: String) {
        info.rawXML = xml
        if info.friendlyName.isEmpty { info.friendlyName = "Samsung Camera" }
        if info.manufacturer.isEmpty { info.manufacturer = "Samsung" }
        
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentPath.append(localName)
        currentText = ""
        
        if localName == "service" {
            currentService = DLNAService()
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if currentPath.last == localName {
            currentPath.removeLast()
        }
        
        if localName == "service", let s = currentService {
            info.services.append(s)
            currentService = nil
            return
        }
        
        if currentService != nil {
            switch localName {
            case "serviceType": currentService?.serviceType = text
            case "serviceId": currentService?.serviceId = text
            case "controlURL": currentService?.controlURL = text
            case "eventSubURL": currentService?.eventSubURL = text
            case "SCPDURL": currentService?.scpdURL = text
            default: break
            }
        } else {
            switch localName {
            case "friendlyName": if !text.isEmpty { info.friendlyName = text }
            case "manufacturer": if !text.isEmpty { info.manufacturer = text }
            case "modelName": info.modelName = text
            case "modelDescription": info.modelDescription = text
            case "modelNumber": info.modelNumber = text
            case "serialNumber": info.serialNumber = text
            case "UDN": info.uuid = text
            default: break
            }
        }
    }
}

final class DLNACapabilitiesParser: NSObject, XMLParserDelegate {
    var caps = SamsungCameraCapabilities()
    private var currentPath: [String] = []
    private var currentText = ""
    private var currentWidth: Int?
    private var currentHeight: Int?
    
    func parse(xml: String) {
        caps.rawXML = xml
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentPath.append(localName)
        currentText = ""
        if localName == "Resolution" {
            currentWidth = nil
            currentHeight = nil
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentPath.last == localName {
            currentPath.removeLast()
        }
        
        switch localName {
        case "AVAILSHOTS": caps.availableShots = Int(text) ?? 0
        case "MaxZoom": caps.maxZoom = Int(text) ?? 0
        case "Defaultflash": caps.defaultFlash = text
        case "QualityHighUrl": caps.highQualityStreamURL = text
        case "QualityLowUrl": caps.lowQualityStreamURL = text
        case "Width": currentWidth = Int(text)
        case "Height": currentHeight = Int(text)
        case "Resolution":
            if let w = currentWidth, let h = currentHeight {
                caps.resolutions.append((w, h))
            }
        case "Support":
            if !text.isEmpty {
                caps.flashModes.append(text)
            }
        default: break
        }
    }
}

final class DLNASOAPResultParser: NSObject, XMLParserDelegate {
    var resultString = ""
    private var inResult = false
    
    func parse(xml: String) {
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "Result" {
            inResult = true
            resultString = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inResult {
            resultString += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "Result" {
            inResult = false
        }
    }
}

final class DLNABrowseParser: NSObject, XMLParserDelegate {
    var items: [DLNAMediaItem] = []
    var containers: [String] = []
    private var currentPath: [String] = []
    private var currentText = ""
    private var currentItem: DLNAMediaItem?
    
    // Temporary variables for the currently parsed <res> tag
    private var tempMimeType = ""
    private var tempSize: Int64 = 0
    private var tempResolution = ""
    private var isParsingRes = false

    func parse(xml: String) {
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentPath.append(localName)
        currentText = ""
        
        if localName == "item" {
            currentItem = DLNAMediaItem()
        } else if localName == "container", let id = attributeDict["id"] {
            containers.append(id)
        } else if localName == "res", currentItem != nil {
            isParsingRes = true
            tempMimeType = attributeDict["protocolInfo"] ?? ""
            tempResolution = attributeDict["resolution"] ?? ""
            if let sizeStr = attributeDict["size"], let size = Int64(sizeStr) {
                tempSize = size
            } else {
                tempSize = 0
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        
        if currentPath.last == localName {
            currentPath.removeLast()
        }
        
        if localName == "item", let item = currentItem {
            if !item.title.isEmpty || !item.url.isEmpty {
                items.append(item)
            }
            currentItem = nil
            return
        }
        
        if let current = currentItem {
            switch localName {
            case "title":
                if currentItem?.title.isEmpty == true {
                    currentItem?.title = text
                }
            case "date": currentItem?.date = text
            case "res":
                isParsingRes = false
                // Heuristic: Prefer the resource with the largest size (full resolution)
                // If it's the first resource, or if this one is larger, use it.
                if current.url.isEmpty || tempSize > current.size {
                    currentItem?.url = text
                    currentItem?.size = tempSize
                    currentItem?.mimeType = tempMimeType
                    currentItem?.resolution = tempResolution
                }
            case "albumArtURI": currentItem?.thumbnailURL = text
            default: break
            }
        }
    }
}
