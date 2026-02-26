//
//  SyncManager.swift
//  CameraSamsung
//
//  Manages automatic sync of camera photos to the iPhone photo library.
//  Tracks synced filenames via SwiftData and downloads new files.
//

import Foundation
import SwiftData
import Photos
import OSLog

private let logger = Logger(subsystem: "com.camerasamsung", category: "Sync")

/// Manages automatic synchronization of camera photos to the iPhone photo library
@MainActor
@Observable
final class SyncManager {
    @MainActor
    static let shared = SyncManager()
    
    // MARK: - Observable State
    
    private(set) var isSyncing = false
    private(set) var syncedCount = 0
    private(set) var totalToSync = 0
    private(set) var currentFileName = ""
    private(set) var lastSyncMessage = ""
    
    private init() {}
    
    // MARK: - Sync Logic
    
    /// Returns true if a file has already been synced or deleted
    func isSyncedOrDeleted(_ filename: String) -> Bool {
        let context = DatabaseManager.shared.context
        var fetchDescriptor = FetchDescriptor<CameraMediaRecord>()
        fetchDescriptor.predicate = #Predicate { $0.filename == filename }
        
        if let record = try? context.fetch(fetchDescriptor).first {
            return record.statusRaw == MediaStatus.synced.rawValue || record.statusRaw == MediaStatus.deleted.rawValue
        }
        return false
    }
    
    /// Returns true if a file has already been synced
    func isSynced(_ file: CameraFile) -> Bool {
        let context = DatabaseManager.shared.context
        let filename = file.filename
        var fetchDescriptor = FetchDescriptor<CameraMediaRecord>()
        fetchDescriptor.predicate = #Predicate { $0.filename == filename }
        
        if let record = try? context.fetch(fetchDescriptor).first {
            return record.statusRaw == MediaStatus.synced.rawValue
        }
        return false
    }
    
    /// Check which files are new (not yet synced) and return them
    func findNewFiles(in cameraFiles: [CameraFile]) -> [CameraFile] {
        return cameraFiles.filter { !isSyncedOrDeleted($0.filename) }
    }
    

    /// Sync all new files from the camera to the photo library
    func syncNewFiles(_ files: [CameraFile], using client: SamsungDLNAClient) async {
        let newFiles = findNewFiles(in: files)
        
        guard !newFiles.isEmpty else {
            lastSyncMessage = "Tudo sincronizado ✓"
            logger.info("No new files to sync")
            return
        }
        
        // Request photo library permission
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            lastSyncMessage = "Sem permissão para salvar fotos"
            logger.error("Photo library permission denied")
            return
        }
        
        isSyncing = true
        syncedCount = 0
        totalToSync = newFiles.count
        lastSyncMessage = "Sincronizando..."
        
        logger.info("Starting sync of \(newFiles.count) new files")
        
        for file in newFiles {
            guard let contentURL = file.contentURL, !contentURL.isEmpty else {
                logger.warning("Skipping \(file.filename): no content URL")
                continue
            }
            
            currentFileName = file.filename
            
            do {
                // Download full resolution
                let data = try await client.downloadFile(url: contentURL)
                
                // Save to Photos
                try await saveToPhotoLibrary(data: data, filename: file.filename, isVideo: file.isVideo)
                
                // Mark as synced in DB
                let context = DatabaseManager.shared.context
                let filename = file.filename
                var fetchDescriptor = FetchDescriptor<CameraMediaRecord>()
                fetchDescriptor.predicate = #Predicate { $0.filename == filename }
                
                if let record = try? context.fetch(fetchDescriptor).first {
                    record.status = .synced
                } else {
                    var thumbPath: String?
                    if let thumbData = file.thumbnailData {
                        thumbPath = ThumbnailManager.shared.saveThumbnail(data: thumbData, for: file.filename)
                    }
                    
                    let newRecord = CameraMediaRecord(
                        filename: file.filename,
                        source: .mobileLink,
                        status: .synced,
                        captureDate: file.parsedDate ?? Date(),
                        thumbnailLocalPath: thumbPath,
                        fileSize: Int64(file.fileSize),
                        isVideo: file.isVideo,
                        contentURL: file.contentURL,
                        thumbnailURL: file.thumbnailURL
                    )
                    context.insert(newRecord)
                }
                try? context.save()
                
                syncedCount += 1
                lastSyncMessage = "Sincronizado \(syncedCount)/\(totalToSync)"
                logger.info("Synced \(file.filename) (\(self.syncedCount)/\(self.totalToSync))")
                
            } catch {
                logger.error("Failed to sync \(file.filename): \(error.localizedDescription)")
                lastSyncMessage = "Erro ao sincronizar \(file.filename)"
            }
        }
        
        currentFileName = ""
        isSyncing = false
        lastSyncMessage = totalToSync == syncedCount
            ? "\(syncedCount) foto(s) sincronizada(s) ✓"
            : "\(syncedCount)/\(totalToSync) sincronizadas"
        
        logger.info("Sync complete: \(self.syncedCount)/\(self.totalToSync)")
    }
    
    /// Sync explicitly selected files from the camera to the photo library
    func syncSelectedFiles(_ files: [CameraFile], using client: SamsungDLNAClient) async {
        let filesToSync = files.filter { !isSyncedOrDeleted($0.filename) }
        
        guard !filesToSync.isEmpty else {
            lastSyncMessage = "Tudo sincronizado ✓"
            logger.info("No selected files to sync")
            return
        }
        
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            lastSyncMessage = "Sem permissão para salvar fotos"
            logger.error("Photo library permission denied")
            return
        }
        
        isSyncing = true
        syncedCount = 0
        totalToSync = filesToSync.count
        lastSyncMessage = "Baixando arquivos selecionados..."
        
        logger.info("Starting sync of \(filesToSync.count) selected files")
        
        for file in filesToSync {
            guard let contentURL = file.contentURL, !contentURL.isEmpty else {
                logger.warning("Skipping \(file.filename): no content URL")
                continue
            }
            
            currentFileName = file.filename
            
            do {
                let data = try await client.downloadFile(url: contentURL)
                try await saveToPhotoLibrary(data: data, filename: file.filename, isVideo: file.isVideo)
                
                // Mark as synced in DB
                let context = DatabaseManager.shared.context
                let filename = file.filename
                var fetchDescriptor = FetchDescriptor<CameraMediaRecord>()
                fetchDescriptor.predicate = #Predicate { $0.filename == filename }
                
                if let record = try? context.fetch(fetchDescriptor).first {
                    record.status = .synced
                } else {
                    var thumbPath: String?
                    if let thumbData = file.thumbnailData {
                        thumbPath = ThumbnailManager.shared.saveThumbnail(data: thumbData, for: file.filename)
                    }
                    
                    let newRecord = CameraMediaRecord(
                        filename: file.filename,
                        source: .mobileLink,
                        status: .synced,
                        captureDate: file.parsedDate ?? Date(),
                        thumbnailLocalPath: thumbPath,
                        fileSize: Int64(file.fileSize),
                        isVideo: file.isVideo,
                        contentURL: file.contentURL,
                        thumbnailURL: file.thumbnailURL
                    )
                    context.insert(newRecord)
                }
                try? context.save()
                
                syncedCount += 1
                lastSyncMessage = "Baixado \(syncedCount)/\(totalToSync)"
                logger.info("Synced \(file.filename) (\(self.syncedCount)/\(self.totalToSync))")
                
            } catch {
                logger.error("Failed to sync \(file.filename): \(error.localizedDescription)")
                lastSyncMessage = "Erro ao baixar \(file.filename)"
            }
        }
        
        currentFileName = ""
        isSyncing = false
        lastSyncMessage = totalToSync == syncedCount
            ? "\(syncedCount) fotos baixadas com sucesso ✓"
            : "\(syncedCount)/\(totalToSync) baixadas"
        
        logger.info("Selected sync complete: \(self.syncedCount)/\(self.totalToSync)")
    }
    
    // MARK: - Photo Library
    
    private func saveToPhotoLibrary(data: Data, filename: String, isVideo: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if isVideo {
                    // Write to temp file for video
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(filename)
                    try? data.write(to: tempURL)
                    request.addResource(with: .video, fileURL: tempURL, options: nil)
                } else {
                    request.addResource(with: .photo, data: data, options: nil)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "SyncManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to save photo"]))
                }
            }
        }
    }
    
    /// Save a photo received via AutoShare (S2L push) directly to the photo library
    func saveAutoSharePhoto(data: Data, filename: String) async {
        // Check if already processed
        guard !isSyncedOrDeleted(filename) else {
            logger.info("AutoShare: \(filename) already synced or deleted, skipping")
            return
        }
        
        // Request permission
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            logger.error("AutoShare: Photo library permission denied")
            return
        }
        
        let isVideo = filename.lowercased().hasSuffix(".mp4") || filename.lowercased().hasSuffix(".mov")
        
        do {
            try await saveToPhotoLibrary(data: data, filename: filename, isVideo: isVideo)
            
            // Mark as synced in DB
            let context = DatabaseManager.shared.context
            var fetchDescriptor = FetchDescriptor<CameraMediaRecord>()
            fetchDescriptor.predicate = #Predicate { $0.filename == filename }
            
            if let record = try? context.fetch(fetchDescriptor).first {
                record.status = .synced
                if record.thumbnailLocalPath == nil {
                    record.thumbnailLocalPath = ThumbnailManager.shared.saveThumbnail(data: data, for: filename)
                }
            } else {
                let thumbPath = ThumbnailManager.shared.saveThumbnail(data: data, for: filename)
                let newRecord = CameraMediaRecord(
                    filename: filename,
                    source: .autoShare,
                    status: .synced,
                    captureDate: Date(),
                    thumbnailLocalPath: thumbPath,
                    fileSize: Int64(data.count),
                    isVideo: isVideo,
                    contentURL: nil
                )
                context.insert(newRecord)
            }
            try? context.save()
            
            logger.info("AutoShare: Saved \(filename) to photo library")
        } catch {
            logger.error("AutoShare: Failed to save \(filename): \(error.localizedDescription)")
        }
    }
    
    /// Clear all sync history (for debugging/reset)
    func resetSyncHistory() {
        do {
            let context = DatabaseManager.shared.context
            try context.delete(model: CameraMediaRecord.self)
            try context.save()
            lastSyncMessage = "Histórico limpo"
        } catch {
            logger.error("Failed to reset history: \(error.localizedDescription)")
        }
    }
}
