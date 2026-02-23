//
//  AutoShareClient.swift
//  CameraSamsung
//
//  S2L/1.0 protocol client for Samsung AutoShare mode.
//  Registers with camera on port 801, then listens on port 1801
//  for pushed images. Saves received photos to the photo library.
//

import Foundation
@preconcurrency import Network
import Photos
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.camerasamsung", category: "AutoShare")

/// A photo received via AutoShare push
struct ReceivedPhoto: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
    let receivedAt: Date
    let fileSize: Int
    
    var thumbnail: Data? {
        // Use the full data for thumbnail (UIImage will handle downscaling)
        data
    }
}

/// S2L/1.0 AutoShare client — receives photos pushed by the camera
@Observable
final class AutoShareClient: @unchecked Sendable {
    // MARK: - Configuration
    
    static let s2lPort: UInt16 = 801
    static let listenPort: UInt16 = 1801
    
    // MARK: - Observable State
    
    private(set) var isActive = false
    private(set) var isListening = false
    private(set) var isRegistered = false
    private(set) var receivedPhotos: [ReceivedPhoto] = []
    private(set) var totalReceived = 0
    private(set) var statusMessage = "Parado"
    private(set) var logEntries: [ConnectionLogEntry] = []
    
    // MARK: - Private
    
    private var listener: NWListener?
    private var cameraIP: String = ""
    private var localIP: String = ""
    private var localMAC: String = "00:00:00:00:00:00"
    private let queue = DispatchQueue(label: "com.camerasamsung.autoshare", qos: .userInitiated)
    
    /// Keep the initialization phase alive in the background
    private var startupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    /// Track active connections to close them on stop
    private var activeConnections: [NWConnection] = []
    private let connectionsLock = NSRecursiveLock()
    
    /// Weak ref to forward logs to the connection console
    weak var connectionManager: CameraConnectionManager?
    
    // MARK: - Lifecycle
    
    /// Start AutoShare: listen on port 1801, then register with camera on port 801
    func start(cameraIP: String, localIP: String) async {
        guard !isActive else { return }
        
        self.cameraIP = cameraIP
        self.localIP = localIP
        self.localMAC = getLocalMAC()
        isActive = true
        statusMessage = "Iniciando..."
        addLog(.info, "AutoShare iniciando — câmera: \(cameraIP), local: \(localIP)")
        
        // Begin a background task to ensure the listener starts and S2L handshake completes
        // even if the user immediately leaves the app
        startupBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AutoShare-Startup") { [weak self] in
            guard let self = self else { return }
            self.addLog(.warning, "Sistema finalizou a task de background antes do término!")
            if self.startupBackgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.startupBackgroundTask)
                self.startupBackgroundTask = .invalid
            }
        }
        
        // Enable background execution via silent audio loop
        BackgroundAudioManager.shared.startSilentPlayback()
        addLog(.info, "Áudio silencioso ativado para manter app em segundo plano")
        
        // Step 1: Start TCP listener on port 1801
        startListener()
        
        // Give listener time to start
        try? await Task.sleep(for: .milliseconds(500))
        
        guard isListening else {
            addLog(.error, "Falha ao iniciar servidor na porta \(Self.listenPort)")
            statusMessage = "Erro: porta \(Self.listenPort) indisponível"
            isActive = false
            return
        }
        
        // Step 2: Register with camera via S2L init on port 801
        await registerWithCamera()
        
        // At this point either we succeeded or timed out.
        // We can end the startup background task since the silent audio will now carry the weight.
        if startupBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(startupBackgroundTask)
            startupBackgroundTask = .invalid
            addLog(.debug, "Task de inicialização em background encerrada")
        }
    }
    
    /// Stop AutoShare
    func stop() {
        addLog(.info, "Parando AutoShare...")
        
        // Send ByeBye to camera
        if isRegistered {
            sendByeBye()
        }
        
        listener?.cancel()
        listener = nil
        
        // Cancel all active connections
        connectionsLock.lock()
        let connections = activeConnections
        activeConnections.removeAll()
        connectionsLock.unlock()
        
        for conn in connections {
            conn.cancel()
        }
        
        isActive = false
        isListening = false
        isRegistered = false
        statusMessage = "Parado"
        
        if startupBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(startupBackgroundTask)
            startupBackgroundTask = .invalid
        }
        
        addLog(.info, "AutoShare parado")
    }
    
    // MARK: - Concurrency Helpers
    
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
    
    // MARK: - TCP Listener (port 1801)
    
    private func startListener() {
        let params = makeWiFiTCP()
        params.allowLocalEndpointReuse = true
        
        // Configure TCP options for fast restart
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10
        }
        
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.listenPort)!)
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.addLog(.success, "Servidor escutando na porta \(Self.listenPort)")
                        self.statusMessage = "Escutando na porta \(Self.listenPort)..."
                    case .failed(let error):
                        self.isListening = false
                        
                        // Handle "Address already in use" (POSIX 48)
                        if case let .posix(code) = error, code == .EADDRINUSE {
                            self.addLog(.warning, "Porta \(Self.listenPort) ocupada, tentando em 2s...")
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                if self.isActive {
                                    self.startListener()
                                }
                            }
                        } else {
                            self.addLog(.error, "Servidor falhou: \(error)")
                            self.statusMessage = "Erro no servidor"
                        }
                        
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connectionsLock.lock()
                self.activeConnections.append(connection)
                self.connectionsLock.unlock()
                
                self.handleIncomingConnection(connection)
            }
            
            listener.start(queue: queue)
            self.listener = listener
            
        } catch {
            addLog(.error, "Erro ao criar listener: \(error)")
            statusMessage = "Erro: \(error.localizedDescription)"
        }
    }
    
    // MARK: - S2L Init (port 801)
    
    private func registerWithCamera() async {
        addLog(.info, "Registrando com câmera em \(cameraIP):\(Self.s2lPort)...")
        statusMessage = "Registrando com câmera..."
        
        let request = buildS2LRequest()
        
        for attempt in 1...3 {
            addLog(.debug, "Tentando handshake S2L (\(attempt)/3)...")
            
            let result = await sendS2LInit(request: request)
            
            switch result {
            case .accepted:
                DispatchQueue.main.async {
                    self.isRegistered = true
                    self.statusMessage = "AutoShare ativo — aguardando fotos"
                    self.addLog(.success, "Câmera aceitou! AutoShare ativo.")
                }
                return
                
            case .rejected(let reason):
                DispatchQueue.main.async {
                    // Result_Error just means the camera requires the user to hit 'Share' on its screen.
                    // The camera successfully saved our IP to connect to port 1801.
                    self.isRegistered = true
                    self.statusMessage = "Aguardando aprovação na câmera..."
                    self.addLog(.info, "Câmera detectada! Confirme no visor da câmera.")
                }
                // We don't need to loop anymore, the camera knows we are here.
                return
                
            case .timeout:
                addLog(.warning, "Timeout na tentativa \(attempt)")
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
            
            case .error(let msg):
                addLog(.error, "Erro: \(msg)")
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        
        statusMessage = "Aguardando fotos (init pendente)..."
        addLog(.warning, "S2L init sem resposta — servidor continua escutando")
    }
    
    private enum S2LInitResult {
        case accepted
        case rejected(String)
        case timeout
        case error(String)
    }
    
    private func sendS2LInit(request: String) async -> S2LInitResult {
        let connection = NWConnection(
            host: NWEndpoint.Host(self.cameraIP),
            port: NWEndpoint.Port(rawValue: Self.s2lPort)!,
            using: self.makeWiFiTCP()
        )
        
        return await withTaskCancellationHandler {
            do {
                return try await withTimeout(seconds: 4) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<S2LInitResult, Error>) in
                        var done = false
                        
                        connection.stateUpdateHandler = { state in
                            guard !done else { return }
                            switch state {
                            case .ready:
                                connection.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
                                    if let error = error {
                                        done = true
                                        connection.cancel()
                                        continuation.resume(throwing: error)
                                        return
                                    }
                                    
                                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                                        guard !done else { return }
                                        done = true
                                        connection.cancel()
                                        
                                        if let error = error {
                                            self.addLog(.debug, "S2L [801]: Erro na recepção (\(error))")
                                            continuation.resume(throwing: error)
                                        } else if let content = content, let msg = String(data: content, encoding: .utf8) {
                                            self.addLog(.debug, "S2L [801] Resposta: \n\(msg.prefix(200))")
                                            if msg.contains("200 OK") || msg.contains("ACCEPTED") || msg.contains("Result_OK") {
                                                continuation.resume(returning: .accepted)
                                            } else {
                                                continuation.resume(returning: .rejected(msg))
                                            }
                                        } else {
                                            self.addLog(.debug, "S2L [801]: Resposta vazia")
                                            continuation.resume(returning: .error("Resposta vazia"))
                                        }
                                    }
                                })
                            case .failed(let error):
                                done = true
                                connection.cancel()
                                continuation.resume(throwing: error)
                            case .cancelled:
                                if !done {
                                    done = true
                                    continuation.resume(returning: .error("Cancelado"))
                                }
                            default:
                                break
                            }
                        }
                        connection.start(queue: self.queue)
                    }
                }
            } catch is TimeoutError {
                connection.cancel()
                return .timeout
            } catch {
                connection.cancel()
                return .error(error.localizedDescription)
            }
        } onCancel: {
            connection.cancel()
        }
    }
    
    // MARK: - Handle Incoming Image Push
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        DispatchQueue.main.async {
            self.addLog(.info, "Conexão recebida da câmera!")
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readS2LData(from: connection)
            case .failed(let error):
                DispatchQueue.main.async {
                    self.addLog(.error, "Conexão falhou: \(error)")
                    self.removeActiveConnection(connection)
                }
            case .cancelled:
                self.removeActiveConnection(connection)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func removeActiveConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }
    
    private func readS2LData(from connection: NWConnection) {
        // Read until we have the full header (terminated by \r\n\r\n)
        var buffer = Data()
        
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 102400) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                
                if let data {
                    buffer.append(data)
                }
                
                // Check if we have the header end
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                    let bodyStart = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
                    
                    let header = self.parseS2LHeader(headerData)
                    
                    DispatchQueue.main.async {
                        self.addLog(.debug, "Conexão S2L: \(header.request)")
                        self.addLog(.info, "Foto Detectada: \(header.filename ?? "NOME_DESCONHECIDO"), Tamanho: \(header.contentLength) bytes")
                    }
                    
                    // ByeBye message
                    if header.request.lowercased().contains("bye") {
                        DispatchQueue.main.async {
                            self.addLog(.warning, "Câmera enviou ByeBye")
                        }
                        connection.cancel()
                        return
                    }
                    
                    // If no file, send OK and close
                    guard let filename = header.filename, header.contentLength > 0 else {
                        let resp = self.buildS2LResponse(header: header, ok: true)
                        connection.send(content: resp, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    }
                    
                    // Read remaining file data
                    self.readFileData(
                        from: connection,
                        header: header,
                        filename: filename,
                        initialData: bodyStart
                    )
                } else if isComplete || error != nil {
                    // Connection closed before header complete
                    DispatchQueue.main.async {
                        self.addLog(.warning, "Conexão fechada antes do header completo (\(buffer.count) bytes)")
                    }
                    connection.cancel()
                } else {
                    // Need more data
                    readMore()
                }
            }
        }
        
        readMore()
    }
    
    private func readFileData(from connection: NWConnection, header: S2LHeader, filename: String, initialData: Data) {
        var fileData = initialData
        let totalSize = header.contentLength
        
        DispatchQueue.main.async {
            self.statusMessage = "Recebendo \(filename)..."
            self.addLog(.info, "Recebendo \(filename) (\(totalSize) bytes)...")
        }
        
        func readChunk() {
            let remaining = totalSize - fileData.count
            
            if remaining <= 0 {
                // File complete
                finishFileReceive(connection: connection, header: header, filename: filename, data: fileData)
                return
            }
            
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(102400, remaining)) { [weak self] data, _, isComplete, error in
                if let data {
                    fileData.append(data)
                }
                
                if fileData.count >= totalSize || isComplete || error != nil {
                    self?.finishFileReceive(connection: connection, header: header, filename: filename, data: fileData)
                } else {
                    readChunk()
                }
            }
        }
        
        readChunk()
    }
    
    private func finishFileReceive(connection: NWConnection, header: S2LHeader, filename: String, data: Data) {
        // Begin background task to ensure save completes even if app is backgrounded
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "AutoShare-Save-\(filename)") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        
        DispatchQueue.main.async {
            self.addLog(.success, "Recebido: \(filename) (\(data.count) bytes)")
            
            let photo = ReceivedPhoto(
                filename: filename,
                data: data,
                receivedAt: Date(),
                fileSize: data.count
            )
            self.receivedPhotos.insert(photo, at: 0)
            self.totalReceived += 1
            self.statusMessage = "AutoShare ativo — \(self.totalReceived) foto(s)"
            
            // Save to photo library
            Task {
                await SyncManager.shared.saveAutoSharePhoto(data: data, filename: filename)
                self.addLog(.success, "\(filename) salvo na galeria ✓")
                
                // End background task after save
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
        
        // Send OK response
        let resp = buildS2LResponse(header: header, ok: true)
        connection.send(content: resp, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    // MARK: - S2L Protocol Builders
    
    private func buildS2LRequest() -> String {
        let userAgent = "SEC_RVF_\(localMAC.replacingOccurrences(of: ":", with: ""))"
        return "S2L/1.0 Request\r\n" +
        "Host: SAMSUNG-S2L\r\n" +
        "Content-Type: text/xml;charset=utf-8\r\n" +
        "User-Agent: \(userAgent)\r\n" +
        "Content-Length: 0\r\n" +
        "HOST-Mac : \(localMAC)\r\n" +
        "HOST-Address : \(localIP)\r\n" +
        "HOST-port : \(Self.listenPort)\r\n" +
        "HOST-PNumber : none\r\n" +
        "Host-Gps : 0\r\n" +
        "Access-Method : manual\r\n" +
        "Authorization : none\r\n" +
        "Connection : Close\r\n" +
        "\r\n"
    }
    
    private struct S2LHeader {
        var request: String = ""
        var filename: String?
        var contentLength: Int = 0
        var host: String = "SAMSUNG-S2L"
        var authorization: String = "none"
    }
    
    private func parseS2LHeader(_ data: Data) -> S2LHeader {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        var header = S2LHeader()
        
        if let first = lines.first {
            header.request = first
            // Extract filename from "S2L/1.0 /path/filename.jpg"
            if let lastSlash = first.lastIndex(of: "/") {
                let fname = String(first[first.index(after: lastSlash)...]).trimmingCharacters(in: .whitespaces)
                if !fname.isEmpty && fname.contains(".") {
                    header.filename = fname
                }
            }
        }
        
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            
            switch key {
            case "content-length":
                header.contentLength = Int(value) ?? 0
            case "host":
                header.host = value
            case "authorization":
                header.authorization = value
            default:
                break
            }
        }
        
        return header
    }
    
    private func buildS2LResponse(header: S2LHeader, ok: Bool) -> Data {
        let result = ok ? "Result_OK" : "Result_Error"
        let code = ok ? "0" : "1"
        let resp = "S2L/1.0 \(result)\r\n" +
            "Host: \(header.host)\r\n" +
            "Content-length: \(header.contentLength)\r\n" +
            "Authorization: \(header.authorization)\r\n" +
            "Sub-ErrorCode: \(code)\r\n" +
            "\r\n"
        return resp.data(using: .utf8) ?? Data()
    }
    
    // MARK: - ByeBye
    
    private func sendByeBye() {
        let byebye = "S2L/1.0 ByeBye\r\n" +
            "Host: SAMSUNG-S2L\r\n" +
            "Content-Type: text/xml;charset=utf-8\r\n" +
            "User-Agent: APP-TYPE\r\n" +
            "Content-Length: 0\r\n" +
            "Connection: Close\r\n" +
            "\r\n"
        
        let connection = NWConnection(
            host: NWEndpoint.Host(cameraIP),
            port: NWEndpoint.Port(rawValue: Self.s2lPort)!,
            using: makeWiFiTCP()
        )
        
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: byebye.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        
        connection.start(queue: queue)
    }
    
    // MARK: - Helpers
    
    private func makeWiFiTCP() -> NWParameters {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }
    
    private func getLocalMAC() -> String {
        // iOS doesn't expose real MAC; use a placeholder
        "02:00:00:00:00:00"
    }
    
    /// Get the local IP address on the WiFi interface
    static func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let iface = ptr.pointee
            let family = iface.ifa_addr.pointee.sa_family
            
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    let addr = String(cString: hostname)
                    if addr.hasPrefix("192.168.") {
                        address = addr
                    }
                }
            }
            
            guard let next = iface.ifa_next else { break }
            ptr = next
        }
        
        return address
    }
    
    // MARK: - Logging
    
    func addLog(_ level: ConnectionLogEntry.Level, _ message: String) {
        let entry = ConnectionLogEntry(level: level, message: "[AutoShare] \(message)")
        logEntries.append(entry)
        if logEntries.count > 200 {
            logEntries.removeFirst(logEntries.count - 200)
        }
        
        // Forward to connection manager's log
        connectionManager?.addLog(level, "[AutoShare] \(message)")
        
        switch level {
        case .error: logger.error("\(message)")
        case .warning: logger.warning("\(message)")
        case .success, .info: logger.info("\(message)")
        case .debug: logger.debug("\(message)")
        }
    }
}
