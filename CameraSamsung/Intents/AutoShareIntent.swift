//
//  AutoShareIntent.swift
//  CameraSamsung
//
//  App Intent to trigger AutoShare connection from Shortcuts or Automations.
//

import AppIntents
import Foundation

struct ConnectAutoShareIntent: AppIntent {
    static var title: LocalizedStringResource = "Conectar ao AutoShare"
    static var description = IntentDescription("Inicia a conexão AutoShare com a câmera Samsung.")
    static var openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = CameraConnectionManager.shared
        
        // Start connection process
        await manager.connect()
        
        // Wait briefly for status update
        try? await Task.sleep(for: .seconds(2))
        
        let message: String
        switch manager.status {
        case .connected, .autoShareActive:
            message = "Conectado com sucesso!"
        case .error(let err):
            message = "Erro ao conectar: \(err)"
        default:
            message = "Status: \(manager.status.displayText)"
        }
        
        return .result(value: message)
    }
}

struct AutoShareShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectAutoShareIntent(),
            phrases: [
                "Conectar ao AutoShare em \(.applicationName)",
                "Ativar AutoShare da Câmera em \(.applicationName)",
                "Conectar Câmera Samsung em \(.applicationName)"
            ],
            shortTitle: "Conectar AutoShare",
            systemImageName: "wifi"
        )
    }
}
