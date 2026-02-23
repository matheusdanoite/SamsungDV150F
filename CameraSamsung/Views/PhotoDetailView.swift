//
//  PhotoDetailView.swift
//  CameraSamsung
//
//  Full-resolution image viewer with download capability and deletion from sync
//

import SwiftUI
import SwiftData
import Photos

struct PhotoDetailView: View {
    @Environment(CameraConnectionManager.self) private var manager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    let record: CameraMediaRecord
    
    @State private var fullImage: UIImage?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var showShareSheet = false
    @State private var savedToPhotos = false
    @State private var errorMessage: String?
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Image
                if let image = fullImage {
                    GeometryReader { geo in
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                                .gesture(
                                    MagnifyGesture()
                                        .onChanged { value in
                                            scale = value.magnification
                                        }
                                        .onEnded { _ in
                                            withAnimation(.spring()) {
                                                scale = max(1.0, min(scale, 5.0))
                                            }
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.spring()) {
                                        scale = scale > 1.0 ? 1.0 : 2.5
                                    }
                                }
                        }
                    }
                } else if let uiImage = record.thumbnailImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(
                            Group {
                                if isDownloading {
                                    downloadOverlay
                                }
                            }
                        )
                } else if record.status == .available,
                          let file = manager.cameraFiles.first(where: { $0.filename == record.filename }),
                          let thumbData = file.thumbnailData,
                          let uiImage = UIImage(data: thumbData) {
                    // Display transient thumbnail from memory
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(
                            Group {
                                if isDownloading {
                                    downloadOverlay
                                }
                            }
                        )
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: record.isVideo ? "video.fill" : "photo")
                            .font(.system(size: 60))
                            .foregroundColor(.cameraTextTertiary)
                        
                        if isDownloading {
                            downloadOverlay
                        }
                    }
                }
                
                // Error
                if let error = errorMessage {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.red.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(20)
                    }
                }
            }
            .navigationTitle(record.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                        .foregroundColor(.cameraAmber)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    deleteButton
                }
                
                ToolbarItemGroup(placement: .bottomBar) {
                    fileInfoButton
                    Spacer()
                    downloadButton
                    Spacer()
                    saveToPhotosButton
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Auto-load full image if available via AutoShare
            if fullImage == nil && !isDownloading {
                await loadOrDownloadFullImage()
            }
        }
    }
    
    // MARK: - Download Overlay
    
    private var downloadOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: downloadProgress)
                .tint(.cameraAmber)
                .frame(width: 200)
            
            Text("Baixando... \(Int(downloadProgress * 100))%")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Toolbar Items
    
    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: record.fileSize)
    }
    
    private var fileInfoButton: some View {
        VStack(spacing: 2) {
            Text(record.source == .autoShare ? "AutoShare" : "MobileLink")
                .font(.system(size: 11, design: .monospaced))
            
            Text(formattedSize)
                .font(.system(size: 10))
        }
        .foregroundColor(.cameraTextSecondary)
    }
    
    private var downloadButton: some View {
        Button {
            Task { await loadOrDownloadFullImage() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: fullImage != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 22))
                Text("Baixar")
                    .font(.system(size: 10))
            }
            .foregroundColor(fullImage != nil ? .cameraSuccess : .cameraAmber)
        }
        .disabled(isDownloading || fullImage != nil)
    }
    
    private var saveToPhotosButton: some View {
        Button {
            saveToPhotoLibrary()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: savedToPhotos || record.status == .synced ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 22))
                Text(record.status == .synced ? "Sincronizado" : "Salvar")
                    .font(.system(size: 10))
            }
            .foregroundColor(savedToPhotos || record.status == .synced ? .cameraSuccess : .cameraAmber)
        }
        .disabled(fullImage == nil || savedToPhotos || record.status == .synced)
    }
    
    private var deleteButton: some View {
        Button(role: .destructive) {
            record.status = .deleted
            try? modelContext.save()
            dismiss()
        } label: {
            Image(systemName: "trash")
                .foregroundColor(.red)
        }
    }
    
    // MARK: - Actions
    
    private func loadOrDownloadFullImage() async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        
        // If it's AutoShare, the thumbnail is the full image saved on disk
        if record.source == .autoShare, let image = record.thumbnailImage {
            if !record.isVideo {
                 fullImage = image
            }
            isDownloading = false
            return
        }
        
        // For MobileLink, we need to download from camera
        guard let activeFile = manager.cameraFiles.first(where: { $0.filename == record.filename }) else {
            errorMessage = "Arquivo não está ativo na câmera agora"
            isDownloading = false
            return
        }
        
        // Simulate progress visually
        let progressTask = Task {
            for i in 1...9 {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled {
                    downloadProgress = Double(i) * 0.1
                }
            }
        }
        
        do {
            let data = try await manager.downloadFile(activeFile)
            progressTask.cancel()
            downloadProgress = 1.0
            
            if !record.isVideo, let image = UIImage(data: data) {
                fullImage = image
            } else if record.isVideo {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(record.filename)
                try data.write(to: tempURL)
                savedToPhotos = true
                saveVideoToPhotos(url: tempURL)
            }
        } catch {
            progressTask.cancel()
            errorMessage = "Falha: \(error.localizedDescription)"
        }
        
        isDownloading = false
    }
    
    private func saveToPhotoLibrary() {
        guard let image = fullImage else { return }
        
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                Task { @MainActor in errorMessage = "Sem permissão para salvar fotos" }
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(
                    with: .photo,
                    data: image.jpegData(compressionQuality: 1.0) ?? Data(),
                    options: nil
                )
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        savedToPhotos = true
                        record.status = .synced
                        try? modelContext.save()
                    } else {
                        errorMessage = "Falha ao salvar: \(error?.localizedDescription ?? "Erro")"
                    }
                }
            }
        }
    }
    
    private func saveVideoToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(
                    with: .video,
                    fileURL: url,
                    options: nil
                )
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        savedToPhotos = true
                        record.status = .synced
                        try? modelContext.save()
                    } else {
                        errorMessage = "Falha ao salvar vídeo"
                    }
                }
            }
        }
    }
}
