//
//  CameraMediaRecord.swift
//  CameraSamsung
//
//  SwiftData model for storing local metadata of camera files
//

import Foundation
import SwiftData
import SwiftUI

/// Status of the media file
enum MediaStatus: String, Codable {
    case available // Only on camera, not downloaded yet
    case synced    // Downloaded and saved to Photo Library
    case deleted   // Deleted by the user; do not download again
}

/// Source of the media file
enum MediaSource: String, Codable {
    case autoShare
    case mobileLink
}

@Model
final class CameraMediaRecord {
    @Attribute(.unique)
    var filename: String        // Unique identifier (e.g. SAM_1234.JPG)
    
    var sourceRaw: String       // Core string to map to MediaSource
    var statusRaw: String       // Core string to map to MediaStatus
    var captureDate: Date       // Creation or capture date
    
    var thumbnailLocalPath: String? // Filename in Caches directory
    
    var fileSize: Int64
    var isVideo: Bool
    
    // DLNA URLs or PTP Handler (optional mapping)
    var contentURL: String?
    var thumbnailURL: String?
    
    var thumbnailImage: UIImage? {
        guard let path = thumbnailLocalPath else { return nil }
        return ThumbnailManager.shared.loadThumbnail(path: path)
    }
    
    var source: MediaSource {
        get { MediaSource(rawValue: sourceRaw) ?? .mobileLink }
        set { sourceRaw = newValue.rawValue }
    }
    
    var status: MediaStatus {
        get { MediaStatus(rawValue: statusRaw) ?? .available }
        set { statusRaw = newValue.rawValue }
    }
    
    init(filename: String,
         source: MediaSource,
         status: MediaStatus = .available,
         captureDate: Date = Date(),
         thumbnailLocalPath: String? = nil,
         fileSize: Int64 = 0,
         isVideo: Bool = false,
         contentURL: String? = nil,
         thumbnailURL: String? = nil) {
        self.filename = filename
        self.sourceRaw = source.rawValue
        self.statusRaw = status.rawValue
        self.captureDate = captureDate
        self.thumbnailLocalPath = thumbnailLocalPath
        self.fileSize = fileSize
        self.isVideo = isVideo
        self.contentURL = contentURL
        self.thumbnailURL = thumbnailURL
    }
}
