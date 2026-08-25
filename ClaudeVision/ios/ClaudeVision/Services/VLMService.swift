import Foundation

/// Protocol abstracting communication with a VLM backend.
/// Both `ClaudeBridge` (PC server) and `DirectVLMClient` (direct API) conform to this.
protocol VLMService: AnyObject {
    var isConnected: Bool { get }
    
    // Callbacks
    var onReply: ((String, String?) -> Void)? { get set }    // (text, audioURL?)
    var onStatus: ((String) -> Void)? { get set }
    var onThinking: ((String) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    
    func connect() async
    func disconnect()
    func sendMessage(text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async
    func resetConversation()
}
