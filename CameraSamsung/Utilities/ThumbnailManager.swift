//
//  ThumbnailManager.swift
//  CameraSamsung
//

import Foundation
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.camerasamsung", category: "Thumbnails")

final class ThumbnailManager {
    static let shared = ThumbnailManager()
    
    private let fileManager = FileManager.default
    
    private var cacheDirectory: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails")
    }
    
    init() {
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Saves thumbnail data to disk and returns the relative path (filename)
    func saveThumbnail(data: Data, for filename: String) -> String? {
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            return filename
        } catch {
            logger.error("Failed to save thumbnail for \(filename): \(error)")
            return nil
        }
    }
    
    /// Loads thumbnail image from disk
    func loadThumbnail(path: String) -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }
    
    /// Returns the full URL for a given relative path
    func url(for path: String) -> URL {
        cacheDirectory.appendingPathComponent(path)
    }
    
    /// Deletes a thumbnail from disk
    func deleteThumbnail(path: String) {
        let fileURL = cacheDirectory.appendingPathComponent(path)
        try? fileManager.removeItem(at: fileURL)
    }
}
