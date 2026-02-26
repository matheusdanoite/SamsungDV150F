//
//  DatabaseManager.swift
//  CameraSamsung
//
//  Provides globally accessible CoreData/SwiftData container
//

import SwiftData
import Foundation

@MainActor
final class DatabaseManager {
    static let shared = DatabaseManager()
    
    let container: ModelContainer
    
    private init() {
        do {
            let schema = Schema([CameraMediaRecord.self])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
    
    var context: ModelContext {
        container.mainContext
    }
}
