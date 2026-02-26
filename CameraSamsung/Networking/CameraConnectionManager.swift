//
//  CameraConnectionManager.swift
//  CameraSamsung
//
//  Manages the overall connection lifecycle with the Samsung DV150F camera
//  Detects Wi-Fi network, discovers services, and coordinates protocol clients
//

import Foundation
@preconcurrency import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import OSLog

private let logger = Logger(subsystem: "com.camera.samsung", category: "Network")

/// Connection states
enum CameraConnectionStatus: Equatable {
    case disconnected
    case detectingNetwork
    case networkFound(ssid: String)
    case connecting
    case connected
    case autoShareActive
    case error(String)
    
    var displayText: String {
        switch self {
        case .disconnected: return "Desconectado"
        case .detectingNetwork: return "Procurando câmera..."
        case .networkFound(let ssid): return "Rede encontrada: \(ssid)"
        case .connecting: return "Conectando..."
        case .connected: return "Conectado"
        case .autoShareActive: return "AutoShare ativo"
        case .error(let msg): return "Erro: \(msg)"
        }
    }
    
    var systemImage: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .detectingNetwork: return "wifi.exclamationmark"
        case .networkFound: return "wifi"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .autoShareActive: return "arrow.down.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var isConnected: Bool {
        switch self {
        case .connected, .autoShareActive: return true
        default: return false
        }
    }
}

/// Detected camera mode based on open ports
enum DetectedCameraMode: Equatable {
    case unknown
    case mobileLink   // Port 7676/7679 → DLNA
    case autoShare    // Port 801 → S2L
}

/// Port scan result
struct DiscoveredService: Identifiable {
    let id = UUID()
    let port: UInt16
    let name: String
    let isAvailable: Bool
}

/// A log entry for the connection debug console
struct ConnectionLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String
    
    enum Level: String {
        case info = "ℹ"
        case success = "✓"
        case warning = "⚠"
        case error = "✗"
        case debug = "⊙"
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

/// Manages connection to the Samsung DV150F camera
@Observable
final class CameraConnectionManager {
    static let shared = CameraConnectionManager()
    
    // MARK: - Published State
    
    private(set) var status: CameraConnectionStatus = .disconnected
    private(set) var ptpClient: PTPIPClient?
    private(set) var dlnaClient: SamsungDLNAClient?
    private(set) var autoShareClient: AutoShareClient?
    private(set) var discoveredServices: [DiscoveredService] = []
    private(set) var cameraFiles: [CameraFile] = []
    private(set) var isLoadingFiles = false
    private(set) var downloadProgress: Double = 0
    private(set) var currentSSID: String?
    private(set) var connectionLog: [ConnectionLogEntry] = []
    private(set) var detectedMode: DetectedCameraMode = .unknown
    
    // MARK: - Network Monitoring
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.camera.samsung.monitor")
    private var isNetworkSatisfied = false
    
    /// The camera's gateway IP — Samsung DV150F uses 192.168.101.1
    var cameraIP: String = "192.168.101.1"
    
    /// Samsung DV150F ports (only 7676 and 7679 are open)
    private let knownPorts: [(port: UInt16, name: String)] = [
        (7676, "Samsung MobileLink"),
        (7679, "Samsung Remote Viewfinder Stream"),
    ]
    
    // MARK: - Init
    
    init() {
        startNetworkMonitoring()
    }
    
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let isSatisfied = path.status == .satisfied
            
            // Only act on state changes
            if isSatisfied != self.isNetworkSatisfied {
                self.isNetworkSatisfied = isSatisfied
                
                Task { @MainActor in
                    if isSatisfied {
                        self.addLog(.info, "Wi-Fi detectado. Aguardando 5 segundos para a câmera iniciar...")
                        // Wait 5 seconds as requested to ensure camera DHCP and services are fully up
                        try? await Task.sleep(for: .seconds(5))
                        
                        // Only auto-connect if we're currently disconnected or errored
                        if case .disconnected = self.status {
                            await self.connect()
                        } else if case .error = self.status {
                            await self.connect()
                        }
                    } else {
                        self.addLog(.warning, "Wi-Fi desconectado.")
                        // If we lose Wi-Fi, immediately clear the state
                        self.disconnect()
                    }
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    // MARK: - Connection Flow
    
    /// Main entry: detect camera network, determine mode, and connect
    func connect() async {
        connectionLog.removeAll()
        status = .detectingNetwork
        detectedMode = .unknown
        
        addLog(.info, "Iniciando detecção da câmera...")
        
        // Step 1: Try to detect SSID
        let detectedSSID = await detectCameraSSID()
        
        // Step 2: Probe all Samsung subnets and ports to find the camera and its mode
        let cameraFound: Bool
        let ssidLabel: String
        
        if let ssid = detectedSSID {
            addLog(.success, "SSID da câmera detectado: \(ssid)")
            // Still need to probe to find the right IP and mode
            if let (foundIP, mode) = await probeAllSubnets() {
                self.cameraIP = foundIP
                self.detectedMode = mode
                cameraFound = true
                ssidLabel = ssid
                let modeName: String
                switch mode {
                case .autoShare: modeName = "AutoShare"
                case .mobileLink: modeName = "MobileLink"
                case .unknown: modeName = "Desconhecido"
                }
                addLog(.success, "Modo detectado: \(modeName) em \(foundIP)")
            } else {
                cameraFound = true
                ssidLabel = ssid
                addLog(.warning, "SSID detectado, mas nenhuma porta respondeu")
            }
        } else {
            addLog(.warning, "Detecção de SSID falhou (pode ser limitação do iOS)")
            addLog(.info, "Escaneando todas as sub-redes Samsung...")
            
            if let (foundIP, mode) = await probeAllSubnets() {
                self.cameraIP = foundIP
                self.detectedMode = mode
                cameraFound = true
                ssidLabel = "Câmera detectada: \(mode == .autoShare ? "AutoShare" : "MobileLink") (\(foundIP))"
                addLog(.success, ssidLabel)
            } else {
                cameraFound = false
                addLog(.error, "Câmera não encontrada em nenhuma sub-rede.")
                addLog(.info, "Verifique: 1) Wi-Fi da câmera ligado 2) iPhone conectado à rede da câmera")
                ssidLabel = ""
            }
        }
        
        guard cameraFound else {
            status = .error("Câmera não encontrada. Verifique a conexão Wi-Fi.")
            return
        }
        
        currentSSID = ssidLabel
        status = .networkFound(ssid: ssidLabel)
        try? await Task.sleep(for: .milliseconds(500))
        
        // Step 3: Connect based on detected mode
        status = .connecting
        
        switch detectedMode {
        case .autoShare:
            addLog(.info, "Modo AutoShare detectado — iniciando S2L...")
            await connectAutoShare()
            if autoShareClient?.isActive == true {
                status = .autoShareActive
            } else {
                status = .error("Falha ao iniciar AutoShare")
            }
            
        case .mobileLink, .unknown:
            addLog(.info, "Modo MobileLink/DLNA detectado — conectando...")
            let client = SamsungDLNAClient(host: cameraIP)
            do {
                try await client.connect()
                self.dlnaClient = client
                self.status = .connected
                
                // Automatically load files after connection
                addLog(.info, "Conexão estabelecida, buscando arquivos automaticamente...")
                await self.loadFiles()
                
                addLog(.success, "Conectado à câmera Samsung via DLNA!")
                if let info = client.cameraInfo {
                    addLog(.info, "Câmera: \(info.friendlyName)")
                }
                
            } catch {
                addLog(.error, "Falha na conexão DLNA: \(error.localizedDescription)")
                status = .error("Falha na conexão DLNA: \(error.localizedDescription)")
            }
        }
    }
    
    /// Disconnect from camera
    func disconnect() {
        ptpClient?.disconnect()
        autoShareClient?.stop()
        ptpClient = nil
        dlnaClient = nil
        autoShareClient = nil
        cameraFiles = []
        status = .disconnected
        
        addLog(.info, "Desconectado")
    }
    
    // MARK: - AutoShare
    
    /// Connect in AutoShare mode (S2L protocol on port 801)
    func connectAutoShare() async {
        addLog(.info, "Iniciando AutoShare...")
        
        // Detect local IP
        guard let localIP = AutoShareClient.getLocalIP() else {
            addLog(.error, "Não foi possível detectar o IP local")
            return
        }
        
        // Determine camera IP — prefer 192.168.103.1 for AutoShare
        let autoShareIP: String
        if localIP.hasPrefix("192.168.103.") {
            autoShareIP = "192.168.103.1"
        } else {
            autoShareIP = cameraIP
        }
        
        addLog(.info, "Local: \(localIP), Câmera: \(autoShareIP)")
        
        let client = AutoShareClient()
        client.connectionManager = self
        self.autoShareClient = client
        
        await client.start(cameraIP: autoShareIP, localIP: localIP)
    }
    
    /// Stop AutoShare mode
    func disconnectAutoShare() {
        autoShareClient?.stop()
        autoShareClient = nil
        addLog(.info, "AutoShare desconectado")
    }
    
    // MARK: - File Operations
    
    /// Load file listing from camera
    func loadFiles() async {
        // Try DLNA first, fall back to PTP
        if let dlna = dlnaClient {
            await loadFilesViaDLNA(dlna)
        } else if let ptp = ptpClient {
            await loadFilesViaPTP(ptp)
        }
    }
    
    /// Load files via Samsung DLNA Browse (recursive)
    private func loadFilesViaDLNA(_ client: SamsungDLNAClient) async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        
        do {
            // Initialize session for stability
            addLog(.info, "Inicializando sessão DLNA...")
            await client.initializeSession()
            try await Task.sleep(for: .milliseconds(500))
            
            addLog(.info, "Buscando arquivos via DLNA Browse (recursivo)...")
            let items = try await client.browseAllFiles(objectID: "0")
            
            cameraFiles = items.enumerated().map { index, item in
                CameraFile(
                    handle: UInt32(index),
                    name: item.title,
                    format: item.mimeType.contains("video") ? .mp4 : .jpeg,
                    size: item.size,
                    width: 0,
                    height: 0,
                    captureDate: item.date,
                    thumbnailURL: item.thumbnailURL,
                    contentURL: item.url
                )
            }
            
            // Automatically sync new files in MobileLink mode
            if !cameraFiles.isEmpty {
                addLog(.info, "Iniciando importação automática de novos arquivos...")
                await SyncManager.shared.syncNewFiles(cameraFiles, using: client)
            }
            
            // Auto-sync is disabled to allow on-demand downloads (user manual override)
        } catch {
            addLog(.error, "Erro ao buscar arquivos DLNA: \(error.localizedDescription)")
        }
    }
    
    /// Load files via PTP/IP
    private func loadFilesViaPTP(_ client: PTPIPClient) async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        
        do {
            // Get storage IDs
            let storageIDs = try await client.getStorageIDs()
            addLog(.info, "Encontrado(s) \(storageIDs.count) armazenamento(s)")
            
            var files: [CameraFile] = []
            
            for storageID in storageIDs {
                addLog(.debug, "Listando storage 0x\(String(storageID, radix: 16))...")
                
                // Get all object handles
                let handles = try await client.getObjectHandles(
                    storageID: storageID,
                    formatCode: 0,
                    parentHandle: 0xFFFFFFFF
                )
                
                addLog(.info, "Encontrados \(handles.count) objetos no storage 0x\(String(storageID, radix: 16))")
                
                for handle in handles {
                    do {
                        let info = try await client.getObjectInfo(handle: handle)
                        let format = PTPObjectFormat(rawValue: info.objectFormat) ?? .undefined
                        
                        // Only include images and videos
                        guard format.isImage || format.isVideo else { continue }
                        
                        var file = CameraFile(
                            handle: handle,
                            name: info.filename,
                            format: format,
                            size: Int64(info.objectCompressedSize),
                            width: Int(info.imagePixWidth),
                            height: Int(info.imagePixHeight),
                            captureDate: info.captureDate
                        )
                        
                        // Try to load thumbnail
                        if let thumbData = try? await client.getThumb(handle: handle),
                           !thumbData.isEmpty {
                            file.thumbnailData = thumbData
                        }
                        
                        files.append(file)
                    } catch {
                        addLog(.warning, "Falha ao ler handle \(handle): \(error.localizedDescription)")
                    }
                }
            }
            
            // Sort by filename (typically includes date)
            files.sort { $0.filename > $1.filename }
            self.cameraFiles = files
            
            addLog(.success, "Carregados \(files.count) arquivos da câmera")
        } catch {
            addLog(.error, "Falha ao listar arquivos: \(error.localizedDescription)")
        }
    }
    
    /// Download a full-resolution file from the camera
    func downloadFile(_ file: CameraFile) async throws -> Data {
        // Try DLNA content URL first
        if let contentURL = file.contentURL, !contentURL.isEmpty {
            downloadProgress = 0
            addLog(.info, "Baixando \(file.filename) via DLNA (\(file.formattedSize))...")
            
            guard let dlna = dlnaClient else {
                throw SamsungDLNAError.connectionFailed("DLNA client not connected")
            }
            
            let data = try await dlna.downloadFile(url: contentURL)
            downloadProgress = 1.0
            addLog(.success, "Download concluído: \(file.filename)")
            return data
        }
        
        // Fall back to PTP/IP
        guard let client = ptpClient else {
            throw PTPIPError.sessionNotOpen
        }
        
        downloadProgress = 0
        addLog(.info, "Baixando \(file.filename) via PTP (\(file.formattedSize))...")
        let data = try await client.getObject(handle: file.id)
        downloadProgress = 1.0
        addLog(.success, "Download concluído: \(file.filename)")
        return data
    }
    
    // MARK: - Network Detection
    
    /// Detect if current Wi-Fi is the camera's AP
    private func detectCameraSSID() async -> String? {
        addLog(.debug, "Método 1: NEHotspotNetwork.fetchCurrent()...")
        
        // Method 1: NEHotspotNetwork (iOS 14+)
        let hotspotSSID = await getSSIDViaHotspotNetwork()
        if let ssid = hotspotSSID {
            addLog(.debug, "NEHotspotNetwork retornou SSID: '\(ssid)'")
            if isCameraSSID(ssid) {
                addLog(.success, "SSID corresponde ao padrão da câmera!")
                return ssid
            } else {
                addLog(.warning, "SSID '\(ssid)' não corresponde ao padrão AP_SSC_DV150F*")
            }
        } else {
            addLog(.warning, "NEHotspotNetwork retornou nil (entitlement 'Access WiFi Information' necessário?)")
        }
        
        // Method 2: CNCopyCurrentNetworkInfo (deprecated but still works)
        addLog(.debug, "Método 2: CNCopyCurrentNetworkInfo()...")
        let captiveSSID = getSSIDViaCaptiveNetwork()
        if let ssid = captiveSSID {
            addLog(.debug, "CNCopyCurrentNetworkInfo retornou SSID: '\(ssid)'")
            if isCameraSSID(ssid) {
                addLog(.success, "SSID corresponde ao padrão da câmera!")
                return ssid
            } else {
                addLog(.warning, "SSID '\(ssid)' não corresponde ao padrão AP_SSC_DV150F*")
            }
        } else {
            addLog(.warning, "CNCopyCurrentNetworkInfo retornou nil")
        }
        
        // Method 3: Get interface addresses to detect network info
        addLog(.debug, "Método 3: Verificando interfaces de rede...")
        if let ifInfo = getNetworkInterfaceInfo() {
            addLog(.debug, "Interface info: \(ifInfo)")
        }
        
        return nil
    }
    
    /// Probe all known Samsung subnets and ports to determine mode
    private func probeAllSubnets() async -> (String, DetectedCameraMode)? {
        let subnets: [(String, UInt16, DetectedCameraMode)] = [
            // AutoShare subnet + port
            ("192.168.103.1", 801, .autoShare),
            // MobileLink subnets + ports
            ("192.168.101.1", 7676, .mobileLink),
            ("192.168.102.1", 7676, .mobileLink),
            ("192.168.104.1", 7676, .mobileLink),
            ("192.168.102.1", 7679, .mobileLink),
            ("192.168.101.1", 7679, .mobileLink),
            ("192.168.104.1", 7679, .mobileLink),
        ]
        
        // Probe all in parallel for speed
        let results = await withTaskGroup(of: (String, UInt16, DetectedCameraMode, Bool).self, returning: [(String, UInt16, DetectedCameraMode)].self) { group in
            for (ip, port, mode) in subnets {
                group.addTask { [self] in
                    let reachable = await self.isHostReachable(ip, port: port, timeout: 2)
                    return (ip, port, mode, reachable)
                }
            }
            
            var found: [(String, UInt16, DetectedCameraMode)] = []
            for await (ip, port, mode, reachable) in group {
                if reachable {
                    self.addLog(.success, "Porta \(port) aberta em \(ip) → \(mode == .autoShare ? "AutoShare" : "MobileLink")")
                    found.append((ip, port, mode))
                }
            }
            return found
        }
        
        if results.isEmpty {
            addLog(.info, "Câmera não encontrada em nenhuma sub-rede.")
            addLog(.debug, "Verifique: 1) Wi-Fi da câmera ligado 2) iPhone conectado à rede da câmera")
            return nil
        }
        
        
        if let first = results.first {
            return (first.0, first.2)
        }
        
        return nil
    }
    
    /// Legacy check (kept for direct IP config)
    private func checkCameraReachability() async -> String? {
        if let (ip, _) = await probeAllSubnets() {
            return ip
        }
        return nil
    }
    
    private func getSSIDViaHotspotNetwork() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
    
    private func getSSIDViaCaptiveNetwork() -> String? {
        #if !targetEnvironment(simulator)
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
            addLog(.debug, "CNCopySupportedInterfaces retornou nil")
            return nil
        }
        addLog(.debug, "Interfaces disponíveis: \(interfaces)")
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any] else {
                addLog(.debug, "CNCopyCurrentNetworkInfo(\(interface)) retornou nil")
                continue
            }
            addLog(.debug, "Info para \(interface): \(info.keys.joined(separator: ", "))")
            if let ssid = info["SSID"] as? String {
                return ssid
            }
        }
        #else
        addLog(.debug, "Simulador detectado — CNCopyCurrentNetworkInfo não disponível")
        #endif
        return nil
    }
    
    /// Get network interface info for debugging
    private func getNetworkInterfaceInfo() -> String? {
        var addresses: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            addLog(.debug, "getifaddrs() falhou")
            return nil
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            
            if family == UInt8(AF_INET) {  // IPv4
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                let address = String(cString: hostname)
                addresses.append("\(name): \(address)")
                addLog(.debug, "Interface \(name) → \(address)")
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return addresses.isEmpty ? nil : addresses.joined(separator: ", ")
    }
    
    private func isCameraSSID(_ ssid: String) -> Bool {
        // Samsung DV150F creates APs like "AP_SSC_DV150F_0-FB:58:97"
        let patterns = [
            "AP_SSC_DV150F",
            "SAMSUNG_DV150F",
            "DV150F",
            "AP_SSC_"
        ]
        let matches = patterns.contains { ssid.uppercased().contains($0.uppercased()) }
        addLog(.debug, "isCameraSSID('\(ssid)') → \(matches)")
        return matches
    }
    
    // MARK: - Port Scanning
    
    /// Scan known ports to discover available services
    /// Perform aggressive discovery to map open ports and HTTP endpoints
    func aggressiveDiscovery(ip: String) async {
        let portsToScan: [(UInt16, String)] = [
            (80, "HTTP Web"),
            (443, "HTTPS"),
            (1900, "UPnP Discovery"),
            (5000, "UPnP Eventing"),
            (7676, "MobileLink/DLNA"),
            (8080, "HTTP Alternate"),
            (15740, "PTP/IP"),
            (49152, "UPnP Media"),
            (49153, "UPnP Media 2"),
            (52235, "Samsung Smart TV")
        ]
        
        addLog(.info, "\n=== 1. ESCANEANDO PORTAS ===")
        var openPorts: [UInt16] = []
        
        await withTaskGroup(of: (UInt16, String, Bool).self) { group in
            for (port, name) in portsToScan {
                group.addTask { [self] in
                    let available = await self.isHostReachable(ip, port: port, timeout: 2)
                    return (port, name, available)
                }
            }
            
            for await (port, name, available) in group {
                if available {
                    addLog(.success, "Porta \(port) (\(name)) ABERTA")
                    openPorts.append(port)
                }
            }
        }
        
        // Update discovered services for UI
        self.discoveredServices = openPorts.map { p in
            DiscoveredService(port: p, name: portsToScan.first(where: { $0.0 == p })?.1 ?? "Unknown", isAvailable: true)
        }
        
        addLog(.info, "\n=== 2. SONDANDO HTTP (Probing) ===")
        let pathsToTry = [
            "/", "/index.html", "/smp_0_", "/smp_1_", "/smp_2_", "/smp_3_", "/smp_4_",
            "/device.xml", "/description.xml", "/MobileLink", "/Samsung", "/api",
            "/Server/device.xml"
        ]
        
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 4
        sessionConfig.allowsCellularAccess = false
        let session = URLSession(configuration: sessionConfig)
        
        let targetPorts = [UInt16]([80, 7676, 8080, 49152, 49153]).filter { openPorts.contains($0) }
        
        for port in targetPorts {
            addLog(.info, "Sondando porta \(port)...")
            for path in pathsToTry {
                let urlStr = "http://\(ip):\(port)\(path)"
                guard let url = URL(string: urlStr) else { continue }
                
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                
                do {
                    let (data, response) = try await session.data(for: req)
                    if let httpResp = response as? HTTPURLResponse {
                        let ctype = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                        addLog(.success, "GET \(path) → HTTP \(httpResp.statusCode) | \(data.count)b | \(ctype)")
                        
                        // Extract first couple elements to help identify content
                        if data.count > 0 && !ctype.contains("image") {
                            let preview = String(data: data.prefix(150), encoding: .utf8) ?? String(data: data.prefix(150), encoding: .ascii) ?? ""
                            if !preview.isEmpty {
                                addLog(.debug, ">> \(preview.replacingOccurrences(of: "\n", with: " "))")
                            }
                        }
                    }
                } catch {
                    // Ignore timeouts
                }
            }
        }
        addLog(.info, "=== FIM DA DESCOBERTA ===")
    }
    
    private enum TimeoutError: Error {
        case timedOut
    }
    
    private func withTimeout<T>(seconds: TimeInterval, body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
    
    /// Check if a host:port is reachable
    private func isHostReachable(_ host: String, port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: makeTCPParameters()
        )
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let safe = SafeContinuation(continuation)
                
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.cancel()
                        safe.resume(returning: true)
                    case .failed:
                        connection.cancel()
                        safe.resume(returning: false)
                    case .cancelled:
                        safe.resume(returning: false)
                    default:
                        break
                    }
                }
                
                // Timeout handling
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    connection.cancel()
                    safe.resume(returning: false)
                }
                
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }
    
    /// Create TCP parameters for camera communication
    private func makeTCPParameters() -> NWParameters {
        let tcp = NWParameters.tcp
        // Force WiFi and prohibit cellular to avoid routing issues on no-internet networks
        tcp.requiredInterfaceType = .wifi
        tcp.prohibitedInterfaceTypes = [.cellular]
        return tcp
    }
    
    // MARK: - Protocol Probing
    
    /// Connect to a port and read whatever data the camera sends (for protocol identification)
    private func probePort(host: String, port: UInt16) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: makeTCPParameters()
        )
        
        // Connect
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var done = false
            connection.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    continuation.resume()
                case .failed(let error):
                    done = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    done = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        
        addLog(.debug, "Probe: conectado à porta \(port), aguardando dados...")
        
        // Wait a moment then read any data the camera sends
        try await Task.sleep(for: .seconds(1))
        
        // Try to read whatever is available
        let data: Data
        do {
            data = try await withTimeout(seconds: 2) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let content = content {
                            continuation.resume(returning: content)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            }
        } catch {
            // If timeout or error, try sending a PTP/IP init as a probe
            self.addLog(.debug, "Probe: falha ou timeout aguardando dados (câmera não enviou nada espontaneamente)")
            
            var writer = PTPDataWriter()
            writer.writeGUID(UUID())
            writer.writePTPString("CameraSamsung")
            writer.writeUInt32(1)
            let initPacket = PTPIPPacket(type: .initCommandRequest, payload: writer.data)
            let probeBytes = initPacket.serialized
            
            self.addLog(.debug, "Probe: enviando PTP/IP InitCommandRequest (\(probeBytes.count) bytes)...")
            
            data = await withCheckedContinuation { continuation in
                connection.send(content: probeBytes, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                        connection.cancel()
                        continuation.resume(returning: content ?? Data())
                    }
                })
            }
        }
        
        return data
    }
    
    // MARK: - Logging
    
    func addLog(_ level: ConnectionLogEntry.Level, _ message: String) {
        let entry = ConnectionLogEntry(level: level, message: message)
        connectionLog.append(entry)
        
        // Keep last 300 entries
        if connectionLog.count > 300 {
            connectionLog.removeFirst(connectionLog.count - 300)
        }
        
        // Also log to system
        switch level {
        case .error:
            logger.error("\(message)")
        case .warning:
            logger.warning("\(message)")
        case .success, .info:
            logger.info("\(message)")
        case .debug:
            logger.debug("\(message)")
        }
    }
}

/// A thread-safe wrapper to ensure a continuation is resumed exactly once.
private class SafeContinuation<T> {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    
    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }
    
    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }
}
