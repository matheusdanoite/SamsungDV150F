//
//  ContentView.swift
//  CameraSamsung
//
//  Main TabView container with Connection, Gallery, and Viewfinder tabs
//

import SwiftUI

struct ContentView: View {
    @Environment(CameraConnectionManager.self) private var manager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectionView()
                .tabItem {
                    Label("Conexão", systemImage: "wifi")
                }
                .tag(0)
            
            GalleryView()
                .tabItem {
                    Label("Galeria", systemImage: "photo.on.rectangle.angled")
                }
                .tag(1)
        }
        .tint(.cameraAmber)
        .onChange(of: manager.status) { _, newStatus in
            // Auto-switch based on detected mode
            if selectedTab == 0 {
                if newStatus.isConnected {
                    withAnimation { selectedTab = 1 } // Gallery tab
                }
            }
        }
        .task {
            // Auto-connect when app opens
            if manager.status == .disconnected {
                await manager.connect()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(CameraConnectionManager())
        .preferredColorScheme(.dark)
}
