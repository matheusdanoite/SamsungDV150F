//
//  CameraSamsungApp.swift
//  CameraSamsung
//
//  Samsung DV150F Wi-Fi Camera Companion App
//

import SwiftUI
import SwiftData

@main
struct CameraSamsungApp: App {
    @State private var connectionManager = CameraConnectionManager.shared
    
    init() {
        // Start silent audio loop to allow the app to run in the background
        BackgroundAudioManager.shared.startSilentPlayback()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .preferredColorScheme(.dark)
        }
        .modelContainer(DatabaseManager.shared.container)
    }
}
