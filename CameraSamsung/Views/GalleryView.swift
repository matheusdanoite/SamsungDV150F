//
//  GalleryView.swift
//  CameraSamsung
//
//  Grid view of photos/videos from the local database
//

import SwiftUI
import SwiftData

struct GalleryView: View {
    @Environment(CameraConnectionManager.self) private var manager
    @Environment(\.modelContext) private var modelContext
    
    // Fetch all synced media
    @Query(filter: #Predicate<CameraMediaRecord> { $0.statusRaw == "synced" },
           sort: \CameraMediaRecord.captureDate, order: .reverse)
    private var syncedRecords: [CameraMediaRecord]
    
    // Combined list of transient and synced files for display
    private var displayRecords: [CameraMediaRecord] {
        var records: [CameraMediaRecord] = syncedRecords
        
        // Gather exact filenames already in DB
        let syncedFilenames = Set(syncedRecords.map { $0.filename })
        
        // Add transient files that haven't been synced yet
        for file in manager.cameraFiles {
            // Skip if we already have this exact filename synced
            if !syncedFilenames.contains(file.filename) {
                let transientRecord = CameraMediaRecord(
                    filename: file.filename,
                    source: .mobileLink,
                    status: .available,
                    captureDate: file.parsedDate ?? Date(),
                    thumbnailLocalPath: nil,
                    fileSize: Int64(file.fileSize),
                    isVideo: file.isVideo,
                    contentURL: file.contentURL,
                    thumbnailURL: file.thumbnailURL
                )
                records.append(transientRecord)
            }
        }
        
        return records.sorted { $0.captureDate > $1.captureDate }
    }
    
    @State private var selectedRecord: CameraMediaRecord?
    @State private var isRefreshing = false
    @State private var selectionMode = false
    @State private var selectedRecords = Set<String>() // Use filename for selection since transient records may be recreated
    
    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.cameraDark
                    .ignoresSafeArea()
                
                Group {
                    if !manager.status.isConnected && displayRecords.isEmpty {
                        notConnectedView
                    } else if manager.isLoadingFiles && displayRecords.isEmpty {
                        loadingView
                    } else if displayRecords.isEmpty {
                        emptyView
                    } else {
                        galleryGrid
                    }
                }
                
                if selectionMode && !selectedRecords.isEmpty {
                    downloadBottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Galeria")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if manager.status.isConnected && !displayRecords.isEmpty {
                    if !selectionMode {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                selectionMode = true
                            } label: {
                                Text("Selecionar")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.cameraAmber)
                            }
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                selectionMode = false
                                selectedRecords.removeAll()
                            } label: {
                                Text("Cancelar")
                                    .font(.system(size: 16))
                                    .foregroundColor(.cameraTextSecondary)
                            }
                        }
                    }
                }
                
                if manager.status.isConnected && !selectionMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                isRefreshing = true
                                await manager.loadFiles()
                                isRefreshing = false
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.cameraAmber)
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        }
                    }
                }
            }
            .sheet(item: $selectedRecord) { record in
                PhotoDetailView(record: record)
                    .environment(manager)
            }
            .task {
                if manager.status.isConnected && displayRecords.isEmpty {
                    await manager.loadFiles()
                }
                cleanupAvailableRecords()
            }
        }
    }
    
    // Call this to clean up any legacy DB state when the view loads
    private func cleanupAvailableRecords() {
        let context = modelContext
        let availableStatus = MediaStatus.available.rawValue
        var descriptor = FetchDescriptor<CameraMediaRecord>()
        descriptor.predicate = #Predicate { $0.statusRaw == availableStatus }
        
        if let staleRecords = try? context.fetch(descriptor) {
            for record in staleRecords {
                context.delete(record)
            }
            try? context.save()
        }
    }
    
    // MARK: - Gallery Grid
    
    private var galleryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Sync status bar
                syncStatusBar
                
                // Active AutoShare indicator (if applicable)
                if manager.autoShareClient?.isActive == true {
                    autoShareIndicator
                }
                
                // Photos
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(displayRecords.count) arquivos")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.cameraTextSecondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(displayRecords) { record in
                            thumbnailCell(record)
                                .onTapGesture {
                                    if selectionMode {
                                        if selectedRecords.contains(record.filename) {
                                            selectedRecords.remove(record.filename)
                                        } else {
                                            selectedRecords.insert(record.filename)
                                        }
                                    } else {
                                        selectedRecord = record
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    // MARK: - AutoShare active indicator
    
    private var autoShareIndicator: some View {
        HStack {
            Label("AutoShare Ativo", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.cameraTeal)
            
            Spacer()
            
            Text("Ao vivo")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.cameraSuccess)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.cameraSuccess.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - Thumbnail Cell
    
    private func thumbnailCell(_ record: CameraMediaRecord) -> some View {
        let isSelected = selectedRecords.contains(record.filename)
        return GeometryReader { geo in
            ZStack {
                // Image layer
                if let uiImage = record.thumbnailImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else if record.status == .available,
                          let file = manager.cameraFiles.first(where: { $0.filename == record.filename }),
                          let thumbData = file.thumbnailData,
                          let uiImage = UIImage(data: thumbData) {
                    // Display transient thumbnail from memory
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else if let thumbnailURL = record.thumbnailURL, !thumbnailURL.isEmpty, let url = URL(string: thumbnailURL) {
                    // DLNA fallback to thumbnailURL string
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.width)
                                .clipped()
                        case .failure:
                            Rectangle().fill(Color.cameraCard)
                                .overlay(
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.cameraTextTertiary)
                                )
                        case .empty:
                            Rectangle().fill(Color.cameraCard)
                                .overlay(ProgressView().tint(.cameraAmber))
                        @unknown default:
                            Rectangle().fill(Color.cameraCard)
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.cameraCard)
                        .overlay(
                            Image(systemName: record.isVideo ? "video.fill" : "photo")
                                .foregroundColor(.cameraTextTertiary)
                        )
                }
                
                // Video indicator
                if record.isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            
                            Text(formatSize(record.fileSize))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                
                // Filename overlay
                VStack {
                    Spacer()
                    Text(record.filename)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.4))
                }
                
                // Synced badge
                if record.status == .synced {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.cameraSuccess)
                                .shadow(color: .black.opacity(0.6), radius: 2)
                                .padding(4)
                        }
                        Spacer()
                    }
                }
                
                // Source badge (AutoShare vs MobileLink)
                VStack {
                    HStack {
                        Text(record.source == .autoShare ? "A" : "M")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(record.source == .autoShare ? Color.cameraTeal : Color.cameraAmber)
                            .clipShape(Circle())
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
                
                // Selection overlay
                if selectionMode {
                    Rectangle()
                        .fill(isSelected ? Color.cameraAmber.opacity(0.3) : Color.black.opacity(0.1))
                        .animation(.easeInOut(duration: 0.1), value: isSelected)
                    
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundColor(isSelected ? .cameraAmber : .white.opacity(0.8))
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    // MARK: - State Views
    
    private var downloadBottomBar: some View {
        VStack {
            Button {
                Task {
                    guard let dlna = manager.dlnaClient else { return }
                    selectionMode = false
                    
                    // Create an array of selected CameraMediaRecord based on the selected filenames
                    let currentDisplayRecords = displayRecords
                    let recordsToDownload = currentDisplayRecords
                        .filter { selectedRecords.contains($0.filename) }
                        .sorted(by: { $0.captureDate < $1.captureDate })
                        
                    // Convert CameraMediaRecord to CameraFile for the SyncManager
                    let filesToDownload = recordsToDownload.map { record in
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
                        let dateString = formatter.string(from: record.captureDate)
                        
                        return CameraFile(
                            handle: 0,
                            name: record.filename,
                            format: record.isVideo ? .mp4 : .jpeg,
                            size: Int64(record.fileSize),
                            width: 0,
                            height: 0,
                            captureDate: dateString,
                            thumbnailURL: record.thumbnailURL,
                            contentURL: record.contentURL
                        )
                    }
                    
                    selectedRecords.removeAll()
                    await SyncManager.shared.syncSelectedFiles(filesToDownload, using: dlna)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Baixar \(selectedRecords.count) selecionada(s)")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.cameraAmber)
                .foregroundColor(.black)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.7), .black], startPoint: .top, endPoint: .bottom)
        )
    }
    
    private var syncStatusBar: some View {
        Group {
            let sync = SyncManager.shared
            if sync.isSyncing {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.cameraAmber)
                            .rotationEffect(.degrees(sync.isSyncing ? 360 : 0))
                            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: sync.isSyncing)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Importando Fotos")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.cameraTextPrimary)
                            
                            if !sync.currentFileName.isEmpty {
                                Text(sync.currentFileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.cameraTextTertiary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                        
                        Text("\(sync.syncedCount) / \(sync.totalToSync)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.cameraAmber)
                    }
                    
                    ProgressView(value: Double(sync.syncedCount), total: Double(max(sync.totalToSync, 1)))
                        .tint(.cameraAmber)
                        .background(Color.white.opacity(0.1))
                        .scaleEffect(x: 1, y: 1.5, anchor: .center)
                        .clipShape(Capsule())
                }
                .padding(14)
                .glassCard()
                .padding(.horizontal, 16)
            } else if !sync.lastSyncMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: sync.lastSyncMessage.contains("✓") ? "checkmark.circle.fill" : "info.circle")
                        .foregroundColor(sync.lastSyncMessage.contains("✓") ? .cameraSuccess : .cameraAmber)
                    
                    Text(sync.lastSyncMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.cameraTextSecondary)
                    
                    Spacer()
                }
                .padding(12)
                .glassCard()
                .padding(.horizontal, 16)
            }
        }
    }
    
    private var notConnectedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 50))
                .foregroundColor(.cameraTextTertiary)
            
            Text("Não Conectado")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.cameraTextPrimary)
            
            Text("Conecte-se à câmera na aba Conexão\npara visualizar as fotos e receber via AutoShare")
                .font(.system(size: 14))
                .foregroundColor(.cameraTextSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(.cameraAmber)
            
            Text("Carregando arquivos...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.cameraTextSecondary)
            Spacer()
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 50))
                .foregroundColor(.cameraTextTertiary)
            
            Text("Nenhum Arquivo")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.cameraTextPrimary)
            
            Text("Nenhuma foto salva pelo AutoShare\nou encontrada na câmera (MobileLink)")
                .font(.system(size: 14))
                .foregroundColor(.cameraTextSecondary)
                .multilineTextAlignment(.center)
            
            if manager.status.isConnected {
                Button {
                    Task { await manager.loadFiles() }
                } label: {
                    Label("Tentar Novamente", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CameraButtonStyle())
            }
            
            Spacer()
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
