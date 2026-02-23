//
//  Theme.swift
//  CameraSamsung
//
//  Design system — dark-mode-first, camera-inspired aesthetic
//

import SwiftUI

// MARK: - Color Palette

extension Color {
    // Primary accents
    static let cameraAmber = Color(hue: 0.10, saturation: 0.85, brightness: 0.95)
    static let cameraGold = Color(hue: 0.12, saturation: 0.65, brightness: 0.90)
    static let cameraTeal = Color(hue: 0.49, saturation: 0.70, brightness: 0.75)
    
    // Backgrounds
    static let cameraDark = Color(hue: 0.0, saturation: 0.0, brightness: 0.08)
    static let cameraSurface = Color(hue: 0.0, saturation: 0.0, brightness: 0.12)
    static let cameraCard = Color(hue: 0.0, saturation: 0.0, brightness: 0.16)
    
    // Status
    static let cameraSuccess = Color(hue: 0.35, saturation: 0.70, brightness: 0.75)
    static let cameraWarning = Color(hue: 0.10, saturation: 0.80, brightness: 0.90)
    static let cameraError = Color(hue: 0.0, saturation: 0.75, brightness: 0.80)
    
    // Text
    static let cameraTextPrimary = Color.white
    static let cameraTextSecondary = Color.white.opacity(0.6)
    static let cameraTextTertiary = Color.white.opacity(0.35)
}

// MARK: - View Modifiers

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.05 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct CameraButtonStyle: ButtonStyle {
    var color: Color = .cameraAmber
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [color, color.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.3), value: configuration.isPressed)
    }
}

// MARK: - View Extensions

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
    
    func pulsing() -> some View {
        modifier(PulsingModifier())
    }
}

// MARK: - App Icon Symbol

struct CameraSymbol: View {
    var size: CGFloat = 60
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.cameraAmber, .cameraGold],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            Image(systemName: "camera.fill")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundColor(.white)
        }
        .shadow(color: .cameraAmber.opacity(0.4), radius: size * 0.2, x: 0, y: size * 0.05)
    }
}
