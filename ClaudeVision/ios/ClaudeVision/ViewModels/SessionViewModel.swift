import Foundation
import Combine
import UIKit
import MediaPlayer

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case listening = "Listening"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

@MainActor
class SessionViewModel: ObservableObject {
    @Published var state: SessionState = .disconnected
    @Published var transcript: [TranscriptMessage] = []
    @Published var currentTranscription: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false
    @Published var connectionMode: AppConnectionMode = .direct

    @Published var config: ClaudeConfig {
        didSet {
            bridge.updateConfig(config)
            speechManager.configureElevenLabs(
                apiKey: config.elevenLabsAPIKey,
                voiceId: config.elevenLabsVoiceId
            )
            speechManager.setVoice(config.elevenLabsVoiceId)
            speechManager.setPauseThreshold(config.speechPauseThreshold)
            connectionMode = config.appConnectionMode
            config.save()
        }
    }

    // Frame sources
    @Published var activeFrameSource: FrameSourceType = .iPhone {
        didSet { switchFrameSource() }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?

    // Mode system
    @Published var modeManager = ModeManager()

    // QR/Barcode toast
    @Published var codeToastMessage: String?
    @Published var codeToastDetectedCode: DetectedCode?

    let bridge: ClaudeBridge
    var directClient: DirectVLMClient?
    private var vlmService: VLMService {
        if config.appConnectionMode == .direct, let client = directClient {
            return client
        }
        return bridge
    }
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private var cancellables = Set<AnyCancellable>()

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        setupBindings()
        setupBridgeCallbacks()
        setupCodeDetection()
        setupRemoteCommandCenter()
        rayBanManager.startMonitoringRegistration()
        connectionMode = config.appConnectionMode
        if config.appConnectionMode == .direct {
            directClient = DirectVLMClient(config: config)
            setupDirectClientCallbacks()
        }
        speechManager.configureElevenLabs(
            apiKey: config.elevenLabsAPIKey,
            voiceId: config.elevenLabsVoiceId
        )

        // Forward Ray-Ban frames for SwiftUI reactivity
        rayBanManager.$latestImage
            .receive(on: RunLoop.main)
            .assign(to: &$rayBanFrame)

        // Forward Ray-Ban connection status
        rayBanManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .rayBan else { return }
                self.frameSourceStatus = status
            }
            .store(in: &cancellables)

        // Forward bridge connection state
        bridge.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self, self.config.appConnectionMode == .channel else { return }
                self.isConnected = connected
            }
            .store(in: &cancellables)
    }

    // MARK: - Bridge Callbacks

    private func setupBridgeCallbacks() {
        // When Claude replies via the channel
        bridge.onReply = { [weak self] text, audioUrl in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.transcript.append(TranscriptMessage(role: .assistant, text: text))
                self.isProcessing = false

                if let audioUrl, let url = URL(string: audioUrl) {
                    // Play TTS audio from channel server
                    self.state = .speaking
                    self.speechManager.playRemoteAudio(url: url) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isConnected, self.state == .speaking else { return }
                            if self.config.appConnectionMode != .voiceCommand {
                                self.startListening()
                            } else {
                                self.state = .idle
                            }
                        }
                    }
                } else {
                    // Fallback to local TTS
                    self.state = .speaking
                    self.speechManager.speak(text)
                    self.observeSpeechCompletion()
                }
            }
        }

        bridge.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == "connected" {
                    self.state = .idle
                    self.errorMessage = nil
                    try? AudioSessionManager.shared.configureForVoiceChat()
                    if self.config.appConnectionMode != .voiceCommand {
                        self.startActiveFrameSource()
                    } else {
                        // Delay audio routing slightly for Bluetooth in voice mode
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
                            // Wait for tap in Voice Command Mode
                            self.state = .idle
                        }
                    }
                }
            }
        }

        bridge.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.state = .disconnected
            }
        }
    }

    private func setupDirectClientCallbacks() {
        directClient?.onReply = { [weak self] text, audioUrl in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcript.append(TranscriptMessage(role: .assistant, text: text))
                self.isProcessing = false
                self.state = .speaking
                self.speechManager.speak(text)
                self.observeSpeechCompletion()
            }
        }
        directClient?.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == "connected" {
                    self.state = .idle
                    self.errorMessage = nil
                }
            }
        }
        directClient?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorMessage = error
                self.isProcessing = false
                self.state = .idle
            }
        }
    }

    // MARK: - QR/Barcode Detection

    private func setupCodeDetection() {
        cameraManager.$lastDetectedCode
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self else { return }
                self.handleDetectedCode(code)
            }
            .store(in: &cancellables)
    }

    private func handleDetectedCode(_ code: DetectedCode) {
        if modeManager.activeMode.id == "qr_scanner" {
            // In QR Scanner mode: automatically send to Claude
            let message = "I scanned a \(code.type) code: \(code.value). What is this?"
            Task { await self.sendText(message) }
        } else {
            // In other modes: show a toast notification
            codeToastDetectedCode = code
            codeToastMessage = "\(code.type): \(code.value)"
            // Auto-dismiss toast after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.codeToastDetectedCode?.timestamp == code.timestamp {
                    self?.codeToastMessage = nil
                    self?.codeToastDetectedCode = nil
                }
            }
        }
    }

    func sendCodeToChat(_ code: DetectedCode) {
        codeToastMessage = nil
        codeToastDetectedCode = nil
        let message = "I scanned a \(code.type) code: \(code.value). What is this?"
        Task { await self.sendText(message) }
    }

    // MARK: - Remote Commands (Glasses Taps)

    private func setupRemoteCommandCenter() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.toggleListening()
            }
            return .success
        }
        
        // Some headsets send explicit play/pause
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.toggleListening()
            }
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.toggleListening()
            }
            return .success
        }
    }

    func copyCodeToClipboard(_ code: DetectedCode) {
        UIPasteboard.general.string = code.value
        codeToastMessage = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.codeToastMessage = nil
            self?.codeToastDetectedCode = nil
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil

        if config.appConnectionMode == .direct {
            // Direct mode: no server needed
            if directClient == nil {
                directClient = DirectVLMClient(config: config)
                setupDirectClientCallbacks()
            }
            directClient?.updateConfig(config)
            await directClient?.connect()
            isConnected = true
            state = .idle
            try? AudioSessionManager.shared.configureForVoiceChat()
            startActiveFrameSource()
            return
        }

        // Channel mode: connect to PC server
        bridge.mode = .channel
        bridge.connectWebSocket()

        do {
            let health = try await bridge.checkHealth()
            if health.status == "ok" {
                print("[Session] Channel server health OK")
            }
        } catch {
            print("[Session] Health check failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        speechManager.stopListening()
        speechManager.stopSpeaking()
        if config.appConnectionMode != .voiceCommand {
            cameraManager.stop()
            rayBanManager.stop()
        }
        if config.appConnectionMode == .direct {
            directClient?.disconnect()
        } else {
            bridge.disconnect()
        }
        frameSourceStatus = .disconnected
        isConnected = false
        state = .disconnected
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    // MARK: - Frame Source

    private func switchFrameSource() {
        guard config.appConnectionMode != .voiceCommand else { return }
        
        cameraManager.stop()
        rayBanManager.stop()

        if activeFrameSource == .rayBan {
            // Reconfigure audio session for Bluetooth, then route mic
            try? AudioSessionManager.shared.configureForVoiceChat()
            // Retry mic routing after DAT SDK has had time to set up streaming
            // The SDK may reset the audio route when it starts
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
                }
            }
            if isConnected && !speechManager.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.startListening()
                }
            }
        }
        startActiveFrameSource()
    }

    private func startActiveFrameSource() {
        do {
            switch activeFrameSource {
            case .iPhone:
                cameraManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try cameraManager.start()
                frameSourceStatus = .connected
            case .rayBan:
                rayBanManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try rayBanManager.start()
            }
            errorMessage = nil
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Interrupt

    func interruptSpeaking() {
        speechManager.stopSpeaking()
        print("[Session] Speaking interrupted by user — resuming listening")
        // Brief delay for audio session to settle after stopping playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startListening()
        }
    }

    // MARK: - Voice

    func toggleListening() {
        if speechManager.isListening {
            speechManager.stopListening()
            state = .idle
        } else {
            startListening()
        }
    }

    func startListening() {
        if speechManager.isSpeaking {
            speechManager.stopSpeaking()
        }
        do {
            try speechManager.startListening()
            state = .listening
            errorMessage = nil
        } catch {
            errorMessage = "Mic: \(error.localizedDescription)"
        }
    }

    private func setupBindings() {
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .assign(to: &$currentTranscription)

        speechManager.onSpeechPause = { [weak self] text in
            Task { @MainActor in
                await self?.handleUserSpeech(text)
            }
        }

        speechManager.setPauseThreshold(config.speechPauseThreshold)

        NotificationCenter.default.publisher(for: .audioInterruptionBegan)
            .sink { [weak self] _ in
                self?.speechManager.stopListening()
                self?.speechManager.stopSpeaking()
                self?.state = .idle
            }
            .store(in: &cancellables)
    }

    // MARK: - Send Message

    func sendText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await handleUserSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleUserSpeech(_ text: String) async {
        guard !isProcessing else { return }
        isProcessing = true

        transcript.append(TranscriptMessage(role: .user, text: text))
        currentTranscription = ""
        state = .thinking
        errorMessage = nil

        // Prepend mode system prompt as context
        let modeContext = modeManager.activeMode.systemPrompt
        let systemPrompt = "[Mode: \(modeManager.activeMode.name)] \(modeContext)"

        // Grab latest frame
        var image: Data?
        let source: String
        
        if config.appConnectionMode == .voiceCommand {
            image = nil
            source = "glasses-mic"
        } else {
            switch activeFrameSource {
            case .iPhone:
                image = cameraManager.consumeFrame()
                source = "iphone"
            case .rayBan:
                image = rayBanManager.consumeFrame()
                source = "rayban"
            }
        }

        if config.appConnectionMode == .direct {
            // Direct mode: send to VLM API
            let recentHistory = Array(transcript.suffix(config.maxConversationHistory))
            await vlmService.sendMessage(
                text: text,
                imageData: image,
                systemPrompt: systemPrompt,
                history: recentHistory
            )
            print("[Session] Sent to direct VLM: \"\(text)\" with \(image != nil ? "image" : "no image") [mode: \(modeManager.activeMode.name)]")
            // Reply comes back via onReply callback

        } else if bridge.mode == .channel {
            let fullText = "\(systemPrompt)\n\nUser: \(text)"
            // Channel mode: send via WebSocket or HTTP upload
            if let imageData = image, imageData.count > 100_000 {
                do {
                    try await bridge.uploadImage(text: fullText, image: imageData, source: source)
                } catch {
                    print("[Session] Upload error, falling back to WS: \(error)")
                    bridge.sendMessage(text: fullText, image: imageData, source: source)
                }
            } else {
                bridge.sendMessage(text: fullText, image: image, source: source)
            }
            print("[Session] Sent to channel: \"\(text)\" with \(image != nil ? "image" : "no image") [mode: \(modeManager.activeMode.name)]")

        } else {
            // Gateway mode: REST fallback
            let fullText = "\(systemPrompt)\n\nUser: \(text)"
            do {
                let response = try await bridge.chatREST(text: fullText, images: image.map { [$0] } ?? [])
                transcript.append(TranscriptMessage(
                    role: .assistant,
                    text: response.text,
                    toolCalls: response.tool_calls
                ))
                state = .speaking
                speechManager.speak(response.text)
                observeSpeechCompletion()
            } catch {
                errorMessage = error.localizedDescription
                state = .idle
            }
            isProcessing = false
        }
    }

    private func observeSpeechCompletion() {
        speechManager.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected, self.state == .speaking else { return }
                if self.config.appConnectionMode != .voiceCommand {
                    self.startListening()
                } else {
                    self.state = .idle
                }
            }
            .store(in: &cancellables)
    }

    func resetConversation() async {
        transcript.removeAll()
        bridge.resetConversation()
        directClient?.resetConversation()
        errorMessage = nil
    }
}
