//
//  BackgroundAudioManager.swift
//  CameraSamsung
//
//  Plays a silent audio file in loop to keep the app alive in background
//  while connected to the camera. Uses .mixWithOthers so it doesn't
//  interrupt Spotify, Apple Music, etc.
//
//  Reinforced with interruption handling to prevent termination.
//

import Foundation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.camerasamsung", category: "BackgroundAudio")

@Observable
final class BackgroundAudioManager: NSObject {
    static let shared = BackgroundAudioManager()
    
    private(set) var isPlaying = false
    private var audioPlayer: AVAudioPlayer?
    
    private override init() {
        super.init()
        setupInterruptionObserver()
    }
    
    /// Configure audio session for background playback mixed with other audio
    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // .playback is required for background audio
            // .mixWithOthers allows other apps to keep playing music
            // .allowBluetooth and .defaultToSpeaker make route assignment more resilient
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true)
            logger.info("Audio session configured for background playback")
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
    
    /// Start playing silent audio in loop to keep app alive
    func startSilentPlayback() {
        guard !isPlaying else { return }
        
        guard let url = Bundle.main.url(forResource: "1-second-of-silence", withExtension: "mp3") else {
            logger.error("Silent audio file not found in bundle")
            return
        }
        
        do {
            configureAudioSession()
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1  // Loop forever
            audioPlayer?.volume = 0.01  // Extremely low but not absolute zero to ensure system treats as active audio
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            isPlaying = true
            logger.info("Silent background audio started")
        } catch {
            logger.error("Failed to start silent audio: \(error.localizedDescription)")
        }
    }
    
    /// Stop silent audio playback
    func stopSilentPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        logger.info("Silent background audio stopped")
    }
    
    // MARK: - Interruption Handling
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        // Just force play to resume if a route changed (e.g. bluetooth dropped)
        if isPlaying {
            logger.info("Audio route changed, ensuring playback continues")
            audioPlayer?.play()
        }
    }
    
    @objc private func handleMediaServicesReset(notification: Notification) {
        logger.warning("Media services were reset. Reconfiguring audio...")
        if isPlaying {
            // Need to completely rebuild the audio player since the old one is dead
            isPlaying = false
            audioPlayer = nil
            startSilentPlayback()
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            logger.info("Audio interruption began")
            // System already paused the player
        case .ended:
            logger.info("Audio interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                logger.info("Resuming silent playback after interruption")
                audioPlayer?.play()
            }
        @unknown default:
            break
        }
    }
}
