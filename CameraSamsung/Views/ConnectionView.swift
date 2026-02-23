//
//  ConnectionView.swift
//  CameraSamsung
//
//  Connection status screen with camera detection, port scanning, and debug console
//

import SwiftUI

struct ConnectionView: View {
    @Environment(CameraConnectionManager.self) private var manager
    @State private var showDebugLog = false
    @State private var isScanning = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero Section
                    heroSection
                    
                    // Connection Status Card
                    statusCard
                    
                    // Action Buttons
                    actionButtons
                    
                    // Camera Info (when connected)
                    if manager.status.isConnected, let info = manager.ptpClient?.deviceInfo {
                        cameraInfoCard(info)
                    }
                    
                    // Discovered Services
                    if !manager.discoveredServices.isEmpty {
                        servicesCard
                    }
                    
                    // IP Configuration
                    
                    // Debug Console Toggle
                    debugToggle
                    
                    // Connection Log (always visible when toggled)
                    if showDebugLog {
                        connectionDebugConsole
                    }
                    
                    // PTP/IP Log
                    if showDebugLog, let client = manager.ptpClient {
                        ptpDebugConsole(client)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color.cameraDark)
            .navigationTitle("Conexão")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(spacing: 16) {
            CameraSymbol(size: 80)
                .padding(.top, 10)
            
            Text("Samsung DV150F")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.cameraTextPrimary)
            
            Text("Conecte seu iPhone à rede Wi-Fi da câmera\npara transferir fotos e usar o visor remoto")
                .font(.system(size: 14))
                .foregroundColor(.cameraTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
    }
    
    // MARK: - Status Card
    
    private var statusCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                
                Image(systemName: manager.status.systemImage)
                    .font(.system(size: 22))
                    .foregroundColor(statusColor)
                    .if(isAnimatingStatus) { view in
                        view.pulsing()
                    }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.cameraTextTertiary)
                    .textCase(.uppercase)
                    .tracking(1)
                
                Text(manager.status.displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.cameraTextPrimary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            if let ssid = manager.currentSSID {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("SSID")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.cameraTextTertiary)
                    Text(ssid)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.cameraTeal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(16)
        .glassCard()
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if manager.status.isConnected {
                Button {
                    manager.disconnect()
                } label: {
                    Label("Desconectar", systemImage: "wifi.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CameraButtonStyle(color: .cameraError))
            } else {
                Button {
                    Task {
                        await manager.connect()
                    }
                } label: {
                    Label("Conectar à Câmera", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CameraButtonStyle(color: .cameraAmber))
                .disabled(isConnecting)
            }
        }
    }
    
    // MARK: - Camera Info Card
    
    private func cameraInfoCard(_ info: PTPDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Informações da Câmera", systemImage: "camera")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.cameraAmber)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                infoItem(title: "Modelo", value: info.model)
                infoItem(title: "Fabricante", value: info.manufacturer)
                infoItem(title: "Versão", value: info.deviceVersion)
                infoItem(title: "Serial", value: info.serialNumber)
                infoItem(title: "Operações", value: "\(info.operationsSupported.count)")
                infoItem(title: "Formatos", value: "\(info.imageFormats.count)")
            }
        }
        .padding(16)
        .glassCard()
    }
    
    private func infoItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.cameraTextTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.cameraTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Services Card
    
    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Serviços Descobertos", systemImage: "network")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.cameraTeal)
            
            ForEach(manager.discoveredServices) { service in
                HStack {
                    Circle()
                        .fill(service.isAvailable ? Color.cameraSuccess : Color.cameraTextTertiary)
                        .frame(width: 8, height: 8)
                    
                    Text(":\(service.port)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.cameraTextSecondary)
                        .frame(width: 60, alignment: .leading)
                    
                    Text(service.name)
                        .font(.system(size: 13))
                        .foregroundColor(.cameraTextPrimary)
                    
                    Spacer()
                    
                    Text(service.isAvailable ? "Aberto" : "Fechado")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(service.isAvailable ? .cameraSuccess : .cameraTextTertiary)
                }
            }
        }
        .padding(16)
        .glassCard()
    }
    
    
    // MARK: - Debug Console
    
    private var debugToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                showDebugLog.toggle()
            }
        } label: {
            HStack {
                Label("Console de Debug", systemImage: "terminal")
                Spacer()
                Image(systemName: showDebugLog ? "chevron.up" : "chevron.down")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.cameraTextSecondary)
            .padding(16)
            .glassCard()
        }
    }
    
    private var connectionDebugConsole: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection Log")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.cameraTeal)
                
                Spacer()
                
                Text("\(manager.connectionLog.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.cameraTextTertiary)
                
                Button {
                    // Clear log - cannot clear directly but re-connect will reset
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.cameraTextTertiary)
                }
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(manager.connectionLog) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.formattedTime)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.cameraTextTertiary)
                                    .frame(width: 65, alignment: .leading)
                                
                                Text(entry.level.rawValue)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(connectionLogColor(for: entry.level))
                                
                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.cameraTextSecondary)
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(entry.id)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: manager.connectionLog.count) { _, _ in
                    if let last = manager.connectionLog.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.5))
        .glassCard(cornerRadius: 12)
    }
    
    private func ptpDebugConsole(_ client: PTPIPClient) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PTP/IP Log")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.cameraAmber)
                
                Spacer()
                
                Text("\(client.logEntries.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.cameraTextTertiary)
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(client.logEntries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.direction.rawValue)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(logColor(for: entry.direction))
                            
                            Text(entry.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cameraTextSecondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding(16)
        .background(Color.black.opacity(0.5))
        .glassCard(cornerRadius: 12)
    }
    
    // MARK: - Helpers
    
    private var statusColor: Color {
        switch manager.status {
        case .disconnected: return .cameraTextTertiary
        case .detectingNetwork: return .cameraAmber
        case .networkFound: return .cameraTeal
        case .connecting: return .cameraAmber
        case .connected: return .cameraSuccess
        case .autoShareActive: return .cameraTeal
        case .error: return .cameraError
        }
    }
    
    private var isAnimatingStatus: Bool {
        switch manager.status {
        case .detectingNetwork, .connecting: return true
        default: return false
        }
    }
    
    private var isConnecting: Bool {
        switch manager.status {
        case .detectingNetwork, .connecting: return true
        default: return false
        }
    }
    
    private func logColor(for direction: PTPLogEntry.Direction) -> Color {
        switch direction {
        case .sent: return .cameraAmber
        case .received: return .cameraTeal
        case .info: return .cameraTextSecondary
        case .error: return .cameraError
        }
    }
    
    private func connectionLogColor(for level: ConnectionLogEntry.Level) -> Color {
        switch level {
        case .info: return .cameraTeal
        case .success: return .cameraSuccess
        case .warning: return .cameraWarning
        case .error: return .cameraError
        case .debug: return .cameraTextTertiary
        }
    }
    
}

// MARK: - Conditional View Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
