//
//  CameraFile.swift
//  CameraSamsung
//
//  Model representing a photo/video file on the camera
//

import Foundation
import SwiftUI

/// Represents a file (photo or video) stored on the Samsung camera
struct CameraFile: Identifiable, Hashable {
    let id: UInt32  // PTP object handle or index
    let filename: String
    let format: PTPObjectFormat
    let fileSize: UInt32
    let imageWidth: UInt32
    let imageHeight: UInt32
    let captureDate: String
    var thumbnailData: Data?
    
    /// DLNA-specific URLs (when connected via Samsung DLNA)
    var thumbnailURL: String?
    var contentURL: String?
    
    var isImage: Bool { format.isImage }
    var isVideo: Bool { format.isVideo }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }
    
    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: captureDate)
    }
    
    var displayDate: String {
        guard let date = parsedDate else { return captureDate }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var thumbnailImage: Image? {
        guard let data = thumbnailData,
              let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }
    
    var resolution: String {
        "\(imageWidth) × \(imageHeight)"
    }
    
    /// Convenience init for DLNA media items
    init(handle: UInt32, name: String, format: PTPObjectFormat, size: Int64,
         width: Int, height: Int, captureDate: String,
         thumbnailURL: String? = nil, contentURL: String? = nil) {
        self.id = handle
        self.filename = name
        self.format = format
        self.fileSize = UInt32(min(size, Int64(UInt32.max)))
        self.imageWidth = UInt32(width)
        self.imageHeight = UInt32(height)
        self.captureDate = captureDate
        self.thumbnailURL = thumbnailURL
        self.contentURL = contentURL
    }
}
